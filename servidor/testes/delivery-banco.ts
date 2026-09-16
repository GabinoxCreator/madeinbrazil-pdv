// Testa as migrations do PDV + delivery num Postgres em memória (PGlite).
// Uso (precisa de bun + @electric-sql/pglite): MIGRATIONS=servidor/migrations bun servidor/testes/delivery-banco.ts
import { PGlite } from "@electric-sql/pglite";
import { readdirSync, readFileSync } from "fs";

const DIR = process.env.MIGRATIONS!;
const db = new PGlite();
let passou = 0, falhou = 0;

const sql = async (q: string, params: any[] = []) => (await db.query(q, params)).rows as any[];
const um = async (q: string, params: any[] = []) => Object.values((await sql(q, params))[0] ?? {})[0] as any;

async function como<T>(papel: "anon" | "authenticated" | "service_role", sub: string | null, fn: () => Promise<T>) {
  await db.exec("RESET ROLE");
  await sql("select set_config('request.jwt.claim.sub', $1, false)", [sub ?? ""]);
  await db.exec(`SET ROLE ${papel}`);
  try { return await fn(); } finally { await db.exec("RESET ROLE"); }
}

async function ok<T>(nome: string, fn: () => Promise<T>, conferir?: (r: T) => boolean | string) {
  try {
    const r = await fn();
    const c = conferir ? conferir(r) : true;
    if (c !== true) throw new Error(typeof c === "string" ? c : "resultado inesperado: " + JSON.stringify(r).slice(0, 400));
    passou++; console.log("✅", nome);
    return r;
  } catch (e: any) { falhou++; console.log("❌", nome, "→", e.message); return undefined as any; }
}
async function recusa(nome: string, fn: () => Promise<any>, trecho?: string) {
  try { await fn(); falhou++; console.log("❌", nome, "→ deveria ter sido recusado"); }
  catch (e: any) {
    if (trecho && !String(e.message).includes(trecho)) { falhou++; console.log("❌", nome, "→ recusado com outra mensagem:", e.message); }
    else { passou++; console.log("✅", nome, "· recusado:", String(e.message).slice(0, 100)); }
  }
}

// ---------------------------------------------------------------- ambiente Supabase mínimo
await db.exec(`
  CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
  GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
  CREATE SCHEMA auth; GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
  CREATE TABLE auth.users (id uuid PRIMARY KEY, email text);
  CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
  -- Storage mínimo (só as colunas que as políticas do dlv-fotos usam), com RLS ligado como no Supabase.
  -- O dlv-fotos já existe com configuração errada para provar o ON CONFLICT DO UPDATE.
  CREATE SCHEMA storage; GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
  CREATE TABLE storage.buckets (id text PRIMARY KEY, name text NOT NULL, public boolean NOT NULL DEFAULT false, file_size_limit bigint, allowed_mime_types text[]);
  CREATE TABLE storage.objects (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), bucket_id text REFERENCES storage.buckets(id), name text NOT NULL, owner uuid);
  ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
  GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO anon, authenticated, service_role;
  GRANT SELECT ON storage.buckets TO anon, authenticated, service_role;
  INSERT INTO storage.buckets (id, name, public) VALUES ('dlv-fotos', 'dlv-fotos', false), ('outro', 'outro', false);
`);

// Três fases, igual ao servidor real: (1) tudo ANTES da migration de tamanhos, cria pedidos com os
// pratos antigos ("Filé de Frango Média"...); (2) tamanhos, cria pedidos com variação ("Filé de Frango
// (Média)" + Empanado); (3) variações e o resto.
const CORTE_TAMANHOS = "20260915090000";
const CORTE_VARIACOES = "20260915120000";
const arquivos = readdirSync(DIR).filter((f) => f.endsWith(".sql")).sort();
async function aplicar(lista: string[]) {
  for (const f of lista) {
    try { await db.exec(readFileSync(`${DIR}/${f}`, "utf8")); console.log("📦", f); }
    catch (e: any) { console.log("💥 migration falhou:", f, "→", e.message); process.exit(1); }
  }
}
await aplicar(arquivos.filter((f) => f < CORTE_TAMANHOS));

// ---------------------------------------------------------------- dados de teste
const PAINEL = "11111111-1111-1111-1111-111111111111";
const ESTRANHO = "22222222-2222-2222-2222-222222222222";
const TERMINAL = "33333333-3333-3333-3333-333333333333";
await db.exec(`
  INSERT INTO auth.users (id) VALUES ('${PAINEL}'), ('${ESTRANHO}'), ('${TERMINAL}');
  INSERT INTO public.pdv_panel_users (user_id, display_name, role) VALUES ('${PAINEL}', 'Caixa Teste', 'caixa');
  INSERT INTO public.pdv_terminal_accounts (user_id, terminal_id) SELECT '${TERMINAL}', id FROM public.pdv_terminals LIMIT 1;
  UPDATE public.dlv_settings SET value = 'aberta' WHERE key = 'store_mode';
  -- a bateria cria dezenas de pedidos em segundos: limite geral alto aqui, testado na seção 12
  UPDATE public.dlv_settings SET value = '1000' WHERE key = 'max_orders_per_window';
`);

const perto = { lat: -20.8200, lng: -49.3752 };  // ~0,6 km
const cinco = { lat: -20.8592, lng: -49.3752 };  // ~5 km → faixa até 7 km = R$ 10
const longe = { lat: -20.9500, lng: -49.3752 };  // ~15 km

// ---------------------------------------------------------------- 0. pedidos antigos, antes dos tamanhos
console.log("\n— Pedidos antigos (antes da migration de tamanhos)");
const itemAnota = (a: string) => um("select id from dlv_items where anota_id = $1", [a]);
const opcaoNome = (g: string, n: string) => um("select o.id from dlv_options o join dlv_option_groups g on g.id = o.group_id where g.name = $1 and o.name = $2", [g, n]);
// ids buscados como dono do banco (o anônimo não lê tabela nenhuma)
const ids = {
  frangoM: await itemAnota("68b70ba8ef53a8516017b871"), frangoP: await itemAnota("68b70ba8ef53a8516017b86c"), batata: await itemAnota("68b70ba8ef53a8516017b8ca"),
  grelhado: await opcaoNome("Escolhe seu Filé de Frango", "Grelhado"), empanado: await opcaoNome("Escolhe seu Filé de Frango", "Empanado"),
  macarrao: await opcaoNome("Escolha o Acompanhamento", "Macarrão"), farofa: await opcaoNome("Escolha o Acompanhamento", "Farofa"),
  batataAcomp: await opcaoNome("Escolha o Acompanhamento", "Batata Frita"), coca: await opcaoNome("Bebidas", "Coca-Cola 200ml"),
};
const antigoA = await ok("pedido antigo com 'Filé de Frango Média' (2 acompanhamentos + coca)", () => como("anon", null, () => um("select dlv_criar_pedido($1)", [JSON.stringify({
  modo: "entrega", cliente: { nome: "Antigo A", telefone: "17911110001" },
  endereco: { rua: "Rua Antiga", numero: "1", ...perto }, pagamento: { forma: "dinheiro", troco_para_cents: 5000 },
  itens: [{ item_id: ids.frangoM, quantidade: 1, opcoes: [
    { opcao_id: ids.grelhado },
    { opcao_id: ids.macarrao },
    { opcao_id: ids.farofa },
    { opcao_id: ids.coca }] }],
})])), (r: any) => r.subtotal_cents === 3040 && r.status === "em_producao" || JSON.stringify(r));
const antigoB = await ok("pedido antigo com 'Filé de Frango Pequena' + porção de batata", () => como("anon", null, () => um("select dlv_criar_pedido($1)", [JSON.stringify({
  modo: "retirada", cliente: { nome: "Antigo B", telefone: "17911110002" }, pagamento: { forma: "credito" },
  itens: [
    { item_id: ids.frangoP, quantidade: 2, opcoes: [
      { opcao_id: ids.empanado },
      { opcao_id: ids.batataAcomp }] },
    { item_id: ids.batata, quantidade: 1 }],
})])), (r: any) => r.subtotal_cents === 2 * 2590 + 3490 || JSON.stringify(r));
const fotoPedidos = (pedidos: string[]) => sql(`
  select o.number, o.status, o.subtotal_cents, o.total_cents, oi.item_id, oi.item_name, to_jsonb(oi) ->> 'size_id' as size_id, to_jsonb(oi) ->> 'size_name' as size_name, oi.quantity, oi.unit_price_cents, oi.total_cents as linha,
         oi.production_point_id, (select json_agg(json_build_object('g', x.group_name, 'n', x.option_name, 'q', x.quantity, 'c', x.extra_cents, 'o', x.option_id) order by x.option_name)
                                   from dlv_order_item_options x where x.order_item_id = oi.id) as opcoes,
         (select count(*)::int from dlv_print_jobs j where j.order_id = o.id) as cupons
    from dlv_orders o join dlv_order_items oi on oi.order_id = o.id
   where o.id = any($1::uuid[]) order by o.number, oi.item_name`, [pedidos]);
const fotoAntigos = () => fotoPedidos([antigoA.pedido_id, antigoB.pedido_id]);
const antes = JSON.stringify(await fotoAntigos());

await aplicar(arquivos.filter((f) => f >= CORTE_TAMANHOS && f < CORTE_VARIACOES));

console.log("\n— Migration de tamanhos sobre pedidos antigos");
await ok("pedidos antigos continuam idênticos (itens, complementos, preços, cupons)", async () => JSON.stringify(await fotoAntigos()), (d: string) => d === antes || `antes ${antes}\ndepois ${d}`);
await ok("item do pedido antigo ainda aponta para o 'Média' antigo, agora inativo; tamanho vazio", () => sql(
  `select i.name, i.is_active, oi.size_id, oi.size_name from dlv_order_items oi join dlv_items i on i.id = oi.item_id where oi.order_id = $1`, [antigoA.pedido_id]),
  (r: any[]) => r.length === 1 && r[0].name === "Filé de Frango Média" && r[0].is_active === false && r[0].size_id === null && r[0].size_name === null || JSON.stringify(r));
await ok("cliente acompanha o pedido antigo com o nome de sempre", () => como("anon", null, () => um("select dlv_acompanhar_pedido($1)", [antigoA.codigo])),
  (r: any) => r.itens[0].nome === "Filé de Frango Média" && r.itens[0].opcoes.length === 4 || JSON.stringify(r));
await ok("cupons dos pedidos antigos saem com o nome de sempre", async () => {
  const r = await como("authenticated", TERMINAL, () => um("select dlv_reservar_impressoes(50)"));
  await como("authenticated", TERMINAL, async () => { for (const j of r) await sql("select dlv_concluir_impressao($1, true)", [j.trabalho_id]); });
  return r;
}, (r: any[]) => r.length === 5
  && r.some((j: any) => j.pedido.numero === antigoA.numero && j.ponto.codigo === "cozinha" && j.itens[0].nome === "Filé de Frango Média")
  && r.some((j: any) => j.pedido.numero === antigoB.numero && j.ponto.codigo === "cozinha" && j.itens.map((i: any) => i.nome).sort().join() === "Batata Frita,Filé de Frango Pequena")
  || JSON.stringify(r.map((j: any) => [j.pedido.numero, j.ponto.codigo, j.itens.map((i: any) => i.nome)])));
await ok("painel avança e reimprime pedido antigo", async () => {
  const n = await como("authenticated", PAINEL, async () => {
    await sql("select dlv_avancar_pedido($1, 'pronto', 'Caixa')", [antigoA.pedido_id]);
    return um("select dlv_reimprimir_pedido($1, 'Caixa')", [antigoA.pedido_id]);
  });
  const r = await como("authenticated", TERMINAL, () => um("select dlv_reservar_impressoes(50)"));
  await como("authenticated", TERMINAL, async () => { for (const j of r) await sql("select dlv_concluir_impressao($1, true)", [j.trabalho_id]); });
  return { n, cupons: r.length, nome: r.find((j: any) => j.ponto.codigo === "cozinha")?.itens[0].nome };
}, (x: any) => x.n === 3 && x.cupons === 3 && x.nome === "Filé de Frango Média" || JSON.stringify(x));
await ok("a migração juntou 10 trios em 10 pratos com 30 tamanhos, sem apagar item", () => sql(`select
    (select count(*)::int from dlv_items) itens,
    (select count(*)::int from dlv_items where not is_active) inativos,
    (select count(*)::int from dlv_item_sizes) tamanhos,
    (select count(distinct item_id)::int from dlv_item_sizes) pratos,
    (select count(*)::int from dlv_item_size_option_groups) regras,
    (select count(*)::int from dlv_items where is_active and name ~ '\\s(Pequena|Média|Grande)$') com_tamanho_no_nome`),
  (r: any[]) => JSON.stringify(r[0]) === JSON.stringify({ itens: 80, inativos: 20, tamanhos: 30, pratos: 10, regras: 111, com_tamanho_no_nome: 0 }) || JSON.stringify(r[0]));
await ok("Especiais de Frango: 'Filé de Frango' ativo; 'Média' e 'Grande' inativos", () => sql(
  `select i.name, i.is_active from dlv_items i join dlv_categories c on c.id = i.category_id where c.name = 'Especiais de Frango' order by i.name`),
  (r: any[]) => JSON.stringify(r) === JSON.stringify([{ name: "Filé de Frango", is_active: true }, { name: "Filé de Frango Grande", is_active: false }, { name: "Filé de Frango Média", is_active: false }]) || JSON.stringify(r));
await ok("PF do Dia: pratos juntados continuam pausados (os 3 estavam); sem tamanho ficam iguais", () => sql(
  `select i.name || ':' || i.is_paused n from dlv_items i join dlv_categories c on c.id = i.category_id where c.name = 'PF do Dia' and i.is_active`),
  (r: any[]) => r.map((x) => x.n).sort().join(", ") === ["Bife:true", "Feijoada Completa:true", "Filé de Frango:true", "Lasanha 700g:true", "Parmegiana:true", "Só Feijoada 500g:true", "Stronogoff:true"].sort().join(", ") || JSON.stringify(r));
await ok("tamanhos copiam preço, pausado e descrição (só guarda quando muda)", () => sql(
  `select s.short_name, s.price_cents, s.is_paused, s.description from dlv_item_sizes s join dlv_items i on i.id = s.item_id
    join dlv_categories c on c.id = i.category_id where c.name = 'Especiais de Frango' order by s.sort_order`),
  (r: any[]) => r.map((x) => x.short_name + x.price_cents).join() === "P2390,M2690,G2990" && r[0].description === null && r[1].description.includes("2 filés") && r.every((x) => !x.is_paused) || JSON.stringify(r));

// ---------------------------------------------------------------- 0b. pedidos com variação, antes da migration de variações
console.log("\n— Pedidos com variação (antes da migration de variações)");
const menuV0 = await como("anon", null, () => um("select dlv_cardapio_publico()"));
const prato0 = (cat: string, nome: string) => menuV0.categorias.find((c: any) => c.nome === cat).itens.find((i: any) => i.nome === nome);
const tam0 = (p: any, n: string) => p.tamanhos.find((t: any) => t.nome === n);
const op0 = (t: any, g: string, n: string) => ({ opcao_id: t.grupos.find((x: any) => x.nome === g).opcoes.find((o: any) => o.nome === n).id });
const frango0 = prato0("Especiais de Frango", "Filé de Frango"), bife0 = prato0("Especiais de Carne", "Bife");
const criar0 = (p: any) => como("anon", null, () => um("select dlv_criar_pedido($1)", [JSON.stringify(p)]));
const antigoC = await ok("pedido 'Filé de Frango (Média)' + Empanado + 2 acompanhamentos: 26,90 + 2,00", () => criar0({
  modo: "retirada", cliente: { nome: "Antigo C", telefone: "17911110003" }, pagamento: { forma: "credito" },
  itens: [{ item_id: frango0.id, tamanho_id: tam0(frango0, "Média").id, quantidade: 1, opcoes: [
    op0(tam0(frango0, "Média"), "Escolhe seu Filé de Frango", "Empanado"),
    op0(tam0(frango0, "Média"), "Escolha o Acompanhamento", "Macarrão"),
    op0(tam0(frango0, "Média"), "Escolha o Acompanhamento", "Farofa")] }],
}), (r: any) => r.subtotal_cents === 2890 || JSON.stringify(r));
const antigoD = await ok("pedido 'Bife (Pequena)' A Cavalo + batata, 2 unidades: 2 × (24,90 + 2,00)", () => criar0({
  modo: "entrega", cliente: { nome: "Antigo D", telefone: "17911110004" }, endereco: { rua: "Rua Antiga", numero: "4", ...perto },
  pagamento: { forma: "dinheiro", troco_para_cents: 10000 },
  itens: [{ item_id: bife0.id, tamanho_id: tam0(bife0, "Pequena").id, quantidade: 2, opcoes: [
    op0(tam0(bife0, "Pequena"), "Escolha Sua Carne", "A Cavalo"),
    op0(tam0(bife0, "Pequena"), "Escolha o Acompanhamento", "Batata Frita")] }],
}), (r: any) => r.subtotal_cents === 2 * 2690 || JSON.stringify(r));
await como("authenticated", TERMINAL, async () => {
  const r = await um("select dlv_reservar_impressoes(50)");
  for (const j of r) await sql("select dlv_concluir_impressao($1, true)", [j.trabalho_id]);
});
const todosAntigos = () => fotoPedidos([antigoA.pedido_id, antigoB.pedido_id, antigoC.pedido_id, antigoD.pedido_id]);
const antesVariacoes = JSON.stringify(await todosAntigos());

const arqVariacoes = arquivos.find((f) => f.startsWith(CORTE_VARIACOES))!;
const contagemCardapio = () => sql(`select (select count(*)::int from dlv_items) itens, (select count(*)::int from dlv_items where not is_active) inativos,
  (select count(*)::int from dlv_item_sizes) tamanhos, (select count(*)::int from dlv_item_size_option_groups) regras`);
const regraTilapiaG = (await sql(`select sg.* from dlv_item_size_option_groups sg join dlv_item_sizes s on s.id = sg.size_id
  join dlv_items i on i.id = s.item_id join dlv_categories c on c.id = i.category_id join dlv_option_groups g on g.id = sg.group_id
  where c.name = 'Especiais de Peixe' and s.name = 'Grande' and i.is_active and g.name = 'Escolha seu Filé de Tilápia'`))[0];
async function tentarVariacoes(mexer: () => Promise<any>, desfazer: () => Promise<any>) {
  await mexer();
  try { await db.exec(readFileSync(`${DIR}/${arqVariacoes}`, "utf8")); }
  finally { await db.exec("ROLLBACK"); await desfazer(); }
}
const contagemAntes = JSON.stringify(await contagemCardapio());
await recusa("migration de variações: grupo de variação faltando num tamanho → RAISE", () => tentarVariacoes(
  () => sql("delete from dlv_item_size_option_groups where size_id = $1 and group_id = $2", [regraTilapiaG.size_id, regraTilapiaG.group_id]),
  () => sql("insert into dlv_item_size_option_groups (size_id, group_id, min_choices, max_choices, sort_order) values ($1, $2, $3, $4, $5)",
    [regraTilapiaG.size_id, regraTilapiaG.group_id, regraTilapiaG.min_choices, regraTilapiaG.max_choices, regraTilapiaG.sort_order])),
  "não está em todos os tamanhos");
await recusa("migration de variações: regra inconsistente (variação opcional num tamanho) → RAISE", () => tentarVariacoes(
  () => sql("update dlv_item_size_option_groups set min_choices = 0 where size_id = $1 and group_id = $2", [regraTilapiaG.size_id, regraTilapiaG.group_id]),
  () => sql("update dlv_item_size_option_groups set min_choices = 1 where size_id = $1 and group_id = $2", [regraTilapiaG.size_id, regraTilapiaG.group_id])),
  "não está em todos os tamanhos");
await ok("migration recusada não gravou nada", async () => JSON.stringify(await contagemCardapio()), (d: string) => d === contagemAntes || `antes ${contagemAntes} depois ${d}`);

await aplicar(arquivos.filter((f) => f >= CORTE_VARIACOES));

console.log("\n— Migration de variações");
await ok("pedidos antigos (antes dos tamanhos e antes das variações) continuam idênticos", async () => JSON.stringify(await todosAntigos()),
  (d: string) => d === antesVariacoes || `antes ${antesVariacoes}\ndepois ${d}`);
await ok("pedido com variação ainda aponta para o 'Filé de Frango' original, agora inativo, e o tamanho antigo", () => sql(
  `select i.name, i.is_active, oi.item_name, oi.size_name, s.is_active as tam_ativo from dlv_order_items oi join dlv_items i on i.id = oi.item_id
    join dlv_item_sizes s on s.id = oi.size_id where oi.order_id = $1`, [antigoC.pedido_id]),
  (r: any[]) => r.length === 1 && r[0].name === "Filé de Frango" && r[0].is_active === false && r[0].item_name === "Filé de Frango (Média)"
    && r[0].size_name === "Média" && r[0].tam_ativo === false || JSON.stringify(r));
await ok("cliente acompanha o pedido com variação como antes (Empanado nos complementos)", () => como("anon", null, () => um("select dlv_acompanhar_pedido($1)", [antigoC.codigo])),
  (r: any) => r.itens[0].nome === "Filé de Frango (Média)" && r.itens[0].opcoes.some((o: any) => o.nome === "Empanado") || JSON.stringify(r.itens));
await ok("contagens: 18 pratos novos, 9 originais inativos, 54 tamanhos, 156 regras novas", () => contagemCardapio(),
  (r: any[]) => JSON.stringify(r[0]) === JSON.stringify({ itens: 98, inativos: 29, tamanhos: 84, regras: 267 }) || JSON.stringify(r[0]));
await ok("pratos ativos das categorias com variação (ordem do cardápio)", () => sql(`
  select c.name cat, string_agg(i.name, ' | ' order by i.sort_order, i.name) pratos from dlv_items i join dlv_categories c on c.id = i.category_id
   where i.is_active and c.name in ('PF do Dia','Especiais de Carne','Especiais de Frango','Especiais de Peixe','Especiais Parmegianas','Especiais Strogonoff')
   group by c.name, c.sort_order order by c.sort_order`),
  (r: any[]) => JSON.stringify(r.map((x) => [x.cat, x.pratos])) === JSON.stringify([
    ["PF do Dia", "Strogonoff de Carne | Strogonoff de Frango | Filé de Frango Grelhado | Filé de Frango Empanado | Feijoada Completa | Só Feijoada 500g | Lasanha 700g | Bife a Cavalo | Bife Acebolado | Parmegiana de Frango | Parmegiana de Carne"],
    ["Especiais de Carne", "Bife a Cavalo | Bife Acebolado"],
    ["Especiais de Frango", "Filé de Frango Grelhado | Filé de Frango Empanado"],
    ["Especiais de Peixe", "Filé de Tilápia Empanado | Filé de Tilápia Grelhado"],
    ["Especiais Parmegianas", "Parmegiana de Frango | Parmegiana de Carne"],
    ["Especiais Strogonoff", "Strogonoff de Carne | Strogonoff de Frango"],
  ]) || JSON.stringify(r));
await ok("originais inativos: Stronogoff, Filé de Frango ×2, Bife ×2, Parmegiana ×2, Filé de Tilápia, Strogonoff", () => sql(`
  select i.name from dlv_items i where not i.is_active and exists (select 1 from dlv_item_sizes s where s.item_id = i.id) order by i.name`),
  (r: any[]) => r.map((x) => x.name).join() === "Bife,Bife,Filé de Frango,Filé de Frango,Filé de Tilápia,Parmegiana,Parmegiana,Strogonoff,Stronogoff" || JSON.stringify(r));
await ok("PF do Dia: 'Strogonoff' corrigido, nenhum 'Stronogoff' ativo, tudo continua pausado e no mesmo dia", () => sql(`
  select i.name, i.is_paused, i.weekdays from dlv_items i join dlv_categories c on c.id = i.category_id where c.name = 'PF do Dia' and i.is_active and i.name ilike 'stro%' order by i.name`),
  (r: any[]) => r.map((x) => `${x.name}:${x.is_paused}:${x.weekdays}`).join() === "Strogonoff de Carne:true:2,Strogonoff de Frango:true:2" || JSON.stringify(r));
await ok("preço de cada tamanho do 'Bife a Cavalo' = do Bife + 2,00 (Especiais e PF do Dia)", () => sql(`
  select c.name cat, sn.short_name, sn.price_cents novo, so.price_cents velho from dlv_items n join dlv_categories c on c.id = n.category_id
    join dlv_item_sizes sn on sn.item_id = n.id
    join dlv_items o on o.category_id = n.category_id and o.name = 'Bife' and not o.is_active
    join dlv_item_sizes so on so.item_id = o.id and so.name = sn.name
   where n.name = 'Bife a Cavalo' and n.is_active order by c.name, sn.sort_order`),
  (r: any[]) => r.length === 6 && r.every((x) => x.novo === x.velho + 200) && r.map((x) => x.short_name + x.novo).join() === "P2690,M2990,G3290,P2390,M2790,G3190" || JSON.stringify(r));
await ok("prato novo copia ponto, dias, pausado; anota_id vazio; tamanhos copiam descrição; descrição e foto próprias (dlv_descricoes_e_fotos)", () => sql(`
  select n.name, n.image_url like '/fotos-pratos/file-frango-%' foto,
         n.description not ilike '% ou %' and n.description ilike '%' || lower(split_part(n.name, ' ', 4)) || '%' descr,
         n.production_point_id = o.production_point_id ponto,
         n.weekdays is not distinct from o.weekdays dias, n.is_paused = o.is_paused pausado, n.anota_id is null sem_anota,
         (select string_agg(coalesce(s.description, '-'), '|' order by s.sort_order) from dlv_item_sizes s where s.item_id = n.id)
           = (select string_agg(coalesce(s.description, '-'), '|' order by s.sort_order) from dlv_item_sizes s where s.item_id = o.id) descr_tam
    from dlv_items n join dlv_items o on o.category_id = n.category_id and not o.is_active and o.name = 'Filé de Frango'
   where n.is_active and n.name like 'Filé de Frango %'`),
  (r: any[]) => r.length === 4 && r.every((x) => x.foto && x.descr && x.ponto && x.dias && x.pausado && x.sem_anota && x.descr_tam) || JSON.stringify(r));
await ok("nenhum tamanho ativo ligado a grupo de variação; grupos e opções continuam existindo", () => sql(`
  select (select count(*)::int from dlv_item_size_option_groups sg join dlv_item_sizes s on s.id = sg.size_id and s.is_active
            join dlv_items i on i.id = s.item_id and i.is_active join dlv_option_groups g on g.id = sg.group_id
           where g.name in ('Escolha Sua Carne','Escolha Seu Strogonoff','Escolhe seu Filé de Frango','Escolha seu Filé de Tilápia','Escolha Sua Parmegiana')) ligados,
         (select count(*)::int from dlv_options o join dlv_option_groups g on g.id = o.group_id and g.is_active
           where o.is_active and g.name in ('Escolha Sua Carne','Escolha Seu Strogonoff','Escolhe seu Filé de Frango','Escolha seu Filé de Tilápia','Escolha Sua Parmegiana')) opcoes`),
  (r: any[]) => r[0].ligados === 0 && r[0].opcoes === 10 || JSON.stringify(r));
await ok("regras dos tamanhos novos = originais sem a variação (Filé de Frango Empanado)", () => sql(`
  select s.short_name, string_agg(g.name || ' ' || sg.min_choices || '-' || sg.max_choices, ', ' order by sg.sort_order) regras
    from dlv_items i join dlv_categories c on c.id = i.category_id and c.name = 'Especiais de Frango'
    join dlv_item_sizes s on s.item_id = i.id join dlv_item_size_option_groups sg on sg.size_id = s.id join dlv_option_groups g on g.id = sg.group_id
   where i.name = 'Filé de Frango Empanado' group by s.short_name, s.sort_order order by s.sort_order`),
  (r: any[]) => r.map((x) => `${x.short_name}: ${x.regras}`).join(" / ") ===
    "P: Escolha o Acompanhamento 1-1, + Proteína 0-2, Bebidas 0-10 / M: Escolha o Acompanhamento 1-2, + Proteína 0-2, Bebidas 0-10 / G: Escolha o Acompanhamento 0-2, + Proteína 0-2, Bebidas 0-10" || JSON.stringify(r));
await ok("rodar a migration de variações de novo é recusado e não grava nada", async () => {
  const c0 = JSON.stringify(await contagemCardapio());
  let erro = "";
  try { await db.exec(readFileSync(`${DIR}/${arqVariacoes}`, "utf8")); } catch (e: any) { erro = e.message; } finally { await db.exec("ROLLBACK"); }
  return { erro, igual: JSON.stringify(await contagemCardapio()) === c0 };
}, (x: any) => x.erro.includes("esperado 9") && x.igual || JSON.stringify(x));

// ---------------------------------------------------------------- 1. acesso
console.log("\n— Acesso");
await recusa("anônimo não lê pedidos direto", () => como("anon", null, () => sql("select * from dlv_orders")), "permission denied");
await recusa("anônimo não lê clientes direto", () => como("anon", null, () => sql("select * from dlv_customers")), "permission denied");
await ok("logado sem painel não vê pedidos", () => como("authenticated", ESTRANHO, () => sql("select * from dlv_orders")), (r) => r.length === 0);
await recusa("anônimo não avança pedido", () => como("anon", null, () => sql("select dlv_avancar_pedido(gen_random_uuid(), 'pronto', 'x')")), "permission denied");
await recusa("anônimo não confirma Pix", () => como("anon", null, () => sql("select dlv_confirmar_pix('x', 1)")), "permission denied");
await recusa("logado sem painel não confirma Pix", () => como("authenticated", ESTRANHO, () => sql("select dlv_confirmar_pix('x', 1)")), "permission denied");
await recusa("logado sem painel não avança pedido", () => como("authenticated", ESTRANHO, () => sql("select dlv_avancar_pedido(gen_random_uuid(), 'pronto', 'x')")), "Sem permissão");
await recusa("logado que não é estação não reserva impressão", () => como("authenticated", ESTRANHO, () => sql("select dlv_reservar_impressoes(10)")), "não é uma estação");

// ---------------------------------------------------------------- 2. cardápio público
console.log("\n— Cardápio");
const menu = await ok("anônimo lê o cardápio", () => como("anon", null, () => um("select dlv_cardapio_publico()")),
  (m: any) => m.categorias.length > 0 && m.loja.aberta === true || "sem categorias ou loja fechada");
await ok("PF do Dia (tudo pausado) não aparece", async () => menu.categorias.map((c: any) => c.nome), (n: string[]) => !n.includes("PF do Dia") || n.join(", "));
await ok("embalagem separada não existe", async () => JSON.stringify(menu), (s: string) => !s.includes("Embalagem") || "achou embalagem");
await ok("pedido mínimo R$ 15 e faixas no cardápio", async () => menu.loja, (l: any) => l.pedido_minimo_cents === 1500 && l.faixas_entrega.length === 5 || JSON.stringify(l));

const pratoFrango = menu.categorias.find((c: any) => c.nome === "Especiais de Frango").itens.find((i: any) => i.nome === "Filé de Frango Empanado");
const frango = pratoFrango.tamanhos.find((t: any) => t.nome === "Pequena");  // os grupos vêm do tamanho
const grupo = (item: any, n: string) => item.grupos.find((g: any) => g.nome === n);
const opcao = (item: any, g: string, n: string) => grupo(item, g).opcoes.find((o: any) => o.nome === n);
const agua = menu.categorias.find((c: any) => c.nome === "Bebidas").itens.find((i: any) => i.nome === "Água");

const linhaFrango = (extra: any[] = []) => ({
  item_id: pratoFrango.id, tamanho_id: frango.id, quantidade: 1, preco_cents: 1, // preço mandado pelo navegador deve ser ignorado
  opcoes: [
    { opcao_id: opcao(frango, "Escolha o Acompanhamento", "Batata Frita").id },
    { opcao_id: opcao(frango, "Bebidas", "Coca-Cola 200ml").id },
    ...extra,
  ],
});
const pedido = (over: any = {}) => ({
  modo: "entrega",
  cliente: { nome: "Cliente Teste", telefone: "(17) 99999-0001" },
  endereco: { rua: "Rua Teste", numero: "10", bairro: "Centro", ...perto },
  pagamento: { forma: "dinheiro", troco_para_cents: 5000 },
  itens: [linhaFrango()],
  ...over,
});
const criar = (p: any) => como("anon", null, () => um("select dlv_criar_pedido($1)", [JSON.stringify(p)]));

// ---------------------------------------------------------------- 3. entrega
console.log("\n— Área de entrega");
await ok("0,6 km: grátis", () => como("anon", null, () => um("select dlv_consultar_entrega($1, $2)", [perto.lat, perto.lng])), (r: any) => r.entrega && r.taxa_cents === 0 || JSON.stringify(r));
await ok("5 km: R$ 10", () => como("anon", null, () => um("select dlv_consultar_entrega($1, $2)", [cinco.lat, cinco.lng])), (r: any) => r.taxa_cents === 1000 || JSON.stringify(r));
await ok("15 km: fora da área", () => como("anon", null, () => um("select dlv_consultar_entrega($1, $2)", [longe.lat, longe.lng])), (r: any) => r.entrega === false || JSON.stringify(r));

// ---------------------------------------------------------------- 4. criar pedido (validações)
console.log("\n— Validações do pedido");
await recusa("falta complemento obrigatório", () => criar(pedido({ itens: [{ item_id: pratoFrango.id, tamanho_id: frango.id, quantidade: 1, opcoes: [] }] })), "pelo menos 1");
await recusa("passa do máximo de proteína", () => criar(pedido({ itens: [linhaFrango([
  { opcao_id: opcao(frango, "+ Proteína", "Ovo Frito").id, quantidade: 3 }])] })), "no máximo 2");
await recusa("complemento de outro item", () => criar(pedido({ itens: [{ ...linhaFrango(), opcoes: [...linhaFrango().opcoes, { opcao_id: opcao(
  menu.categorias.find((c: any) => c.nome === "Lanche Artesanal").itens[0], "Deseja Sachês de Molho?", "Quero sachês").id }] }] })), "Complemento inválido");
await recusa("abaixo do pedido mínimo", () => criar(pedido({ itens: [{ item_id: agua.id, quantidade: 1 }] })), "pedido mínimo");
await recusa("fora da área de entrega", () => criar(pedido({ endereco: { rua: "Longe", ...longe } })), "fora da nossa área");
await recusa("troco menor que o total", () => criar(pedido({ pagamento: { forma: "dinheiro", troco_para_cents: 1000 } })), "troco");
await recusa("telefone inválido", () => criar(pedido({ cliente: { nome: "X Y", telefone: "123" } })), "telefone");
await recusa("item que não existe", () => criar(pedido({ itens: [{ item_id: "00000000-0000-0000-0000-000000000000", quantidade: 1 }] })), "não existe");
await sql("UPDATE dlv_settings SET value = 'fechada' WHERE key = 'store_mode'");
await recusa("loja fechada", () => criar(pedido()), "fechada");
await sql("UPDATE dlv_settings SET value = 'aberta' WHERE key = 'store_mode'");

// ---------------------------------------------------------------- 5. pedido em dinheiro com aceite automático
console.log("\n— Pedido em dinheiro (aceite automático)");
const p1 = await ok("cria pedido: Filé de Frango Empanado P 25,90 + coca 3,50 = 29,40, frete grátis", () => criar(pedido()),
  // número >= 5000: pedido recusado antes também gasta número (sequência do Postgres não volta)
  (r: any) => r.subtotal_cents === 2940 && r.total_cents === 2940 && r.status === "em_producao" && r.numero >= 5000 || JSON.stringify(r));
await ok("gerou 3 cupons: cozinha, bar de cerveja e via do caixa", () => sql(
  `select pp.code, j.kind from dlv_print_jobs j join pdv_production_points pp on pp.id = j.production_point_id where j.order_id = $1 order by 1, 2`, [p1.pedido_id]),
  (r: any[]) => JSON.stringify(r) === JSON.stringify([{ code: "caixa", kind: "via_entrega" }, { code: "cerveja", kind: "producao" }, { code: "cozinha", kind: "producao" }]) || JSON.stringify(r));
await ok("cliente salvo com endereço", () => sql(`select c.orders_count, a.street from dlv_customers c join dlv_customer_addresses a on a.customer_id = c.id where c.phone = '17999990001'`),
  (r: any[]) => r.length === 1 && r[0].orders_count === 1 || JSON.stringify(r));
await ok("cliente acompanha pelo código", () => como("anon", null, () => um("select dlv_acompanhar_pedido($1)", [p1.codigo])),
  (r: any) => r.status === "em_producao" && r.itens[0].opcoes.length === 2 && !("telefone" in r) || JSON.stringify(r));
await recusa("código inventado não acha pedido", () => como("anon", null, () => um("select dlv_acompanhar_pedido($1)", ["0".repeat(32)])), "não encontrado");

// ---------------------------------------------------------------- 6. estação de impressão
console.log("\n— Estação de impressão");
const jobs = await ok("estação reserva os 3 cupons", () => como("authenticated", TERMINAL, () => um("select dlv_reservar_impressoes(10)")), (r: any[]) => r.length === 3 || JSON.stringify(r).slice(0, 300));
const cozinha = jobs?.find((j: any) => j.ponto.codigo === "cozinha");
const cerveja = jobs?.find((j: any) => j.ponto.codigo === "cerveja");
const via = jobs?.find((j: any) => j.tipo === "via_entrega");
await ok("cozinha recebe o frango empanado com batata, sem a coca", async () => cozinha,
  (j: any) => j.itens.length === 1 && j.itens[0].nome === "Filé de Frango Empanado (Pequena)" && j.itens[0].opcoes.map((o: any) => o.nome).sort().join() === "Batata Frita" || JSON.stringify(j?.itens));
await ok("bar de cerveja recebe só a coca, 'junto com' o prato", async () => cerveja,
  (j: any) => j.itens.length === 1 && j.itens[0].nome === "Coca-Cola 200ml" && j.itens[0].observacao.includes("Filé de Frango") || JSON.stringify(j?.itens));
await ok("via do caixa tem tudo, endereço, troco e link do mapa", async () => via,
  (j: any) => j.itens[0].opcoes.length === 2 && j.pedido.troco_para_cents === 5000 && j.pedido.endereco.mapa_url.includes("google.com/maps") && j.ponto.ip === "192.168.0.70" || JSON.stringify(j?.pedido));
await ok("segunda estação não pega os mesmos cupons", () => como("authenticated", TERMINAL, () => um("select dlv_reservar_impressoes(10)")), (r: any[]) => r.length === 0 || `${r.length} cupons`);
await ok("conclui cozinha e cerveja; via do caixa falha", async () => {
  await como("authenticated", TERMINAL, async () => {
    await sql("select dlv_concluir_impressao($1, true)", [cozinha.trabalho_id]);
    await sql("select dlv_concluir_impressao($1, true)", [cerveja.trabalho_id]);
    await sql("select dlv_concluir_impressao($1, false, 'impressora sem papel')", [via.trabalho_id]);
  });
  // conferência como dono do banco: a conta da estação não enxerga a tabela de propósito
  return sql("select kind, status, last_error from dlv_print_jobs where order_id = (select order_id from dlv_print_jobs where id = $1) order by kind", [via.trabalho_id]);
}, (r: any[]) => r.filter((x) => x.status === "impresso").length === 2 && r.find((x) => x.kind === "via_entrega").status === "pendente" || JSON.stringify(r));
await ok("cupom que falhou volta para a fila", () => como("authenticated", TERMINAL, () => um("select dlv_reservar_impressoes(10)")), (r: any[]) => r.length === 1 && r[0].tipo === "via_entrega" || JSON.stringify(r).slice(0, 200));
await ok("painel vê a estação online", () => como("authenticated", PAINEL, () => um("select dlv_status_estacao()")), (r: any) => r.online === true || JSON.stringify(r));

// ---------------------------------------------------------------- 7. etapas no painel
console.log("\n— Etapas no painel");
await recusa("não sai para entrega sem motoboy", () => como("authenticated", PAINEL, () => sql("select dlv_avancar_pedido($1, 'saiu_entrega', 'Caixa')", [p1.pedido_id])), "motoboy");
await ok("escolhe motoboy, marca pronto, sai e finaliza", () => como("authenticated", PAINEL, async () => {
  const italo = await um("select id from dlv_couriers where name = 'Italo'");
  await sql("select dlv_definir_motoboy($1, $2, 'Caixa')", [p1.pedido_id, italo]);
  await sql("select dlv_avancar_pedido($1, 'pronto', 'Caixa')", [p1.pedido_id]);
  await sql("select dlv_avancar_pedido($1, 'saiu_entrega', 'Caixa')", [p1.pedido_id]);
  await sql("select dlv_avancar_pedido($1, 'finalizado', 'Caixa')", [p1.pedido_id]);
  return sql("select status, ready_at is not null r, dispatched_at is not null d, finished_at is not null f from dlv_orders where id = $1", [p1.pedido_id]);
}), (r: any[]) => r[0].status === "finalizado" && r[0].r && r[0].d && r[0].f || JSON.stringify(r));
await recusa("etapa não volta para trás", () => como("authenticated", PAINEL, () => sql("select dlv_avancar_pedido($1, 'em_producao', 'Caixa')", [p1.pedido_id])), "não pode ir");
await ok("auditoria registrou todas as etapas", () => sql("select to_status, by_name from dlv_order_events where order_id = $1 order by created_at, id", [p1.pedido_id]),
  (r: any[]) => r.length >= 6 || JSON.stringify(r));

// ---------------------------------------------------------------- 8. cancelamento depois de aceito
console.log("\n— Cancelamento");
const p2 = await ok("novo pedido para cancelar", () => criar(pedido({ cliente: { nome: "Outro", telefone: "17999990002" } })), (r: any) => r.status === "em_producao");
await como("authenticated", TERMINAL, async () => {
  const r = await um("select dlv_reservar_impressoes(10)");
  for (const j of r) await sql("select dlv_concluir_impressao($1, true)", [j.trabalho_id]);
});
await ok("cancela com motivo e gera aviso para cozinha e bar", () => como("authenticated", PAINEL, async () => {
  const r = await um("select dlv_cancelar_pedido($1, 'cliente desistiu', 'Caixa')", [p2.pedido_id]);
  const avisos = await sql("select count(*)::int n from dlv_print_jobs where order_id = $1 and kind = 'cancelamento'", [p2.pedido_id]);
  return { r, avisos: avisos[0].n };
}), (x: any) => x.r.tipo === "cancelado" && x.avisos === 2 || JSON.stringify(x));
await recusa("cancelar sem motivo", () => como("authenticated", PAINEL, () => sql("select dlv_cancelar_pedido($1, '', 'Caixa')", [p1.pedido_id])), "motivo");

// ---------------------------------------------------------------- 9. Pix online
console.log("\n— Pix online");
const p3 = await ok("pedido Pix nasce aguardando pagamento", () => criar(pedido({ cliente: { nome: "Pix", telefone: "17999990003" }, pagamento: { forma: "pix_online" }, endereco: { rua: "Rua 5km", ...cinco } })),
  (r: any) => r.status === "aguardando_pagamento" && r.taxa_entrega_cents === 1000 && r.total_cents === 3940 && !!r.pix_expira_em || JSON.stringify(r));
await ok("sem cupom antes de pagar", () => sql("select count(*)::int n from dlv_print_jobs where order_id = $1", [p3.pedido_id]), (r: any[]) => r[0].n === 0);
await recusa("painel não aceita Pix não pago", () => como("authenticated", PAINEL, () => sql("select dlv_avancar_pedido($1, 'em_producao', 'Caixa')", [p3.pedido_id])), "não pode ir");
await ok("Edge Function registra o Pix", () => como("service_role", null, () => sql("select dlv_registrar_pix($1, 'mp-111', '00020126...')", [p3.pedido_id])));
await recusa("valor pago diferente é recusado", () => como("service_role", null, () => sql("select dlv_confirmar_pix('mp-111', 100)")), "diferente");
await ok("Pix confirmado vira produção e imprime", () => como("service_role", null, () => um("select dlv_confirmar_pix('mp-111', 3940)")), (r: any) => r.status === "em_producao" || JSON.stringify(r));
await ok("webhook repetido não duplica", () => como("service_role", null, () => um("select dlv_confirmar_pix('mp-111', 3940)")), (r: any) => r.ja_confirmado === true || JSON.stringify(r));
await ok("cupons do Pix gerados uma vez só", () => sql("select count(*)::int n from dlv_print_jobs where order_id = $1", [p3.pedido_id]), (r: any[]) => r[0].n === 3 || JSON.stringify(r));

const p4 = await ok("outro Pix para expirar", () => criar(pedido({ cliente: { nome: "Pix Lento", telefone: "17999990004" }, pagamento: { forma: "pix_online" } })));
await sql("select dlv_registrar_pix($1, 'mp-222', 'x')", [p4.pedido_id]);
await sql("update dlv_orders set pix_expires_at = now() - interval '1 minute' where id = $1", [p4.pedido_id]);
await ok("Pix vencido aparece cancelado para o cliente", () => como("anon", null, () => um("select dlv_acompanhar_pedido($1)", [p4.codigo])), (r: any) => r.status === "cancelado" && r.cancelamento === "pix_expirado" || JSON.stringify(r));
await ok("pagou depois do prazo: pedido volta e vai para produção", () => como("service_role", null, () => um("select dlv_confirmar_pix('mp-222', 2940)")), (r: any) => r.status === "em_producao" || JSON.stringify(r));

// ---------------------------------------------------------------- 10. limites e painel
console.log("\n— Limites e painel");
// limite 5 desde 20260916120000 (antes 3); o detalhe da regra nova está na seção "Limite por telefone"
await ok("5 pedidos em andamento no mesmo telefone passam", async () => {
  for (let i = 0; i < 5; i++) await criar(pedido({ cliente: { nome: "Trote", telefone: "17988880000" } }));
  return true;
});
await recusa("6º pedido em andamento no mesmo telefone é barrado",() => criar(pedido({ cliente: { nome: "Trote", telefone: "17988880000" } })), "em andamento");
await sql("UPDATE dlv_settings SET value = 'fechada' WHERE key = 'store_mode'");
await ok("painel lança pedido por telefone com a loja fechada (retirada, Pix na entrega)", () => como("authenticated", PAINEL, () => um("select dlv_criar_pedido_painel($1, 'Caixa')", [JSON.stringify({
  modo: "retirada", cliente: { nome: "Balcão", telefone: "17977770000" }, pagamento: { forma: "pix_entrega" }, itens: [linhaFrango()] })])),
  (r: any) => r.status === "em_producao" && r.taxa_entrega_cents === 0 || JSON.stringify(r));
await recusa("painel não gera Pix online", () => como("authenticated", PAINEL, () => um("select dlv_criar_pedido_painel($1, 'Caixa')", [JSON.stringify({
  modo: "retirada", cliente: { nome: "Balcão", telefone: "17977770000" }, pagamento: { forma: "pix_online" }, itens: [linhaFrango()] })])), "forma de pagamento");
await sql("UPDATE dlv_settings SET value = 'auto' WHERE key = 'store_mode'");
await sql("DELETE FROM dlv_opening_hours");
await ok("modo automático: fechado fora do horário", () => como("anon", null, () => um("select dlv_cardapio_publico()")), (m: any) => m.loja.aberta === false);
await sql("INSERT INTO dlv_opening_hours (weekday, opens_at, closes_at) VALUES (extract(dow from now() at time zone 'America/Sao_Paulo')::int, '00:00', '23:59:59')");
await ok("modo automático: aberto dentro do horário de hoje", () => como("anon", null, () => um("select dlv_cardapio_publico()")), (m: any) => m.loja.aberta === true);
await sql("UPDATE dlv_settings SET value = 'false' WHERE key = 'auto_accept'");
const p5 = await ok("sem aceite automático o pedido fica em análise e não imprime", () => criar(pedido({ cliente: { nome: "Manual", telefone: "17966660000" } })), (r: any) => r.status === "em_analise");
await ok("painel aceita e aí gera os cupons", () => como("authenticated", PAINEL, async () => {
  await sql("select dlv_avancar_pedido($1, 'em_producao', 'Caixa')", [p5.pedido_id]);
  return sql("select count(*)::int n from dlv_print_jobs where order_id = $1", [p5.pedido_id]);
}), (r: any[]) => r[0].n === 3 || JSON.stringify(r));
await ok("recusar em análise conta como 'recusado'", async () => {
  const p6 = await criar(pedido({ cliente: { nome: "Recusa", telefone: "17955550000" } }));
  return como("authenticated", PAINEL, () => um("select dlv_cancelar_pedido($1, 'fora do cardápio hoje', 'Caixa')", [p6.pedido_id]));
}, (r: any) => r.tipo === "recusado" || JSON.stringify(r));

// ---------------------------------------------------------------- 11. gestão da loja e do cardápio (migration dlv_gestao)
console.log("\n— Gestão pelo painel");
await recusa("painel não escreve mais direto no cardápio", () => como("authenticated", PAINEL, () => sql("update dlv_items set price_cents = 1 where id = $1", [agua.id])), "permission denied");
await recusa("anônimo não configura a loja", () => como("anon", null, () => sql("select dlv_configurar_loja('fechada', null, 'x')")), "permission denied");
await recusa("logado sem painel não configura a loja", () => como("authenticated", ESTRANHO, () => sql("select dlv_configurar_loja('fechada', null, 'x')")), "Sem permissão");
await recusa("situação da loja inválida", () => como("authenticated", PAINEL, () => sql("select dlv_configurar_loja('meio', null, 'Caixa')")), "inválida");
await ok("painel fecha a loja e o cardápio mostra fechado", async () => {
  const r = await como("authenticated", PAINEL, () => um("select dlv_configurar_loja('fechada', true, 'Caixa')"));
  const m = await como("anon", null, () => um("select dlv_cardapio_publico()"));
  return { r, aberta: m.loja.aberta };
}, (x: any) => x.r.modo === "fechada" && x.r.aceite_automatico === true && x.aberta === false || JSON.stringify(x));
await ok("painel reabre a loja", () => como("authenticated", PAINEL, () => um("select dlv_configurar_loja('aberta', null, 'Caixa')")), (r: any) => r.aberta === true || JSON.stringify(r));
await ok("esgota a água e muda o preço; cardápio mostra esgotado", async () => {
  await como("authenticated", PAINEL, () => sql("select dlv_ajustar_item($1, null, true, 350, 'Caixa')", [agua.id]));
  const m = await como("anon", null, () => um("select dlv_cardapio_publico()"));
  return m.categorias.find((c: any) => c.nome === "Bebidas").itens.find((i: any) => i.id === agua.id);
}, (i: any) => i.esgotado === true && i.preco_cents === 350 || JSON.stringify(i));
await recusa("pedido com item esgotado é recusado", () => criar(pedido({ cliente: { nome: "Sede", telefone: "17944440000" }, itens: [linhaFrango(), { item_id: agua.id, quantidade: 1 }] })), "esgotado");
await ok("mudanças ficam registradas com o valor antigo e o novo", () => sql("select field, old_value, new_value, by_name from dlv_menu_changes where target_id = $1 order by field", [agua.id]),
  (r: any[]) => r.length === 2 && r.some((x) => x.field === "preço" && x.old_value === "R$ 2,99" && x.new_value === "R$ 3,50") || JSON.stringify(r));
await ok("pausar complemento tira ele do cardápio", async () => {
  await como("authenticated", PAINEL, () => sql("select dlv_ajustar_opcao($1, true, null, null, 'Caixa')", [opcao(frango, "Escolha o Acompanhamento", "Batata Frita").id]));
  const m = await como("anon", null, () => um("select dlv_cardapio_publico()"));
  const f = m.categorias.find((c: any) => c.nome === "Especiais de Frango").itens.find((i: any) => i.id === pratoFrango.id);
  return f.tamanhos.find((t: any) => t.id === frango.id).grupos.find((g: any) => g.nome === "Escolha o Acompanhamento").opcoes.map((o: any) => o.nome);
}, (n: string[]) => !n.includes("Batata Frita") && n.length === 3 || n.join(","));
await recusa("pedido com complemento pausado é recusado", () => criar(pedido({ cliente: { nome: "Batata", telefone: "17933330000" } })), "indisponível");
await ok("mudança sem diferença não gera registro", async () => {
  await como("authenticated", PAINEL, () => sql("select dlv_ajustar_item($1, null, true, 350, 'Caixa')", [agua.id]));
  return sql("select count(*)::int n from dlv_menu_changes where target_id = $1", [agua.id]);
}, (r: any[]) => r[0].n === 2 || JSON.stringify(r));

// ---------------------------------------------------------------- 12. limite geral contra pedido falso em massa
console.log("\n— Limite geral");
await como("authenticated", PAINEL, () => sql("select dlv_ajustar_opcao($1, false, null, null, 'Caixa')", [opcao(frango, "Escolha o Acompanhamento", "Batata Frita").id]));
const recentes = await um("select count(*)::int from dlv_orders where source = 'cardapio' and created_at > now() - interval '5 minutes'");
await sql("UPDATE dlv_settings SET value = $1 WHERE key = 'max_orders_per_window'", [String(recentes + 1)]);
await ok("dentro do limite: pedido passa", () => criar(pedido({ cliente: { nome: "Limite Um", telefone: "17922220001" } })), (r: any) => !!r.numero || JSON.stringify(r));
await recusa("passou do limite na janela: pedido do cardápio é recusado", () => criar(pedido({ cliente: { nome: "Limite Dois", telefone: "17922220002" } })), "muitos pedidos");
await ok("pedido pelo painel não entra no limite", () => como("authenticated", PAINEL, () => um("select dlv_criar_pedido_painel($1, 'Caixa')", [JSON.stringify({
  modo: "retirada", cliente: { nome: "Balcão Limite", telefone: "17922220003" }, pagamento: { forma: "dinheiro" }, itens: [linhaFrango()] })])),
  (r: any) => !!r.numero || JSON.stringify(r));
await sql("UPDATE dlv_settings SET value = '1000' WHERE key = 'max_orders_per_window'");

// ---------------------------------------------------------------- 13. tamanhos (migration dlv_tamanhos)
console.log("\n— Tamanhos");
const menuT = await como("anon", null, () => um("select dlv_cardapio_publico()"));
const pratoDe = (m: any, cat: string, nome: string) => m.categorias.find((c: any) => c.nome === cat)?.itens.find((i: any) => i.nome === nome);
const frangoT = pratoDe(menuT, "Especiais de Frango", "Filé de Frango Grelhado");
const tam = (prato: any, nome: string) => prato.tamanhos.find((t: any) => t.nome === nome);
const [fP, fM, fG] = ["Pequena", "Média", "Grande"].map((n) => tam(frangoT, n));
const bifeT = pratoDe(menuT, "Especiais de Carne", "Bife Acebolado");
const [bP, bM] = ["Pequena", "Média"].map((n) => tam(bifeT, n));
const batata = pratoDe(menuT, "Porções", "Batata Frita");

await recusa("anônimo não lê tamanhos direto", () => como("anon", null, () => sql("select * from dlv_item_sizes")), "permission denied");
await ok("painel lê os tamanhos (30 dos tamanhos + 54 das variações)", () => como("authenticated", PAINEL, () => sql("select id from dlv_item_sizes")), (r: any[]) => r.length === 84 || `${r.length}`);
await recusa("painel não escreve direto nos tamanhos", () => como("authenticated", PAINEL, () => sql("update dlv_item_sizes set price_cents = 1")), "permission denied");
await ok("cardápio: 'Filé de Frango Grelhado' com P/M/G, preço 'a partir de' R$ 23,90 e sem grupos no prato", async () => frangoT,
  (i: any) => i.tamanhos.map((t: any) => `${t.sigla}${t.preco_cents}`).join() === "P2390,M2690,G2990" && i.preco_cents === 2390 && i.grupos.length === 0 || JSON.stringify(i).slice(0, 400));
await ok("cardápio: regras por tamanho (Pequena até 1 acompanhamento, Média até 2) e descrição da Média", async () => [fP, fM],
  ([p, m]: any) => grupo(p, "Escolha o Acompanhamento").max === 1 && grupo(m, "Escolha o Acompanhamento").max === 2
    && m.descricao.includes("2 filés") && p.descricao === frangoT.descricao || JSON.stringify([p, m]).slice(0, 400));
await ok("cardápio: item sem tamanho vem com 'tamanhos' vazio e grupos como antes", async () => pratoDe(menuT, "Lanche Artesanal", "Brasileirão"),
  (i: any) => i.tamanhos.length === 0 && i.grupos.length === 4 && i.preco_cents === 3990 || JSON.stringify(i).slice(0, 300));

const linhaT = (prato: any, t: any, opcoes: [string, string][], extra: any = {}) => ({
  item_id: prato.id, tamanho_id: t?.id, quantidade: 1, opcoes: opcoes.map(([g, n]) => ({ opcao_id: opcao(t, g, n).id })), ...extra });
const pedidoT = (tel: string, itens: any[]) => pedido({ modo: "retirada", cliente: { nome: "Tamanho", telefone: tel }, pagamento: { forma: "credito" }, itens });
const opcFrango: [string, string][] = [["Escolha o Acompanhamento", "Macarrão"]];

await recusa("prato com tamanho sem escolher tamanho é recusado", () => criar(pedidoT("17900000001", [{ ...linhaT(frangoT, fP, opcFrango), tamanho_id: undefined }])), 'Escolha o tamanho de "Filé de Frango Grelhado"');
await recusa("tamanho de outro prato é recusado", () => criar(pedidoT("17900000001", [{ ...linhaT(frangoT, fP, opcFrango), tamanho_id: bP.id }])), "Tamanho inválido");
await recusa("tamanho que não é código válido é recusado", () => criar(pedidoT("17900000001", [{ ...linhaT(frangoT, fP, opcFrango), tamanho_id: "grande" }])), "Tamanho inválido");
await recusa("complemento de outro prato não vale no tamanho", async () => criar(pedidoT("17900000001", [
  { ...linhaT(frangoT, fP, opcFrango), opcoes: [...linhaT(frangoT, fP, opcFrango).opcoes, { opcao_id: await opcaoNome("Deseja turbinar a feijoada?", "Torresmo 100g") }] }])), "Complemento inválido");
await recusa("Filé de Frango Grelhado Pequena com 2 acompanhamentos: máximo 1", () => criar(pedidoT("17900000001", [
  linhaT(frangoT, fP, [...opcFrango, ["Escolha o Acompanhamento", "Farofa"]])])), "no máximo 1");
await recusa("Bife Acebolado Pequena sem acompanhamento: exige 1", () => criar(pedidoT("17900000001", [linhaT(bifeT, bP, [])])), "pelo menos 1");
await recusa("Bife Acebolado Média com 1 acompanhamento: exige 2", () => criar(pedidoT("17900000001", [
  linhaT(bifeT, bM, [["Escolha o Acompanhamento", "Macarrão"]])])), 'Em "Bife Acebolado (Média)", escolha pelo menos 2');
await ok("Bife Acebolado Média com 2 acompanhamentos passa, com o preço da Média", () => criar(pedidoT("17900000002", [
  linhaT(bifeT, bM, [["Escolha o Acompanhamento", "Macarrão"], ["Escolha o Acompanhamento", "Farofa"]])])),
  (r: any) => r.subtotal_cents === 2790 || JSON.stringify(r));
const pM = await ok("Filé de Frango Grelhado Média com 2 acompanhamentos e coca: 26,90 + 3,50", () => criar(pedidoT("17900000003", [
  linhaT(frangoT, fM, [...opcFrango, ["Escolha o Acompanhamento", "Farofa"], ["Bebidas", "Coca-Cola 200ml"]], { preco_cents: 1 })])),
  (r: any) => r.subtotal_cents === 3040 || JSON.stringify(r));
await ok("item do pedido congela 'Filé de Frango Grelhado (Média)' e guarda o tamanho", () => sql("select item_name, size_name, size_id from dlv_order_items where order_id = $1", [pM.pedido_id]),
  (r: any[]) => r.length === 1 && r[0].item_name === "Filé de Frango Grelhado (Média)" && r[0].size_name === "Média" && r[0].size_id === fM.id || JSON.stringify(r));
await ok("cupom da cozinha, do bar e via do caixa mostram 'Filé de Frango Grelhado (Média)'", () => sql(
  "select j.kind, pp.code, dlv__conteudo_impressao(j.id) c from dlv_print_jobs j join pdv_production_points pp on pp.id = j.production_point_id where j.order_id = $1 order by pp.code", [pM.pedido_id]),
  (r: any[]) => r.length === 3
    && r.find((x) => x.code === "cozinha").c.itens[0].nome === "Filé de Frango Grelhado (Média)"
    && r.find((x) => x.code === "cerveja").c.itens[0].observacao === "junto com Filé de Frango Grelhado (Média)"
    && r.find((x) => x.kind === "via_entrega").c.itens[0].nome === "Filé de Frango Grelhado (Média)" || JSON.stringify(r).slice(0, 500));
await ok("cliente acompanha com 'Filé de Frango Grelhado (Média)'", () => como("anon", null, () => um("select dlv_acompanhar_pedido($1)", [pM.codigo])),
  (r: any) => r.itens[0].nome === "Filé de Frango Grelhado (Média)" || JSON.stringify(r.itens));
await ok("item sem tamanho (Batata Frita porção) continua funcionando", async () => {
  const r = await criar(pedidoT("17900000004", [{ item_id: batata.id, quantidade: 1 }]));
  return sql("select o.subtotal_cents, oi.item_name, oi.size_id from dlv_orders o join dlv_order_items oi on oi.order_id = o.id where o.id = $1", [r.pedido_id]);
}, (r: any[]) => r[0].subtotal_cents === 3490 && r[0].item_name === "Batata Frita" && r[0].size_id === null || JSON.stringify(r));
await recusa("mandar tamanho em item sem tamanho é recusado", () => criar(pedidoT("17900000005", [{ item_id: batata.id, tamanho_id: fP.id, quantidade: 1 }])), "não tem opção de tamanho");

await recusa("anônimo não ajusta tamanho", () => como("anon", null, () => sql("select dlv_ajustar_tamanho($1, true, null, null, 'x')", [fG.id])), "permission denied");
await recusa("logado sem painel não ajusta tamanho", () => como("authenticated", ESTRANHO, () => sql("select dlv_ajustar_tamanho($1, true, null, null, 'x')", [fG.id])), "Sem permissão");
await recusa("ajustar tamanho que não existe", () => como("authenticated", PAINEL, () => sql("select dlv_ajustar_tamanho(gen_random_uuid(), true, null, null, 'Caixa')")), "Tamanho não encontrado");
await ok("pausar a Grande tira só esse tamanho do cardápio", async () => {
  await como("authenticated", PAINEL, () => sql("select dlv_ajustar_tamanho($1, true, null, null, 'Caixa')", [fG.id]));
  return pratoDe(await como("anon", null, () => um("select dlv_cardapio_publico()")), "Especiais de Frango", "Filé de Frango Grelhado");
}, (i: any) => i.tamanhos.map((t: any) => t.sigla).join() === "P,M" || JSON.stringify(i?.tamanhos));
await recusa("pedido com tamanho pausado é recusado", () => criar(pedidoT("17900000006", [linhaT(frangoT, fG, [...opcFrango])])), 'Filé de Frango Grelhado (Grande)" não está disponível');
await ok("esgotar a Média: aparece esgotada no cardápio", async () => {
  await como("authenticated", PAINEL, () => sql("select dlv_ajustar_tamanho($1, null, true, null, 'Caixa')", [fM.id]));
  return tam(pratoDe(await como("anon", null, () => um("select dlv_cardapio_publico()")), "Especiais de Frango", "Filé de Frango Grelhado"), "Média");
}, (t: any) => t.esgotado === true || JSON.stringify(t));
await recusa("pedido com tamanho esgotado é recusado", () => criar(pedidoT("17900000006", [linhaT(frangoT, fM, [...opcFrango, ["Escolha o Acompanhamento", "Farofa"]])])), "esgotado");
await ok("preço da Pequena muda e o 'a partir de' acompanha", async () => {
  await como("authenticated", PAINEL, () => sql("select dlv_ajustar_tamanho($1, null, null, 2490, 'Caixa')", [fP.id]));
  const i = pratoDe(await como("anon", null, () => um("select dlv_cardapio_publico()")), "Especiais de Frango", "Filé de Frango Grelhado");
  const r = await criar(pedidoT("17900000007", [linhaT(frangoT, fP, opcFrango)]));
  return { item: i.preco_cents, p: tam(i, "Pequena").preco_cents, pedido: r.subtotal_cents };
}, (x: any) => x.item === 2490 && x.p === 2490 && x.pedido === 2490 || JSON.stringify(x));
await ok("histórico registra as mudanças de tamanho (quem, de quanto para quanto)", () => sql(
  "select target_name, field, old_value, new_value, by_name from dlv_menu_changes where target = 'tamanho' order by created_at, field"),
  (r: any[]) => r.length === 3
    && r.some((x) => x.target_name === "Filé de Frango Grelhado (Grande)" && x.field === "pausado" && x.old_value === "false" && x.new_value === "true")
    && r.some((x) => x.target_name === "Filé de Frango Grelhado (Média)" && x.field === "esgotado")
    && r.some((x) => x.target_name === "Filé de Frango Grelhado (Pequena)" && x.field === "preço" && x.old_value === "R$ 23,90" && x.new_value === "R$ 24,90" && x.by_name === "Caixa")
    || JSON.stringify(r));
await ok("todos os tamanhos pausados: o prato some do cardápio", async () => {
  await como("authenticated", PAINEL, async () => {
    await sql("select dlv_ajustar_tamanho($1, true, null, null, 'Caixa')", [fP.id]);
    await sql("select dlv_ajustar_tamanho($1, true, null, null, 'Caixa')", [fM.id]);
  });
  return pratoDe(await como("anon", null, () => um("select dlv_cardapio_publico()")), "Especiais de Frango", "Filé de Frango Grelhado");
}, (i: any) => i === undefined || JSON.stringify(i).slice(0, 200));

// ---------------------------------------------------------------- situação da loja, leitura leve (migration dlv_status_loja)
console.log("\n— Situação da loja (leitura leve)");
await ok("anônimo lê a situação da loja sem baixar o cardápio", () => como("anon", null, () => um("select dlv_status_loja()")),
  (r: any) => typeof r.aberta === "boolean" && typeof r.modo === "string" && Array.isArray(r.horarios) && !("categorias" in r) || JSON.stringify(r));
await ok("situação bate com a do cardápio público", async () => {
  const s = await como("anon", null, () => um("select dlv_status_loja()"));
  const m = await como("anon", null, () => um("select dlv_cardapio_publico()"));
  return s.aberta === m.loja.aberta;
});
await ok("loja forçada fechada aparece fechada", async () => {
  const antes = await um("select value from dlv_settings where key = 'store_mode'");
  await sql("UPDATE dlv_settings SET value = 'fechada' WHERE key = 'store_mode'");
  const r = await como("anon", null, () => um("select dlv_status_loja()"));
  await sql("UPDATE dlv_settings SET value = $1 WHERE key = 'store_mode'", [antes]);
  return r;
}, (r: any) => r.aberta === false && r.modo === "fechada" || JSON.stringify(r));

// ---------------------------------------------------------------- 14. um prato por variação (migration dlv_variacoes)
console.log("\n— Um prato por variação");
const menuV = await como("anon", null, () => um("select dlv_cardapio_publico()"));
const nomesVariacao = ["Escolha Sua Carne", "Escolha Seu Strogonoff", "Escolhe seu Filé de Frango", "Escolha seu Filé de Tilápia", "Escolha Sua Parmegiana"];
await ok("cardápio público não mostra nenhum grupo de variação", async () => JSON.stringify(menuV),
  (s: string) => nomesVariacao.every((n) => !s.includes(`"${n}"`)) || "achou grupo de variação");
const empanadoV = pratoDe(menuV, "Especiais de Frango", "Filé de Frango Empanado");
await ok("cardápio: 'Filé de Frango Empanado' P/M/G com o adicional embutido e só os complementos que continuam", async () => empanadoV,
  (i: any) => i.tamanhos.map((t: any) => `${t.sigla}${t.preco_cents}`).join() === "P2590,M2890,G3190" && i.preco_cents === 2590 && i.grupos.length === 0
    && i.tamanhos.every((t: any) => t.grupos.map((g: any) => g.nome).join() === "Escolha o Acompanhamento,+ Proteína,Bebidas") || JSON.stringify(i).slice(0, 400));
const empM = tam(empanadoV, "Média");
const opcEmpM: [string, string][] = [["Escolha o Acompanhamento", "Macarrão"], ["Escolha o Acompanhamento", "Farofa"]];
const pEmp = await ok("pedido 'Filé de Frango Empanado (Média)' com 2 acompanhamentos: 28,90", () => criar(pedidoT("17890000001", [linhaT(empanadoV, empM, opcEmpM)])),
  (r: any) => r.subtotal_cents === 2890 || JSON.stringify(r));
await ok("item do pedido sai 'Filé de Frango Empanado (Média)', sem complemento de variação", () => sql(
  `select oi.item_name, oi.size_name, oi.unit_price_cents,
          (select string_agg(x.option_name, ',' order by x.option_name) from dlv_order_item_options x where x.order_item_id = oi.id) opcoes
     from dlv_order_items oi where oi.order_id = $1`, [pEmp.pedido_id]),
  (r: any[]) => r.length === 1 && r[0].item_name === "Filé de Frango Empanado (Média)" && r[0].size_name === "Média" && r[0].unit_price_cents === 2890 && r[0].opcoes === "Farofa,Macarrão" || JSON.stringify(r));
await recusa("mandar a opção 'Empanado' do grupo de variação no prato novo é recusado", () => criar(pedidoT("17890000002", [
  { ...linhaT(empanadoV, empM, opcEmpM), opcoes: [...linhaT(empanadoV, empM, opcEmpM).opcoes, { opcao_id: ids.empanado }] }])), "Complemento inválido");
await recusa("prato original (inativo) não aceita pedido novo", () => criar(pedidoT("17890000002", [
  { item_id: frango0.id, tamanho_id: tam0(frango0, "Média").id, quantidade: 1, opcoes: [] }])), "não existe mais");
const cavaloV = pratoDe(menuV, "Especiais de Carne", "Bife a Cavalo");
await ok("pedido 'Bife a Cavalo (Pequena)': 26,90 = Bife 24,90 + 2,00", () => criar(pedidoT("17890000003", [
  linhaT(cavaloV, tam(cavaloV, "Pequena"), [["Escolha o Acompanhamento", "Farofa"]])])),
  (r: any) => r.subtotal_cents === 2690 || JSON.stringify(r));

// ---------------------------------------------------------------- 15. editar prato (migration dlv_edicao_painel)
console.log("\n— Editar prato pelo painel");
const tilapiaG = pratoDe(menuV, "Especiais de Peixe", "Filé de Tilápia Grelhado");
const catCarne = menuV.categorias.find((c: any) => c.nome === "Especiais de Carne").id;
const editar = (papel: "anon" | "authenticated", sub: string | null, args: any[]) =>
  como(papel, sub, () => um("select dlv_editar_item($1, $2, $3, $4, $5, $6, $7, $8)", args));
const semMudar = (extra: Record<number, any>) => { const a: any[] = [tilapiaG.id, null, null, null, null, null, null, "Gerente"]; for (const k in extra) a[k] = extra[k]; return a; };

await recusa("anônimo não edita prato", () => editar("anon", null, semMudar({ 1: "X" })), "permission denied");
await recusa("logado sem painel não edita prato", () => editar("authenticated", ESTRANHO, semMudar({ 1: "X" })), "Sem permissão");
await ok("painel muda nome, descrição, categoria, dias e foto", () => editar("authenticated", PAINEL,
  semMudar({ 1: "  Tilápia Grelhada  ", 2: "Tilápia na chapa com arroz e feijão.", 3: catCarne, 4: "{5,1,1}", 6: "https://exemplo.com.br/fotos/tilapia.jpg" })),
  (r: any) => r.nome === "Tilápia Grelhada" && r.categoria_id === catCarne && JSON.stringify(r.dias) === "[1,5]" && r.imagem_url === "https://exemplo.com.br/fotos/tilapia.jpg" || JSON.stringify(r));
await ok("histórico registra cada campo alterado, com antes e depois", () => sql(
  "select field, old_value, new_value, by_name, target, target_name from dlv_menu_changes where target_id = $1 and by_name = 'Gerente' order by field", [tilapiaG.id]),
  (r: any[]) => r.length === 5 && r.every((x) => x.by_name === "Gerente" && x.target === "item" && x.target_name === "Tilápia Grelhada")
    && r.some((x) => x.field === "nome" && x.old_value === "Filé de Tilápia Grelhado" && x.new_value === "Tilápia Grelhada")
    && r.some((x) => x.field === "descrição" && x.old_value.startsWith("Acompanha arroz") && x.new_value === "Tilápia na chapa com arroz e feijão.")
    && r.some((x) => x.field === "categoria" && x.old_value === "Especiais de Peixe" && x.new_value === "Especiais de Carne")
    && r.some((x) => x.field === "dias" && x.old_value === "todos os dias" && x.new_value === "seg, sex")
    && r.some((x) => x.field === "foto" && x.old_value === "/fotos-pratos/tilapia-grelhada.jpg" && x.new_value.endsWith("tilapia.jpg")) || JSON.stringify(r));
await ok("tudo NULL não muda nada nem registra histórico", async () => {
  await editar("authenticated", PAINEL, semMudar({}));
  return sql("select (select count(*)::int from dlv_menu_changes where target_id = $1 and by_name = 'Gerente') n, (select row(name, category_id, weekdays)::text from dlv_items where id = $1) item", [tilapiaG.id]);
}, (r: any[]) => r[0].n === 5 && r[0].item.includes("Tilápia Grelhada") && r[0].item.includes("{1,5}") || JSON.stringify(r));
const tilV = await ok("p_mudar_dias com dias NULL = todos os dias; foto com caminho '/'; prato aparece na categoria nova", async () => {
  await editar("authenticated", PAINEL, semMudar({ 5: true, 6: "/fotos/tilapia.webp" }));
  const i = pratoDe(await como("anon", null, () => um("select dlv_cardapio_publico()")), "Especiais de Carne", "Tilápia Grelhada");
  const dias = await um("select new_value from dlv_menu_changes where target_id = $1 and field = 'dias' order by created_at desc limit 1", [tilapiaG.id]);
  return { i, dias };
}, (x: any) => x.i?.imagem === "/fotos/tilapia.webp" && x.i.descricao === "Tilápia na chapa com arroz e feijão." && x.i.tamanhos.length === 3
  && !pratoDe(menuV, "Especiais de Carne", "Tilápia Grelhada") && x.dias === "todos os dias" || JSON.stringify(x).slice(0, 300));
await ok("pedido do prato editado sai com o nome novo", async () => {
  const r = await criar(pedidoT("17890000005", [linhaT(tilV.i, tam(tilV.i, "Pequena"), [["Escolha o Acompanhamento", "Macarrão"]])]));
  return sql("select o.subtotal_cents, oi.item_name from dlv_orders o join dlv_order_items oi on oi.order_id = o.id where o.id = $1", [r.pedido_id]);
}, (r: any[]) => r[0].subtotal_cents === 2590 && r[0].item_name === "Tilápia Grelhada (Pequena)" || JSON.stringify(r));
await ok("descrição em branco tira a descrição", async () => {
  await editar("authenticated", PAINEL, semMudar({ 2: "   " }));
  return sql("select description from dlv_items where id = $1", [tilapiaG.id]);
}, (r: any[]) => r[0].description === null || JSON.stringify(r));
const catInativa = await um("insert into dlv_categories (name, is_active) values ('Categoria Antiga', false) returning id");
await recusa("nome vazio", () => editar("authenticated", PAINEL, semMudar({ 1: "   " })), "não pode ficar vazio");
await recusa("nome com mais de 80 caracteres", () => editar("authenticated", PAINEL, semMudar({ 1: "x".repeat(81) })), "Nome muito longo");
await recusa("descrição com mais de 500 caracteres", () => editar("authenticated", PAINEL, semMudar({ 2: "x".repeat(501) })), "Descrição muito longa");
await recusa("categoria que não existe", () => editar("authenticated", PAINEL, semMudar({ 3: "00000000-0000-0000-0000-000000000001" })), "Categoria não encontrada");
await recusa("categoria inativa", () => editar("authenticated", PAINEL, semMudar({ 3: catInativa })), "Categoria não encontrada");
await recusa("dia fora de 0 a 6", () => editar("authenticated", PAINEL, semMudar({ 4: "{1,7}" })), "Dias da semana");
await recusa("foto com http://", () => editar("authenticated", PAINEL, semMudar({ 6: "http://exemplo.com/x.jpg" })), "foto inválido");
await recusa("foto com //outro-site", () => editar("authenticated", PAINEL, semMudar({ 6: "//evil.com/x.jpg" })), "foto inválido");
await recusa("foto com barra invertida", () => editar("authenticated", PAINEL, semMudar({ 6: "/\\evil.com/x.jpg" })), "foto inválido");
await recusa("foto com javascript:", () => editar("authenticated", PAINEL, semMudar({ 6: "javascript:alert(1)" })), "foto inválido");
await recusa("prato inativo (original das variações) não é editado", () => editar("authenticated", PAINEL, semMudar({ 0: frango0.id, 1: "Volta" })), "Item não encontrado");
await recusa("sem operador", () => editar("authenticated", PAINEL, semMudar({ 1: "Outro", 7: " " })), "Informe quem está operando");
await ok("recusas não gravaram nada", () => sql("select name, image_url, (select count(*)::int from dlv_menu_changes where target_id = $1 and by_name = 'Gerente') n from dlv_items where id = $1", [tilapiaG.id]),
  (r: any[]) => r[0].name === "Tilápia Grelhada" && r[0].image_url === "/fotos/tilapia.webp" && r[0].n === 8 || JSON.stringify(r));

// ---------------------------------------------------------------- 16. horários de funcionamento (migration dlv_edicao_painel)
console.log("\n— Horários de funcionamento");
const salvar = (papel: "anon" | "authenticated", sub: string | null, h: any) =>
  como(papel, sub, () => um("select dlv_salvar_horarios($1, 'Gerente')", [JSON.stringify(h)]));
const horariosTabela = async () => (await sql("select weekday, to_char(opens_at, 'HH24:MI') a, to_char(closes_at, 'HH24:MI') f from dlv_opening_hours order by 1, 2"))
  .map((x: any) => `${x.weekday} ${x.a}-${x.f}`).join("; ");

await recusa("anônimo não salva horários", () => salvar("anon", null, []), "permission denied");
await recusa("logado sem painel não salva horários", () => salvar("authenticated", ESTRANHO, []), "Sem permissão");
await ok("painel salva: duas faixas na segunda, faixas encostadas na sexta", () => salvar("authenticated", PAINEL, [
  { dia: 5, abre: "15:00", fecha: "16:30" }, { dia: 1, abre: "18:00", fecha: "22:00" }, { dia: 1, abre: "10:00", fecha: "14:00" }, { dia: 5, abre: "11:00", fecha: "15:00" }]),
  (r: any) => r.horarios.map((h: any) => `${h.dia} ${h.abre}-${h.fecha}`).join("; ") === "1 10:00-14:00; 1 18:00-22:00; 5 11:00-15:00; 5 15:00-16:30" || JSON.stringify(r));
await ok("tabela substituída por inteiro (o horário antigo de hoje sumiu)", () => horariosTabela(), (s: string) => s === "1 10:00-14:00; 1 18:00-22:00; 5 11:00-15:00; 5 15:00-16:30" || s);
await ok("histórico guarda o resumo antes e depois", () => sql("select old_value, new_value, by_name, target from dlv_menu_changes where field = 'horários' order by created_at"),
  (r: any[]) => r.length === 1 && r[0].target === "loja" && r[0].old_value.includes("00:00-23:59")
    && r[0].new_value === "seg 10:00-14:00; seg 18:00-22:00; sex 11:00-15:00; sex 15:00-16:30" && r[0].by_name === "Gerente" || JSON.stringify(r));
await recusa("faixas sobrepostas no mesmo dia", () => salvar("authenticated", PAINEL, [{ dia: 2, abre: "10:00", fecha: "14:00" }, { dia: 2, abre: "13:00", fecha: "15:00" }]), "se sobrepõem");
await recusa("faixa dentro de outra", () => salvar("authenticated", PAINEL, [{ dia: 3, abre: "10:00", fecha: "20:00" }, { dia: 3, abre: "12:00", fecha: "13:00" }]), "se sobrepõem");
await recusa("fecha igual a abre", () => salvar("authenticated", PAINEL, [{ dia: 2, abre: "14:00", fecha: "14:00" }]), "precisa ser depois");
await recusa("fecha antes de abre", () => salvar("authenticated", PAINEL, [{ dia: 2, abre: "15:00", fecha: "10:00" }]), "precisa ser depois");
await recusa("mais de 3 faixas no mesmo dia", () => salvar("authenticated", PAINEL, [
  { dia: 4, abre: "08:00", fecha: "09:00" }, { dia: 4, abre: "09:00", fecha: "10:00" }, { dia: 4, abre: "10:00", fecha: "11:00" }, { dia: 4, abre: "11:00", fecha: "12:00" }]), "no máximo 3");
await recusa("hora sem zero à esquerda", () => salvar("authenticated", PAINEL, [{ dia: 1, abre: "9:00", fecha: "14:00" }]), "Horário inválido");
await recusa("dia 7", () => salvar("authenticated", PAINEL, [{ dia: 7, abre: "09:00", fecha: "14:00" }]), "Horário inválido");
await recusa("dia como texto", () => salvar("authenticated", PAINEL, [{ dia: "1", abre: "09:00", fecha: "14:00" }]), "Horário inválido");
await recusa("24:00 não existe", () => salvar("authenticated", PAINEL, [{ dia: 1, abre: "09:00", fecha: "24:00" }]), "Horário inválido");
await recusa("não é lista", () => salvar("authenticated", PAINEL, { dia: 1 }), "lista");
await ok("recusas não mexeram nos horários nem no histórico", async () => ({
  t: await horariosTabela(), n: await um("select count(*)::int from dlv_menu_changes where field = 'horários'") }),
  (x: any) => x.t === "1 10:00-14:00; 1 18:00-22:00; 5 11:00-15:00; 5 15:00-16:30" && x.n === 1 || JSON.stringify(x));
await ok("lista vazia: sem horários, e no modo automático a loja fica fechada", async () => {
  const r = await salvar("authenticated", PAINEL, []);
  const loja = await como("authenticated", PAINEL, () => um("select dlv_configurar_loja('auto', null, 'Gerente')"));
  const hist = await um("select new_value from dlv_menu_changes where field = 'horários' order by created_at desc limit 1");
  await como("authenticated", PAINEL, () => um("select dlv_configurar_loja('aberta', null, 'Gerente')"));
  return { h: r.horarios.length, linhas: await um("select count(*)::int from dlv_opening_hours"), aberta: loja.aberta, hist };
}, (x: any) => x.h === 0 && x.linhas === 0 && x.aberta === false && x.hist === "nenhum horário" || JSON.stringify(x));

// ---------------------------------------------------------------- 17. Storage das fotos (migration dlv_edicao_painel)
console.log("\n— Storage das fotos (dlv-fotos)");
await ok("bucket dlv-fotos (já existia) ficou público, 2 MB, só jpeg/png/webp", () => sql(
  "select public, file_size_limit::int lim, array_to_string(allowed_mime_types, ',') mimes from storage.buckets where id = 'dlv-fotos'"),
  (r: any[]) => r[0].public === true && r[0].lim === 2097152 && r[0].mimes === "image/jpeg,image/png,image/webp" || JSON.stringify(r));
await ok("4 políticas em storage.objects, todas com bucket_id = 'dlv-fotos'", () => sql(
  "select policyname, cmd, roles::text roles, coalesce(qual, '') q, coalesce(with_check, '') w from pg_policies where schemaname = 'storage' and tablename = 'objects' order by policyname"),
  (r: any[]) => r.length === 4 && r.every((x) => (x.q === "" || x.q.includes("'dlv-fotos'")) && (x.w === "" || x.w.includes("'dlv-fotos'")))
    && r.filter((x) => x.cmd !== "SELECT").every((x) => x.roles === "{authenticated}" && (x.q + x.w).includes("pdv_is_panel_user()")) || JSON.stringify(r));
const novaFoto = (bucket: string, nome: string) => sql("insert into storage.objects (bucket_id, name) values ($1, $2) returning id", [bucket, nome]);
await recusa("anônimo não envia foto", () => como("anon", null, () => novaFoto("dlv-fotos", "anon.jpg")), "row-level security");
await recusa("logado sem painel não envia foto", () => como("authenticated", ESTRANHO, () => novaFoto("dlv-fotos", "estranho.jpg")), "row-level security");
await ok("usuário do painel envia foto", () => como("authenticated", PAINEL, () => novaFoto("dlv-fotos", "pratos/bife.jpg")), (r: any[]) => r.length === 1);
await recusa("usuário do painel não envia em outro bucket", () => como("authenticated", PAINEL, () => novaFoto("outro", "x.jpg")), "row-level security");
await um("insert into storage.objects (bucket_id, name) values ('outro', 'segredo.txt') returning id");
await ok("anônimo lê a foto do dlv-fotos, mas não vê objeto de outro bucket", () => como("anon", null, () => sql("select bucket_id, name from storage.objects order by name")),
  (r: any[]) => r.length === 1 && r[0].name === "pratos/bife.jpg" || JSON.stringify(r));
const fotosNoBucket = () => um("select count(*)::int from storage.objects where bucket_id = 'dlv-fotos'");
await ok("anônimo não apaga foto (nenhuma linha afetada)", async () => ({
  apagou: (await como("anon", null, () => sql("delete from storage.objects where bucket_id = 'dlv-fotos' returning id"))).length, sobrou: await fotosNoBucket() }),
  (x: any) => x.apagou === 0 && x.sobrou === 1 || JSON.stringify(x));
await ok("logado sem painel não apaga nem troca foto", async () => ({
  apagou: (await como("authenticated", ESTRANHO, () => sql("delete from storage.objects where bucket_id = 'dlv-fotos' returning id"))).length,
  trocou: (await como("authenticated", ESTRANHO, () => sql("update storage.objects set name = 'hack.jpg' where bucket_id = 'dlv-fotos' returning id"))).length,
  nome: await um("select name from storage.objects where bucket_id = 'dlv-fotos'") }),
  (x: any) => x.apagou === 0 && x.trocou === 0 && x.nome === "pratos/bife.jpg" || JSON.stringify(x));
await recusa("usuário do painel não move foto para outro bucket", () => como("authenticated", PAINEL, () => sql("update storage.objects set bucket_id = 'outro' where bucket_id = 'dlv-fotos'")), "row-level security");
await ok("usuário do painel troca e apaga foto do dlv-fotos, sem tocar em outro bucket", async () => ({
  trocou: (await como("authenticated", PAINEL, () => sql("update storage.objects set name = 'pratos/bife-2.jpg' where bucket_id = 'dlv-fotos' returning id"))).length,
  apagou: (await como("authenticated", PAINEL, () => sql("delete from storage.objects returning bucket_id"))).map((x: any) => x.bucket_id).join(),
  outro: await um("select count(*)::int from storage.objects where bucket_id = 'outro'") }),
  (x: any) => x.trocou === 1 && x.apagou === "dlv-fotos" && x.outro === 1 || JSON.stringify(x));

// ---------------------------------------------------------------- 18. pagamento online (migration dlv_pagamento_online)
console.log("\n— Pagamento online (Checkout Pro)");
await sql("UPDATE dlv_settings SET value = 'aberta' WHERE key = 'store_mode'");
await sql("UPDATE dlv_settings SET value = 'true' WHERE key = 'auto_accept'");
const cuponsDe = (id: string) => um("select count(*)::int from dlv_print_jobs where order_id = $1", [id]);
const eventosCom = (id: string, nota: string) => um("select count(*)::int from dlv_order_events where order_id = $1 and note = $2", [id, nota]);
const pedidoDb = async (id: string) => (await sql(`select status, cancel_kind, cancel_reason, payment_method, change_for_cents, paid_at is not null as pago,
  accepted_at is not null as aceito, mp_payment_id, mp_payment_type, mp_preference_id, mp_checkout_url from dlv_orders where id = $1`, [id]))[0];
const pedidoOnline = (tel: string) => pedido({ modo: "retirada", cliente: { nome: "Online Teste", telefone: tel }, pagamento: { forma: "online", troco_para_cents: 5000 } });
const paraPagamento = (codigo: string) => como("service_role", null, () => um("select dlv_pedido_para_pagamento($1)", [codigo]));
const registrarCheckout = (id: string, pref: string, url: string) => como("service_role", null, () => sql("select dlv_registrar_checkout($1, $2, $3)", [id, pref, url]));
const confirmarOnline = (id: string, mp: string, valor: number, tipo: string | null) =>
  como("service_role", null, () => um("select dlv_confirmar_pagamento_online($1, $2, $3, $4)", [id, mp, valor, tipo]));
const acompanhar = (codigo: string) => como("anon", null, () => um("select dlv_acompanhar_pedido($1)", [codigo]));
async function esvaziarFila() {
  const todos: any[] = [];
  for (let i = 0; i < 20; i++) {
    const r = await como("authenticated", TERMINAL, () => um("select dlv_reservar_impressoes(50)"));
    if (!r.length) break;
    await como("authenticated", TERMINAL, async () => { for (const j of r) await sql("select dlv_concluir_impressao($1, true)", [j.trabalho_id]); });
    todos.push(...r);
  }
  return todos;
}

// Pix na entrega: fora do cardápio público (decisão do dono), continua no painel
await recusa("cardápio recusa 'pix_entrega'", () => criar(pedido({
  cliente: { nome: "Pix Entrega", telefone: "17870000001" }, pagamento: { forma: "pix_entrega" } })), "Escolha a forma de pagamento");
const pixEntrega = await ok("painel continua lançando 'pix_entrega': vai direto para produção, sem esperar pagamento", () => como("authenticated", PAINEL, () =>
  um("select dlv_criar_pedido_painel($1, 'Caixa')", [JSON.stringify(pedido({ cliente: { nome: "Pix Entrega", telefone: "17870000001" }, pagamento: { forma: "pix_entrega" } }))])),
  (r: any) => r.status === "em_producao" && r.pix_expira_em === null || JSON.stringify(r));
await ok("pedido 'pix_entrega' do painel: não pago, com os 3 cupons", async () => ({ o: await pedidoDb(pixEntrega.pedido_id), c: await cuponsDe(pixEntrega.pedido_id) }),
  (x: any) => x.o.payment_method === "pix_entrega" && !x.o.pago && x.o.aceito && x.c === 3 || JSON.stringify(x));

// cardápio, configuração e acesso
await ok("cardápio público lista as formas ['online', 'dinheiro', 'credito', 'debito']", () => como("anon", null, () => um("select dlv_cardapio_publico()")),
  (m: any) => JSON.stringify(m.loja.formas_pagamento) === JSON.stringify(["online", "dinheiro", "credito", "debito"]) || JSON.stringify(m.loja.formas_pagamento));
await ok("configuração online_payment_expiration_minutes = 30, com descrição", () => sql("select value, description from dlv_settings where key = 'online_payment_expiration_minutes'"),
  (r: any[]) => r.length === 1 && r[0].value === "30" && r[0].description?.length > 10 || JSON.stringify(r));
await recusa("anônimo não executa dlv_pedido_para_pagamento", () => como("anon", null, () => sql("select dlv_pedido_para_pagamento($1)", ["0".repeat(32)])), "permission denied");
await recusa("anônimo não executa dlv_registrar_checkout", () => como("anon", null, () => sql("select dlv_registrar_checkout(gen_random_uuid(), 'x', 'https://x.com')")), "permission denied");
await recusa("anônimo não executa dlv_confirmar_pagamento_online", () => como("anon", null, () => sql("select dlv_confirmar_pagamento_online(gen_random_uuid(), 'x', 1, 'pix')")), "permission denied");
await recusa("usuário do painel também não confirma pagamento online", () => como("authenticated", PAINEL, () => sql("select dlv_confirmar_pagamento_online(gen_random_uuid(), 'x', 1, 'pix')")), "permission denied");
await recusa("usuário do painel não lê pedido para pagamento", () => como("authenticated", PAINEL, () => sql("select dlv_pedido_para_pagamento($1)", ["0".repeat(32)])), "permission denied");
await ok("anônimo executa só as 5 funções públicas do delivery", () => sql(`select string_agg(p.proname, ',' order by p.proname) f from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and left(p.proname, 4) = 'dlv_' and has_function_privilege('anon', p.oid, 'EXECUTE')`),
  (r: any[]) => r[0].f === "dlv_acompanhar_pedido,dlv_cardapio_publico,dlv_consultar_entrega,dlv_criar_pedido,dlv_status_loja" || r[0].f);

// criar
const on1 = await ok("pedido 'online' nasce aguardando pagamento, com prazo", () => criar(pedidoOnline("17870000002")),
  (r: any) => r.status === "aguardando_pagamento" && !!r.pix_expira_em && r.total_cents === 2940 || JSON.stringify(r));
await ok("pedido 'online' aguardando: sem cupom, sem troco, não aceito, prazo de 30 min", async () => ({
  c: await cuponsDe(on1.pedido_id), o: await pedidoDb(on1.pedido_id),
  prazo: await um("select pix_expires_at between now() + interval '29 minutes' and now() + interval '31 minutes' from dlv_orders where id = $1", [on1.pedido_id]) }),
  (x: any) => x.c === 0 && x.o.payment_method === "online" && x.o.change_for_cents === null && !x.o.pago && !x.o.aceito && x.prazo === true || JSON.stringify(x));
await ok("estação não recebe cupom do pedido aguardando pagamento", async () => (await esvaziarFila()).filter((j: any) => j.pedido.numero === on1.numero).length, (n: number) => n === 0 || `${n} cupons`);
await recusa("painel não lança pedido 'online'", () => como("authenticated", PAINEL, () => um("select dlv_criar_pedido_painel($1, 'Caixa')", [JSON.stringify(pedidoOnline("17870000003"))])), "forma de pagamento");
await recusa("painel não aceita pedido online não pago", () => como("authenticated", PAINEL, () => sql("select dlv_avancar_pedido($1, 'em_producao', 'Caixa')", [on1.pedido_id])), "não pode ir");

// dados para o checkout
await ok("Edge Function lê o pedido para montar o checkout", () => paraPagamento(on1.codigo),
  (r: any) => r.id === on1.pedido_id && r.numero === on1.numero && r.status === "aguardando_pagamento" && r.forma === "online" && r.total_cents === 2940
    && r.cliente_nome === "Online Teste" && r.cliente_telefone === "17870000002" && !!r.expira_em && r.preference_id === null && r.checkout_url === null
    && r.itens.length === 1 && r.itens[0].nome === "Filé de Frango Empanado (Pequena)" && r.itens[0].quantidade === 1 && r.itens[0].total_cents === 2940 || JSON.stringify(r));
await recusa("pedido para pagamento: código inválido", () => paraPagamento("abc"), "Pedido não encontrado");
await recusa("pedido para pagamento: código que não existe", () => paraPagamento("f".repeat(32)), "Pedido não encontrado");

// registrar checkout
const URL1 = "https://www.mercadopago.com.br/checkout/v1/redirect?pref_id=pref-1";
await recusa("checkout com link sem https é recusado", () => registrarCheckout(on1.pedido_id, "pref-1", "http://www.mercadopago.com.br/x"), "https://");
await recusa("checkout sem preferência é recusado", () => registrarCheckout(on1.pedido_id, "  ", URL1), "sem identificador");
const pixAntigo = await criar(pedido({ cliente: { nome: "Pix Antigo", telefone: "17870000004" }, pagamento: { forma: "pix_online" } }));
await recusa("checkout em pedido Pix online (não é 'online') é recusado", () => registrarCheckout(pixAntigo.pedido_id, "pref-x", URL1), "Pedido não está aguardando pagamento online");
await recusa("checkout em pedido Pix na entrega é recusado", () => registrarCheckout(pixEntrega.pedido_id, "pref-x", URL1), "Pedido não está aguardando pagamento online");
await ok("registra a preferência do checkout", async () => { await registrarCheckout(on1.pedido_id, " pref-1 ", URL1); return paraPagamento(on1.codigo); },
  (r: any) => r.preference_id === "pref-1" && r.checkout_url === URL1 || JSON.stringify(r));
await ok("cliente acompanha: link e prazo do pagamento enquanto aguarda", () => acompanhar(on1.codigo),
  (r: any) => r.status === "aguardando_pagamento" && r.pagamento_link === URL1 && !!r.pagamento_expira_em && r.pagamento === "online" && r.pago === false || JSON.stringify(r));

// confirmar
await recusa("valor pago diferente do total é recusado", () => confirmarOnline(on1.pedido_id, "mp-on-1", 100, "pix"), "diferente do total");
await recusa("pagamento de pedido que não existe", () => confirmarOnline("00000000-0000-0000-0000-00000000abcd", "mp-on-x", 2940, "pix"), "não pertence a nenhum pedido");
await recusa("confirmar pagamento online em pedido Pix online é recusado", () => confirmarOnline(pixAntigo.pedido_id, "mp-on-y", 2940, "pix"), "não é de pagamento online");
await ok("pagamento confirmado com aceite automático: vai para produção", () => confirmarOnline(on1.pedido_id, "mp-on-1", 2940, "pix"),
  (r: any) => r.numero === on1.numero && r.status === "em_producao" && r.ja_confirmado === false || JSON.stringify(r));
await ok("gravou id, tipo e pago; gerou os 3 cupons; auditoria 'Mercado Pago' + aceite automático", async () => ({
  o: await pedidoDb(on1.pedido_id), c: await cuponsDe(on1.pedido_id),
  ev: await sql("select to_status, by_name, note from dlv_order_events where order_id = $1", [on1.pedido_id]) }),
  (x: any) => x.o.pago && x.o.aceito && x.o.mp_payment_id === "mp-on-1" && x.o.mp_payment_type === "pix" && x.c === 3
    && x.ev.some((e: any) => e.to_status === "em_analise" && e.by_name === "Mercado Pago" && e.note === "Pagamento online confirmado")
    && x.ev.some((e: any) => e.to_status === "em_producao" && e.by_name === "aceite automático") || JSON.stringify(x));
await ok("estação recebe os cupons do pedido online com pagamento='online', pago=true e mp_payment_type='pix'", async () =>
  (await esvaziarFila()).filter((j: any) => j.pedido.numero === on1.numero),
  (r: any[]) => r.length === 3 && r.filter((j) => j.tipo === "producao").length === 2
    && r.every((j) => j.pedido.pagamento === "online" && j.pedido.pago === true && j.pedido.mp_payment_type === "pix") || JSON.stringify(r.map((j: any) => [j.tipo, j.pedido])));
await ok("cupom de pedido sem pagamento online traz mp_payment_type null", async () => {
  const p = await criar(pedido({ cliente: { nome: "Cupom Dinheiro", telefone: "17870000009" } }));
  return (await esvaziarFila()).filter((j: any) => j.pedido.numero === p.numero);
}, (r: any[]) => r.length === 3 && r.every((j) => "mp_payment_type" in j.pedido && j.pedido.mp_payment_type === null && j.pedido.pagamento === "dinheiro" && j.pedido.pago === false) || JSON.stringify(r.map((j: any) => j.pedido)));
await ok("webhook repetido (mesmo id) não duplica", async () => ({ r: await confirmarOnline(on1.pedido_id, "mp-on-1", 2940, "pix"), c: await cuponsDe(on1.pedido_id) }),
  (x: any) => x.r.ja_confirmado === true && x.r.status === "em_producao" && x.r.numero === on1.numero && x.c === 3 || JSON.stringify(x));
await ok("outro pagamento no mesmo pedido: avisa estorno (duplicado) sem mudar o pedido", async () => ({
  r: await confirmarOnline(on1.pedido_id, "mp-on-2", 2940, "credit_card"), o: await pedidoDb(on1.pedido_id),
  ev: await eventosCom(on1.pedido_id, "Pagamento online DUPLICADO (id mp-on-2): ESTORNAR"), c: await cuponsDe(on1.pedido_id) }),
  (x: any) => x.r.precisa_estorno === true && x.r.motivo === "duplicado" && x.r.status === "em_producao"
    && x.o.status === "em_producao" && x.o.mp_payment_id === "mp-on-1" && x.o.mp_payment_type === "pix" && x.ev === 1 && x.c === 3 || JSON.stringify(x));
await ok("acompanhar depois de pago: sem link nem prazo", () => acompanhar(on1.codigo),
  (r: any) => r.status === "em_producao" && r.pago === true && r.pagamento_link === null && r.pagamento_expira_em === null || JSON.stringify(r));
const on5 = await criar(pedidoOnline("17870000010"));
await recusa("id de pagamento já ligado a outro pedido é recusado", () => confirmarOnline(on5.pedido_id, "mp-on-1", 2940, "pix"), "já está ligado a outro pedido");

await sql("UPDATE dlv_settings SET value = 'false' WHERE key = 'auto_accept'");
const on2 = await criar(pedidoOnline("17870000005"));
await ok("sem aceite automático: pagamento confirmado fica em análise e não imprime", async () => ({
  r: await confirmarOnline(on2.pedido_id, "mp-on-3", 2940, "credit_card"), c: await cuponsDe(on2.pedido_id), o: await pedidoDb(on2.pedido_id) }),
  (x: any) => x.r.status === "em_analise" && x.r.ja_confirmado === false && x.c === 0 && x.o.pago && x.o.mp_payment_type === "credit_card" || JSON.stringify(x));
await sql("UPDATE dlv_settings SET value = 'true' WHERE key = 'auto_accept'");

// expiração
const on3 = await criar(pedidoOnline("17870000006"));
const pix3 = await criar(pedido({ cliente: { nome: "Pix Vence", telefone: "17870000007" }, pagamento: { forma: "pix_online" } }));
await registrarCheckout(on3.pedido_id, "pref-3", "https://www.mercadopago.com.br/checkout/v1/redirect?pref_id=pref-3");
await sql("update dlv_orders set pix_expires_at = now() - interval '1 minute' where id = any($1::uuid[])", [[on3.pedido_id, pix3.pedido_id]]);
await ok("online vencido: cancelado (pix_expirado) com 'Pagamento online não feito a tempo', sem link", () => acompanhar(on3.codigo),
  (r: any) => r.status === "cancelado" && r.cancelamento === "pix_expirado" && r.motivo_cancelamento === "Pagamento online não feito a tempo"
    && r.pagamento_link === null && r.pagamento_expira_em === null || JSON.stringify(r));
await ok("Pix online vencido continua 'Pix não pago a tempo'; auditoria com o texto de cada forma", () => sql(`
  select o.payment_method, o.cancel_reason, e.note, e.by_name from dlv_orders o join dlv_order_events e on e.order_id = o.id and e.to_status = 'cancelado'
   where o.id = any($1::uuid[]) order by o.payment_method`, [[on3.pedido_id, pix3.pedido_id]]),
  (r: any[]) => r.length === 2 && r[0].payment_method === "online" && r[0].cancel_reason === "Pagamento online não feito a tempo" && r[0].note === r[0].cancel_reason
    && r[1].payment_method === "pix_online" && r[1].cancel_reason === "Pix não pago a tempo" && r[1].note === "Pix não pago a tempo"
    && r.every((x) => x.by_name === "sistema") || JSON.stringify(r));
await recusa("checkout não é registrado em pedido online vencido", () => registrarCheckout(on3.pedido_id, "pref-3b", "https://x.com/y"), "Pedido não está aguardando pagamento online");
await ok("pagou depois do prazo: pedido reabre e vai para produção", async () => ({
  r: await confirmarOnline(on3.pedido_id, "mp-on-4", 2940, "pix"), o: await pedidoDb(on3.pedido_id),
  ev: await eventosCom(on3.pedido_id, "Pagamento online feito depois do prazo: pedido reaberto"), c: await cuponsDe(on3.pedido_id) }),
  (x: any) => x.r.status === "em_producao" && x.r.ja_confirmado === false && x.o.cancel_kind === null && x.o.cancel_reason === null
    && x.o.pago && x.o.mp_payment_id === "mp-on-4" && x.ev === 1 && x.c === 3 || JSON.stringify(x));

// cancelado pela loja
const on4 = await criar(pedidoOnline("17870000008"));
await ok("painel recusa pedido online ainda não pago: sem estorno", () => como("authenticated", PAINEL, () => um("select dlv_cancelar_pedido($1, 'cliente desistiu', 'Caixa')", [on4.pedido_id])),
  (r: any) => r.tipo === "recusado" && r.precisa_estorno === false || JSON.stringify(r));
await ok("pagamento em pedido cancelado pela loja: grava e avisa estorno", async () => ({
  r: await confirmarOnline(on4.pedido_id, "mp-on-5", 2940, "credit_card"), o: await pedidoDb(on4.pedido_id),
  ev: await eventosCom(on4.pedido_id, "Pagamento online em pedido cancelado: ESTORNAR"), c: await cuponsDe(on4.pedido_id) }),
  (x: any) => x.r.precisa_estorno === true && x.r.motivo === "cancelado" && x.r.status === "cancelado" && x.o.status === "cancelado" && x.o.cancel_kind === "recusado"
    && x.o.pago && x.o.mp_payment_id === "mp-on-5" && x.o.mp_payment_type === "credit_card" && x.ev === 1 && x.c === 0 || JSON.stringify(x));
await ok("webhook repetido no cancelado pago: ja_confirmado, continua cancelado", () => confirmarOnline(on4.pedido_id, "mp-on-5", 2940, "credit_card"),
  (r: any) => r.ja_confirmado === true && r.status === "cancelado" || JSON.stringify(r));
await ok("painel cancela pedido online pago: precisa_estorno", () => como("authenticated", PAINEL, () => um("select dlv_cancelar_pedido($1, 'acabou o frango', 'Caixa')", [on1.pedido_id])),
  (r: any) => r.tipo === "cancelado" && r.precisa_estorno === true || JSON.stringify(r));

// ---------------------------------------------------------------- 19. checkout transparente (migration dlv_checkout_transparente)
console.log("\n— Checkout transparente");
const registrarPagamento = (id: string, mp: string | null, tipo: string | null, pix: string | null) =>
  como("service_role", null, () => sql("select dlv_registrar_pagamento_online($1, $2, $3, $4)", [id, mp, tipo, pix]));
const pagamentoDb = async (id: string) => (await sql("select mp_payment_id, mp_payment_type, pix_copy_paste, paid_at is not null as pago, status from dlv_orders where id = $1", [id]))[0];
const PIX1 = "00020126580014br.gov.bcb.pix0136chave-teste5204000053039865802BR6304ABCD";

await recusa("anônimo não executa dlv_registrar_pagamento_online", () => como("anon", null, () => sql("select dlv_registrar_pagamento_online(gen_random_uuid(), 'x', 'pix', 'y')")), "permission denied");
await recusa("logado sem painel não executa dlv_registrar_pagamento_online", () => como("authenticated", ESTRANHO, () => sql("select dlv_registrar_pagamento_online(gen_random_uuid(), 'x', 'pix', 'y')")), "permission denied");
await recusa("usuário do painel não executa dlv_registrar_pagamento_online", () => como("authenticated", PAINEL, () => sql("select dlv_registrar_pagamento_online(gen_random_uuid(), 'x', 'pix', 'y')")), "permission denied");
await ok("anônimo continua executando só as 5 funções públicas do delivery", () => sql(`select string_agg(p.proname, ',' order by p.proname) f from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and left(p.proname, 4) = 'dlv_' and has_function_privilege('anon', p.oid, 'EXECUTE')`),
  (r: any[]) => r[0].f === "dlv_acompanhar_pedido,dlv_cardapio_publico,dlv_consultar_entrega,dlv_criar_pedido,dlv_status_loja" || r[0].f);

const tr1 = await criar(pedidoOnline("17860000001"));
await ok("pedido para pagamento antes de registrar: chaves novas vazias, pago=false", () => paraPagamento(tr1.codigo),
  (r: any) => r.mp_payment_id === null && r.mp_payment_type === null && r.pix_copia_cola === null && r.pago === false && r.tentativas_cartao === 0 || JSON.stringify(r));
await ok("registra Pix em pedido online aguardando: grava id (sem espaços), tipo e copia e cola", async () => {
  await registrarPagamento(tr1.pedido_id, " mp-tr-1 ", " pix ", PIX1);
  return pagamentoDb(tr1.pedido_id);
}, (o: any) => o.mp_payment_id === "mp-tr-1" && o.mp_payment_type === "pix" && o.pix_copy_paste === PIX1 && !o.pago && o.status === "aguardando_pagamento" || JSON.stringify(o));
await ok("dlv_pedido_para_pagamento mantém as chaves antigas e traz mp_payment_id, mp_payment_type, pix_copia_cola e pago", () => paraPagamento(tr1.codigo),
  (r: any) => Object.keys(r).sort().join() === ["id", "numero", "status", "forma", "total_cents", "cliente_nome", "cliente_telefone", "expira_em",
    "preference_id", "checkout_url", "itens", "mp_payment_id", "mp_payment_type", "pix_copia_cola", "pago", "tentativas_cartao"].sort().join()
    && r.id === tr1.pedido_id && r.total_cents === 2940 && r.itens.length === 1
    && r.mp_payment_id === "mp-tr-1" && r.mp_payment_type === "pix" && r.pix_copia_cola === PIX1 && r.pago === false || JSON.stringify(r));
await ok("nova tentativa (cartão) sobrescreve: id e tipo novos, copia e cola vazio vira null", async () => {
  await registrarPagamento(tr1.pedido_id, "mp-tr-2", "credit_card", "   ");
  return pagamentoDb(tr1.pedido_id);
}, (o: any) => o.mp_payment_id === "mp-tr-2" && o.mp_payment_type === "credit_card" && o.pix_copy_paste === null && !o.pago || JSON.stringify(o));
await ok("tipo vazio vira null; tipo e copia e cola compridos são cortados (40 e 1000)", async () => {
  await registrarPagamento(tr1.pedido_id, "mp-tr-3", "", "x".repeat(1500));
  const vazio = await pagamentoDb(tr1.pedido_id);
  await registrarPagamento(tr1.pedido_id, "mp-tr-2", "t".repeat(60), null);
  const longo = await pagamentoDb(tr1.pedido_id);
  return { vazio, longo };
}, (x: any) => x.vazio.mp_payment_type === null && x.vazio.pix_copy_paste.length === 1000
  && x.longo.mp_payment_id === "mp-tr-2" && x.longo.mp_payment_type.length === 40 && x.longo.pix_copy_paste === null || JSON.stringify(x).slice(0, 300));
await registrarPagamento(tr1.pedido_id, "mp-tr-2", "credit_card", null);

const trDinheiro = await criar(pedido({ cliente: { nome: "Transp Dinheiro", telefone: "17860000002" } }));
const trPix = await criar(pedido({ cliente: { nome: "Transp Pix", telefone: "17860000003" }, pagamento: { forma: "pix_online" } }));
const trCancelado = await criar(pedidoOnline("17860000004"));
await como("authenticated", PAINEL, () => um("select dlv_cancelar_pedido($1, 'cliente desistiu', 'Caixa')", [trCancelado.pedido_id]));
await recusa("pedido em dinheiro é recusado", () => registrarPagamento(trDinheiro.pedido_id, "mp-tr-9", "pix", PIX1), "Pedido não está aguardando pagamento online");
await recusa("pedido Pix online antigo (não é 'online') é recusado", () => registrarPagamento(trPix.pedido_id, "mp-tr-9", "pix", PIX1), "Pedido não está aguardando pagamento online");
await recusa("pedido online já pago é recusado", () => registrarPagamento(on2.pedido_id, "mp-tr-9", "pix", PIX1), "Pedido não está aguardando pagamento online");
await recusa("pedido online cancelado é recusado", () => registrarPagamento(trCancelado.pedido_id, "mp-tr-9", "pix", PIX1), "Pedido não está aguardando pagamento online");
await recusa("pedido que não existe é recusado", () => registrarPagamento("00000000-0000-0000-0000-00000000abcd", "mp-tr-9", "pix", PIX1), "Pedido não está aguardando pagamento online");
await recusa("id vazio é recusado", () => registrarPagamento(tr1.pedido_id, "   ", "pix", PIX1), "Pagamento sem identificador");
await recusa("id nulo é recusado", () => registrarPagamento(tr1.pedido_id, null, "pix", PIX1), "Pagamento sem identificador");
await recusa("id de pagamento já ligado a outro pedido (pago) é recusado", () => registrarPagamento(tr1.pedido_id, "mp-on-1", "pix", PIX1), "Pagamento mp-on-1 já está ligado a outro pedido");
const tr2 = await criar(pedidoOnline("17860000005"));
await recusa("id registrado em outro pedido aguardando é recusado", () => registrarPagamento(tr2.pedido_id, "mp-tr-2", "pix", PIX1), "Pagamento mp-tr-2 já está ligado a outro pedido");
await ok("recusas não gravaram nada", async () => ({
  t1: await pagamentoDb(tr1.pedido_id), t2: await pagamentoDb(tr2.pedido_id), din: await pagamentoDb(trDinheiro.pedido_id),
  pix: await pagamentoDb(trPix.pedido_id), can: await pagamentoDb(trCancelado.pedido_id), pago: await pagamentoDb(on2.pedido_id) }),
  (x: any) => x.t1.mp_payment_id === "mp-tr-2" && x.t1.mp_payment_type === "credit_card" && x.t2.mp_payment_id === null && x.din.mp_payment_id === null
    && x.pix.mp_payment_id === null && x.can.mp_payment_id === null && x.pago.mp_payment_id === "mp-on-3" && x.pago.mp_payment_type === "credit_card" || JSON.stringify(x));

await ok("depois de registrar, confirmar com o mesmo id: vai para produção normal", async () => ({
  r: await confirmarOnline(tr1.pedido_id, "mp-tr-2", 2940, "credit_card"), o: await pagamentoDb(tr1.pedido_id), c: await cuponsDe(tr1.pedido_id) }),
  (x: any) => x.r.ja_confirmado === false && x.r.status === "em_producao" && x.r.numero === tr1.numero
    && x.o.pago && x.o.mp_payment_id === "mp-tr-2" && x.o.mp_payment_type === "credit_card" && x.c === 3 || JSON.stringify(x));
await ok("segunda confirmação com o mesmo id: ja_confirmado, sem duplicar cupom", async () => ({
  r: await confirmarOnline(tr1.pedido_id, "mp-tr-2", 2940, "credit_card"), c: await cuponsDe(tr1.pedido_id) }),
  (x: any) => x.r.ja_confirmado === true && x.r.status === "em_producao" && x.c === 3 || JSON.stringify(x));
await ok("pedido para pagamento depois de pago: pago=true", () => paraPagamento(tr1.codigo),
  (r: any) => r.pago === true && r.status === "em_producao" && r.mp_payment_id === "mp-tr-2" || JSON.stringify(r));
await recusa("registrar de novo depois de pago é recusado", () => registrarPagamento(tr1.pedido_id, "mp-tr-4", "pix", PIX1), "Pedido não está aguardando pagamento online");

// tentativas com cartão (contra teste de cartão roubado)
console.log("\n— Tentativas com cartão");
const tentativa = (id: string) => como("service_role", null, () => um("select dlv_tentativa_cartao($1)", [id]));
const tentativasDb = (id: string) => um("select mp_card_attempts from dlv_orders where id = $1", [id]);
const LIMITE_PEDIDO = "Muitas tentativas com cartão neste pedido. Pague com Pix ou fale com a loja.";
const LIMITE_TELEFONE = "Muitas tentativas com cartão. Pague com Pix ou fale com a loja.";

await recusa("anônimo não executa dlv_tentativa_cartao", () => como("anon", null, () => sql("select dlv_tentativa_cartao(gen_random_uuid())")), "permission denied");
await recusa("logado sem painel não executa dlv_tentativa_cartao", () => como("authenticated", ESTRANHO, () => sql("select dlv_tentativa_cartao(gen_random_uuid())")), "permission denied");
await recusa("usuário do painel não executa dlv_tentativa_cartao", () => como("authenticated", PAINEL, () => sql("select dlv_tentativa_cartao(gen_random_uuid())")), "permission denied");
await ok("configurações card_attempts_per_order = 5 e card_attempts_per_phone_2h = 10, com descrição", () => sql(
  "select key, value, description from dlv_settings where key in ('card_attempts_per_order', 'card_attempts_per_phone_2h') order by key"),
  (r: any[]) => r.length === 2 && r[0].key === "card_attempts_per_order" && r[0].value === "5" && r[1].value === "10" && r.every((x) => x.description?.length > 10) || JSON.stringify(r));
await ok("pedidos antigos começam com 0 tentativas", () => um("select count(*)::int from dlv_orders where mp_card_attempts <> 0"), (n: number) => n === 0 || `${n}`);

const ca = await criar(pedidoOnline("17850000001"));
await ok("1ª tentativa devolve 1 e grava no pedido", async () => ({ r: await tentativa(ca.pedido_id), db: await tentativasDb(ca.pedido_id) }),
  (x: any) => x.r === 1 && x.db === 1 || JSON.stringify(x));
await ok("tentativas 2 a 5 passam e incrementam", async () => { const r = []; for (let i = 0; i < 4; i++) r.push(await tentativa(ca.pedido_id)); return r; },
  (r: number[]) => r.join() === "2,3,4,5" || r.join());
await recusa("6ª tentativa no mesmo pedido é recusada", () => tentativa(ca.pedido_id), LIMITE_PEDIDO);
await ok("recusa não incrementa; dlv_pedido_para_pagamento traz tentativas_cartao = 5", async () => ({ db: await tentativasDb(ca.pedido_id), p: await paraPagamento(ca.codigo) }),
  (x: any) => x.db === 5 && x.p.tentativas_cartao === 5 || JSON.stringify({ db: x.db, t: x.p?.tentativas_cartao }));

const cb = await criar(pedidoOnline("17850000001"));
await ok("outro pedido do mesmo telefone: passa até somar 10 (5 + 5)", async () => { const r = []; for (let i = 0; i < 5; i++) r.push(await tentativa(cb.pedido_id)); return r; },
  (r: number[]) => r.join() === "1,2,3,4,5" || r.join());
const cc = await criar(pedidoOnline("17850000001"));
await recusa("3º pedido do mesmo telefone, com 0 tentativas próprias: recusado pelo limite do telefone (soma 10 em 2h)", () => tentativa(cc.pedido_id), LIMITE_TELEFONE);
await ok("recusa pelo telefone não incrementa", () => tentativasDb(cc.pedido_id), (n: number) => n === 0 || `${n}`);
const cd = await criar(pedidoOnline("17850000002"));
await ok("outro telefone não é afetado", () => tentativa(cd.pedido_id), (n: number) => n === 1 || `${n}`);
await ok("pedidos criados há mais de 2 horas não contam para o telefone", async () => {
  await sql("update dlv_orders set created_at = now() - interval '3 hours' where id = $1", [ca.pedido_id]);
  return tentativa(cc.pedido_id);
}, (n: number) => n === 1 || `${n}`);
await ok("3º pedido completa 5 tentativas e a 6ª esbarra no limite do pedido", async () => {
  const r = []; for (let i = 0; i < 4; i++) r.push(await tentativa(cc.pedido_id));
  let erro = ""; try { await tentativa(cc.pedido_id); } catch (e: any) { erro = e.message; }
  return { r, erro };
}, (x: any) => x.r.join() === "2,3,4,5" && x.erro.includes(LIMITE_PEDIDO) || JSON.stringify(x));

const ce = await criar(pedidoOnline("17850000003"));
await como("authenticated", PAINEL, () => um("select dlv_cancelar_pedido($1, 'cliente desistiu', 'Caixa')", [ce.pedido_id]));
await recusa("tentativa em pedido pago é recusada", () => tentativa(tr1.pedido_id), "Pedido não está aguardando pagamento online");
await recusa("tentativa em pedido cancelado é recusada", () => tentativa(ce.pedido_id), "Pedido não está aguardando pagamento online");
await recusa("tentativa em pedido em dinheiro é recusada", () => tentativa(trDinheiro.pedido_id), "Pedido não está aguardando pagamento online");
await recusa("tentativa em pedido Pix online antigo é recusada", () => tentativa(trPix.pedido_id), "Pedido não está aguardando pagamento online");
await recusa("tentativa em pedido que não existe é recusada", () => tentativa("00000000-0000-0000-0000-00000000abcd"), "Pedido não está aguardando pagamento online");
await ok("recusas por situação não incrementaram", async () => [await tentativasDb(tr1.pedido_id), await tentativasDb(ce.pedido_id), await tentativasDb(trDinheiro.pedido_id), await tentativasDb(trPix.pedido_id)],
  (r: number[]) => r.join() === "0,0,0,0" || r.join());

// ---------------------------------------------------------------- limite de pedidos em andamento por telefone (20260916120000)
console.log("\n— Limite por telefone");
const TROTE = "Já existem pedidos em andamento para este telefone. Aguarde ou fale com a loja.";
const naEntrega = (tel: string) => pedido({ cliente: { nome: "Limite Teste", telefone: tel } });
const emAndamento = (tel: string) => sql(`select count(*)::int n, count(*) filter (where paid_at is not null)::int pagos from dlv_orders
  where customer_phone = $1 and status in ('aguardando_pagamento', 'em_analise', 'em_producao', 'pronto', 'saiu_entrega')`, [tel]);

await ok("configuração max_open_orders_per_phone = 5", () => um("select value from dlv_settings where key = 'max_open_orders_per_phone'"), (v: string) => v === "5" || v);

await ok("4 pedidos em andamento para pagar na entrega passam", async () => {
  const r = []; for (let i = 0; i < 4; i++) r.push((await criar(naEntrega("17840000001"))).status); return r;
}, (r: string[]) => r.join() === "em_producao,em_producao,em_producao,em_producao" || r.join());
await ok("5º pedido para pagar na entrega passa", () => criar(naEntrega("17840000001")), (r: any) => r.status === "em_producao" || JSON.stringify(r));
await recusa("6º pedido é recusado", () => criar(naEntrega("17840000001")), TROTE);
await ok("recusa não gravou pedido: continuam 5 em andamento", () => emAndamento("17840000001"), (r: any[]) => r[0].n === 5 || JSON.stringify(r));

await ok("pedidos online pagos não contam: 6 pagos + 4 abertos ainda deixa criar o 5º aberto", async () => {
  for (let i = 0; i < 6; i++) {
    const o = await criar(pedidoOnline("17840000002"));
    const c = await confirmarOnline(o.pedido_id, `mp-limite-${i}`, o.total_cents, "pix");
    if (c.status !== "em_producao") throw new Error("pagamento não confirmou: " + JSON.stringify(c));
  }
  for (let i = 0; i < 4; i++) await criar(naEntrega("17840000002"));
  const quinto = await criar(naEntrega("17840000002"));
  return { quinto: quinto.status, andamento: (await emAndamento("17840000002"))[0] };
}, (x: any) => x.quinto === "em_producao" && x.andamento.n === 11 && x.andamento.pagos === 6 || JSON.stringify(x));
await recusa("com 6 pagos + 5 abertos, o próximo é recusado", () => criar(naEntrega("17840000002")), TROTE);

await ok("pedido online aguardando pagamento conta: 4 na entrega + 1 online sem pagar", async () => {
  for (let i = 0; i < 4; i++) await criar(naEntrega("17840000003"));
  const on = await criar(pedidoOnline("17840000003"));
  return { status: on.status, andamento: (await emAndamento("17840000003"))[0] };
}, (x: any) => x.status === "aguardando_pagamento" && x.andamento.n === 5 && x.andamento.pagos === 0 || JSON.stringify(x));
await recusa("6º pedido (com o online sem pagar contando) é recusado", () => criar(naEntrega("17840000003")), TROTE);
await recusa("5 online aguardando pagamento também barram o 6º", async () => {
  for (let i = 0; i < 5; i++) await criar(pedidoOnline("17840000004"));
  return criar(pedidoOnline("17840000004"));
}, TROTE);

await ok("painel continua sem limite: lança mais 3 para o telefone que já tem 5 abertos", async () => {
  const r = [];
  for (let i = 0; i < 3; i++) r.push((await como("authenticated", PAINEL, () => um("select dlv_criar_pedido_painel($1, 'Caixa')", [JSON.stringify(naEntrega("17840000001"))]))).status);
  return { r, andamento: (await emAndamento("17840000001"))[0] };
}, (x: any) => x.r.join() === "em_producao,em_producao,em_producao" && x.andamento.n === 8 || JSON.stringify(x));

await ok("rodar a migration do limite de novo é recusado e não grava nada", async () => {
  const antes = await um("select md5(pg_get_functiondef('public.dlv__criar_pedido(jsonb, text, text)'::regprocedure))");
  let erro = "";
  try { await db.exec(readFileSync(`${DIR}/20260916120000_dlv_limite_por_telefone.sql`, "utf8")); } catch (e: any) { erro = e.message; } finally { await db.exec("ROLLBACK"); }
  const depois = await um("select md5(pg_get_functiondef('public.dlv__criar_pedido(jsonb, text, text)'::regprocedure))");
  return { erro, igual: antes === depois };
}, (x: any) => x.erro.includes("achei 0") && x.igual || JSON.stringify(x));

console.log(`\n${falhou === 0 ? "🟢" : "🔴"} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

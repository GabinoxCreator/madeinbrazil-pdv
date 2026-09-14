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
`);

for (const f of readdirSync(DIR).filter((f) => f.endsWith(".sql")).sort()) {
  try { await db.exec(readFileSync(`${DIR}/${f}`, "utf8")); console.log("📦", f); }
  catch (e: any) { console.log("💥 migration falhou:", f, "→", e.message); process.exit(1); }
}

// ---------------------------------------------------------------- dados de teste
const PAINEL = "11111111-1111-1111-1111-111111111111";
const ESTRANHO = "22222222-2222-2222-2222-222222222222";
const TERMINAL = "33333333-3333-3333-3333-333333333333";
await db.exec(`
  INSERT INTO auth.users (id) VALUES ('${PAINEL}'), ('${ESTRANHO}'), ('${TERMINAL}');
  INSERT INTO public.pdv_panel_users (user_id, display_name, role) VALUES ('${PAINEL}', 'Caixa Teste', 'caixa');
  INSERT INTO public.pdv_terminal_accounts (user_id, terminal_id) SELECT '${TERMINAL}', id FROM public.pdv_terminals LIMIT 1;
  UPDATE public.dlv_settings SET value = 'aberta' WHERE key = 'store_mode';
`);

const perto = { lat: -20.8200, lng: -49.3752 };  // ~0,6 km
const cinco = { lat: -20.8592, lng: -49.3752 };  // ~5 km → faixa até 7 km = R$ 10
const longe = { lat: -20.9500, lng: -49.3752 };  // ~15 km

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

const frango = menu.categorias.find((c: any) => c.nome === "Especiais de Frango").itens.find((i: any) => i.nome === "Filé de Frango Pequena");
const grupo = (item: any, n: string) => item.grupos.find((g: any) => g.nome === n);
const opcao = (item: any, g: string, n: string) => grupo(item, g).opcoes.find((o: any) => o.nome === n);
const agua = menu.categorias.find((c: any) => c.nome === "Bebidas").itens.find((i: any) => i.nome === "Água");

const linhaFrango = (extra: any[] = []) => ({
  item_id: frango.id, quantidade: 1, preco_cents: 1, // preço mandado pelo navegador deve ser ignorado
  opcoes: [
    { opcao_id: opcao(frango, "Escolhe seu Filé de Frango", "Empanado").id },
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
await recusa("falta complemento obrigatório", () => criar(pedido({ itens: [{ item_id: frango.id, quantidade: 1, opcoes: [] }] })), "pelo menos 1");
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
const p1 = await ok("cria pedido: 23,90 + empanado 2,00 + coca 3,50 = 29,40, frete grátis", () => criar(pedido()),
  // número >= 5000: pedido recusado antes também gasta número (sequência do Postgres não volta)
  (r: any) => r.subtotal_cents === 2940 && r.total_cents === 2940 && r.status === "em_producao" && r.numero >= 5000 || JSON.stringify(r));
await ok("gerou 3 cupons: cozinha, bar de cerveja e via do caixa", () => sql(
  `select pp.code, j.kind from dlv_print_jobs j join pdv_production_points pp on pp.id = j.production_point_id where j.order_id = $1 order by 1, 2`, [p1.pedido_id]),
  (r: any[]) => JSON.stringify(r) === JSON.stringify([{ code: "caixa", kind: "via_entrega" }, { code: "cerveja", kind: "producao" }, { code: "cozinha", kind: "producao" }]) || JSON.stringify(r));
await ok("cliente salvo com endereço", () => sql(`select c.orders_count, a.street from dlv_customers c join dlv_customer_addresses a on a.customer_id = c.id where c.phone = '17999990001'`),
  (r: any[]) => r.length === 1 && r[0].orders_count === 1 || JSON.stringify(r));
await ok("cliente acompanha pelo código", () => como("anon", null, () => um("select dlv_acompanhar_pedido($1)", [p1.codigo])),
  (r: any) => r.status === "em_producao" && r.itens[0].opcoes.length === 3 && !("telefone" in r) || JSON.stringify(r));
await recusa("código inventado não acha pedido", () => como("anon", null, () => um("select dlv_acompanhar_pedido($1)", ["0".repeat(32)])), "não encontrado");

// ---------------------------------------------------------------- 6. estação de impressão
console.log("\n— Estação de impressão");
const jobs = await ok("estação reserva os 3 cupons", () => como("authenticated", TERMINAL, () => um("select dlv_reservar_impressoes(10)")), (r: any[]) => r.length === 3 || JSON.stringify(r).slice(0, 300));
const cozinha = jobs?.find((j: any) => j.ponto.codigo === "cozinha");
const cerveja = jobs?.find((j: any) => j.ponto.codigo === "cerveja");
const via = jobs?.find((j: any) => j.tipo === "via_entrega");
await ok("cozinha recebe o frango com empanado e batata, sem a coca", async () => cozinha,
  (j: any) => j.itens.length === 1 && j.itens[0].nome === "Filé de Frango Pequena" && j.itens[0].opcoes.map((o: any) => o.nome).sort().join() === "Batata Frita,Empanado" || JSON.stringify(j?.itens));
await ok("bar de cerveja recebe só a coca, 'junto com' o prato", async () => cerveja,
  (j: any) => j.itens.length === 1 && j.itens[0].nome === "Coca-Cola 200ml" && j.itens[0].observacao.includes("Filé de Frango") || JSON.stringify(j?.itens));
await ok("via do caixa tem tudo, endereço, troco e link do mapa", async () => via,
  (j: any) => j.itens[0].opcoes.length === 3 && j.pedido.troco_para_cents === 5000 && j.pedido.endereco.mapa_url.includes("google.com/maps") && j.ponto.ip === "192.168.0.70" || JSON.stringify(j?.pedido));
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
await ok("3 pedidos em andamento no mesmo telefone passam", async () => {
  for (let i = 0; i < 3; i++) await criar(pedido({ cliente: { nome: "Trote", telefone: "17988880000" } }));
  return true;
});
await recusa("4º pedido em andamento no mesmo telefone é barrado", () => criar(pedido({ cliente: { nome: "Trote", telefone: "17988880000" } })), "em andamento");
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

console.log(`\n${falhou === 0 ? "🟢" : "🔴"} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

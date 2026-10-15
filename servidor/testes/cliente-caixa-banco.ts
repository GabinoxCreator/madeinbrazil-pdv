// Testa o cadastro do cliente no caixa (MB-121) num Postgres em memória (PGlite),
// com todas as migrations do servidor aplicadas.
// Uso (precisa de bun + @electric-sql/pglite): MIGRATIONS=servidor/migrations bun servidor/testes/cliente-caixa-banco.ts
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
  CREATE SCHEMA storage; GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
  CREATE TABLE storage.buckets (id text PRIMARY KEY, name text NOT NULL, public boolean NOT NULL DEFAULT false, file_size_limit bigint, allowed_mime_types text[]);
  CREATE TABLE storage.objects (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), bucket_id text REFERENCES storage.buckets(id), name text NOT NULL, owner uuid);
  ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
  GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO anon, authenticated, service_role;
  GRANT SELECT ON storage.buckets TO anon, authenticated, service_role;
  CREATE SCHEMA net;
  CREATE TABLE net.chamadas (id bigserial PRIMARY KEY, url text, body jsonb, headers jsonb);
  CREATE FUNCTION net.http_post(url text, body jsonb, headers jsonb) RETURNS bigint LANGUAGE sql AS
    $$ INSERT INTO net.chamadas (url, body, headers) VALUES (url, body, headers) RETURNING id $$;
`);

for (const f of readdirSync(DIR).filter((f) => f.endsWith(".sql")).sort()) {
  try { await db.exec(readFileSync(`${DIR}/${f}`, "utf8")); }
  catch (e: any) { console.log("💥 migration falhou:", f, "→", e.message); process.exit(1); }
}
console.log("📦 migrations aplicadas");

const PAINEL = "11111111-1111-1111-1111-111111111111";
const ESTRANHO = "22222222-2222-2222-2222-222222222222";
await db.exec(`
  INSERT INTO auth.users (id) VALUES ('${PAINEL}'), ('${ESTRANHO}');
  INSERT INTO public.pdv_panel_users (user_id, display_name, role) VALUES ('${PAINEL}', 'Caixa Teste', 'caixa');
  -- cliente que já veio do delivery, sem aceite
  INSERT INTO public.dlv_customers (phone, name, source) VALUES ('17988887777', 'Zé do Delivery', 'cardapio');
  -- cliente do delivery que JÁ aceitou
  INSERT INTO public.dlv_customers (phone, name, source, marketing_consent, consent_at)
  VALUES ('17966665555', 'Ana Aceitou', 'cardapio', true, '2026-09-20 12:00-03');
`);

const CPF_A = "52998224725";   // válido
const CPF_B = "11144477735";   // válido
const CPF_C = "39053344705";   // válido
const cadastrar = (sub: string | null, papel: "anon" | "authenticated", cpf: string, nome: string, tel: string, nasc: string | null, aceite: boolean) =>
  como(papel, sub, () => um("select pdv_cadastrar_cliente($1, $2, $3, $4::date, $5)", [cpf, nome, tel, nasc, aceite]));
const linha = (tel: string) => sql("select * from dlv_customers where phone = $1", [tel]).then((r) => r[0]);

console.log("\n— CPF");
await ok("CPF com pontuação vira só dígitos", () => um("select pdv__cpf('529.982.247-25')"), (r) => r === CPF_A || r);
await ok("CPF com dígito errado é recusado", () => um("select pdv__cpf('52998224726')"), (r) => r === null || r);
await ok("CPF de números repetidos é recusado", () => um("select pdv__cpf('11111111111')"), (r) => r === null || r);

console.log("\n— Quem pode");
await recusa("anônimo não cadastra", () => cadastrar(null, "anon", CPF_A, "Maria", "17991234567", "1990-05-10", true));
await recusa("logado que não é do painel não cadastra", () => cadastrar(ESTRANHO, "authenticated", CPF_A, "Maria", "17991234567", "1990-05-10", true), "Sem permissão");
await recusa("anônimo não lê o token do bar", () => como("anon", null, () => um("select pdv_bar_token()")));
await recusa("painel não lê o token do bar", () => como("authenticated", PAINEL, () => um("select pdv_bar_token()")));
await recusa("painel não lê a tabela do token", () => como("authenticated", PAINEL, () => um("select token from pdv_bar_segredo")));
await recusa("painel não marca envio ao bar", () => como("authenticated", PAINEL, () => um("select pdv_cliente_bar_resultado(gen_random_uuid(), now(), true, null)")));
await ok("token do bar nasce com 64 caracteres", () => como("service_role", null, () => um("select pdv_bar_token()")), (r) => String(r).length === 64 || r);

console.log("\n— Campos obrigatórios");
await recusa("sem CPF", () => cadastrar(PAINEL, "authenticated", "", "Maria", "17991234567", "1990-05-10", true), "CPF inválido");
await recusa("CPF inválido", () => cadastrar(PAINEL, "authenticated", "12345678900", "Maria", "17991234567", "1990-05-10", true), "CPF inválido");
await recusa("sem nome", () => cadastrar(PAINEL, "authenticated", CPF_A, " ", "17991234567", "1990-05-10", true), "nome");
await recusa("telefone curto", () => cadastrar(PAINEL, "authenticated", CPF_A, "Maria", "9912345", "1990-05-10", true), "Telefone");
await recusa("sem nascimento", () => cadastrar(PAINEL, "authenticated", CPF_A, "Maria", "17991234567", null, true), "nascimento");
await recusa("nascimento no futuro", () => cadastrar(PAINEL, "authenticated", CPF_A, "Maria", "17991234567", "2999-01-01", true), "nascimento");

console.log("\n— Cliente novo");
await ok("cliente novo com aceite", () => cadastrar(PAINEL, "authenticated", "529.982.247-25", " Maria Souza ", "(17) 99123-4567", "1990-05-10", true),
  (r: any) => r.novo === true && r.aceite === true && r.nome === "Maria Souza" || JSON.stringify(r));
await ok("gravado com origem caixa, aceite datado e pendente para o bar", () => linha("17991234567"),
  (r: any) => r.source === "caixa" && r.cpf === CPF_A && r.marketing_consent === true && r.consent_at && r.bar_pendente === true || JSON.stringify(r));
await ok("cliente novo SEM aceite fica sem data de aceite", () => cadastrar(PAINEL, "authenticated", CPF_C, "Carlos", "1733334444", "1985-01-02", false),
  (r: any) => r.aceite === false || JSON.stringify(r));
await ok("… e sem consent_at", () => linha("1733334444"), (r: any) => r.consent_at === null && r.bar_pendente === true || JSON.stringify(r));

console.log("\n— Cliente que já existia");
await ok("cliente do delivery ganha CPF, nascimento e aceite", () => cadastrar(PAINEL, "authenticated", CPF_B, "José Silva", "17988887777", "1979-12-31", true),
  (r: any) => r.novo === false && r.aceite === true || JSON.stringify(r));
await ok("… mantém a origem cardapio e troca o nome", () => linha("17988887777"),
  (r: any) => r.source === "cardapio" && r.name === "José Silva" && r.cpf === CPF_B && !!r.consent_at || JSON.stringify(r));
const aceiteAntes = (await linha("17966665555")).consent_at;
await ok("aceite nunca desliga: desmarcado no caixa não apaga o do delivery", () => cadastrar(PAINEL, "authenticated", "71428793860", "Ana", "17966665555", "1995-03-03", false),
  (r: any) => r.aceite === true || JSON.stringify(r));
await ok("… e a data do primeiro aceite não muda", () => linha("17966665555"),
  (r: any) => String(r.consent_at) === String(aceiteAntes) || JSON.stringify(r));
await recusa("mesmo CPF em outro telefone é recusado", () => cadastrar(PAINEL, "authenticated", CPF_A, "Maria", "17900001111", "1990-05-10", true), "terminado em 4567");
await recusa("telefone já com outro CPF é recusado", () => cadastrar(PAINEL, "authenticated", "12345678909", "Maria", "17991234567", "1990-05-10", true), "outro CPF");
await ok("recadastrar o mesmo cliente (mesmo CPF e telefone) atualiza", () => cadastrar(PAINEL, "authenticated", CPF_A, "Maria S. Souza", "17991234567", "1990-05-10", false),
  (r: any) => r.novo === false && r.aceite === true && r.nome === "Maria S. Souza" || JSON.stringify(r));

console.log("\n— Ponte com o bar");
const pendentes = await ok("pendentes saem para o bar, mais antigo primeiro", () => como("service_role", null, () => sql("select * from pdv_clientes_para_o_bar(10)")),
  (r: any[]) => r.length === 4 && r.every((c) => c.cpf && c.nascimento) || JSON.stringify(r));
const maria = (pendentes ?? []).find((c: any) => c.telefone === "17991234567");
await ok("enviado com a versão certa sai da fila", async () => {
  await como("service_role", null, () => sql("select pdv_cliente_bar_resultado($1, $2, true, null)", [maria.id, maria.versao]));
  return linha("17991234567");
}, (r: any) => r.bar_pendente === false && r.bar_enviado_em && r.bar_erro === null || JSON.stringify(r));
const carlos = (pendentes ?? []).find((c: any) => c.telefone === "1733334444");
await ok("cadastro que mudou no meio do envio continua pendente", async () => {
  await cadastrar(PAINEL, "authenticated", CPF_C, "Carlos Lima", "1733334444", "1985-01-02", true);
  await como("service_role", null, () => sql("select pdv_cliente_bar_resultado($1, $2, true, null)", [carlos.id, carlos.versao]));
  return linha("1733334444");
}, (r: any) => r.bar_pendente === true && r.marketing_consent === true || JSON.stringify(r));
await ok("falha no envio guarda o erro e continua pendente", async () => {
  const c = (await como("service_role", null, () => sql("select * from pdv_clientes_para_o_bar(10)"))).find((x: any) => x.telefone === "1733334444");
  await como("service_role", null, () => sql("select pdv_cliente_bar_resultado($1, $2, false, 'bar respondeu 503')", [c.id, c.versao]));
  return linha("1733334444");
}, (r: any) => r.bar_pendente === true && r.bar_erro === "bar respondeu 503" || JSON.stringify(r));
await ok("delivery sem cadastro no caixa não vai para o bar", () => como("service_role", null, () => sql("select telefone from pdv_clientes_para_o_bar(50)")),
  (r: any[]) => !r.some((c) => c.telefone === "17900000000") && r.length === 3 || JSON.stringify(r));
await ok("painel lê CPF e situação do envio", () => como("authenticated", PAINEL, () => sql("select cpf, bar_pendente from dlv_customers where phone = '17991234567'")),
  (r: any[]) => r[0]?.cpf === CPF_A || JSON.stringify(r));

console.log(`\n${falhou === 0 ? "🟢" : "🔴"} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

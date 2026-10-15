-- =====================================================================
-- PDV · cadastro do cliente no caixa, com aceite de WhatsApp (MB-121)
--
-- Decisões do Gabriel (15/10): tela "Clientes" no painel + botão no
-- recebimento; obrigatórios CPF, nome, telefone e nascimento; a caixa de
-- autorização nasce DESMARCADA e quem marca é o operador, depois de perguntar.
--
-- A base de clientes do PDV continua sendo dlv_customers (o mesmo cliente do
-- delivery e do salão, identificado pelo telefone). O aceite "só liga, nunca
-- desliga", como no delivery.
--
-- Ponte com o bar: o banco do bar é outro projeto. Cada cadastro fica marcado
-- bar_pendente; a edge pdv-cliente-cadastrar manda para a edge
-- pdv-capturar-cliente do bar com o token de pdv_bar_segredo e devolve o
-- resultado por pdv_cliente_bar_resultado. O bar guarda só o HASH do token.
--
-- Mudanças (nada destrutivo; não apaga nem altera dados existentes):
--   * dlv_customers: colunas cpf, birth_date, bar_pendente, bar_enviado_em,
--     bar_erro; CPF único; origem 'caixa'
--   * tabela fechada pdv_bar_segredo (RLS sem política)
--   * pdv__cpf (apoio, IMMUTABLE)
--   * painel: pdv_cadastrar_cliente
--   * só service_role: pdv_bar_token, pdv_clientes_para_o_bar,
--     pdv_cliente_bar_resultado
-- =====================================================================

BEGIN;

ALTER TABLE public.dlv_customers
  ADD COLUMN cpf            text CHECK (cpf ~ '^[0-9]{11}$'),
  ADD COLUMN birth_date     date CHECK (birth_date >= DATE '1900-01-01'),
  ADD COLUMN bar_pendente   boolean NOT NULL DEFAULT false,
  ADD COLUMN bar_enviado_em timestamptz,
  ADD COLUMN bar_erro       text;

-- um CPF, uma pessoa: não junta dois telefones no mesmo CPF
CREATE UNIQUE INDEX dlv_customers_cpf_unico ON public.dlv_customers (cpf) WHERE cpf IS NOT NULL;
CREATE INDEX dlv_customers_bar_pendente ON public.dlv_customers (updated_at) WHERE bar_pendente;

ALTER TABLE public.dlv_customers DROP CONSTRAINT dlv_customers_source_check;
ALTER TABLE public.dlv_customers ADD CONSTRAINT dlv_customers_source_check
  CHECK (source IN ('cardapio', 'painel', 'anota', 'caixa'));

-- token da ponte com o bar: gerado aqui, nunca sai do servidor
CREATE TABLE public.pdv_bar_segredo (
  id    smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  token text NOT NULL CHECK (length(token) = 64)
);
ALTER TABLE public.pdv_bar_segredo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pdv_bar_segredo FROM PUBLIC, anon, authenticated;
INSERT INTO public.pdv_bar_segredo (id, token)
VALUES (1, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));


-- ---------------------------------------------------------------------
-- Apoio: CPF só com dígitos e dígitos verificadores certos, ou NULL
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv__cpf(p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  s int;
  r int;
BEGIN
  IF d !~ '^[0-9]{11}$' OR d ~ '^(\d)\1{10}$' THEN RETURN NULL; END IF;
  s := 0;
  FOR i IN 1..9 LOOP s := s + substr(d, i, 1)::int * (11 - i); END LOOP;
  r := (s * 10) % 11; IF r = 10 THEN r := 0; END IF;
  IF r <> substr(d, 10, 1)::int THEN RETURN NULL; END IF;
  s := 0;
  FOR i IN 1..10 LOOP s := s + substr(d, i, 1)::int * (12 - i); END LOOP;
  r := (s * 10) % 11; IF r = 10 THEN r := 0; END IF;
  IF r <> substr(d, 11, 1)::int THEN RETURN NULL; END IF;
  RETURN d;
END;
$$;


-- ---------------------------------------------------------------------
-- Painel: cadastrar (ou atualizar) o cliente pelo telefone
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv_cadastrar_cliente(
  p_cpf text, p_nome text, p_telefone text, p_nascimento date, p_aceite boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cpf    text := public.pdv__cpf(p_cpf);
  v_tel    text := public.dlv__telefone(p_telefone);
  v_nome   text := btrim(coalesce(p_nome, ''));
  v_aceite boolean := coalesce(p_aceite, false);
  v_atual  public.dlv_customers%ROWTYPE;
  v_outro  text;
  v_novo   boolean := false;
BEGIN
  IF NOT public.pdv_is_panel_user() THEN
    RAISE EXCEPTION 'Sem permissão para cadastrar cliente' USING ERRCODE = '42501';
  END IF;
  IF v_cpf IS NULL THEN RAISE EXCEPTION 'CPF inválido'; END IF;
  IF length(v_nome) < 2 THEN RAISE EXCEPTION 'Informe o nome do cliente'; END IF;
  IF v_tel IS NULL THEN RAISE EXCEPTION 'Telefone inválido: use DDD + número'; END IF;
  IF p_nascimento IS NULL THEN RAISE EXCEPTION 'Informe a data de nascimento'; END IF;
  IF p_nascimento < DATE '1900-01-01' OR p_nascimento > current_date THEN
    RAISE EXCEPTION 'Data de nascimento inválida';
  END IF;

  SELECT phone INTO v_outro FROM public.dlv_customers WHERE cpf = v_cpf AND phone <> v_tel;
  IF v_outro IS NOT NULL THEN
    RAISE EXCEPTION 'Este CPF já está cadastrado com o telefone terminado em %', right(v_outro, 4);
  END IF;

  SELECT * INTO v_atual FROM public.dlv_customers WHERE phone = v_tel FOR UPDATE;

  IF v_atual.id IS NULL THEN
    INSERT INTO public.dlv_customers
      (phone, name, cpf, birth_date, marketing_consent, consent_at, source, bar_pendente)
    VALUES
      (v_tel, v_nome, v_cpf, p_nascimento, v_aceite, CASE WHEN v_aceite THEN now() END, 'caixa', true)
    RETURNING * INTO v_atual;
    v_novo := true;
  ELSE
    IF v_atual.cpf IS NOT NULL AND v_atual.cpf <> v_cpf THEN
      RAISE EXCEPTION 'Este telefone já está cadastrado com outro CPF';
    END IF;
    UPDATE public.dlv_customers SET
      name              = v_nome,
      cpf               = v_cpf,
      birth_date        = p_nascimento,
      -- aceite só liga; a data que vale é a do primeiro
      marketing_consent = marketing_consent OR v_aceite,
      consent_at        = CASE WHEN v_aceite AND consent_at IS NULL THEN now() ELSE consent_at END,
      bar_pendente      = true
    WHERE id = v_atual.id
    RETURNING * INTO v_atual;
  END IF;

  RETURN jsonb_build_object(
    'id', v_atual.id, 'novo', v_novo, 'nome', v_atual.name, 'aceite', v_atual.marketing_consent
  );
END;
$$;
REVOKE ALL ON FUNCTION public.pdv_cadastrar_cliente(text, text, text, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdv_cadastrar_cliente(text, text, text, date, boolean) TO authenticated;


-- ---------------------------------------------------------------------
-- Só service_role (edge pdv-cliente-cadastrar): a ponte com o bar
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv_bar_token()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT token FROM public.pdv_bar_segredo WHERE id = 1;
$$;

-- o que falta mandar, mais antigo primeiro; `versao` evita marcar como
-- enviado um cadastro que mudou enquanto ia para o bar
CREATE FUNCTION public.pdv_clientes_para_o_bar(p_limite int DEFAULT 10)
RETURNS TABLE (
  id uuid, nome text, telefone text, cpf text, nascimento date,
  aceite boolean, aceite_em timestamptz, versao timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.id, c.name, c.phone, c.cpf, c.birth_date, c.marketing_consent, c.consent_at, c.updated_at
    FROM public.dlv_customers c
   WHERE c.bar_pendente
   ORDER BY c.updated_at
   LIMIT greatest(1, least(coalesce(p_limite, 10), 50));
$$;

CREATE FUNCTION public.pdv_cliente_bar_resultado(p_id uuid, p_versao timestamptz, p_ok boolean, p_erro text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_ok THEN
    UPDATE public.dlv_customers
       SET bar_pendente = false, bar_enviado_em = now(), bar_erro = NULL
     WHERE id = p_id AND updated_at = p_versao;
  ELSE
    UPDATE public.dlv_customers
       SET bar_erro = left(coalesce(p_erro, 'falhou'), 300)
     WHERE id = p_id AND updated_at = p_versao;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.pdv_bar_token() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pdv_clientes_para_o_bar(int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pdv_cliente_bar_resultado(uuid, timestamptz, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdv_bar_token() TO service_role;
GRANT EXECUTE ON FUNCTION public.pdv_clientes_para_o_bar(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.pdv_cliente_bar_resultado(uuid, timestamptz, boolean, text) TO service_role;

COMMIT;

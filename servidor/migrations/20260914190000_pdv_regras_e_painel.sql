-- =====================================================================
-- Made in Brazil PDV — Regras da operação no banco + acesso do painel web
--
-- 1) Usuários do PAINEL (caixa/admin), separados das contas de terminal.
--    Leem tudo; ESCREVEM só pelas funções abaixo, nunca direto nas tabelas.
-- 2) As regras de negócio viram funções do banco (RPC). O painel web usa
--    exatamente essas funções; as regras são as mesmas do app Android:
--      * número de comanda na faixa configurada e único entre as vivas
--      * lançamento só em comanda aberta, com nome/preço/ponto CONGELADOS
--        a partir do cardápio do servidor (o navegador não manda preço)
--      * serviço, desconto (nunca deixa total negativo), por pessoa
--        arredondado pra cima
--      * recebimento só com caixa aberto, nunca mais do que falta, troco só
--        em dinheiro e FORA da conta da gaveta
--      * sangria não pode passar do que há na gaveta
--      * caixa não fecha com comanda pendente (comanda de controle não trava)
-- 3) Resumo de vendas por período.
--
-- Todas as funções são SECURITY DEFINER e começam checando se quem chama é
-- terminal ativo ou usuário ativo do painel. O anônimo não executa nenhuma.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Usuários do painel
-- ---------------------------------------------------------------------
CREATE TABLE public.pdv_panel_users (
  user_id       uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name  text NOT NULL CHECK (length(btrim(display_name)) > 0),
  role          text NOT NULL CHECK (role IN ('admin', 'caixa')),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pdv_panel_users ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.pdv_panel_users FROM anon, authenticated;
GRANT SELECT ON TABLE public.pdv_panel_users TO authenticated;
CREATE POLICY "usuario le o proprio acesso ao painel" ON public.pdv_panel_users
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE FUNCTION public.pdv_is_panel_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.pdv_panel_users WHERE user_id = auth.uid() AND is_active);
$$;

CREATE FUNCTION public.pdv_pode_operar()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.pdv_is_terminal() OR public.pdv_is_panel_user();
$$;

-- o painel LÊ tudo que o PDV tem
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'pdv_settings','pdv_production_points','pdv_terminals','pdv_collaborators',
    'pdv_menu_categories','pdv_menu_items','pdv_cash_sessions','pdv_cash_movements',
    'pdv_cards','pdv_card_orders','pdv_card_items','pdv_card_transfers','pdv_payments'
  ] LOOP
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.pdv_is_panel_user())',
      'painel le ' || t, t
    );
  END LOOP;
END $$;


-- ---------------------------------------------------------------------
-- Apoio interno (não expostos)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv__exigir_operador()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.pdv_pode_operar() THEN
    RAISE EXCEPTION 'Sem permissão para operar o PDV' USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE FUNCTION public.pdv__config(p_chave text, p_padrao numeric)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((SELECT value::numeric FROM public.pdv_settings WHERE key = p_chave), p_padrao);
$$;

CREATE FUNCTION public.pdv__brl(p_centavos bigint)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT 'R$ ' || replace(to_char(p_centavos / 100.0, 'FM9999999990.00'), '.', ',');
$$;

-- conta da comanda: MESMA matemática do app (Conta.calcular)
CREATE FUNCTION public.pdv__conta(p_comanda uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c record;
  v_sub bigint; v_serv bigint; v_desc bigint; v_total bigint; v_pessoas int; v_pago bigint;
BEGIN
  SELECT * INTO c FROM public.pdv_cards WHERE id = p_comanda;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comanda não encontrada'; END IF;

  SELECT coalesce(sum(total_cents), 0) INTO v_sub
    FROM public.pdv_card_items WHERE card_id = p_comanda AND status = 'ativo';
  v_serv    := round(v_sub * c.service_fee_pct / 100.0)::bigint;
  v_desc    := least(c.discount_cents, v_sub + v_serv);          -- desconto nunca deixa negativo
  v_total   := v_sub + v_serv - v_desc;
  v_pessoas := greatest(c.people_count, 1);
  SELECT coalesce(sum(amount_cents), 0) INTO v_pago FROM public.pdv_payments WHERE card_id = p_comanda;

  RETURN jsonb_build_object(
    'comanda_id', c.id, 'numero', c.card_number, 'status', c.status,
    'subtotal_cents', v_sub, 'taxa_servico_pct', c.service_fee_pct, 'servico_cents', v_serv,
    'desconto_cents', v_desc, 'total_cents', v_total, 'pessoas', v_pessoas,
    -- arredonda pra cima: 10,00 entre 3 não pode somar 9,99
    'por_pessoa_cents', CASE WHEN v_total <= 0 THEN 0 ELSE (v_total + v_pessoas - 1) / v_pessoas END,
    'pago_cents', v_pago, 'falta_cents', greatest(v_total - v_pago, 0),
    'quitada', (v_pago >= v_total AND v_total > 0)
  );
END;
$$;

-- apuração do caixa: MESMA regra do app (Fechamento.calcular). Troco fora.
CREATE FUNCTION public.pdv__apuracao(p_sessao uuid, p_contado bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s record;
  v_supr bigint; v_sang bigint; v_din bigint; v_total bigint; v_cmd int;
  v_metodos jsonb; v_esperado bigint; v_contado bigint;
BEGIN
  SELECT * INTO s FROM public.pdv_cash_sessions WHERE id = p_sessao;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sessão de caixa não encontrada'; END IF;

  SELECT coalesce(sum(amount_cents) FILTER (WHERE type = 'suprimento'), 0),
         coalesce(sum(amount_cents) FILTER (WHERE type = 'sangria'), 0)
    INTO v_supr, v_sang
    FROM public.pdv_cash_movements WHERE session_id = p_sessao;

  SELECT coalesce(sum(amount_cents) FILTER (WHERE method = 'dinheiro'), 0),
         coalesce(sum(amount_cents), 0),
         count(DISTINCT card_id)
    INTO v_din, v_total, v_cmd
    FROM public.pdv_payments WHERE session_id = p_sessao;

  SELECT coalesce(jsonb_object_agg(method, soma), '{}'::jsonb) INTO v_metodos
    FROM (SELECT method, sum(amount_cents) AS soma
            FROM public.pdv_payments WHERE session_id = p_sessao GROUP BY method) x;

  v_esperado := s.opening_float_cents + v_supr - v_sang + v_din;
  v_contado  := coalesce(p_contado, s.counted_cents);

  RETURN jsonb_build_object(
    'sessao_id', s.id, 'status', s.status,
    'aberta_por', s.opened_by_name, 'aberta_em', s.opened_at,
    'fechada_por', s.closed_by_name, 'fechada_em', s.closed_at,
    'fundo_troco_cents', s.opening_float_cents,
    'suprimentos_cents', v_supr, 'sangrias_cents', v_sang,
    'recebido_dinheiro_cents', v_din,
    'esperado_cents', v_esperado,
    'contado_cents', v_contado,
    'diferenca_cents', CASE WHEN v_contado IS NULL THEN NULL ELSE v_contado - v_esperado END,
    'por_metodo', v_metodos,
    'total_recebido_cents', v_total,
    'comandas_recebidas', v_cmd
  );
END;
$$;


-- ---------------------------------------------------------------------
-- Consultas
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv_conta(p_comanda uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.pdv__exigir_operador();
  RETURN public.pdv__conta(p_comanda);
END;
$$;

CREATE FUNCTION public.pdv_apuracao_caixa(p_sessao uuid, p_contado_cents bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.pdv__exigir_operador();
  RETURN public.pdv__apuracao(p_sessao, p_contado_cents);
END;
$$;


-- ---------------------------------------------------------------------
-- Comandas
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv_abrir_comanda(
  p_numero integer, p_mesa text, p_pessoas integer, p_cliente text, p_controle boolean, p_operador text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_min numeric := public.pdv__config('card_number_min', 0);
  v_max numeric := public.pdv__config('card_number_max', 9999);
  v_id uuid;
BEGIN
  PERFORM public.pdv__exigir_operador();
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;
  IF p_numero IS NULL OR p_numero < v_min OR p_numero > v_max THEN
    RAISE EXCEPTION 'Comanda % está fora da faixa configurada (% a %). Se esse número existe de verdade, avise — a faixa é configurável.',
      p_numero, v_min, v_max;
  END IF;
  IF EXISTS (SELECT 1 FROM public.pdv_cards WHERE card_number = p_numero AND status IN ('aberta', 'fechada')) THEN
    RAISE EXCEPTION 'A comanda % já está aberta', p_numero;
  END IF;

  BEGIN
    INSERT INTO public.pdv_cards (
      card_number, table_number, customer_name, people_count, is_control_card, service_fee_pct,
      opened_by_name, last_activity_by_name, last_activity_at
    ) VALUES (
      p_numero, nullif(btrim(p_mesa), ''), nullif(btrim(p_cliente), ''), greatest(coalesce(p_pessoas, 1), 1),
      coalesce(p_controle, false),
      CASE WHEN coalesce(p_controle, false) THEN 0 ELSE public.pdv__config('service_fee_percent', 10) END,
      p_operador, p_operador, now()
    ) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'A comanda % já está aberta', p_numero;
  END;
  RETURN v_id;
END;
$$;

-- p_itens: [{"menu_item_id": "<uuid>", "quantidade": 2, "observacao": "sem cebola"}]
CREATE FUNCTION public.pdv_lancar_pedido(p_comanda uuid, p_itens jsonb, p_operador text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c record; m record; r record;
  v_pedido uuid := gen_random_uuid();
BEGIN
  PERFORM public.pdv__exigir_operador();
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;
  SELECT * INTO c FROM public.pdv_cards WHERE id = p_comanda FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comanda não encontrada'; END IF;
  IF c.status <> 'aberta' THEN
    RAISE EXCEPTION 'Comanda % está %, não aceita lançamento', c.card_number, c.status;
  END IF;
  IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' OR jsonb_array_length(p_itens) = 0 THEN
    RAISE EXCEPTION 'Nenhum item escolhido';
  END IF;

  INSERT INTO public.pdv_card_orders (id, card_id, created_by_name, table_number)
  VALUES (v_pedido, c.id, p_operador, c.table_number);

  FOR r IN SELECT * FROM jsonb_to_recordset(p_itens) AS x(menu_item_id uuid, quantidade integer, observacao text) LOOP
    SELECT * INTO m FROM public.pdv_menu_items WHERE id = r.menu_item_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item do cardápio não encontrado ou inativo'; END IF;
    IF coalesce(r.quantidade, 0) <= 0 THEN RAISE EXCEPTION 'Quantidade inválida para %', m.name; END IF;
    -- nome, preço e ponto de produção vêm do cardápio do servidor e ficam congelados
    INSERT INTO public.pdv_card_items (
      order_id, card_id, menu_item_id, item_name, quantity, unit_price_cents, production_point_id, notes
    ) VALUES (
      v_pedido, c.id, m.id, m.name, r.quantidade, m.price_cents, m.production_point_id, nullif(btrim(r.observacao), '')
    );
  END LOOP;

  UPDATE public.pdv_cards
     SET first_order_at = coalesce(first_order_at, now()),
         last_activity_by_name = p_operador, last_activity_at = now()
   WHERE id = c.id;
  RETURN v_pedido;
END;
$$;

CREATE FUNCTION public.pdv_cancelar_item(p_item uuid, p_motivo text, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE i record; c record;
BEGIN
  PERFORM public.pdv__exigir_operador();
  IF length(btrim(coalesce(p_motivo, ''))) = 0 THEN RAISE EXCEPTION 'Informe o motivo do cancelamento'; END IF;
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;
  SELECT * INTO i FROM public.pdv_card_items WHERE id = p_item FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item não encontrado'; END IF;
  IF i.status = 'cancelado' THEN RAISE EXCEPTION 'Item já está cancelado'; END IF;
  SELECT * INTO c FROM public.pdv_cards WHERE id = i.card_id FOR UPDATE;
  IF c.status <> 'aberta' THEN
    RAISE EXCEPTION 'Só dá para cancelar item de comanda aberta (a comanda % está %)', c.card_number, c.status;
  END IF;

  UPDATE public.pdv_card_items
     SET status = 'cancelado', cancelled_by_name = p_operador, cancelled_reason = btrim(p_motivo), cancelled_at = now()
   WHERE id = i.id;
  UPDATE public.pdv_cards SET last_activity_by_name = p_operador, last_activity_at = now() WHERE id = c.id;
  RETURN public.pdv__conta(c.id);
END;
$$;

CREATE FUNCTION public.pdv_ajustar_conta(
  p_comanda uuid, p_pessoas integer, p_cobrar_servico boolean, p_desconto_cents bigint
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c record;
BEGIN
  PERFORM public.pdv__exigir_operador();
  SELECT * INTO c FROM public.pdv_cards WHERE id = p_comanda FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comanda não encontrada'; END IF;
  IF c.status IN ('recebida', 'cancelada') THEN
    RAISE EXCEPTION 'Comanda % já está %', c.card_number, c.status;
  END IF;
  UPDATE public.pdv_cards
     SET people_count = greatest(coalesce(p_pessoas, 1), 1),
         service_fee_pct = CASE WHEN coalesce(p_cobrar_servico, true)
                                THEN public.pdv__config('service_fee_percent', 10) ELSE 0 END,
         discount_cents = greatest(coalesce(p_desconto_cents, 0), 0)
   WHERE id = c.id;
  RETURN public.pdv__conta(c.id);
END;
$$;

CREATE FUNCTION public.pdv_fechar_comanda(p_comanda uuid, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c record;
BEGIN
  PERFORM public.pdv__exigir_operador();
  SELECT * INTO c FROM public.pdv_cards WHERE id = p_comanda FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comanda não encontrada'; END IF;
  IF c.status <> 'aberta' THEN RAISE EXCEPTION 'Comanda % já está %', c.card_number, c.status; END IF;
  UPDATE public.pdv_cards
     SET status = 'fechada', closed_at = now(), last_activity_by_name = p_operador, last_activity_at = now()
   WHERE id = c.id;
  RETURN public.pdv__conta(c.id);
END;
$$;

CREATE FUNCTION public.pdv_reabrir_comanda(p_comanda uuid, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c record;
BEGIN
  PERFORM public.pdv__exigir_operador();
  SELECT * INTO c FROM public.pdv_cards WHERE id = p_comanda FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comanda não encontrada'; END IF;
  IF c.status <> 'fechada' THEN RAISE EXCEPTION 'Só dá para reabrir comanda fechada'; END IF;
  UPDATE public.pdv_cards
     SET status = 'aberta', closed_at = NULL, last_activity_by_name = p_operador, last_activity_at = now()
   WHERE id = c.id;
  RETURN public.pdv__conta(c.id);
END;
$$;


-- ---------------------------------------------------------------------
-- Caixa
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv_abrir_caixa(p_fundo_cents bigint, p_operador text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s record; v_id uuid;
BEGIN
  PERFORM public.pdv__exigir_operador();
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;
  SELECT * INTO s FROM public.pdv_cash_sessions WHERE status = 'aberta';
  IF FOUND THEN RAISE EXCEPTION 'Já existe um caixa aberto (por %)', s.opened_by_name; END IF;
  IF coalesce(p_fundo_cents, 0) < 0 THEN RAISE EXCEPTION 'Fundo de troco não pode ser negativo'; END IF;
  BEGIN
    INSERT INTO public.pdv_cash_sessions (opened_by_name, opening_float_cents)
    VALUES (p_operador, coalesce(p_fundo_cents, 0)) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Já existe um caixa aberto';
  END;
  RETURN v_id;
END;
$$;

CREATE FUNCTION public.pdv_movimentar_caixa(p_tipo text, p_valor_cents bigint, p_motivo text, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s record; v_esperado bigint;
BEGIN
  PERFORM public.pdv__exigir_operador();
  SELECT * INTO s FROM public.pdv_cash_sessions WHERE status = 'aberta' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Não há caixa aberto'; END IF;
  IF p_tipo NOT IN ('sangria', 'suprimento') THEN RAISE EXCEPTION 'Tipo de movimento inválido: %', p_tipo; END IF;
  IF coalesce(p_valor_cents, 0) <= 0 THEN RAISE EXCEPTION 'Informe um valor maior que zero'; END IF;
  IF length(btrim(coalesce(p_motivo, ''))) = 0 THEN RAISE EXCEPTION 'Informe o motivo'; END IF;
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;

  IF p_tipo = 'sangria' THEN
    v_esperado := (public.pdv__apuracao(s.id, NULL) ->> 'esperado_cents')::bigint;
    IF p_valor_cents > v_esperado THEN
      RAISE EXCEPTION 'A gaveta tem %; não dá para sangrar %', public.pdv__brl(v_esperado), public.pdv__brl(p_valor_cents);
    END IF;
  END IF;

  INSERT INTO public.pdv_cash_movements (session_id, type, amount_cents, reason, created_by_name)
  VALUES (s.id, p_tipo, p_valor_cents, btrim(p_motivo), p_operador);
  RETURN public.pdv__apuracao(s.id, NULL);
END;
$$;

CREATE FUNCTION public.pdv_receber(
  p_comanda uuid, p_metodo text, p_valor_cents bigint, p_entregue_cents bigint, p_operador text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s record; c record; v_conta jsonb;
  v_total bigint; v_pago bigint; v_falta bigint; v_troco bigint := 0; v_quitada boolean;
BEGIN
  PERFORM public.pdv__exigir_operador();
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;

  SELECT * INTO s FROM public.pdv_cash_sessions WHERE status = 'aberta' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Não há caixa aberto — abra o caixa antes de receber'; END IF;

  SELECT * INTO c FROM public.pdv_cards WHERE id = p_comanda FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comanda não encontrada'; END IF;
  IF c.status = 'cancelada' THEN RAISE EXCEPTION 'Comanda cancelada não recebe pagamento'; END IF;
  IF c.status = 'recebida' THEN RAISE EXCEPTION 'A comanda % já foi recebida', c.card_number; END IF;
  IF p_metodo NOT IN ('dinheiro', 'pix', 'credito', 'debito', 'voucher') THEN
    RAISE EXCEPTION 'Forma de pagamento inválida: %', p_metodo;
  END IF;
  IF coalesce(p_valor_cents, 0) <= 0 THEN RAISE EXCEPTION 'Informe um valor maior que zero'; END IF;

  v_conta := public.pdv__conta(c.id);
  v_total := (v_conta ->> 'total_cents')::bigint;
  v_pago  := (v_conta ->> 'pago_cents')::bigint;
  v_falta := (v_conta ->> 'falta_cents')::bigint;
  IF p_valor_cents > v_falta THEN
    RAISE EXCEPTION 'Falta apenas % nesta comanda', public.pdv__brl(v_falta);
  END IF;

  IF p_metodo = 'dinheiro' AND p_entregue_cents IS NOT NULL THEN
    IF p_entregue_cents < p_valor_cents THEN
      RAISE EXCEPTION 'O cliente entregou %, menos que os % a receber',
        public.pdv__brl(p_entregue_cents), public.pdv__brl(p_valor_cents);
    END IF;
    v_troco := p_entregue_cents - p_valor_cents;
  END IF;

  -- valor = o que abate da conta E o que entra na gaveta; troco é só mecânica física
  INSERT INTO public.pdv_payments (card_id, session_id, method, amount_cents, change_cents, received_by_name)
  VALUES (c.id, s.id, p_metodo, p_valor_cents, v_troco, p_operador);

  v_quitada := (v_pago + p_valor_cents) >= v_total AND v_total > 0;
  IF v_quitada THEN
    UPDATE public.pdv_cards
       SET status = 'recebida', closed_at = coalesce(closed_at, now()), received_at = now(),
           last_activity_by_name = p_operador, last_activity_at = now()
     WHERE id = c.id;
  ELSE
    UPDATE public.pdv_cards SET last_activity_by_name = p_operador, last_activity_at = now() WHERE id = c.id;
  END IF;

  RETURN jsonb_build_object(
    'numero', c.card_number, 'valor_cents', p_valor_cents, 'troco_cents', v_troco,
    'falta_cents', greatest(v_falta - p_valor_cents, 0), 'quitada', v_quitada
  );
END;
$$;

CREATE FUNCTION public.pdv_fechar_caixa(p_contado_cents bigint, p_observacao text, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s record; v_pend integer[]; v_ap jsonb; v_qtd int;
BEGIN
  PERFORM public.pdv__exigir_operador();
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;
  SELECT * INTO s FROM public.pdv_cash_sessions WHERE status = 'aberta' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Não há caixa aberto'; END IF;
  IF p_contado_cents IS NULL OR p_contado_cents < 0 THEN RAISE EXCEPTION 'Informe quanto foi contado na gaveta'; END IF;

  -- comanda de controle (banda, equipe) fica aberta de propósito e não trava o fechamento
  SELECT array_agg(card_number ORDER BY card_number) INTO v_pend
    FROM public.pdv_cards WHERE status IN ('aberta', 'fechada') AND NOT is_control_card;
  IF v_pend IS NOT NULL THEN
    v_qtd := array_length(v_pend, 1);
    RAISE EXCEPTION 'Ainda há % comanda(s) sem receber: %', v_qtd,
      array_to_string(v_pend[1:5], ', ') || CASE WHEN v_qtd > 5 THEN ' e mais ' || (v_qtd - 5) ELSE '' END;
  END IF;

  v_ap := public.pdv__apuracao(s.id, p_contado_cents);
  UPDATE public.pdv_cash_sessions
     SET status = 'fechada', closed_by_name = p_operador, closed_at = now(),
         counted_cents = p_contado_cents, expected_cents = (v_ap ->> 'esperado_cents')::bigint,
         notes = nullif(btrim(p_observacao), '')
   WHERE id = s.id;
  RETURN public.pdv__apuracao(s.id, p_contado_cents);
END;
$$;


-- ---------------------------------------------------------------------
-- Vendas
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv_resumo_vendas(p_de timestamptz, p_ate timestamptz)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_total bigint; v_cmds int; v_troco bigint; v_metodos jsonb; v_itens jsonb;
  v_cancel int; v_cancel_valor bigint;
BEGIN
  PERFORM public.pdv__exigir_operador();

  SELECT coalesce(sum(amount_cents), 0), count(DISTINCT card_id), coalesce(sum(change_cents), 0)
    INTO v_total, v_cmds, v_troco
    FROM public.pdv_payments WHERE received_at >= p_de AND received_at < p_ate;

  SELECT coalesce(jsonb_object_agg(method, soma), '{}'::jsonb) INTO v_metodos
    FROM (SELECT method, sum(amount_cents) AS soma FROM public.pdv_payments
           WHERE received_at >= p_de AND received_at < p_ate GROUP BY method) x;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.total_cents DESC), '[]'::jsonb) INTO v_itens
    FROM (SELECT item_name AS nome, sum(quantity) AS quantidade, sum(total_cents) AS total_cents
            FROM public.pdv_card_items
           WHERE status = 'ativo' AND created_at >= p_de AND created_at < p_ate
           GROUP BY item_name ORDER BY sum(total_cents) DESC LIMIT 10) x;

  SELECT count(*), coalesce(sum(total_cents), 0) INTO v_cancel, v_cancel_valor
    FROM public.pdv_card_items WHERE status = 'cancelado' AND cancelled_at >= p_de AND cancelled_at < p_ate;

  RETURN jsonb_build_object(
    'de', p_de, 'ate', p_ate,
    'total_recebido_cents', v_total,
    'comandas_recebidas', v_cmds,
    'ticket_medio_cents', CASE WHEN v_cmds > 0 THEN v_total / v_cmds ELSE 0 END,
    'por_metodo', v_metodos,
    'itens_mais_vendidos', v_itens,
    'itens_cancelados', v_cancel,
    'valor_cancelado_cents', v_cancel_valor,
    'troco_dado_cents', v_troco
  );
END;
$$;


-- ---------------------------------------------------------------------
-- Quem pode executar o quê
-- (o Supabase dá EXECUTE pro anônimo por padrão: tirar explicitamente)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  public.pdv__exigir_operador(), public.pdv__config(text, numeric), public.pdv__brl(bigint),
  public.pdv__conta(uuid), public.pdv__apuracao(uuid, bigint)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
  public.pdv_is_terminal(), public.pdv_is_panel_user(), public.pdv_pode_operar(),
  public.pdv_conta(uuid), public.pdv_apuracao_caixa(uuid, bigint),
  public.pdv_abrir_comanda(integer, text, integer, text, boolean, text),
  public.pdv_lancar_pedido(uuid, jsonb, text),
  public.pdv_cancelar_item(uuid, text, text),
  public.pdv_ajustar_conta(uuid, integer, boolean, bigint),
  public.pdv_fechar_comanda(uuid, text), public.pdv_reabrir_comanda(uuid, text),
  public.pdv_abrir_caixa(bigint, text),
  public.pdv_movimentar_caixa(text, bigint, text, text),
  public.pdv_receber(uuid, text, bigint, bigint, text),
  public.pdv_fechar_caixa(bigint, text, text),
  public.pdv_resumo_vendas(timestamptz, timestamptz)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
  public.pdv_is_terminal(), public.pdv_is_panel_user(), public.pdv_pode_operar(),
  public.pdv_conta(uuid), public.pdv_apuracao_caixa(uuid, bigint),
  public.pdv_abrir_comanda(integer, text, integer, text, boolean, text),
  public.pdv_lancar_pedido(uuid, jsonb, text),
  public.pdv_cancelar_item(uuid, text, text),
  public.pdv_ajustar_conta(uuid, integer, boolean, bigint),
  public.pdv_fechar_comanda(uuid, text), public.pdv_reabrir_comanda(uuid, text),
  public.pdv_abrir_caixa(bigint, text),
  public.pdv_movimentar_caixa(text, bigint, text, text),
  public.pdv_receber(uuid, text, bigint, bigint, text),
  public.pdv_fechar_caixa(bigint, text, text),
  public.pdv_resumo_vendas(timestamptz, timestamptz)
TO authenticated;

COMMIT;

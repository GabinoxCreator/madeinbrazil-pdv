-- =====================================================================
-- Made in Brazil Delivery — Checkout Transparente do Mercado Pago
--
-- Decisão (16/09): o pagamento online deixa de redirecionar para o
-- Checkout Pro. O site cria o pagamento direto na API /v1/payments (Pix com
-- QR no próprio site, ou cartão de crédito tokenizado no navegador), por
-- Edge Function com service role. A forma de pagamento continua 'online' e
-- a confirmação continua por dlv_confirmar_pagamento_online (não muda).
--
-- Fluxo:
--   1. cardápio → dlv_criar_pedido (forma 'online') → aguardando_pagamento
--   2. Edge Function → dlv_pedido_para_pagamento(codigo) → cria o pagamento
--      no Mercado Pago → dlv_registrar_pagamento_online(pedido, id, tipo, pix)
--   3. Mercado Pago aprova → webhook → dlv_confirmar_pagamento_online
--
-- Contra teste de cartão roubado (a função que cobra cartão é pública):
-- antes de cada cobrança com cartão, a Edge Function chama
-- dlv_tentativa_cartao, que conta e limita as tentativas por pedido e por
-- telefone (janela de 2 horas).
--
-- Mudanças (nada destrutivo; não apaga nem altera dados):
--   * dlv_orders: coluna mp_card_attempts (int, padrão 0)
--   * dlv_settings: card_attempts_per_order = 5, card_attempts_per_phone_2h = 10
--   * novas, só service_role: dlv_registrar_pagamento_online, dlv_tentativa_cartao
--   * redefinida a partir de 20260915131000: dlv_pedido_para_pagamento
--     (mesmas chaves + mp_payment_id, mp_payment_type, pix_copia_cola, pago,
--     tentativas_cartao)
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- TABELA E CONFIGURAÇÃO
-- ---------------------------------------------------------------------
ALTER TABLE public.dlv_orders
  ADD COLUMN mp_card_attempts int NOT NULL DEFAULT 0;   -- tentativas de cobrança com cartão neste pedido

INSERT INTO public.dlv_settings (key, value, description) VALUES
  ('card_attempts_per_order',    '5',  'Máximo de tentativas de pagamento com cartão em um mesmo pedido'),
  ('card_attempts_per_phone_2h', '10', 'Máximo de tentativas de pagamento com cartão somando os pedidos do mesmo telefone nas últimas 2 horas');


-- ---------------------------------------------------------------------
-- dados para criar o pagamento, pelo código do link de acompanhamento
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dlv_pedido_para_pagamento(p_codigo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o record;
BEGIN
  IF p_codigo IS NULL OR p_codigo !~ '^[0-9a-f]{32}$' THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;
  PERFORM public.dlv__expirar_pix();
  SELECT * INTO o FROM public.dlv_orders WHERE public_code = p_codigo;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;

  RETURN jsonb_build_object(
    'id', o.id, 'numero', o.number, 'status', o.status, 'forma', o.payment_method,
    'total_cents', o.total_cents,
    'cliente_nome', o.customer_name, 'cliente_telefone', o.customer_phone,
    'expira_em', o.pix_expires_at,
    'preference_id', o.mp_preference_id, 'checkout_url', o.mp_checkout_url,
    'mp_payment_id', o.mp_payment_id, 'mp_payment_type', o.mp_payment_type,
    'pix_copia_cola', o.pix_copy_paste, 'pago', o.paid_at IS NOT NULL,
    'tentativas_cartao', o.mp_card_attempts,
    'itens', coalesce((
      SELECT jsonb_agg(jsonb_build_object('nome', oi.item_name, 'quantidade', oi.quantity, 'total_cents', oi.total_cents)
                       ORDER BY oi.created_at, oi.id)
        FROM public.dlv_order_items oi WHERE oi.order_id = o.id), '[]'::jsonb)
  );
END;
$$;

-- ---------------------------------------------------------------------
-- guarda o pagamento criado no Mercado Pago (Pix ou cartão).
-- Pode ser chamada de novo (outra tentativa com outro cartão ou outro Pix):
-- sobrescreve o que estava gravado.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv_registrar_pagamento_online(p_pedido uuid, p_mp_payment_id text, p_tipo text, p_pix_copia_cola text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id   text := btrim(coalesce(p_mp_payment_id, ''));
  v_tipo text := nullif(left(btrim(coalesce(p_tipo, '')), 40), '');
  v_pix  text := nullif(left(btrim(coalesce(p_pix_copia_cola, '')), 1000), '');
BEGIN
  IF length(v_id) = 0 THEN RAISE EXCEPTION 'Pagamento sem identificador'; END IF;
  IF EXISTS (SELECT 1 FROM public.dlv_orders WHERE mp_payment_id = v_id AND id <> p_pedido) THEN
    RAISE EXCEPTION 'Pagamento % já está ligado a outro pedido', v_id;
  END IF;

  UPDATE public.dlv_orders
     SET mp_payment_id = v_id, mp_payment_type = v_tipo, pix_copy_paste = v_pix
   WHERE id = p_pedido AND status = 'aguardando_pagamento' AND payment_method = 'online' AND paid_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não está aguardando pagamento online'; END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- conta uma tentativa de cobrança com cartão (chamar ANTES de cobrar).
-- Recusa se o pedido ou o telefone passou do limite; devolve o novo total
-- de tentativas do pedido.
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv_tentativa_cartao(p_pedido uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  o       record;
  v_total int;
BEGIN
  SELECT * INTO o FROM public.dlv_orders WHERE id = p_pedido FOR UPDATE;
  IF NOT FOUND OR o.payment_method <> 'online' OR o.status <> 'aguardando_pagamento' OR o.paid_at IS NOT NULL THEN
    RAISE EXCEPTION 'Pedido não está aguardando pagamento online';
  END IF;

  IF o.mp_card_attempts >= public.dlv__config('card_attempts_per_order', '5')::int THEN
    RAISE EXCEPTION 'Muitas tentativas com cartão neste pedido. Pague com Pix ou fale com a loja.';
  END IF;

  SELECT coalesce(sum(mp_card_attempts), 0) INTO v_total
    FROM public.dlv_orders
   WHERE customer_phone = o.customer_phone AND created_at > now() - interval '2 hours';
  IF v_total >= public.dlv__config('card_attempts_per_phone_2h', '10')::int THEN
    RAISE EXCEPTION 'Muitas tentativas com cartão. Pague com Pix ou fale com a loja.';
  END IF;

  UPDATE public.dlv_orders SET mp_card_attempts = mp_card_attempts + 1 WHERE id = o.id
  RETURNING mp_card_attempts INTO v_total;
  RETURN v_total;
END;
$$;


-- ---------------------------------------------------------------------
-- Quem pode executar (CREATE OR REPLACE mantém as permissões das que já existiam)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  public.dlv_registrar_pagamento_online(uuid, text, text, text),
  public.dlv_tentativa_cartao(uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.dlv_registrar_pagamento_online(uuid, text, text, text),
  public.dlv_tentativa_cartao(uuid)
TO service_role;


-- ---------------------------------------------------------------------
-- Conferência: se algo não bater, nada fica gravado
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_publicas text[] := ARRAY['dlv_acompanhar_pedido', 'dlv_cardapio_publico', 'dlv_consultar_entrega', 'dlv_criar_pedido', 'dlv_status_loja'];
  v_so_servico text[] := ARRAY['dlv_confirmar_pagamento_online', 'dlv_pedido_para_pagamento', 'dlv_registrar_checkout', 'dlv_registrar_pagamento_online', 'dlv_tentativa_cartao'];
  v_anon     text[];
  v_def      text;
BEGIN
  -- anônimo executa só as 5 públicas
  SELECT coalesce(array_agg(p.proname::text ORDER BY p.proname), '{}') INTO v_anon
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND left(p.proname, 4) = 'dlv_'
     AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF v_anon <> v_publicas THEN
    RAISE EXCEPTION 'anônimo executa funções diferentes das 5 públicas: %', v_anon;
  END IF;

  -- funções de pagamento online: existem uma vez cada e só service_role executa
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = ANY (v_so_servico)) <> 5 THEN
    RAISE EXCEPTION 'esperava 5 funções de pagamento online (uma de cada)';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname = ANY (v_so_servico)
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
                     OR NOT has_function_privilege('service_role', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'funções de pagamento online com permissão errada';
  END IF;

  -- dlv_pedido_para_pagamento com as chaves novas
  v_def := pg_get_functiondef('public.dlv_pedido_para_pagamento(text)'::regprocedure);
  IF strpos(v_def, '''mp_payment_id''') = 0 OR strpos(v_def, '''mp_payment_type''') = 0
     OR strpos(v_def, '''pix_copia_cola''') = 0 OR strpos(v_def, '''pago''') = 0
     OR strpos(v_def, '''tentativas_cartao''') = 0
     OR strpos(v_def, '''checkout_url''') = 0 OR strpos(v_def, '''itens''') = 0 THEN
    RAISE EXCEPTION 'dlv_pedido_para_pagamento sem as chaves esperadas';
  END IF;

  -- coluna e limites de tentativas com cartão
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'dlv_orders' AND column_name = 'mp_card_attempts'
                    AND data_type = 'integer' AND is_nullable = 'NO' AND column_default = '0') THEN
    RAISE EXCEPTION 'coluna mp_card_attempts de dlv_orders não ficou como esperado';
  END IF;
  IF EXISTS (SELECT 1 FROM public.dlv_orders WHERE mp_card_attempts <> 0) THEN
    RAISE EXCEPTION 'pedidos existentes deveriam começar com mp_card_attempts = 0';
  END IF;
  IF public.dlv__config('card_attempts_per_order', NULL) IS DISTINCT FROM '5'
     OR public.dlv__config('card_attempts_per_phone_2h', NULL) IS DISTINCT FROM '10' THEN
    RAISE EXCEPTION 'configurações card_attempts_per_order (5) e card_attempts_per_phone_2h (10) não ficaram certas';
  END IF;
END $$;

COMMIT;

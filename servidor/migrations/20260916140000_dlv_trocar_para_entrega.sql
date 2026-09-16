-- =====================================================================
-- Made in Brazil Delivery — trocar "pagar online" por "pagar na entrega"
--
-- Decisão do dono (16/09): o cliente que escolheu "pagar online" e desistiu
-- na tela de pagamento pode passar a pagar na entrega (crédito, débito ou
-- dinheiro com troco) sem refazer o pedido.
--
-- Fluxo:
--   1. cliente pede a troca na tela de pagamento
--   2. Edge Function (service role) confere no Mercado Pago que nenhum
--      pagamento foi aprovado e cancela o Pix pendente
--   3. Edge Function → dlv_trocar_para_pagamento_na_entrega(pedido, forma, troco)
--   4. pedido segue o caminho normal de quem paga na entrega: em análise e,
--      com aceite automático, produção (gera os cupons)
--
-- Mudanças (nada destrutivo; não apaga nem altera dados existentes):
--   * nova, só service_role: dlv_trocar_para_pagamento_na_entrega
--     - mesma trava por telefone do cardápio (20260916120000), contando só
--       os OUTROS pedidos do telefone
--     - mesma regra e mensagem de troco de dlv__criar_pedido
--     - limpa os dados do pagamento online abandonado (prazo, id, tipo,
--       Pix copia e cola, preferência e link do checkout)
--     - muda de etapa por dlv__mudar_status, que registra o evento com a
--       nota 'Cliente trocou para pagar na entrega (<forma>)'
-- =====================================================================

BEGIN;

CREATE FUNCTION public.dlv_trocar_para_pagamento_na_entrega(p_pedido uuid, p_forma text, p_troco_para_cents bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  o        record;
  v_troco  bigint := p_troco_para_cents;
  v_status text;
BEGIN
  -- online vencido vira cancelado antes (e aí não pode mais trocar)
  PERFORM public.dlv__expirar_pix();

  SELECT * INTO o FROM public.dlv_orders WHERE id = p_pedido FOR UPDATE;
  IF NOT FOUND OR o.payment_method <> 'online' OR o.status <> 'aguardando_pagamento' OR o.paid_at IS NOT NULL THEN
    RAISE EXCEPTION 'Este pedido não pode mais trocar a forma de pagamento';
  END IF;

  IF p_forma IS NULL OR p_forma NOT IN ('credito', 'debito', 'dinheiro') THEN
    RAISE EXCEPTION 'Escolha a forma de pagamento';
  END IF;

  -- troco só em dinheiro, e para um valor que cubra o total
  IF p_forma <> 'dinheiro' THEN v_troco := NULL; END IF;
  IF v_troco IS NOT NULL AND v_troco < o.total_cents THEN
    RAISE EXCEPTION 'O troco precisa ser para um valor maior que o total (%)', public.dlv__brl(o.total_cents);
  END IF;

  -- mesma trava contra trote do cardápio, contando os OUTROS pedidos do telefone
  -- (este já estava contando enquanto aguardava pagamento)
  IF o.source = 'cardapio' AND (
       SELECT count(*) FROM public.dlv_orders
        WHERE customer_phone = o.customer_phone
          AND id <> o.id
          AND status IN ('aguardando_pagamento', 'em_analise', 'em_producao', 'pronto', 'saiu_entrega')
          AND paid_at IS NULL
     ) >= public.dlv__config('max_open_orders_per_phone', '5')::int THEN
    RAISE EXCEPTION 'Já existem pedidos em andamento para este telefone. Aguarde ou fale com a loja.';
  END IF;

  -- o pagamento online foi abandonado (a Edge Function já cancelou no Mercado Pago)
  UPDATE public.dlv_orders
     SET payment_method   = p_forma,
         change_for_cents = v_troco,
         pix_expires_at   = NULL,
         mp_payment_id    = NULL,
         mp_payment_type  = NULL,
         pix_copy_paste   = NULL,
         mp_preference_id = NULL,
         mp_checkout_url  = NULL
   WHERE id = o.id;

  PERFORM public.dlv__mudar_status(o.id, 'em_analise', 'cliente',
    'Cliente trocou para pagar na entrega (' || p_forma || ')');
  v_status := 'em_analise';

  -- mesmo aceite automático de quem já pede para pagar na entrega
  IF public.dlv__config('auto_accept', 'false') = 'true' THEN
    PERFORM public.dlv__mudar_status(o.id, 'em_producao', 'aceite automático');
    v_status := 'em_producao';
  END IF;

  RETURN jsonb_build_object('numero', o.number, 'status', v_status, 'forma', p_forma);
END;
$$;


-- ---------------------------------------------------------------------
-- Quem pode executar: só service_role (Edge Function)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.dlv_trocar_para_pagamento_na_entrega(uuid, text, bigint)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.dlv_trocar_para_pagamento_na_entrega(uuid, text, bigint)
TO service_role;


-- ---------------------------------------------------------------------
-- Conferência: se algo não bater, nada fica gravado
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_publicas text[] := ARRAY['dlv_acompanhar_pedido', 'dlv_cardapio_publico', 'dlv_consultar_entrega', 'dlv_criar_pedido', 'dlv_status_loja'];
  v_anon     text[];
  v_oid      oid;
  v_def      text;
BEGIN
  -- existe uma vez só
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'dlv_trocar_para_pagamento_na_entrega') <> 1 THEN
    RAISE EXCEPTION 'esperava 1 função dlv_trocar_para_pagamento_na_entrega';
  END IF;
  v_oid := 'public.dlv_trocar_para_pagamento_na_entrega(uuid, text, bigint)'::regprocedure;

  -- só service_role executa
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'dlv_trocar_para_pagamento_na_entrega com permissão errada';
  END IF;

  -- anônimo continua executando só as 5 públicas
  SELECT coalesce(array_agg(p.proname::text ORDER BY p.proname), '{}') INTO v_anon
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND left(p.proname, 4) = 'dlv_'
     AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF v_anon <> v_publicas THEN
    RAISE EXCEPTION 'anônimo executa funções diferentes das 5 públicas: %', v_anon;
  END IF;

  -- regras principais presentes
  v_def := pg_get_functiondef(v_oid);
  IF strpos(v_def, 'PERFORM public.dlv__expirar_pix()') = 0
     OR strpos(v_def, 'FOR UPDATE') = 0
     OR strpos(v_def, $t$NOT IN ('credito', 'debito', 'dinheiro')$t$) = 0
     OR strpos(v_def, 'AND id <> o.id') = 0
     OR strpos(v_def, 'AND paid_at IS NULL') = 0
     OR strpos(v_def, $t$'max_open_orders_per_phone', '5'$t$) = 0
     OR strpos(v_def, 'mp_checkout_url  = NULL') = 0
     OR strpos(v_def, $t$dlv__mudar_status(o.id, 'em_analise'$t$) = 0 THEN
    RAISE EXCEPTION 'dlv_trocar_para_pagamento_na_entrega sem as regras esperadas';
  END IF;

  -- regras da tabela que a troca precisa respeitar continuam lá
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.dlv_orders'::regclass AND contype = 'c'
                  AND pg_get_constraintdef(oid) LIKE '%change_for_cents IS NULL%' AND pg_get_constraintdef(oid) LIKE '%dinheiro%') THEN
    RAISE EXCEPTION 'regra "troco só em dinheiro" não encontrada em dlv_orders';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.dlv_orders'::regclass
                  AND conname = 'dlv_orders_pagamento_online_pago_check') THEN
    RAISE EXCEPTION 'regra "online só avança pago" não encontrada em dlv_orders';
  END IF;
END $$;

COMMIT;

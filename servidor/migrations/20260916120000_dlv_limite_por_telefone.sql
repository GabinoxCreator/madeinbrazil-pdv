-- =====================================================================
-- Made in Brazil Delivery — limite de pedidos em andamento por telefone
--
-- Decisão (16/09): a trava contra trote estava barrando cliente de verdade
-- (pediu uma marmita e, dois minutos depois, um colega quis pedir com o
-- mesmo celular). Pedido já PAGO online é pagamento único e não é trote,
-- então não conta mais.
--
-- Mudanças (nada destrutivo; não apaga dados):
--   * dlv__criar_pedido(jsonb, text, text): na contagem de pedidos em
--     andamento do telefone, pedidos com paid_at preenchido (pagos online)
--     não contam. Continuam contando: 'aguardando_pagamento' sem pagar e
--     pedidos para pagar na entrega em andamento. O painel continua sem
--     limite. A troca é feita só no trecho da trava, sobre a definição que
--     está no banco (confere que o trecho antigo aparece exatamente 1 vez).
--   * dlv_settings: max_open_orders_per_phone passa de 3 para 5
--     (e o valor padrão dentro da função, usado só se a chave sumir, também).
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- dlv__criar_pedido: pedido pago online não conta na trava
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_antigo text := $antigo$
  -- contra trote: poucos pedidos em andamento por telefone (o painel não tem limite)
  IF p_origem = 'cardapio' AND (
       SELECT count(*) FROM public.dlv_orders
        WHERE customer_phone = v_tel
          AND status IN ('aguardando_pagamento', 'em_analise', 'em_producao', 'pronto', 'saiu_entrega')
     ) >= public.dlv__config('max_open_orders_per_phone', '3')::int THEN
    RAISE EXCEPTION 'Já existem pedidos em andamento para este telefone. Aguarde ou fale com a loja.';
  END IF;
$antigo$;
  v_novo text := $novo$
  -- contra trote: poucos pedidos em andamento por telefone (o painel não tem limite).
  -- Pedido já pago online não conta: é pagamento único, não é trote.
  IF p_origem = 'cardapio' AND (
       SELECT count(*) FROM public.dlv_orders
        WHERE customer_phone = v_tel
          AND status IN ('aguardando_pagamento', 'em_analise', 'em_producao', 'pronto', 'saiu_entrega')
          AND paid_at IS NULL
     ) >= public.dlv__config('max_open_orders_per_phone', '5')::int THEN
    RAISE EXCEPTION 'Já existem pedidos em andamento para este telefone. Aguarde ou fale com a loja.';
  END IF;
$novo$;
  v_def   text;
  v_vezes int;
BEGIN
  v_def := pg_get_functiondef('public.dlv__criar_pedido(jsonb, text, text)'::regprocedure);
  v_vezes := (length(v_def) - length(replace(v_def, v_antigo, ''))) / length(v_antigo);
  IF v_vezes <> 1 THEN
    RAISE EXCEPTION 'dlv__criar_pedido: esperava o trecho antigo da trava por telefone 1 vez, achei %', v_vezes;
  END IF;
  EXECUTE replace(v_def, v_antigo, v_novo);
END $$;


-- ---------------------------------------------------------------------
-- configuração: 3 → 5 pedidos em andamento por telefone
-- ---------------------------------------------------------------------
DO $$
DECLARE v_linhas int;
BEGIN
  UPDATE public.dlv_settings SET value = '5' WHERE key = 'max_open_orders_per_phone';
  GET DIAGNOSTICS v_linhas = ROW_COUNT;
  IF v_linhas <> 1 THEN
    RAISE EXCEPTION 'max_open_orders_per_phone: esperava atualizar 1 linha, atualizou %', v_linhas;
  END IF;
END $$;


-- ---------------------------------------------------------------------
-- Conferência: se algo não bater, nada fica gravado
-- ---------------------------------------------------------------------
DO $$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.dlv__criar_pedido(jsonb, text, text)'::regprocedure);
  IF strpos(v_def, 'AND paid_at IS NULL
     ) >= public.dlv__config(''max_open_orders_per_phone'', ''5'')::int THEN') = 0
     OR strpos(v_def, '''max_open_orders_per_phone'', ''3''') > 0 THEN
    RAISE EXCEPTION 'dlv__criar_pedido sem o trecho novo da trava por telefone';
  END IF;
  IF public.dlv__config('max_open_orders_per_phone', NULL) IS DISTINCT FROM '5' THEN
    RAISE EXCEPTION 'configuração max_open_orders_per_phone não ficou 5';
  END IF;
END $$;

COMMIT;

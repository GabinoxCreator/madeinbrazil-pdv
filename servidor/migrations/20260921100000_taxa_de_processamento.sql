-- Taxa de processamento: valor fixo por pedido, cobrado do cliente e somado ao total.
-- Vale para entrega e retirada, pedido do cardápio e do painel. Fica guardada em
-- coluna própria para dar para medir quanto ela rendeu no período.

ALTER TABLE public.dlv_orders
  ADD COLUMN IF NOT EXISTS service_fee_cents bigint NOT NULL DEFAULT 0
  CHECK (service_fee_cents >= 0);

COMMENT ON COLUMN public.dlv_orders.service_fee_cents IS
  'Taxa de processamento cobrada do cliente neste pedido (congelada no momento do pedido).';

-- O total do pedido passa a incluir a taxa. Pedidos antigos têm taxa zero,
-- então o total deles continua exatamente o mesmo.
ALTER TABLE public.dlv_orders
  ALTER COLUMN total_cents
  SET EXPRESSION AS ((subtotal_cents + delivery_fee_cents + service_fee_cents) - discount_cents);

-- Valor atual. Mudar aqui muda só os pedidos novos: o que já foi cobrado fica como está.
INSERT INTO public.dlv_settings (key, value) VALUES ('service_fee_cents', '99')
ON CONFLICT (key) DO UPDATE SET value = excluded.value;

-- Pedido do cardápio online nasce com a taxa do momento. Pedido lançado no balcão
-- pelo painel não tem taxa: o cliente não usou o sistema para pedir.
CREATE OR REPLACE FUNCTION public.dlv__aplicar_taxa_processamento()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.service_fee_cents = 0 AND NEW.source = 'cardapio' THEN
    NEW.service_fee_cents := public.dlv__config('service_fee_cents', '0')::bigint;
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.dlv__aplicar_taxa_processamento() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS dlv_orders_taxa_processamento ON public.dlv_orders;
CREATE TRIGGER dlv_orders_taxa_processamento
  BEFORE INSERT ON public.dlv_orders
  FOR EACH ROW EXECUTE FUNCTION public.dlv__aplicar_taxa_processamento();

-- O troco precisa cobrir o total COM a taxa.
DO $do$
DECLARE d text; a text; b text;
BEGIN
  d := pg_get_functiondef('public.dlv__criar_pedido(jsonb,text,text)'::regprocedure);
  a := 'IF v_troco IS NOT NULL AND v_troco < v_subtotal + v_taxa THEN';
  b := 'IF v_troco IS NOT NULL AND v_troco < v_subtotal + v_taxa + public.dlv__config(''service_fee_cents'', ''0'')::bigint THEN';
  IF position(a in d) = 0 THEN RAISE EXCEPTION 'nao achei a checagem do troco'; END IF;
  d := replace(d, a, b);
  d := replace(d,
    'public.dlv__brl(v_subtotal + v_taxa);',
    'public.dlv__brl(v_subtotal + v_taxa + public.dlv__config(''service_fee_cents'', ''0'')::bigint);');
  EXECUTE d;
END
$do$;

-- A taxa aparece para quem acompanha o pedido e na tela de pagamento.
DO $do$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.dlv_acompanhar_pedido(text)'::regprocedure);
  a := '''subtotal_cents'', o.subtotal_cents, ''taxa_entrega_cents'', o.delivery_fee_cents,';
  IF position(a in d) = 0 THEN RAISE EXCEPTION 'nao achei o bloco de valores do acompanhamento'; END IF;
  EXECUTE replace(d, a, a || ' ''taxa_servico_cents'', o.service_fee_cents,');

  d := pg_get_functiondef('public.dlv_pedido_para_pagamento(text)'::regprocedure);
  a := '''total_cents'', o.total_cents,';
  IF position(a in d) = 0 THEN RAISE EXCEPTION 'nao achei o total na tela de pagamento'; END IF;
  EXECUTE replace(d, a, a || ' ''taxa_servico_cents'', o.service_fee_cents,');
END
$do$;

-- E no cupom, logo abaixo da taxa de entrega.
DO $do$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.dlv__cupom_linhas(uuid)'::regprocedure);
  a := '    IF v_entrega THEN
      l := l || jsonb_build_object(''esq'', ''  Taxa de entrega'', ''dir'', public.dlv__brl(o.delivery_fee_cents));
    END IF;';
  IF position(a in d) = 0 THEN RAISE EXCEPTION 'nao achei a taxa de entrega no cupom'; END IF;
  EXECUTE replace(d, a, a || '
    IF o.service_fee_cents > 0 THEN
      l := l || jsonb_build_object(''esq'', ''  Taxa de processamento'', ''dir'', public.dlv__brl(o.service_fee_cents));
    END IF;');
END
$do$;

-- O cardápio público informa a taxa para a tela mostrar antes de o cliente confirmar.
DO $do$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.dlv_cardapio_publico()'::regprocedure);
  a := '''pedido_minimo_cents'', public.dlv__config(''min_order_cents'', ''0'')::bigint,';
  IF position(a in d) = 0 THEN RAISE EXCEPTION 'nao achei o pedido minimo no cardapio publico'; END IF;
  EXECUTE replace(d, a, a || '
      ''taxa_servico_cents'', public.dlv__config(''service_fee_cents'', ''0'')::bigint,');
END
$do$;

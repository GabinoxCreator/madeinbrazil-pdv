-- Relatório do delivery por período: o que vendeu, como pagaram, quanto ficou
-- com os motoqueiros e — a conta que interessa no fim do dia — quanto dá para
-- tirar da conta do Mercado Pago do que foi pago online.
--
-- A taxa do Pix do Mercado Pago é percentual e muda por contrato, então mora em
-- configuração, não no código.

INSERT INTO public.dlv_settings (key, value) VALUES ('mp_pix_fee_percent', '0.99')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.dlv_relatorio(p_de date DEFAULT NULL, p_ate date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_hoje   date := (public.dlv__agora_local())::date;
  v_de     date := coalesce(p_de, v_hoje);
  v_ate    date := coalesce(p_ate, v_de);
  v_inicio timestamptz;
  v_fim    timestamptz;
  v_fixo   bigint  := public.dlv__config('courier_daily_cents', '0')::bigint;
  v_perto  bigint  := public.dlv__config('courier_short_fee_cents', '0')::bigint;
  v_raio   numeric := public.dlv__config('courier_short_km', '2')::numeric;
  v_taxa_mp numeric := public.dlv__config('mp_pix_fee_percent', '0')::numeric;
  v_online_cents bigint;
  v_online_taxa  bigint;
  v_motoboys bigint;
  r record;
BEGIN
  PERFORM public.dlv__exigir_painel();
  IF v_ate < v_de THEN SELECT v_ate, v_de INTO v_de, v_ate; END IF;
  IF v_ate - v_de > 366 THEN RAISE EXCEPTION 'Período muito longo (máximo de um ano)'; END IF;

  v_inicio := (v_de::text  || ' 00:00:00')::timestamp AT TIME ZONE 'America/Sao_Paulo';
  v_fim    := ((v_ate + 1)::text || ' 00:00:00')::timestamp AT TIME ZONE 'America/Sao_Paulo';

  SELECT
    count(*) FILTER (WHERE status <> 'cancelado')                              AS pedidos,
    count(*) FILTER (WHERE status = 'cancelado')                               AS cancelados,
    count(*) FILTER (WHERE status NOT IN ('finalizado','cancelado'))           AS em_aberto,
    count(*) FILTER (WHERE mode='entrega'  AND status <> 'cancelado')          AS entregas,
    count(*) FILTER (WHERE mode='retirada' AND status <> 'cancelado')          AS retiradas,
    coalesce(sum(total_cents)        FILTER (WHERE status <> 'cancelado'), 0)  AS bruto,
    coalesce(sum(subtotal_cents)     FILTER (WHERE status <> 'cancelado'), 0)  AS comida,
    coalesce(sum(delivery_fee_cents) FILTER (WHERE status <> 'cancelado'), 0)  AS taxa_entrega,
    coalesce(sum(service_fee_cents)  FILTER (WHERE status <> 'cancelado'), 0)  AS taxa_proc,
    coalesce(sum(discount_cents)     FILTER (WHERE status <> 'cancelado'), 0)  AS desconto,
    coalesce(sum(total_cents)        FILTER (WHERE status = 'cancelado'), 0)   AS perdido,
    coalesce(sum(total_cents) FILTER (WHERE mode='entrega'  AND status <> 'cancelado'), 0) AS valor_entregas,
    coalesce(sum(total_cents) FILTER (WHERE mode='retirada' AND status <> 'cancelado'), 0) AS valor_retiradas,
    count(*) FILTER (WHERE payment_method IN ('online','pix_online') AND status <> 'cancelado') AS online_pedidos,
    coalesce(sum(total_cents) FILTER (WHERE payment_method IN ('online','pix_online') AND status <> 'cancelado'), 0) AS online_valor,
    count(*) FILTER (WHERE service_fee_cents > 0 AND status <> 'cancelado')    AS pedidos_com_taxa
    INTO r
    FROM public.dlv_orders
   WHERE created_at >= v_inicio AND created_at < v_fim;

  v_online_cents := r.online_valor;
  -- A taxa do Mercado Pago sai do que caiu lá: é o que não dá para transferir.
  v_online_taxa  := round(v_online_cents * v_taxa_mp / 100.0);

  SELECT coalesce(sum(total_cents), 0) INTO v_motoboys FROM (
    SELECT c.id, (o.created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
           v_fixo + sum(CASE WHEN o.distance_km IS NOT NULL AND o.distance_km <= v_raio
                             THEN v_perto ELSE o.delivery_fee_cents END) AS total_cents
      FROM public.dlv_orders o
      JOIN public.dlv_couriers c ON c.id = o.courier_id
     WHERE o.created_at >= v_inicio AND o.created_at < v_fim
       AND o.mode = 'entrega' AND o.status IN ('saiu_entrega','finalizado')
     GROUP BY c.id, 2
  ) d;

  RETURN jsonb_build_object(
    'de', v_de, 'ate', v_ate, 'hoje', v_hoje,
    'pedidos', r.pedidos, 'cancelados', r.cancelados, 'em_aberto', r.em_aberto,
    'perdido_cents', r.perdido,
    'bruto_cents', r.bruto, 'comida_cents', r.comida,
    'taxa_entrega_cents', r.taxa_entrega, 'desconto_cents', r.desconto,
    'ticket_cents', CASE WHEN r.pedidos > 0 THEN round(r.bruto::numeric / r.pedidos) ELSE 0 END,
    'entregas', r.entregas, 'retiradas', r.retiradas,
    'valor_entregas_cents', r.valor_entregas, 'valor_retiradas_cents', r.valor_retiradas,

    'pagamentos', coalesce((
      SELECT jsonb_agg(jsonb_build_object('forma', forma, 'pedidos', qtd, 'valor_cents', valor) ORDER BY valor DESC)
        FROM (SELECT coalesce(payment_method,'-') AS forma, count(*) AS qtd, sum(total_cents) AS valor
                FROM public.dlv_orders
               WHERE created_at >= v_inicio AND created_at < v_fim AND status <> 'cancelado'
               GROUP BY 1) p), '[]'::jsonb),

    -- dinheiro que está na conta do Mercado Pago e precisa ser transferido
    'online', jsonb_build_object(
      'pedidos', r.online_pedidos,
      'valor_cents', v_online_cents,
      'taxa_percent', v_taxa_mp,
      'taxa_cents', v_online_taxa,
      'a_transferir_cents', v_online_cents - v_online_taxa),

    'processamento', jsonb_build_object(
      'pedidos', r.pedidos_com_taxa,
      'valor_unitario_cents', public.dlv__config('service_fee_cents', '0')::bigint,
      'total_cents', r.taxa_proc),

    'motoqueiros', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'nome', nome, 'dias', dias, 'entregas', entregas,
               'fixo_cents', fixo, 'variavel_cents', variavel,
               'total_cents', fixo + variavel, 'pago_cents', pago) ORDER BY nome)
        FROM (
          SELECT c.name AS nome,
                 count(DISTINCT (o.created_at AT TIME ZONE 'America/Sao_Paulo')::date) AS dias,
                 count(*) AS entregas,
                 v_fixo * count(DISTINCT (o.created_at AT TIME ZONE 'America/Sao_Paulo')::date) AS fixo,
                 coalesce(sum(CASE WHEN o.distance_km IS NOT NULL AND o.distance_km <= v_raio
                                   THEN v_perto ELSE o.delivery_fee_cents END), 0) AS variavel,
                 coalesce((SELECT sum(p.total_cents) FROM public.dlv_courier_payouts p
                            WHERE p.courier_id = c.id AND p.dia BETWEEN v_de AND v_ate AND p.pago_em IS NOT NULL), 0) AS pago
            FROM public.dlv_orders o
            JOIN public.dlv_couriers c ON c.id = o.courier_id
           WHERE o.created_at >= v_inicio AND o.created_at < v_fim
             AND o.mode = 'entrega' AND o.status IN ('saiu_entrega','finalizado')
           GROUP BY c.id, c.name
        ) m), '[]'::jsonb),
    'motoqueiros_total_cents', v_motoboys,

    -- o que sobra: vendido menos os entregadores e menos a taxa do Mercado Pago.
    -- Falta ainda a taxa da maquininha (crédito/débito), que não está no sistema.
    'liquido_cents', r.bruto - v_motoboys - v_online_taxa,

    'por_dia', coalesce((
      SELECT jsonb_agg(jsonb_build_object('dia', dia, 'pedidos', qtd, 'bruto_cents', bruto) ORDER BY dia)
        FROM (SELECT (created_at AT TIME ZONE 'America/Sao_Paulo')::date AS dia,
                     count(*) AS qtd, sum(total_cents) AS bruto
                FROM public.dlv_orders
               WHERE created_at >= v_inicio AND created_at < v_fim AND status <> 'cancelado'
               GROUP BY 1) x), '[]'::jsonb)
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.dlv_relatorio(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dlv_relatorio(date, date) TO authenticated;

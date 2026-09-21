-- Resumo do dia do delivery, para o relatório automático das 14h30 no WhatsApp.
-- Quem lê é o servidor do bar (outro projeto), por uma função sem login mas com
-- token próprio — faturamento não pode ficar aberto na internet.

-- Guardamos só o HASH do token: o segredo em si mora no servidor do bar, que é
-- quem chama. Nasce vazio; o valor é gravado direto no banco, fora do git.
INSERT INTO public.dlv_settings (key, value) VALUES ('relatorio_token_hash', '')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.dlv__resumo_do_dia(p_dia date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_dia    date := coalesce(p_dia, (public.dlv__agora_local())::date);
  v_inicio timestamptz := (v_dia::text || ' 00:00:00')::timestamp AT TIME ZONE 'America/Sao_Paulo';
  v_fim    timestamptz := ((v_dia + 1)::text || ' 00:00:00')::timestamp AT TIME ZONE 'America/Sao_Paulo';
  v_fixo   bigint  := public.dlv__config('courier_daily_cents', '0')::bigint;
  v_perto  bigint  := public.dlv__config('courier_short_fee_cents', '0')::bigint;
  v_raio   numeric := public.dlv__config('courier_short_km', '2')::numeric;
  r record;
BEGIN
  SELECT
    count(*) FILTER (WHERE status <> 'cancelado')                          AS validos,
    count(*) FILTER (WHERE status = 'cancelado')                           AS cancelados,
    count(*) FILTER (WHERE status NOT IN ('finalizado','cancelado'))       AS em_aberto,
    count(*) FILTER (WHERE mode = 'entrega'  AND status <> 'cancelado')    AS entregas,
    count(*) FILTER (WHERE mode = 'retirada' AND status <> 'cancelado')    AS retiradas,
    coalesce(sum(total_cents)        FILTER (WHERE status <> 'cancelado'), 0) AS bruto,
    coalesce(sum(delivery_fee_cents) FILTER (WHERE status <> 'cancelado'), 0) AS taxa_entrega,
    coalesce(sum(service_fee_cents)  FILTER (WHERE status <> 'cancelado'), 0) AS taxa_processamento,
    coalesce(sum(total_cents)        FILTER (WHERE status = 'cancelado'), 0)  AS perdido
    INTO r
    FROM public.dlv_orders
   WHERE created_at >= v_inicio AND created_at < v_fim;

  RETURN jsonb_build_object(
    'dia', v_dia,
    'pedidos', r.validos, 'cancelados', r.cancelados, 'em_aberto', r.em_aberto,
    'entregas', r.entregas, 'retiradas', r.retiradas,
    'bruto_cents', r.bruto, 'taxa_entrega_cents', r.taxa_entrega,
    'taxa_processamento_cents', r.taxa_processamento, 'perdido_cents', r.perdido,
    'ticket_cents', CASE WHEN r.validos > 0 THEN round(r.bruto::numeric / r.validos) ELSE 0 END,
    'pagamentos', coalesce((
      SELECT jsonb_agg(jsonb_build_object('forma', forma, 'pedidos', qtd, 'valor_cents', valor) ORDER BY valor DESC)
        FROM (SELECT coalesce(payment_method,'-') AS forma, count(*) AS qtd, sum(total_cents) AS valor
                FROM public.dlv_orders
               WHERE created_at >= v_inicio AND created_at < v_fim AND status <> 'cancelado'
               GROUP BY 1) p), '[]'::jsonb),
    'motoqueiros', coalesce((
      SELECT jsonb_agg(jsonb_build_object('nome', nome, 'entregas', qtd, 'total_cents', total) ORDER BY nome)
        FROM (SELECT c.name AS nome, count(*) AS qtd,
                     v_fixo + coalesce(sum(CASE WHEN o.distance_km IS NOT NULL AND o.distance_km <= v_raio
                                                THEN v_perto ELSE o.delivery_fee_cents END), 0) AS total
                FROM public.dlv_orders o
                JOIN public.dlv_couriers c ON c.id = o.courier_id
               WHERE o.created_at >= v_inicio AND o.created_at < v_fim
                 AND o.mode = 'entrega' AND o.status IN ('saiu_entrega','finalizado')
               GROUP BY c.name) m), '[]'::jsonb)
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.dlv__resumo_do_dia(date) FROM PUBLIC, anon, authenticated;

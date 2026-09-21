-- Acerto diário dos motoqueiros: quanto cada um fez no dia e o que já foi pago.
-- O valor é calculado das entregas do dia, mas fica CONGELADO quando o acerto é
-- pago — mudar a regra depois não mexe no que já foi acertado.

CREATE TABLE IF NOT EXISTS public.dlv_courier_payouts (
  courier_id     uuid NOT NULL REFERENCES public.dlv_couriers(id) ON DELETE CASCADE,
  dia            date NOT NULL,
  entregas       integer NOT NULL DEFAULT 0,
  fixo_cents     bigint  NOT NULL DEFAULT 0,
  variavel_cents bigint  NOT NULL DEFAULT 0,
  total_cents    bigint  NOT NULL DEFAULT 0,
  pago_em        timestamptz,
  pago_por       text,
  PRIMARY KEY (courier_id, dia)
);
ALTER TABLE public.dlv_courier_payouts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dlv_courier_payouts FROM PUBLIC, anon, authenticated;

-- Quanto cada motoqueiro fez num dia, já com o que foi pago.
CREATE OR REPLACE FUNCTION public.dlv_acerto_do_dia(p_dia date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_dia   date   := coalesce(p_dia, (public.dlv__agora_local())::date);
  v_fixo  bigint := public.dlv__config('courier_daily_cents', '0')::bigint;
  v_perto bigint := public.dlv__config('courier_short_fee_cents', '0')::bigint;
  v_raio  numeric := public.dlv__config('courier_short_km', '2')::numeric;
  v_inicio timestamptz := (v_dia::text || ' 00:00:00')::timestamp AT TIME ZONE 'America/Sao_Paulo';
  v_fim    timestamptz := ((v_dia + 1)::text || ' 00:00:00')::timestamp AT TIME ZONE 'America/Sao_Paulo';
BEGIN
  PERFORM public.dlv__exigir_painel();

  RETURN jsonb_build_object(
    'dia', v_dia,
    'fixo_cents', v_fixo,
    'perto_cents', v_perto,
    'raio_km', v_raio,
    'motoqueiros', coalesce((
      SELECT jsonb_agg(x ORDER BY x->>'nome')
        FROM (
          SELECT jsonb_build_object(
                   'courier_id', c.id,
                   'nome', c.name,
                   'ativo', c.is_active,
                   'entregas', count(o.id),
                   'perto', count(o.id) FILTER (WHERE o.distance_km IS NOT NULL AND o.distance_km <= v_raio),
                   'longe', count(o.id) FILTER (WHERE o.distance_km IS NULL OR o.distance_km > v_raio),
                   'fixo_cents', CASE WHEN count(o.id) > 0 THEN v_fixo ELSE 0 END,
                   'variavel_cents', coalesce(sum(
                      CASE WHEN o.distance_km IS NOT NULL AND o.distance_km <= v_raio
                           THEN v_perto ELSE o.delivery_fee_cents END), 0),
                   'total_cents', CASE WHEN count(o.id) > 0 THEN v_fixo ELSE 0 END + coalesce(sum(
                      CASE WHEN o.distance_km IS NOT NULL AND o.distance_km <= v_raio
                           THEN v_perto ELSE o.delivery_fee_cents END), 0),
                   'pago_em', p.pago_em,
                   'pago_por', p.pago_por,
                   'pago_total_cents', p.total_cents
                 ) AS x
            FROM public.dlv_couriers c
            LEFT JOIN public.dlv_orders o
              ON o.courier_id = c.id AND o.mode = 'entrega'
             AND o.status IN ('saiu_entrega', 'finalizado')
             AND o.created_at >= v_inicio AND o.created_at < v_fim
            LEFT JOIN public.dlv_courier_payouts p ON p.courier_id = c.id AND p.dia = v_dia
           WHERE c.is_active OR p.pago_em IS NOT NULL OR o.id IS NOT NULL
           GROUP BY c.id, c.name, c.is_active, p.pago_em, p.pago_por, p.total_cents
        ) s), '[]'::jsonb)
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.dlv_acerto_do_dia(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dlv_acerto_do_dia(date) TO authenticated;

-- Marca (ou desmarca) o acerto de um motoqueiro num dia, congelando o valor.
CREATE OR REPLACE FUNCTION public.dlv_marcar_acerto(p_motoqueiro uuid, p_dia date, p_pago boolean, p_operador text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_linha jsonb; v_nome text;
BEGIN
  PERFORM public.dlv__exigir_painel();
  SELECT name INTO v_nome FROM public.dlv_couriers WHERE id = p_motoqueiro;
  IF v_nome IS NULL THEN RAISE EXCEPTION 'Motoqueiro não encontrado'; END IF;

  IF NOT p_pago THEN
    DELETE FROM public.dlv_courier_payouts WHERE courier_id = p_motoqueiro AND dia = p_dia;
    RETURN jsonb_build_object('pago', false, 'motoqueiro', v_nome, 'dia', p_dia);
  END IF;

  SELECT x INTO v_linha
    FROM jsonb_array_elements(public.dlv_acerto_do_dia(p_dia) -> 'motoqueiros') x
   WHERE (x->>'courier_id')::uuid = p_motoqueiro;
  IF v_linha IS NULL THEN RAISE EXCEPTION 'Sem acerto para % nesse dia', v_nome; END IF;

  INSERT INTO public.dlv_courier_payouts (courier_id, dia, entregas, fixo_cents, variavel_cents, total_cents, pago_em, pago_por)
  VALUES (p_motoqueiro, p_dia, (v_linha->>'entregas')::int, (v_linha->>'fixo_cents')::bigint,
          (v_linha->>'variavel_cents')::bigint, (v_linha->>'total_cents')::bigint,
          now(), public.dlv__exigir_operador_nome(p_operador))
  ON CONFLICT (courier_id, dia) DO UPDATE
    SET entregas = excluded.entregas, fixo_cents = excluded.fixo_cents,
        variavel_cents = excluded.variavel_cents, total_cents = excluded.total_cents,
        pago_em = now(), pago_por = excluded.pago_por;

  RETURN jsonb_build_object('pago', true, 'motoqueiro', v_nome, 'dia', p_dia,
                            'total_cents', (v_linha->>'total_cents')::bigint);
END;
$function$;
REVOKE ALL ON FUNCTION public.dlv_marcar_acerto(uuid, date, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dlv_marcar_acerto(uuid, date, boolean, text) TO authenticated;

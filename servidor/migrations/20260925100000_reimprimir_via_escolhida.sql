-- Reimpressão por via. Antes, reimprimir mandava o pedido inteiro para todas as
-- térmicas; na prática quase sempre falta UMA via (acabou o papel na cozinha,
-- a impressora do bar estava fora). Agora dá para escolher.

-- Quais vias esse pedido tem e como cada uma terminou.
CREATE OR REPLACE FUNCTION public.dlv_vias_do_pedido(p_pedido uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_caixa text := public.dlv__config('receipt_point_code', 'caixa');
BEGIN
  PERFORM public.dlv__exigir_painel();

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'codigo', codigo, 'nome', nome, 'tipo', tipo, 'itens', itens,
             'status', status, 'quando', quando) ORDER BY ordem, nome)
      FROM (
        -- vias de produção: só os pontos que têm item neste pedido
        SELECT pp.code AS codigo, pp.name AS nome, 'producao' AS tipo, count(DISTINCT i.item_id) AS itens,
               1 AS ordem,
               (SELECT j.status FROM public.dlv_print_jobs j
                 WHERE j.order_id = p_pedido AND j.production_point_id = pp.id AND j.kind = 'producao'
                 ORDER BY j.created_at DESC LIMIT 1) AS status,
               (SELECT j.created_at FROM public.dlv_print_jobs j
                 WHERE j.order_id = p_pedido AND j.production_point_id = pp.id AND j.kind = 'producao'
                 ORDER BY j.created_at DESC LIMIT 1) AS quando
          FROM (
            SELECT oi.production_point_id AS ponto, oi.id AS item_id
              FROM public.dlv_order_items oi WHERE oi.order_id = p_pedido
            UNION
            SELECT x.production_point_id, oi.id
              FROM public.dlv_order_item_options x
              JOIN public.dlv_order_items oi ON oi.id = x.order_item_id
             WHERE oi.order_id = p_pedido
          ) i
          JOIN public.pdv_production_points pp ON pp.id = i.ponto
         GROUP BY pp.id, pp.code, pp.name

        UNION ALL

        -- via de entrega / caixa: sempre existe
        SELECT pp.code, pp.name, 'via_entrega', 0, 0,
               (SELECT j.status FROM public.dlv_print_jobs j
                 WHERE j.order_id = p_pedido AND j.production_point_id = pp.id AND j.kind = 'via_entrega'
                 ORDER BY j.created_at DESC LIMIT 1),
               (SELECT j.created_at FROM public.dlv_print_jobs j
                 WHERE j.order_id = p_pedido AND j.production_point_id = pp.id AND j.kind = 'via_entrega'
                 ORDER BY j.created_at DESC LIMIT 1)
          FROM public.pdv_production_points pp
         WHERE pp.code = v_caixa AND pp.is_active
      ) vias), '[]'::jsonb);
END;
$function$;
REVOKE ALL ON FUNCTION public.dlv_vias_do_pedido(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dlv_vias_do_pedido(uuid) TO authenticated;

-- A versão antiga (dois argumentos) sai de cena: com as duas no banco, chamar
-- com dois argumentos vira ambiguidade.
DROP FUNCTION IF EXISTS public.dlv_reimprimir_pedido(uuid, text);

-- Reimpressão: sem lista de vias, reimprime tudo (como era). Com lista, só as
-- escolhidas — e o evento registra quais foram, para a auditoria não perder isso.
CREATE OR REPLACE FUNCTION public.dlv_reimprimir_pedido(p_pedido uuid, p_operador text, p_vias text[] DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  o record; v_por text; v_qtd int := 0; v_prod int; v_via int;
  v_caixa text := public.dlv__config('receipt_point_code', 'caixa');
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);
  SELECT * INTO o FROM public.dlv_orders WHERE id = p_pedido;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;
  IF o.accepted_at IS NULL THEN RAISE EXCEPTION 'O pedido #% ainda não foi aceito', o.number; END IF;
  IF o.status = 'cancelado' THEN RAISE EXCEPTION 'O pedido #% está cancelado', o.number; END IF;

  IF p_vias IS NULL OR cardinality(p_vias) = 0 THEN
    v_qtd := public.dlv__gerar_impressao(o.id);
    PERFORM public.dlv__registrar_evento(o.id, o.status, o.status, v_por, 'reimpressão (todas as vias)');
    RETURN v_qtd;
  END IF;

  -- produção: só pontos escolhidos que realmente têm item no pedido
  INSERT INTO public.dlv_print_jobs (order_id, production_point_id, kind)
  SELECT p_pedido, pp.id, 'producao'
    FROM public.pdv_production_points pp
   WHERE pp.code = ANY(p_vias)
     AND EXISTS (
       SELECT 1 FROM public.dlv_order_items oi
        WHERE oi.order_id = p_pedido AND oi.production_point_id = pp.id
       UNION ALL
       SELECT 1 FROM public.dlv_order_item_options x
         JOIN public.dlv_order_items oi ON oi.id = x.order_item_id
        WHERE oi.order_id = p_pedido AND x.production_point_id = pp.id);
  GET DIAGNOSTICS v_prod = ROW_COUNT;

  -- via de entrega, se o caixa estiver entre os escolhidos
  INSERT INTO public.dlv_print_jobs (order_id, production_point_id, kind)
  SELECT p_pedido, pp.id, 'via_entrega'
    FROM public.pdv_production_points pp
   WHERE pp.code = v_caixa AND pp.is_active AND pp.code = ANY(p_vias);
  GET DIAGNOSTICS v_via = ROW_COUNT;

  v_qtd := v_prod + v_via;
  IF v_qtd = 0 THEN RAISE EXCEPTION 'Nenhuma via para reimprimir com essa escolha'; END IF;

  PERFORM public.dlv__registrar_evento(o.id, o.status, o.status, v_por,
    'reimpressão: ' || array_to_string(p_vias, ', '));
  RETURN v_qtd;
END;
$function$;
REVOKE ALL ON FUNCTION public.dlv_reimprimir_pedido(uuid, text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dlv_reimprimir_pedido(uuid, text, text[]) TO authenticated;

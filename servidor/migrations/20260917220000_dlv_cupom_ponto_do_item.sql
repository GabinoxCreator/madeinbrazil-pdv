-- =====================================================================
-- Cupom do delivery: a via de entrega diz o ponto de produção de cada item
--
-- Pedido do Gabriel (17/09, no bar): no cupom do caixa, bebida tem que
-- saltar aos olhos. O ponto ('drink', 'cerveja', 'cozinha') passa a vir
-- junto de cada item da via de entrega e a estação imprime a marca de
-- bebida em negrito.
--
-- Só muda o conteúdo entregue à estação de impressão; nenhum dado é alterado.
-- Base: a versão com mp_payment_type (20260915131000).
-- =====================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.dlv__conteudo_impressao(p_trabalho uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE j record; o record; pp record; v_itens jsonb;
BEGIN
  SELECT * INTO j FROM public.dlv_print_jobs WHERE id = p_trabalho;
  SELECT * INTO o FROM public.dlv_orders WHERE id = j.order_id;
  SELECT code, name, host(printer_ip) AS ip, printer_port INTO pp
    FROM public.pdv_production_points WHERE id = j.production_point_id;

  IF j.kind = 'via_entrega' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'nome', oi.item_name, 'quantidade', oi.quantity, 'total_cents', oi.total_cents, 'observacao', oi.notes,
             'ponto', (SELECT code FROM public.pdv_production_points pp2 WHERE pp2.id = oi.production_point_id),
             'opcoes', coalesce((
               SELECT jsonb_agg(jsonb_build_object('grupo', x.group_name, 'nome', x.option_name, 'quantidade', x.quantity))
                 FROM public.dlv_order_item_options x WHERE x.order_item_id = oi.id), '[]'::jsonb)
           ) ORDER BY oi.created_at, oi.id), '[]'::jsonb)
      INTO v_itens
      FROM public.dlv_order_items oi WHERE oi.order_id = o.id;
  ELSE
    SELECT coalesce(jsonb_agg(linha ORDER BY ordem, chave), '[]'::jsonb) INTO v_itens
      FROM (
        -- itens deste ponto, com os complementos que saem junto
        SELECT oi.created_at AS ordem, oi.id::text AS chave, jsonb_build_object(
                 'nome', oi.item_name, 'quantidade', oi.quantity, 'observacao', oi.notes,
                 'opcoes', coalesce((
                   SELECT jsonb_agg(jsonb_build_object('grupo', x.group_name, 'nome', x.option_name, 'quantidade', x.quantity))
                     FROM public.dlv_order_item_options x
                    WHERE x.order_item_id = oi.id AND x.production_point_id = j.production_point_id), '[]'::jsonb)
               ) AS linha
          FROM public.dlv_order_items oi
         WHERE oi.order_id = o.id AND oi.production_point_id = j.production_point_id
        UNION ALL
        -- complemento deste ponto pedido dentro de item de outro ponto (ex.: bebida no prato)
        SELECT oi.created_at, x.id::text, jsonb_build_object(
                 'nome', x.option_name, 'quantidade', oi.quantity * x.quantity,
                 'observacao', 'junto com ' || oi.item_name, 'opcoes', '[]'::jsonb)
          FROM public.dlv_order_item_options x
          JOIN public.dlv_order_items oi ON oi.id = x.order_item_id
         WHERE oi.order_id = o.id
           AND x.production_point_id = j.production_point_id
           AND oi.production_point_id <> j.production_point_id
      ) t;
  END IF;

  RETURN jsonb_build_object(
    'trabalho_id', j.id,
    'tipo', j.kind,
    'ponto', jsonb_build_object('codigo', pp.code, 'nome', pp.name, 'ip', pp.ip, 'porta', pp.printer_port),
    'pedido', jsonb_build_object(
      'numero', o.number, 'modo', o.mode, 'status', o.status, 'criado_em', o.created_at,
      'cliente', o.customer_name, 'telefone', o.customer_phone,
      'endereco', CASE WHEN o.mode = 'entrega' THEN jsonb_build_object(
          'rua', o.address_street, 'numero', o.address_number, 'bairro', o.address_neighborhood,
          'complemento', o.address_complement, 'referencia', o.address_reference,
          'distancia_km', o.distance_km,
          'mapa_url', 'https://www.google.com/maps/search/?api=1&query=' || o.lat || ',' || o.lng)
        END,
      'pagamento', o.payment_method, 'pago', o.paid_at IS NOT NULL, 'mp_payment_type', o.mp_payment_type,
      'troco_para_cents', o.change_for_cents,
      'subtotal_cents', o.subtotal_cents, 'taxa_entrega_cents', o.delivery_fee_cents,
      'desconto_cents', o.discount_cents, 'total_cents', o.total_cents,
      'observacao', o.notes, 'motivo_cancelamento', o.cancel_reason,
      'motoboy', (SELECT name FROM public.dlv_couriers WHERE id = o.courier_id)
    ),
    'itens', v_itens
  );
END;
$$;

COMMIT;

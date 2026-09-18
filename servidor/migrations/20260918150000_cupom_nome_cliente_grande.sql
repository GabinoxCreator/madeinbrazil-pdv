-- Cupom da cozinha/bar: nome do cliente grande e centralizado (antes saía miúdo no rodapé).
CREATE OR REPLACE FUNCTION public.dlv__cupom_linhas(p_trabalho uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  j record; o record; pp record;
  l jsonb := '[]'::jsonb;
  v_entrega boolean; v_min int; v_max int; v_pedidos int;
  it record; op record; v_forma text;
BEGIN
  SELECT * INTO j FROM public.dlv_print_jobs WHERE id = p_trabalho;
  SELECT * INTO o FROM public.dlv_orders WHERE id = j.order_id;
  SELECT code, name INTO pp FROM public.pdv_production_points WHERE id = j.production_point_id;
  v_entrega := o.mode = 'entrega';
  v_min := (CASE WHEN v_entrega THEN public.dlv__config('delivery_time_min', '45') ELSE public.dlv__config('pickup_time_min', '20') END)::int;
  v_max := (CASE WHEN v_entrega THEN public.dlv__config('delivery_time_max', '60') ELSE public.dlv__config('pickup_time_max', '30') END)::int;

  l := l || jsonb_build_object('t', 'MADE IN BRAZIL FOOD', 'c', true);

  IF j.kind = 'cancelamento' THEN
    l := l || jsonb_build_object('t', 'PEDIDO CANCELADO', 'e', 'g', 'c', true);
  ELSIF j.kind = 'via_entrega' THEN
    l := l || jsonb_build_object('t', CASE WHEN v_entrega THEN 'PARA ENTREGA' ELSE 'PARA RETIRADA' END, 'e', 'b', 'c', true);
  ELSE
    l := l || jsonb_build_object('t', upper(pp.name), 'e', 'g', 'c', true);
  END IF;
  l := l || jsonb_build_object('tipo', 'traco_duplo');

  l := l || jsonb_build_object('t', to_char(o.created_at AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'), 'c', true);
  IF j.kind <> 'cancelamento' AND o.status NOT IN ('finalizado') THEN
    l := l || jsonb_build_object(
      't', CASE WHEN v_entrega THEN 'Entrega prevista: ' ELSE 'Pronto entre: ' END ||
           to_char((o.created_at + (v_min || ' minutes')::interval) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') || ' - ' ||
           to_char((o.created_at + (v_max || ' minutes')::interval) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'c', true);
  END IF;
  l := l || jsonb_build_object('tipo', 'traco');
  l := l || jsonb_build_object('t', 'PEDIDO #' || o.number, 'e', 'g', 'c', true);
  l := l || jsonb_build_object('tipo', 'traco');

  l := l || jsonb_build_object('t', 'ITENS', 'e', 'b');
  IF j.kind = 'via_entrega' OR j.kind = 'cancelamento' THEN
    FOR it IN
      SELECT oi.id, oi.item_name, oi.quantity, oi.total_cents, oi.notes,
             (SELECT code FROM public.pdv_production_points p2 WHERE p2.id = oi.production_point_id) AS ponto
        FROM public.dlv_order_items oi WHERE oi.order_id = o.id ORDER BY oi.created_at, oi.id
    LOOP
      l := l || jsonb_build_object('esq', it.quantity || 'x ' || it.item_name, 'dir', public.dlv__brl(it.total_cents),
                                   'e', CASE WHEN it.ponto IN ('drink', 'cerveja') THEN 'b' ELSE NULL END);
      IF it.ponto IN ('drink', 'cerveja') THEN
        l := l || jsonb_build_object('t', '    >>> BEBIDA <<<', 'e', 'b');
      END IF;
      FOR op IN SELECT option_name, quantity FROM public.dlv_order_item_options WHERE order_item_id = it.id ORDER BY option_name LOOP
        l := l || jsonb_build_object('t', '    ' || CASE WHEN op.quantity > 1 THEN op.quantity || 'x ' ELSE '' END || op.option_name);
      END LOOP;
      IF it.notes IS NOT NULL THEN
        l := l || jsonb_build_object('t', '    obs: ' || it.notes);
      END IF;
    END LOOP;
  ELSE
    FOR it IN
      SELECT oi.id, oi.item_name, oi.quantity, oi.notes
        FROM public.dlv_order_items oi
       WHERE oi.order_id = o.id AND oi.production_point_id = j.production_point_id
       ORDER BY oi.created_at, oi.id
    LOOP
      l := l || jsonb_build_object('t', it.quantity || 'x ' || it.item_name, 'e', 'a');
      FOR op IN SELECT option_name, quantity FROM public.dlv_order_item_options
                 WHERE order_item_id = it.id AND production_point_id = j.production_point_id ORDER BY option_name LOOP
        l := l || jsonb_build_object('t', '    ' || CASE WHEN op.quantity > 1 THEN op.quantity || 'x ' ELSE '' END || op.option_name);
      END LOOP;
      IF it.notes IS NOT NULL THEN
        l := l || jsonb_build_object('t', '    obs: ' || it.notes, 'e', 'b');
      END IF;
    END LOOP;
    FOR it IN
      SELECT x.option_name AS item_name, oi.quantity * x.quantity AS quantity, oi.item_name AS junto
        FROM public.dlv_order_item_options x
        JOIN public.dlv_order_items oi ON oi.id = x.order_item_id
       WHERE oi.order_id = o.id AND x.production_point_id = j.production_point_id
         AND oi.production_point_id <> j.production_point_id
       ORDER BY oi.created_at
    LOOP
      l := l || jsonb_build_object('t', it.quantity || 'x ' || it.item_name, 'e', 'a');
      l := l || jsonb_build_object('t', '    junto com ' || it.junto);
    END LOOP;
  END IF;

  l := l || jsonb_build_object('tipo', 'espaco');
  IF j.kind = 'via_entrega' OR j.kind = 'cancelamento' THEN
    l := l || jsonb_build_object('t', 'CLIENTE', 'e', 'b');
    l := l || jsonb_build_object('t', o.customer_name);
  ELSE
    -- Nas vias de produção o nome fica grande e centralizado, para achar o pedido de longe.
    l := l || jsonb_build_object('tipo', 'traco');
    l := l || jsonb_build_object('t', 'CLIENTE', 'e', 'b', 'c', true);
    l := l || jsonb_build_object('t', upper(o.customer_name), 'e', 'g', 'c', true);
    l := l || jsonb_build_object('tipo', 'traco');
  END IF;
  IF j.kind = 'via_entrega' OR j.kind = 'cancelamento' THEN
    IF o.customer_phone IS NOT NULL THEN
      l := l || jsonb_build_object('t', 'Telefone: ' || o.customer_phone);
    END IF;
    SELECT orders_count INTO v_pedidos FROM public.dlv_customers WHERE phone = o.customer_phone;
    IF v_pedidos IS NOT NULL THEN
      l := l || jsonb_build_object('t', 'Pedidos feitos: ' || v_pedidos);
    END IF;
    IF v_entrega THEN
      l := l || jsonb_build_object('tipo', 'espaco');
      l := l || jsonb_build_object('t', 'ENTREGAR EM', 'e', 'b');
      l := l || jsonb_build_object('t', o.address_street || ', ' || coalesce(o.address_number, 'S/N'), 'e', 'a');
      l := l || jsonb_build_object('t', coalesce(o.address_neighborhood, '') ||
             coalesce(' - ' || o.address_city, '') || coalesce(' - CEP ' || o.address_postal_code, ''));
      IF o.address_complement IS NOT NULL THEN
        l := l || jsonb_build_object('t', 'Complemento: ' || o.address_complement);
      END IF;
      IF o.address_reference IS NOT NULL THEN
        l := l || jsonb_build_object('t', 'Referencia: ' || o.address_reference);
      END IF;
      IF o.distance_km IS NOT NULL THEN
        l := l || jsonb_build_object('t', 'Distancia: ' || to_char(o.distance_km, 'FM9990.0') || ' km');
      END IF;
    ELSE
      l := l || jsonb_build_object('t', 'Retirada no balcao');
    END IF;
  END IF;

  IF j.kind = 'via_entrega' OR j.kind = 'cancelamento' THEN
    v_forma := CASE o.payment_method
                 WHEN 'online' THEN 'Pix online'
                 WHEN 'pix_online' THEN 'Pix online'
                 WHEN 'pix_entrega' THEN 'Pix na entrega'
                 WHEN 'dinheiro' THEN 'Dinheiro'
                 WHEN 'credito' THEN 'Cartao de credito'
                 WHEN 'debito' THEN 'Cartao de debito'
                 ELSE coalesce(o.payment_method, '-') END;
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('t', 'PAGAMENTO', 'e', 'b');
    l := l || jsonb_build_object('t', 'Forma: ' || v_forma);
    l := l || jsonb_build_object('esq', 'Subtotal', 'dir', public.dlv__brl(o.subtotal_cents));
    IF v_entrega THEN
      l := l || jsonb_build_object('esq', 'Taxa de entrega', 'dir', public.dlv__brl(o.delivery_fee_cents));
    END IF;
    IF o.discount_cents > 0 THEN
      l := l || jsonb_build_object('esq', 'Desconto', 'dir', '- ' || public.dlv__brl(o.discount_cents));
    END IF;
    l := l || jsonb_build_object('esq', 'TOTAL', 'dir', public.dlv__brl(o.total_cents), 'e', 'b');
    l := l || jsonb_build_object('tipo', 'espaco');
    IF o.paid_at IS NOT NULL THEN
      l := l || jsonb_build_object('t', '* PEDIDO JA PAGO - NAO COBRAR *', 'e', 'a', 'c', true);
    ELSE
      l := l || jsonb_build_object('t', '* COBRAR DO CLIENTE *', 'e', 'a', 'c', true);
      IF o.payment_method = 'dinheiro' THEN
        IF o.change_for_cents IS NOT NULL THEN
          l := l || jsonb_build_object('t', 'Cliente paga com ' || public.dlv__brl(o.change_for_cents), 'c', true);
          l := l || jsonb_build_object('t', 'LEVAR TROCO DE ' || public.dlv__brl(o.change_for_cents - o.total_cents), 'e', 'a', 'c', true);
        ELSE
          l := l || jsonb_build_object('t', 'SEM TROCO - cliente disse que nao precisa', 'e', 'b', 'c', true);
        END IF;
      END IF;
    END IF;
  END IF;

  IF o.notes IS NOT NULL THEN
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('t', 'OBSERVACAO', 'e', 'b');
    l := l || jsonb_build_object('t', o.notes, 'e', CASE WHEN j.kind NOT IN ('via_entrega', 'cancelamento') THEN 'a' ELSE NULL END);
  END IF;

  IF j.kind = 'cancelamento' AND o.cancel_reason IS NOT NULL THEN
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('t', 'Motivo: ' || o.cancel_reason, 'e', 'b');
  END IF;

  l := l || jsonb_build_object('tipo', 'traco_duplo');
  RETURN l;
END;
$function$;

-- Telefone formatado e distância com vírgula no cupom.
CREATE OR REPLACE FUNCTION public.dlv__fone_bonito(p text)
 RETURNS text LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE
           WHEN p IS NULL THEN NULL
           WHEN length(regexp_replace(p, '\D', '', 'g')) = 11 THEN
             '(' || substr(regexp_replace(p, '\D', '', 'g'), 1, 2) || ') ' ||
             substr(regexp_replace(p, '\D', '', 'g'), 3, 5) || '-' ||
             substr(regexp_replace(p, '\D', '', 'g'), 8, 4)
           WHEN length(regexp_replace(p, '\D', '', 'g')) = 10 THEN
             '(' || substr(regexp_replace(p, '\D', '', 'g'), 1, 2) || ') ' ||
             substr(regexp_replace(p, '\D', '', 'g'), 3, 4) || '-' ||
             substr(regexp_replace(p, '\D', '', 'g'), 7, 4)
           ELSE p
         END;
$function$;
REVOKE ALL ON FUNCTION public.dlv__fone_bonito(text) FROM PUBLIC, anon, authenticated;

-- Via de entrega/caixa: mesma informação, arrumada em blocos separados e com
-- respiro entre eles (estava tudo colado e difícil de ler no balcão).
-- Ordem nova: pedido -> cliente -> endereço -> itens -> pagamento -> o que cobrar.
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
  it record; op record; v_forma text; v_via boolean;
BEGIN
  SELECT * INTO j FROM public.dlv_print_jobs WHERE id = p_trabalho;
  SELECT * INTO o FROM public.dlv_orders WHERE id = j.order_id;
  SELECT code, name INTO pp FROM public.pdv_production_points WHERE id = j.production_point_id;
  v_entrega := o.mode = 'entrega';
  v_via := j.kind IN ('via_entrega', 'cancelamento');
  v_min := (CASE WHEN v_entrega THEN public.dlv__config('delivery_time_min', '45') ELSE public.dlv__config('pickup_time_min', '20') END)::int;
  v_max := (CASE WHEN v_entrega THEN public.dlv__config('delivery_time_max', '60') ELSE public.dlv__config('pickup_time_max', '30') END)::int;

  ------------------------------------------------------------------ cabeçalho
  l := l || jsonb_build_object('t', 'MADE IN BRAZIL FOOD', 'c', true);
  IF j.kind = 'cancelamento' THEN
    l := l || jsonb_build_object('t', 'PEDIDO CANCELADO', 'e', 'g', 'c', true);
  ELSIF j.kind = 'via_entrega' THEN
    l := l || jsonb_build_object('t', CASE WHEN v_entrega THEN 'PARA ENTREGA' ELSE 'PARA RETIRADA' END, 'e', 'b', 'c', true);
  ELSE
    l := l || jsonb_build_object('t', upper(pp.name), 'e', 'g', 'c', true);
  END IF;
  l := l || jsonb_build_object('tipo', 'traco_duplo');

  IF v_via THEN l := l || jsonb_build_object('tipo', 'espaco'); END IF;
  l := l || jsonb_build_object('t', 'PEDIDO #' || o.number, 'e', 'g', 'c', true);
  l := l || jsonb_build_object('t', to_char(o.created_at AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'), 'c', true);
  IF j.kind <> 'cancelamento' AND o.status NOT IN ('finalizado') THEN
    l := l || jsonb_build_object(
      't', CASE WHEN v_entrega THEN 'Entrega prevista: ' ELSE 'Pronto entre: ' END ||
           to_char((o.created_at + (v_min || ' minutes')::interval) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') || ' - ' ||
           to_char((o.created_at + (v_max || ' minutes')::interval) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'c', true);
  END IF;
  l := l || jsonb_build_object('tipo', 'espaco');
  l := l || jsonb_build_object('tipo', 'traco_duplo');

  ---------------------------------------------------- cliente e endereço (via)
  IF v_via THEN
    l := l || jsonb_build_object('t', 'CLIENTE', 'e', 'b');
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('t', '  ' || upper(o.customer_name), 'e', 'a');
    IF o.customer_phone IS NOT NULL THEN
      l := l || jsonb_build_object('t', '  Telefone: ' || public.dlv__fone_bonito(o.customer_phone), 'e', 'b');
    END IF;
    SELECT orders_count INTO v_pedidos FROM public.dlv_customers WHERE phone = o.customer_phone;
    IF v_pedidos IS NOT NULL THEN
      l := l || jsonb_build_object('t', '  Pedidos feitos na casa: ' || v_pedidos);
    END IF;
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('tipo', 'traco_duplo');

    IF v_entrega THEN
      l := l || jsonb_build_object('t', 'ENTREGAR EM', 'e', 'b');
      l := l || jsonb_build_object('tipo', 'espaco');
      l := l || jsonb_build_object('t', '  ' || upper(o.address_street || ', ' || coalesce(o.address_number, 'S/N')), 'e', 'a');
      l := l || jsonb_build_object('t', '  ' || coalesce(o.address_neighborhood, '') ||
             coalesce(' - ' || o.address_city, ''));
      IF o.address_postal_code IS NOT NULL THEN
        l := l || jsonb_build_object('t', '  CEP ' || o.address_postal_code);
      END IF;
      IF o.address_complement IS NOT NULL THEN
        l := l || jsonb_build_object('t', '  Complemento: ' || o.address_complement, 'e', 'b');
      END IF;
      IF o.address_reference IS NOT NULL THEN
        l := l || jsonb_build_object('t', '  Referencia: ' || o.address_reference, 'e', 'b');
      END IF;
      IF o.distance_km IS NOT NULL THEN
        l := l || jsonb_build_object('t', '  Distancia: ' || replace(to_char(o.distance_km, 'FM9990.0'), '.', ',') || ' km');
      END IF;
    ELSE
      l := l || jsonb_build_object('t', 'RETIRADA NO BALCAO', 'e', 'b');
      l := l || jsonb_build_object('tipo', 'espaco');
      l := l || jsonb_build_object('t', '  O cliente vem buscar no bar.');
    END IF;
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('tipo', 'traco_duplo');
  END IF;

  ---------------------------------------------------------------------- itens
  l := l || jsonb_build_object('t', 'ITENS', 'e', 'b');
  l := l || jsonb_build_object('tipo', 'espaco');
  IF v_via THEN
    FOR it IN
      SELECT oi.id, oi.item_name, oi.quantity, oi.total_cents, oi.notes,
             (SELECT code FROM public.pdv_production_points p2 WHERE p2.id = oi.production_point_id) AS ponto
        FROM public.dlv_order_items oi WHERE oi.order_id = o.id ORDER BY oi.created_at, oi.id
    LOOP
      l := l || jsonb_build_object('esq', '  ' || it.quantity || 'x ' || it.item_name, 'dir', public.dlv__brl(it.total_cents),
                                   'e', CASE WHEN it.ponto IN ('drink', 'cerveja') THEN 'b' ELSE NULL END);
      IF it.ponto IN ('drink', 'cerveja') THEN
        l := l || jsonb_build_object('t', '      >>> BEBIDA <<<', 'e', 'b');
      END IF;
      FOR op IN SELECT option_name, quantity FROM public.dlv_order_item_options WHERE order_item_id = it.id ORDER BY option_name LOOP
        l := l || jsonb_build_object('t', '      ' || CASE WHEN op.quantity > 1 THEN op.quantity || 'x ' ELSE '' END || op.option_name);
      END LOOP;
      IF it.notes IS NOT NULL THEN
        l := l || jsonb_build_object('t', '      obs: ' || it.notes, 'e', 'b');
      END IF;
      l := l || jsonb_build_object('tipo', 'espaco');
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
      l := l || jsonb_build_object('tipo', 'espaco');
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
      l := l || jsonb_build_object('tipo', 'espaco');
    END LOOP;
  END IF;

  ------------------------------------------------------ pagamento (só na via)
  IF v_via THEN
    l := l || jsonb_build_object('tipo', 'traco_duplo');
    v_forma := CASE o.payment_method
                 WHEN 'online' THEN 'Pix online'
                 WHEN 'pix_online' THEN 'Pix online'
                 WHEN 'pix_entrega' THEN 'Pix na entrega'
                 WHEN 'dinheiro' THEN 'Dinheiro'
                 WHEN 'credito' THEN 'Cartao de credito'
                 WHEN 'debito' THEN 'Cartao de debito'
                 ELSE coalesce(o.payment_method, '-') END;
    l := l || jsonb_build_object('t', 'PAGAMENTO', 'e', 'b');
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('esq', '  Forma', 'dir', v_forma);
    l := l || jsonb_build_object('esq', '  Subtotal', 'dir', public.dlv__brl(o.subtotal_cents));
    IF v_entrega THEN
      l := l || jsonb_build_object('esq', '  Taxa de entrega', 'dir', public.dlv__brl(o.delivery_fee_cents));
    END IF;
    IF o.discount_cents > 0 THEN
      l := l || jsonb_build_object('esq', '  Desconto', 'dir', '- ' || public.dlv__brl(o.discount_cents));
    END IF;
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('esq', '  TOTAL', 'dir', public.dlv__brl(o.total_cents), 'e', 'a');
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('tipo', 'traco_duplo');

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
  ELSE
    -- Vias de produção: nome do cliente grande no pé, para achar o pedido de longe.
    l := l || jsonb_build_object('tipo', 'traco');
    l := l || jsonb_build_object('t', 'CLIENTE', 'e', 'b', 'c', true);
    l := l || jsonb_build_object('t', upper(o.customer_name), 'e', 'g', 'c', true);
    l := l || jsonb_build_object('tipo', 'traco');
    -- O cupom da produção vai grampeado na marmita: leva o que o entregador precisa.
    IF v_entrega THEN
      l := l || jsonb_build_object('t', 'ENTREGAR EM', 'e', 'b');
      l := l || jsonb_build_object('t', '  ' || upper(o.address_street || ', ' || coalesce(o.address_number, 'S/N')), 'e', 'b');
      l := l || jsonb_build_object('t', '  ' || coalesce(o.address_neighborhood, '') || coalesce(' - ' || o.address_city, ''));
      IF o.address_complement IS NOT NULL THEN
        l := l || jsonb_build_object('t', '  Complemento: ' || o.address_complement);
      END IF;
      IF o.address_reference IS NOT NULL THEN
        l := l || jsonb_build_object('t', '  Referencia: ' || o.address_reference);
      END IF;
    ELSE
      l := l || jsonb_build_object('t', 'RETIRADA NO BALCAO', 'e', 'b');
    END IF;
    IF o.customer_phone IS NOT NULL THEN
      l := l || jsonb_build_object('t', '  Telefone: ' || public.dlv__fone_bonito(o.customer_phone));
    END IF;
    IF o.paid_at IS NOT NULL THEN
      l := l || jsonb_build_object('t', '  PAGO - nao cobrar', 'e', 'b');
    ELSE
      l := l || jsonb_build_object('t', '  COBRAR ' || public.dlv__brl(o.total_cents) || ' - ' ||
             CASE o.payment_method
               WHEN 'dinheiro' THEN 'Dinheiro'
               WHEN 'credito' THEN 'Cartao de credito'
               WHEN 'debito' THEN 'Cartao de debito'
               WHEN 'pix_entrega' THEN 'Pix na entrega'
               ELSE coalesce(o.payment_method, '-') END ||
             CASE WHEN o.payment_method = 'dinheiro' AND o.change_for_cents IS NOT NULL
                  THEN ' (troco p/ ' || public.dlv__brl(o.change_for_cents) || ')'
                  WHEN o.payment_method = 'dinheiro' THEN ' (sem troco)'
                  ELSE '' END, 'e', 'b');
    END IF;
    l := l || jsonb_build_object('tipo', 'traco');
  END IF;

  IF o.notes IS NOT NULL THEN
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('t', 'OBSERVACAO DO PEDIDO', 'e', 'b');
    l := l || jsonb_build_object('t', '  ' || o.notes, 'e', CASE WHEN NOT v_via THEN 'a' ELSE 'b' END);
  END IF;

  IF j.kind = 'cancelamento' AND o.cancel_reason IS NOT NULL THEN
    l := l || jsonb_build_object('tipo', 'espaco');
    l := l || jsonb_build_object('t', 'Motivo: ' || o.cancel_reason, 'e', 'b');
  END IF;

  l := l || jsonb_build_object('tipo', 'traco_duplo');
  RETURN l;
END;
$function$;

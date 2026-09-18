-- =====================================================================
-- Cupom montado no SERVIDOR (delivery e comandas)
--
-- Por que: a estação de impressão roda no computador do bar (Windows) e
-- trocar o layout significava mexer naquela máquina. Agora o servidor
-- devolve as LINHAS prontas, com o estilo de cada uma, e a estação só
-- imprime. Mudança de layout passa a ser só SQL.
--
-- Formato de cada linha (jsonb):
--   { "t": "texto" }                     linha simples
--   { "t": "...", "e": "b" }             negrito
--   { "t": "...", "e": "a" }             altura dobrada
--   { "t": "...", "e": "g" }             largura e altura dobradas
--   { "t": "...", "c": true }            centralizado
--   { "esq": "...", "dir": "..." }       duas colunas (48 caracteres)
--   { "tipo": "traco" | "traco_duplo" | "espaco" }
--
-- Modelo pedido pelo Gabriel (18/09), inspirado no cupom do Anota:
-- data e hora, previsão, número do pedido grande, itens com preço, bloco
-- do cliente com endereço completo e bloco de pagamento dizendo se cobra.
--
-- Nada de dado é alterado; o app Android continua lendo os mesmos campos.
-- =====================================================================

BEGIN;

CREATE FUNCTION public.dlv__cupom_linhas(p_trabalho uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
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

  -- cabeçalho
  l := l || jsonb_build_object('t', 'MADE IN BRAZIL FOOD', 'c', true);

  IF j.kind = 'cancelamento' THEN
    l := l || jsonb_build_object('t', 'PEDIDO CANCELADO', 'e', 'g', 'c', true);
  ELSIF j.kind = 'via_entrega' THEN
    l := l || jsonb_build_object('t', CASE WHEN v_entrega THEN 'PARA ENTREGA' ELSE 'PARA RETIRADA' END, 'e', 'b', 'c', true);
  ELSE
    l := l || jsonb_build_object('t', upper(pp.name), 'e', 'g', 'c', true);
  END IF;
  l := l || jsonb_build_object('tipo', 'traco_duplo');

  -- data, hora e previsão
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

  -- itens
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
    -- cupom de produção: só o que sai neste ponto, em letra grande
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
    -- complemento deste ponto pedido dentro de item de outro ponto
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

  -- cliente
  l := l || jsonb_build_object('tipo', 'espaco');
  l := l || jsonb_build_object('t', 'CLIENTE', 'e', 'b');
  l := l || jsonb_build_object('t', o.customer_name);
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

  -- pagamento (só nas vias do caixa)
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
      IF o.change_for_cents IS NOT NULL THEN
        l := l || jsonb_build_object('t', 'Levar troco para ' || public.dlv__brl(o.change_for_cents), 'e', 'b', 'c', true);
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
$$;

REVOKE ALL ON FUNCTION public.dlv__cupom_linhas(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- As linhas prontas entram no conteúdo que a estação já recebe.
-- (o app Android ignora a chave nova e segue montando o cupom dele)
-- ---------------------------------------------------------------------
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
    'itens', v_itens,
    'linhas', public.dlv__cupom_linhas(p_trabalho)
  );
END;
$$;

-- ---------------------------------------------------------------------
-- Comandas lançadas pelo navegador: mesmo modelo, cupom de produção
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv__cupom_linhas(p_trabalho uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE j record; o record; c record; pp record; l jsonb := '[]'::jsonb; it record;
BEGIN
  SELECT * INTO j FROM public.pdv_print_jobs WHERE id = p_trabalho;
  SELECT * INTO o FROM public.pdv_card_orders WHERE id = j.order_id;
  SELECT * INTO c FROM public.pdv_cards WHERE id = j.card_id;
  SELECT code, name INTO pp FROM public.pdv_production_points WHERE id = j.production_point_id;

  l := l || jsonb_build_object('t', upper(pp.name), 'e', 'g', 'c', true);
  l := l || jsonb_build_object('tipo', 'traco_duplo');
  l := l || jsonb_build_object('t', to_char(o.created_at AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'), 'c', true);
  l := l || jsonb_build_object('tipo', 'traco');
  l := l || jsonb_build_object('t', 'COMANDA ' || c.card_number, 'e', 'g', 'c', true);
  IF coalesce(o.table_number, c.table_number) IS NOT NULL THEN
    l := l || jsonb_build_object('t', 'Mesa ' || coalesce(o.table_number, c.table_number), 'e', 'a', 'c', true);
  END IF;
  l := l || jsonb_build_object('tipo', 'traco');

  FOR it IN
    SELECT i.item_name, i.quantity, i.notes FROM public.pdv_card_items i
     WHERE i.order_id = o.id AND i.production_point_id = j.production_point_id AND i.status = 'ativo'
     ORDER BY i.created_at, i.id
  LOOP
    l := l || jsonb_build_object('t', it.quantity || 'x ' || it.item_name, 'e', 'a');
    IF it.notes IS NOT NULL THEN
      l := l || jsonb_build_object('t', '    obs: ' || it.notes, 'e', 'b');
    END IF;
  END LOOP;

  l := l || jsonb_build_object('tipo', 'espaco');
  IF c.customer_name IS NOT NULL THEN
    l := l || jsonb_build_object('t', 'Cliente: ' || c.customer_name);
  END IF;
  l := l || jsonb_build_object('t', 'Lancado por: ' || coalesce(o.created_by_name, '-'));
  l := l || jsonb_build_object('tipo', 'traco_duplo');
  RETURN l;
END;
$$;

CREATE OR REPLACE FUNCTION public.pdv__conteudo_impressao(p_trabalho uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE j record; o record; c record; pp record; v_itens jsonb;
BEGIN
  SELECT * INTO j FROM public.pdv_print_jobs WHERE id = p_trabalho;
  SELECT * INTO o FROM public.pdv_card_orders WHERE id = j.order_id;
  SELECT * INTO c FROM public.pdv_cards WHERE id = j.card_id;
  SELECT code, name, host(printer_ip) AS ip, printer_port INTO pp
    FROM public.pdv_production_points WHERE id = j.production_point_id;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'nome', i.item_name, 'quantidade', i.quantity, 'observacao', i.notes
         ) ORDER BY i.created_at, i.id), '[]'::jsonb)
    INTO v_itens
    FROM public.pdv_card_items i
   WHERE i.order_id = o.id
     AND i.production_point_id = j.production_point_id
     AND i.status = 'ativo';

  RETURN jsonb_build_object(
    'trabalho_id', j.id,
    'tipo', j.kind,
    'ponto', jsonb_build_object('codigo', pp.code, 'nome', pp.name, 'ip', pp.ip, 'porta', pp.printer_port),
    'comanda', jsonb_build_object(
      'numero', c.card_number, 'mesa', coalesce(o.table_number, c.table_number),
      'cliente', c.customer_name, 'pessoas', c.people_count, 'controle', c.is_control_card
    ),
    'pedido', jsonb_build_object(
      'criado_em', o.created_at, 'operador', o.created_by_name, 'origem', 'navegador'
    ),
    'itens', v_itens,
    'linhas', public.pdv__cupom_linhas(p_trabalho)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pdv__cupom_linhas(uuid) FROM PUBLIC, anon, authenticated;

COMMIT;

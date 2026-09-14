-- =====================================================================
-- Made in Brazil Delivery — Regras (funções)
--
-- Quem chama o quê:
--   * CLIENTE (anônimo, cardápio online): dlv_cardapio_publico,
--     dlv_consultar_entrega, dlv_criar_pedido, dlv_acompanhar_pedido.
--   * PAINEL (usuário ativo em pdv_panel_users): criar pedido pelo telefone,
--     avançar etapa, cancelar, escolher motoboy, reimprimir, ver a estação.
--   * ESTAÇÃO DE IMPRESSÃO (conta de terminal do PDV): reservar e concluir
--     trabalhos de impressão.
--   * MERCADO PAGO (service role, pela Edge Function): registrar e confirmar Pix.
--
-- Regras de negócio que vivem aqui (e em nenhum outro lugar):
--   * preço, complementos, taxa e total SEMPRE calculados no servidor;
--   * complemento obrigatório / mínimo / máximo por item;
--   * item pausado, esgotado ou fora do dia não entra;
--   * loja fechada não recebe pedido pelo cardápio;
--   * pedido mínimo (sem taxa), área de entrega por distância, troco;
--   * Pix online só vira pedido depois de pago; expira sozinho;
--   * etapas só andam para frente, com auditoria;
--   * aceitar gera a impressão por ponto de produção + via completa;
--   * cancelar depois de aceito imprime aviso de cancelamento;
--   * cada cupom é reservado por UMA estação (dois aparelhos não imprimem o mesmo).
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Apoio interno (ninguém de fora executa)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv__config(p_chave text, p_padrao text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((SELECT value FROM public.dlv_settings WHERE key = p_chave), p_padrao);
$$;

CREATE FUNCTION public.dlv__agora_local()
RETURNS timestamp LANGUAGE sql STABLE AS $$
  SELECT now() AT TIME ZONE 'America/Sao_Paulo';
$$;

CREATE FUNCTION public.dlv__brl(p_centavos bigint)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT 'R$ ' || replace(to_char(p_centavos / 100.0, 'FM9999999990.00'), '.', ',');
$$;

-- só dígitos, com DDD; tira o 55 do Brasil; NULL se não parecer telefone
CREATE FUNCTION public.dlv__telefone(p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
BEGIN
  IF length(d) > 11 AND left(d, 2) = '55' THEN d := substr(d, 3); END IF;
  IF d ~ '^[0-9]{10,11}$' THEN RETURN d; END IF;
  RETURN NULL;
END;
$$;

CREATE FUNCTION public.dlv__loja_aberta()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_modo  text := public.dlv__config('store_mode', 'auto');
  v_local timestamp := public.dlv__agora_local();
BEGIN
  IF v_modo = 'aberta' THEN RETURN true; END IF;
  IF v_modo = 'fechada' THEN RETURN false; END IF;
  RETURN EXISTS (
    SELECT 1 FROM public.dlv_opening_hours
     WHERE weekday = extract(dow FROM v_local)::int
       AND v_local::time >= opens_at AND v_local::time < closes_at
  );
END;
$$;

CREATE FUNCTION public.dlv__disponivel_hoje(p_dias smallint[])
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_dias IS NULL OR extract(dow FROM public.dlv__agora_local())::smallint = ANY (p_dias);
$$;

-- distância em linha reta do bar até o ponto (km), mesma conta dos círculos do Anota
CREATE FUNCTION public.dlv__distancia_km(p_lat double precision, p_lng double precision)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  la1 double precision := radians(public.dlv__config('bar_lat', NULL)::double precision);
  lo1 double precision := radians(public.dlv__config('bar_lng', NULL)::double precision);
  la2 double precision := radians(p_lat);
  lo2 double precision := radians(p_lng);
  a   double precision;
BEGIN
  IF la1 IS NULL OR lo1 IS NULL THEN RAISE EXCEPTION 'Localização do bar não configurada'; END IF;
  a := sin((la2 - la1) / 2) ^ 2 + cos(la1) * cos(la2) * sin((lo2 - lo1) / 2) ^ 2;
  RETURN round((2 * 6371 * asin(least(1, sqrt(a))))::numeric, 2);
END;
$$;

-- menor faixa ativa que cobre a distância; NULL = fora da área
CREATE FUNCTION public.dlv__taxa_entrega(p_km numeric)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT fee_cents FROM public.dlv_delivery_bands
   WHERE is_active AND max_km >= p_km
   ORDER BY max_km LIMIT 1;
$$;

CREATE FUNCTION public.dlv__exigir_painel()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.pdv_is_panel_user() THEN
    RAISE EXCEPTION 'Sem permissão para operar o delivery' USING ERRCODE = '42501';
  END IF;
END;
$$;

-- devolve o terminal da conta logada (estação de impressão)
CREATE FUNCTION public.dlv__exigir_estacao()
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_terminal uuid;
BEGIN
  SELECT a.terminal_id INTO v_terminal
    FROM public.pdv_terminal_accounts a
    JOIN public.pdv_terminals t ON t.id = a.terminal_id
   WHERE a.user_id = auth.uid() AND a.is_active AND t.is_active;
  IF v_terminal IS NULL THEN
    RAISE EXCEPTION 'Esta conta não é uma estação de impressão' USING ERRCODE = '42501';
  END IF;
  RETURN v_terminal;
END;
$$;

CREATE FUNCTION public.dlv__exigir_operador_nome(p_operador text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;
  RETURN left(btrim(p_operador), 60);
END;
$$;

CREATE FUNCTION public.dlv__registrar_evento(p_pedido uuid, p_de text, p_para text, p_por text, p_nota text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.dlv_order_events (order_id, from_status, to_status, by_name, note)
  VALUES (p_pedido, p_de, p_para, p_por, p_nota);
$$;

-- Pix online vencido vira cancelado (pix_expirado). Chamado por quem lê pedidos.
CREATE FUNCTION public.dlv__expirar_pix()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_qtd int;
BEGIN
  WITH vencidos AS (
    UPDATE public.dlv_orders
       SET status = 'cancelado', cancel_kind = 'pix_expirado', cancelled_at = now(),
           cancel_reason = 'Pix não pago a tempo', last_status_by_name = 'sistema'
     WHERE status = 'aguardando_pagamento' AND pix_expires_at < now()
    RETURNING id
  ), eventos AS (
    INSERT INTO public.dlv_order_events (order_id, from_status, to_status, by_name, note)
    SELECT id, 'aguardando_pagamento', 'cancelado', 'sistema', 'Pix não pago a tempo' FROM vencidos
    RETURNING 1
  )
  SELECT count(*) INTO v_qtd FROM eventos;
  RETURN v_qtd;
END;
$$;

-- um cupom por ponto de produção envolvido + a via completa na térmica configurada
CREATE FUNCTION public.dlv__gerar_impressao(p_pedido uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_prod int; v_via int;
BEGIN
  INSERT INTO public.dlv_print_jobs (order_id, production_point_id, kind)
  SELECT p_pedido, pontos.id, 'producao'
    FROM (
      SELECT oi.production_point_id AS id
        FROM public.dlv_order_items oi WHERE oi.order_id = p_pedido
      UNION
      SELECT x.production_point_id
        FROM public.dlv_order_item_options x
        JOIN public.dlv_order_items oi ON oi.id = x.order_item_id
       WHERE oi.order_id = p_pedido
    ) pontos;
  GET DIAGNOSTICS v_prod = ROW_COUNT;

  INSERT INTO public.dlv_print_jobs (order_id, production_point_id, kind)
  SELECT p_pedido, pp.id, 'via_entrega'
    FROM public.pdv_production_points pp
   WHERE pp.code = public.dlv__config('receipt_point_code', 'caixa') AND pp.is_active;
  GET DIAGNOSTICS v_via = ROW_COUNT;

  RETURN v_prod + v_via;
END;
$$;

-- única porta de mudança de etapa (menos cancelamento, que tem função própria)
CREATE FUNCTION public.dlv__mudar_status(p_pedido uuid, p_novo text, p_por text, p_nota text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o record; v_ok boolean;
BEGIN
  SELECT * INTO o FROM public.dlv_orders WHERE id = p_pedido FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;

  v_ok := CASE o.status
    WHEN 'aguardando_pagamento' THEN p_novo = 'em_analise'
    WHEN 'em_analise'           THEN p_novo = 'em_producao'
    WHEN 'em_producao'          THEN p_novo IN ('pronto', 'saiu_entrega', 'finalizado')
    WHEN 'pronto'               THEN p_novo IN ('saiu_entrega', 'finalizado')
    WHEN 'saiu_entrega'         THEN p_novo = 'finalizado'
    ELSE false
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'O pedido #% está "%" e não pode ir para "%"', o.number, o.status, p_novo;
  END IF;
  IF p_novo = 'saiu_entrega' AND o.mode <> 'entrega' THEN
    RAISE EXCEPTION 'O pedido #% é para retirada, não sai para entrega', o.number;
  END IF;
  IF p_novo = 'saiu_entrega' AND o.courier_id IS NULL THEN
    RAISE EXCEPTION 'Escolha o motoboy do pedido #% antes de sair para entrega', o.number;
  END IF;

  UPDATE public.dlv_orders SET
    status        = p_novo,
    accepted_at   = CASE WHEN p_novo = 'em_producao'  THEN coalesce(accepted_at, now()) ELSE accepted_at END,
    ready_at      = CASE WHEN p_novo = 'pronto'       THEN now() ELSE ready_at END,
    dispatched_at = CASE WHEN p_novo = 'saiu_entrega' THEN now() ELSE dispatched_at END,
    finished_at   = CASE WHEN p_novo = 'finalizado'   THEN now() ELSE finished_at END,
    last_status_by_name = p_por
  WHERE id = o.id;
  PERFORM public.dlv__registrar_evento(o.id, o.status, p_novo, p_por, p_nota);

  IF p_novo = 'em_producao' AND NOT EXISTS (SELECT 1 FROM public.dlv_print_jobs WHERE order_id = o.id) THEN
    PERFORM public.dlv__gerar_impressao(o.id);
  END IF;
END;
$$;

-- conteúdo de um cupom, pronto para a estação montar o ESC/POS
CREATE FUNCTION public.dlv__conteudo_impressao(p_trabalho uuid)
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
      'pagamento', o.payment_method, 'pago', o.paid_at IS NOT NULL, 'troco_para_cents', o.change_for_cents,
      'subtotal_cents', o.subtotal_cents, 'taxa_entrega_cents', o.delivery_fee_cents,
      'desconto_cents', o.discount_cents, 'total_cents', o.total_cents,
      'observacao', o.notes, 'motivo_cancelamento', o.cancel_reason,
      'motoboy', (SELECT name FROM public.dlv_couriers WHERE id = o.courier_id)
    ),
    'itens', v_itens
  );
END;
$$;

-- coração do pedido: valida tudo e calcula no servidor
CREATE FUNCTION public.dlv__criar_pedido(p jsonb, p_origem text, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_modo    text    := p ->> 'modo';
  v_nome    text    := left(btrim(coalesce(p -> 'cliente' ->> 'nome', '')), 80);
  v_tel     text    := public.dlv__telefone(p -> 'cliente' ->> 'telefone');
  v_aceita  boolean := coalesce((p -> 'cliente' ->> 'aceita_whatsapp')::boolean, false);
  v_forma   text    := p -> 'pagamento' ->> 'forma';
  v_troco   bigint  := nullif(p -> 'pagamento' ->> 'troco_para_cents', '')::bigint;
  v_obs     text    := nullif(left(btrim(coalesce(p ->> 'observacao', '')), 500), '');
  e         jsonb   := coalesce(p -> 'endereco', '{}'::jsonb);
  v_rua     text    := nullif(left(btrim(coalesce(e ->> 'rua', '')), 150), '');
  v_num     text    := nullif(left(btrim(coalesce(e ->> 'numero', '')), 20), '');
  v_bairro  text    := nullif(left(btrim(coalesce(e ->> 'bairro', '')), 80), '');
  v_compl   text    := nullif(left(btrim(coalesce(e ->> 'complemento', '')), 120), '');
  v_ref     text    := nullif(left(btrim(coalesce(e ->> 'referencia', '')), 150), '');
  v_cep     text    := nullif(left(regexp_replace(coalesce(e ->> 'cep', ''), '\D', '', 'g'), 8), '');
  v_cidade  text    := nullif(left(btrim(coalesce(e ->> 'cidade', '')), 80), '');
  v_lat     double precision;
  v_lng     double precision;
  v_km      numeric;
  v_taxa    bigint := 0;
  v_minimo  bigint := public.dlv__config('min_order_cents', '0')::bigint;
  v_pedido  uuid   := gen_random_uuid();
  v_cliente uuid;
  v_subtotal bigint := 0;
  v_status  text;
  v_expira  timestamptz;
  linha jsonb; op jsonb;
  it record; g record; opt record; r record;
  v_qtd int; v_unit bigint; v_oi uuid; v_sel int;
BEGIN
  -- cabeçalho
  IF v_modo IS NULL OR v_modo NOT IN ('entrega', 'retirada') THEN RAISE EXCEPTION 'Escolha entrega ou retirada'; END IF;
  IF length(v_nome) < 2 THEN RAISE EXCEPTION 'Informe seu nome'; END IF;
  IF v_tel IS NULL THEN RAISE EXCEPTION 'Informe um telefone com DDD'; END IF;

  IF p_origem = 'cardapio' THEN
    IF v_forma IS NULL OR v_forma NOT IN ('pix_online', 'dinheiro', 'credito', 'debito') THEN
      RAISE EXCEPTION 'Escolha a forma de pagamento';
    END IF;
    IF NOT public.dlv__loja_aberta() THEN RAISE EXCEPTION 'A loja está fechada agora'; END IF;
  ELSE
    IF v_forma IS NULL OR v_forma NOT IN ('pix_entrega', 'dinheiro', 'credito', 'debito') THEN
      RAISE EXCEPTION 'Escolha a forma de pagamento';
    END IF;
  END IF;
  IF v_forma <> 'dinheiro' THEN v_troco := NULL; END IF;

  PERFORM public.dlv__expirar_pix();

  -- contra trote: poucos pedidos em andamento por telefone (o painel não tem limite)
  IF p_origem = 'cardapio' AND (
       SELECT count(*) FROM public.dlv_orders
        WHERE customer_phone = v_tel
          AND status IN ('aguardando_pagamento', 'em_analise', 'em_producao', 'pronto', 'saiu_entrega')
     ) >= public.dlv__config('max_open_orders_per_phone', '3')::int THEN
    RAISE EXCEPTION 'Já existem pedidos em andamento para este telefone. Aguarde ou fale com a loja.';
  END IF;

  IF jsonb_typeof(p -> 'itens') IS DISTINCT FROM 'array' OR jsonb_array_length(p -> 'itens') = 0 THEN
    RAISE EXCEPTION 'Seu carrinho está vazio';
  END IF;
  IF jsonb_array_length(p -> 'itens') > 30 THEN RAISE EXCEPTION 'Pedido com itens demais'; END IF;

  -- entrega: endereço e distância
  IF v_modo = 'entrega' THEN
    IF v_rua IS NULL THEN RAISE EXCEPTION 'Informe o endereço de entrega'; END IF;
    BEGIN
      v_lat := (e ->> 'lat')::double precision;
      v_lng := (e ->> 'lng')::double precision;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Não conseguimos localizar esse endereço';
    END;
    IF v_lat IS NULL OR v_lng IS NULL OR v_lat NOT BETWEEN -90 AND 90 OR v_lng NOT BETWEEN -180 AND 180 THEN
      RAISE EXCEPTION 'Não conseguimos localizar esse endereço';
    END IF;
    v_km   := public.dlv__distancia_km(v_lat, v_lng);
    v_taxa := public.dlv__taxa_entrega(v_km);
    IF v_taxa IS NULL THEN
      RAISE EXCEPTION 'Esse endereço fica a % km e está fora da nossa área de entrega', v_km;
    END IF;
  ELSE
    v_rua := NULL; v_num := NULL; v_bairro := NULL; v_compl := NULL; v_ref := NULL; v_cep := NULL; v_cidade := NULL;
  END IF;

  v_status := CASE WHEN v_forma = 'pix_online' THEN 'aguardando_pagamento' ELSE 'em_analise' END;
  IF v_forma = 'pix_online' THEN
    v_expira := now() + make_interval(mins => public.dlv__config('pix_expiration_minutes', '15')::int);
  END IF;

  -- o pedido nasce com subtotal zero e é atualizado depois dos itens (tudo na mesma transação)
  INSERT INTO public.dlv_orders (
    id, mode, status, source, customer_name, customer_phone,
    address_street, address_number, address_neighborhood, address_complement, address_reference,
    address_postal_code, address_city, lat, lng, distance_km,
    subtotal_cents, delivery_fee_cents, payment_method, change_for_cents, pix_expires_at,
    notes, last_status_by_name
  ) VALUES (
    v_pedido, v_modo, v_status, p_origem, v_nome, v_tel,
    v_rua, v_num, v_bairro, v_compl, v_ref,
    v_cep, v_cidade, v_lat, v_lng, v_km,
    0, v_taxa, v_forma, v_troco, v_expira,
    v_obs, p_operador
  );

  -- itens
  FOR linha IN SELECT value FROM jsonb_array_elements(p -> 'itens') LOOP
    BEGIN
      SELECT i.* INTO it
        FROM public.dlv_items i
        JOIN public.dlv_categories c ON c.id = i.category_id
       WHERE i.id = (linha ->> 'item_id')::uuid AND i.is_active AND c.is_active;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'Um item do carrinho não existe mais no cardápio';
    END;
    IF NOT FOUND OR it.id IS NULL THEN RAISE EXCEPTION 'Um item do carrinho não existe mais no cardápio'; END IF;
    IF it.is_paused OR NOT public.dlv__disponivel_hoje(it.weekdays) THEN
      RAISE EXCEPTION '"%" não está disponível hoje', it.name;
    END IF;
    IF it.is_out_of_stock THEN RAISE EXCEPTION '"%" está esgotado', it.name; END IF;

    v_qtd := coalesce((linha ->> 'quantidade')::int, 0);
    IF v_qtd < 1 OR v_qtd > 50 THEN RAISE EXCEPTION 'Quantidade inválida para "%"', it.name; END IF;
    IF jsonb_typeof(coalesce(linha -> 'opcoes', '[]'::jsonb)) <> 'array' THEN
      RAISE EXCEPTION 'Complementos inválidos em "%"', it.name;
    END IF;

    -- cada opção precisa ser de um grupo deste item e estar disponível
    FOR op IN SELECT value FROM jsonb_array_elements(coalesce(linha -> 'opcoes', '[]'::jsonb)) LOOP
      BEGIN
        SELECT o.* INTO opt
          FROM public.dlv_options o
          JOIN public.dlv_option_groups g2 ON g2.id = o.group_id AND g2.is_active
          JOIN public.dlv_item_option_groups ig ON ig.group_id = o.group_id AND ig.item_id = it.id
         WHERE o.id = (op ->> 'opcao_id')::uuid AND o.is_active;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Complemento inválido em "%"', it.name;
      END;
      IF NOT FOUND OR opt.id IS NULL THEN RAISE EXCEPTION 'Complemento inválido em "%"', it.name; END IF;
      IF opt.is_paused OR opt.is_out_of_stock THEN RAISE EXCEPTION '"%" está indisponível', opt.name; END IF;
      IF coalesce((op ->> 'quantidade')::int, 1) < 1 THEN RAISE EXCEPTION 'Quantidade inválida em "%"', opt.name; END IF;
    END LOOP;

    -- mínimo e máximo de cada grupo do item
    FOR g IN
      SELECT ig.group_id, ig.min_choices, ig.max_choices, g2.name
        FROM public.dlv_item_option_groups ig
        JOIN public.dlv_option_groups g2 ON g2.id = ig.group_id
       WHERE ig.item_id = it.id AND g2.is_active
    LOOP
      SELECT coalesce(sum(coalesce((x.value ->> 'quantidade')::int, 1)), 0) INTO v_sel
        FROM jsonb_array_elements(coalesce(linha -> 'opcoes', '[]'::jsonb)) x
        JOIN public.dlv_options o2 ON o2.id = (x.value ->> 'opcao_id')::uuid
       WHERE o2.group_id = g.group_id;
      IF v_sel < g.min_choices THEN
        RAISE EXCEPTION 'Em "%", escolha pelo menos % em "%"', it.name, g.min_choices, g.name;
      END IF;
      IF v_sel > g.max_choices THEN
        RAISE EXCEPTION 'Em "%", escolha no máximo % em "%"', it.name, g.max_choices, g.name;
      END IF;
    END LOOP;

    -- preço por unidade = item + complementos (do cardápio do servidor, nunca do navegador)
    SELECT it.price_cents + coalesce(sum(o2.extra_cents * coalesce((x.value ->> 'quantidade')::int, 1)), 0)
      INTO v_unit
      FROM jsonb_array_elements(coalesce(linha -> 'opcoes', '[]'::jsonb)) x
      JOIN public.dlv_options o2 ON o2.id = (x.value ->> 'opcao_id')::uuid;

    v_oi := gen_random_uuid();
    INSERT INTO public.dlv_order_items (id, order_id, item_id, item_name, quantity, unit_price_cents, production_point_id, notes)
    VALUES (v_oi, v_pedido, it.id, it.name, v_qtd, v_unit, it.production_point_id,
            nullif(left(btrim(coalesce(linha ->> 'observacao', '')), 200), ''));

    INSERT INTO public.dlv_order_item_options (order_item_id, option_id, group_name, option_name, quantity, extra_cents, production_point_id)
    SELECT v_oi, o2.id, g2.name, o2.name, coalesce((x.value ->> 'quantidade')::int, 1), o2.extra_cents,
           coalesce(o2.production_point_id, it.production_point_id)
      FROM jsonb_array_elements(coalesce(linha -> 'opcoes', '[]'::jsonb)) x
      JOIN public.dlv_options o2 ON o2.id = (x.value ->> 'opcao_id')::uuid
      JOIN public.dlv_option_groups g2 ON g2.id = o2.group_id;

    v_subtotal := v_subtotal + v_qtd * v_unit;
  END LOOP;

  IF v_subtotal < v_minimo THEN
    RAISE EXCEPTION 'O pedido mínimo é % (sem contar a taxa de entrega)', public.dlv__brl(v_minimo);
  END IF;
  IF v_troco IS NOT NULL AND v_troco < v_subtotal + v_taxa THEN
    RAISE EXCEPTION 'O troco precisa ser para um valor maior que o total (%)', public.dlv__brl(v_subtotal + v_taxa);
  END IF;

  -- cliente pelo telefone (consentimento só liga, nunca desliga por aqui)
  INSERT INTO public.dlv_customers (phone, name, marketing_consent, consent_at, orders_count, last_order_at, source)
  VALUES (v_tel, v_nome, v_aceita, CASE WHEN v_aceita THEN now() END, 1, now(), p_origem)
  ON CONFLICT (phone) DO UPDATE SET
    name              = EXCLUDED.name,
    orders_count      = dlv_customers.orders_count + 1,
    last_order_at     = now(),
    marketing_consent = dlv_customers.marketing_consent OR EXCLUDED.marketing_consent,
    consent_at        = CASE WHEN EXCLUDED.marketing_consent AND NOT dlv_customers.marketing_consent
                             THEN now() ELSE dlv_customers.consent_at END
  RETURNING id INTO v_cliente;

  IF v_modo = 'entrega' THEN
    UPDATE public.dlv_customer_addresses
       SET last_used_at = now(), lat = v_lat, lng = v_lng, neighborhood = v_bairro,
           complement = v_compl, reference = v_ref, postal_code = v_cep, city = v_cidade
     WHERE customer_id = v_cliente AND lower(street) = lower(v_rua) AND coalesce(number, '') = coalesce(v_num, '');
    IF NOT FOUND THEN
      INSERT INTO public.dlv_customer_addresses (customer_id, street, number, neighborhood, complement, reference, postal_code, city, lat, lng)
      VALUES (v_cliente, v_rua, v_num, v_bairro, v_compl, v_ref, v_cep, v_cidade, v_lat, v_lng);
    END IF;
  END IF;

  UPDATE public.dlv_orders SET customer_id = v_cliente, subtotal_cents = v_subtotal WHERE id = v_pedido;
  PERFORM public.dlv__registrar_evento(v_pedido, NULL, v_status, p_operador,
    CASE WHEN p_origem = 'painel' THEN 'lançado pelo painel' END);

  IF v_status = 'em_analise' AND public.dlv__config('auto_accept', 'false') = 'true' THEN
    PERFORM public.dlv__mudar_status(v_pedido, 'em_producao', 'aceite automático');
    v_status := 'em_producao';
  END IF;

  SELECT number, public_code, total_cents INTO r FROM public.dlv_orders WHERE id = v_pedido;
  RETURN jsonb_build_object(
    'pedido_id', v_pedido, 'numero', r.number, 'codigo', r.public_code, 'status', v_status,
    'subtotal_cents', v_subtotal, 'taxa_entrega_cents', v_taxa, 'total_cents', r.total_cents,
    'distancia_km', v_km, 'pix_expira_em', v_expira
  );
END;
$$;


-- ---------------------------------------------------------------------
-- CLIENTE (cardápio online, sem login)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv_cardapio_publico()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'loja', jsonb_build_object(
      'aberta', public.dlv__loja_aberta(),
      'horarios', coalesce((
        SELECT jsonb_agg(jsonb_build_object('dia', weekday, 'abre', to_char(opens_at, 'HH24:MI'), 'fecha', to_char(closes_at, 'HH24:MI'))
                         ORDER BY weekday, opens_at)
          FROM public.dlv_opening_hours), '[]'::jsonb),
      'pedido_minimo_cents', public.dlv__config('min_order_cents', '0')::bigint,
      'tempo_entrega',  jsonb_build_object('min', public.dlv__config('delivery_time_min', '45')::int, 'max', public.dlv__config('delivery_time_max', '60')::int),
      'tempo_retirada', jsonb_build_object('min', public.dlv__config('pickup_time_min', '20')::int,   'max', public.dlv__config('pickup_time_max', '30')::int),
      'faixas_entrega', coalesce((
        SELECT jsonb_agg(jsonb_build_object('ate_km', max_km, 'taxa_cents', fee_cents) ORDER BY max_km)
          FROM public.dlv_delivery_bands WHERE is_active), '[]'::jsonb),
      'pix_expira_minutos', public.dlv__config('pix_expiration_minutes', '15')::int,
      'formas_pagamento', jsonb_build_array('pix_online', 'dinheiro', 'credito', 'debito')
    ),
    'categorias', coalesce((
      SELECT jsonb_agg(x.cat ORDER BY x.ordem, x.nome)
        FROM (
          SELECT c.sort_order AS ordem, c.name AS nome,
                 jsonb_build_object('id', c.id, 'nome', c.name, 'itens', itens.lista) AS cat
            FROM public.dlv_categories c
            CROSS JOIN LATERAL (
              SELECT jsonb_agg(jsonb_build_object(
                       'id', i.id, 'nome', i.name, 'descricao', i.description,
                       'preco_cents', i.price_cents, 'imagem', i.image_url, 'esgotado', i.is_out_of_stock,
                       'grupos', coalesce((
                         SELECT jsonb_agg(jsonb_build_object(
                                  'id', g.id, 'nome', g.name, 'min', ig.min_choices, 'max', ig.max_choices,
                                  'opcoes', coalesce((
                                    SELECT jsonb_agg(jsonb_build_object(
                                             'id', o.id, 'nome', o.name, 'adicional_cents', o.extra_cents, 'esgotado', o.is_out_of_stock)
                                           ORDER BY o.sort_order, o.name)
                                      FROM public.dlv_options o
                                     WHERE o.group_id = g.id AND o.is_active AND NOT o.is_paused), '[]'::jsonb)
                                ) ORDER BY ig.sort_order)
                           FROM public.dlv_item_option_groups ig
                           JOIN public.dlv_option_groups g ON g.id = ig.group_id
                          WHERE ig.item_id = i.id AND g.is_active), '[]'::jsonb)
                     ) ORDER BY i.sort_order, i.name) AS lista
                FROM public.dlv_items i
               WHERE i.category_id = c.id AND i.is_active AND NOT i.is_paused
                 AND public.dlv__disponivel_hoje(i.weekdays)
            ) itens
           WHERE c.is_active AND itens.lista IS NOT NULL
        ) x), '[]'::jsonb)
  );
$$;

CREATE FUNCTION public.dlv_consultar_entrega(p_lat double precision, p_lng double precision)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_km numeric; v_taxa bigint;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'Localização inválida';
  END IF;
  v_km   := public.dlv__distancia_km(p_lat, p_lng);
  v_taxa := public.dlv__taxa_entrega(v_km);
  RETURN jsonb_build_object('entrega', v_taxa IS NOT NULL, 'distancia_km', v_km, 'taxa_cents', v_taxa);
END;
$$;

CREATE FUNCTION public.dlv_criar_pedido(p_pedido jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN public.dlv__criar_pedido(p_pedido, 'cardapio', 'cliente');
END;
$$;

CREATE FUNCTION public.dlv_acompanhar_pedido(p_codigo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o record; v_entrega boolean;
BEGIN
  IF p_codigo IS NULL OR p_codigo !~ '^[0-9a-f]{32}$' THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;
  PERFORM public.dlv__expirar_pix();
  SELECT * INTO o FROM public.dlv_orders WHERE public_code = p_codigo;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;
  v_entrega := o.mode = 'entrega';

  RETURN jsonb_build_object(
    'numero', o.number, 'status', o.status, 'cancelamento', o.cancel_kind, 'motivo_cancelamento', o.cancel_reason,
    'modo', o.mode, 'cliente', split_part(o.customer_name, ' ', 1),
    'endereco', CASE WHEN v_entrega THEN concat_ws(', ', o.address_street, o.address_number, o.address_neighborhood) END,
    'criado_em', o.created_at, 'aceito_em', o.accepted_at, 'pronto_em', o.ready_at,
    'saiu_em', o.dispatched_at, 'finalizado_em', o.finished_at, 'cancelado_em', o.cancelled_at,
    'previsao_min', (CASE WHEN v_entrega THEN public.dlv__config('delivery_time_min', '45') ELSE public.dlv__config('pickup_time_min', '20') END)::int,
    'previsao_max', (CASE WHEN v_entrega THEN public.dlv__config('delivery_time_max', '60') ELSE public.dlv__config('pickup_time_max', '30') END)::int,
    'itens', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'nome', oi.item_name, 'quantidade', oi.quantity, 'total_cents', oi.total_cents, 'observacao', oi.notes,
               'opcoes', coalesce((
                 SELECT jsonb_agg(jsonb_build_object('grupo', x.group_name, 'nome', x.option_name, 'quantidade', x.quantity))
                   FROM public.dlv_order_item_options x WHERE x.order_item_id = oi.id), '[]'::jsonb)
             ) ORDER BY oi.created_at, oi.id)
        FROM public.dlv_order_items oi WHERE oi.order_id = o.id), '[]'::jsonb),
    'subtotal_cents', o.subtotal_cents, 'taxa_entrega_cents', o.delivery_fee_cents,
    'desconto_cents', o.discount_cents, 'total_cents', o.total_cents,
    'pagamento', o.payment_method, 'pago', o.paid_at IS NOT NULL, 'troco_para_cents', o.change_for_cents,
    'pix_copia_cola', CASE WHEN o.status = 'aguardando_pagamento' THEN o.pix_copy_paste END,
    'pix_expira_em',  CASE WHEN o.status = 'aguardando_pagamento' THEN o.pix_expires_at END,
    'motoboy', CASE WHEN o.status IN ('saiu_entrega', 'finalizado') THEN (SELECT name FROM public.dlv_couriers WHERE id = o.courier_id) END
  );
END;
$$;


-- ---------------------------------------------------------------------
-- MERCADO PAGO (só service role, chamado pela Edge Function do Pix)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv_registrar_pix(p_pedido uuid, p_mp_payment_id text, p_copia_cola text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF length(btrim(coalesce(p_mp_payment_id, ''))) = 0 THEN RAISE EXCEPTION 'Pagamento sem identificador'; END IF;
  UPDATE public.dlv_orders
     SET mp_payment_id = btrim(p_mp_payment_id), pix_copy_paste = p_copia_cola
   WHERE id = p_pedido AND status = 'aguardando_pagamento' AND payment_method = 'pix_online';
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não está aguardando pagamento Pix'; END IF;
END;
$$;

-- idempotente: o webhook pode chegar mais de uma vez
CREATE FUNCTION public.dlv_confirmar_pix(p_mp_payment_id text, p_valor_cents bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o record;
BEGIN
  SELECT * INTO o FROM public.dlv_orders WHERE mp_payment_id = p_mp_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pagamento % não pertence a nenhum pedido', p_mp_payment_id; END IF;
  IF o.paid_at IS NOT NULL THEN
    RETURN jsonb_build_object('numero', o.number, 'status', o.status, 'ja_confirmado', true);
  END IF;
  IF p_valor_cents IS DISTINCT FROM o.total_cents THEN
    RAISE EXCEPTION 'Valor pago (%) diferente do total do pedido #% (%)',
      public.dlv__brl(p_valor_cents), o.number, public.dlv__brl(o.total_cents);
  END IF;

  IF o.status = 'cancelado' AND o.cancel_kind = 'pix_expirado' THEN
    -- pagou depois do prazo: o dinheiro entrou, então o pedido volta
    UPDATE public.dlv_orders
       SET status = 'aguardando_pagamento', cancel_kind = NULL, cancelled_at = NULL, cancel_reason = NULL
     WHERE id = o.id;
    PERFORM public.dlv__registrar_evento(o.id, 'cancelado', 'aguardando_pagamento', 'Mercado Pago', 'Pix pago depois do prazo: pedido reaberto');
  ELSIF o.status = 'cancelado' THEN
    -- cancelado pela loja e pago mesmo assim: registra e avisa que precisa estornar
    UPDATE public.dlv_orders SET paid_at = now() WHERE id = o.id;
    PERFORM public.dlv__registrar_evento(o.id, 'cancelado', 'cancelado', 'Mercado Pago', 'Pix pago em pedido cancelado: ESTORNAR');
    RETURN jsonb_build_object('numero', o.number, 'status', 'cancelado', 'precisa_estorno', true);
  ELSIF o.status <> 'aguardando_pagamento' THEN
    RAISE EXCEPTION 'O pedido #% está "%" e não esperava pagamento', o.number, o.status;
  END IF;

  UPDATE public.dlv_orders SET paid_at = now() WHERE id = o.id;
  PERFORM public.dlv__mudar_status(o.id, 'em_analise', 'Mercado Pago', 'Pix confirmado');
  IF public.dlv__config('auto_accept', 'false') = 'true' THEN
    PERFORM public.dlv__mudar_status(o.id, 'em_producao', 'aceite automático');
  END IF;

  RETURN jsonb_build_object('numero', o.number, 'status', (SELECT status FROM public.dlv_orders WHERE id = o.id), 'ja_confirmado', false);
END;
$$;


-- ---------------------------------------------------------------------
-- PAINEL
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv_criar_pedido_painel(p_pedido jsonb, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.dlv__exigir_painel();
  RETURN public.dlv__criar_pedido(p_pedido, 'painel', public.dlv__exigir_operador_nome(p_operador));
END;
$$;

CREATE FUNCTION public.dlv_avancar_pedido(p_pedido uuid, p_status text, p_operador text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.dlv__exigir_painel();
  IF p_status IS NULL OR p_status NOT IN ('em_producao', 'pronto', 'saiu_entrega', 'finalizado') THEN
    RAISE EXCEPTION 'Etapa inválida: %', p_status;
  END IF;
  PERFORM public.dlv__expirar_pix();
  PERFORM public.dlv__mudar_status(p_pedido, p_status, public.dlv__exigir_operador_nome(p_operador));
END;
$$;

CREATE FUNCTION public.dlv_cancelar_pedido(p_pedido uuid, p_motivo text, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o record; v_por text; v_tipo text;
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);
  IF length(btrim(coalesce(p_motivo, ''))) = 0 THEN RAISE EXCEPTION 'Informe o motivo do cancelamento'; END IF;

  SELECT * INTO o FROM public.dlv_orders WHERE id = p_pedido FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;
  IF o.status IN ('finalizado', 'cancelado') THEN
    RAISE EXCEPTION 'O pedido #% já está "%"', o.number, o.status;
  END IF;

  v_tipo := CASE WHEN o.status IN ('aguardando_pagamento', 'em_analise') THEN 'recusado' ELSE 'cancelado' END;
  UPDATE public.dlv_orders
     SET status = 'cancelado', cancel_kind = v_tipo, cancelled_at = now(),
         cancel_reason = left(btrim(p_motivo), 300), last_status_by_name = v_por
   WHERE id = o.id;
  PERFORM public.dlv__registrar_evento(o.id, o.status, 'cancelado', v_por, left(btrim(p_motivo), 300));

  -- o que ainda não imprimiu não sai mais
  UPDATE public.dlv_print_jobs SET status = 'cancelado'
   WHERE order_id = o.id AND status = 'pendente' AND kind <> 'cancelamento';
  -- quem já recebeu cupom de produção recebe o aviso de cancelamento
  INSERT INTO public.dlv_print_jobs (order_id, production_point_id, kind)
  SELECT DISTINCT o.id, production_point_id, 'cancelamento'
    FROM public.dlv_print_jobs
   WHERE order_id = o.id AND kind = 'producao' AND status IN ('impresso', 'reservado');

  RETURN jsonb_build_object(
    'numero', o.number, 'tipo', v_tipo,
    'precisa_estorno', o.payment_method = 'pix_online' AND o.paid_at IS NOT NULL
  );
END;
$$;

CREATE FUNCTION public.dlv_definir_motoboy(p_pedido uuid, p_motoboy uuid, p_operador text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o record; v_por text; v_nome text;
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);
  SELECT * INTO o FROM public.dlv_orders WHERE id = p_pedido FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;
  IF o.mode <> 'entrega' THEN RAISE EXCEPTION 'O pedido #% é para retirada', o.number; END IF;
  IF o.status IN ('finalizado', 'cancelado') THEN RAISE EXCEPTION 'O pedido #% já está "%"', o.number, o.status; END IF;
  IF p_motoboy IS NULL THEN
    IF o.status = 'saiu_entrega' THEN RAISE EXCEPTION 'O pedido #% já saiu: não dá para tirar o motoboy', o.number; END IF;
  ELSE
    SELECT name INTO v_nome FROM public.dlv_couriers WHERE id = p_motoboy AND is_active;
    IF v_nome IS NULL THEN RAISE EXCEPTION 'Motoboy não encontrado ou inativo'; END IF;
  END IF;
  UPDATE public.dlv_orders SET courier_id = p_motoboy WHERE id = o.id;
  PERFORM public.dlv__registrar_evento(o.id, o.status, o.status, v_por, 'motoboy: ' || coalesce(v_nome, 'nenhum'));
END;
$$;

CREATE FUNCTION public.dlv_reimprimir_pedido(p_pedido uuid, p_operador text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o record; v_por text; v_qtd int;
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);
  SELECT * INTO o FROM public.dlv_orders WHERE id = p_pedido;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;
  IF o.accepted_at IS NULL THEN RAISE EXCEPTION 'O pedido #% ainda não foi aceito', o.number; END IF;
  IF o.status = 'cancelado' THEN RAISE EXCEPTION 'O pedido #% está cancelado', o.number; END IF;
  v_qtd := public.dlv__gerar_impressao(o.id);
  PERFORM public.dlv__registrar_evento(o.id, o.status, o.status, v_por, 'reimpressão');
  RETURN v_qtd;
END;
$$;

CREATE FUNCTION public.dlv_status_estacao()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ultima timestamptz;
BEGIN
  PERFORM public.dlv__exigir_painel();
  SELECT max(last_seen_at) INTO v_ultima FROM public.dlv_station_heartbeats;
  RETURN jsonb_build_object(
    'online', v_ultima IS NOT NULL
              AND v_ultima > now() - make_interval(secs => public.dlv__config('station_offline_seconds', '90')::int),
    'ultimo_sinal', v_ultima,
    'na_fila', (SELECT count(*) FROM public.dlv_print_jobs WHERE status IN ('pendente', 'reservado')),
    'falhas_24h', (SELECT count(*) FROM public.dlv_print_jobs WHERE status = 'falha' AND updated_at > now() - interval '24 hours')
  );
END;
$$;


-- ---------------------------------------------------------------------
-- ESTAÇÃO DE IMPRESSÃO
-- ---------------------------------------------------------------------
-- Reserva trabalhos para ESTA estação. SKIP LOCKED: duas estações nunca
-- pegam o mesmo cupom. Reserva sem retorno em 2 min volta para a fila.
CREATE FUNCTION public.dlv_reservar_impressoes(p_limite int DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_terminal uuid := public.dlv__exigir_estacao(); v_ids uuid[];
BEGIN
  INSERT INTO public.dlv_station_heartbeats (terminal_id, last_seen_at) VALUES (v_terminal, now())
  ON CONFLICT (terminal_id) DO UPDATE SET last_seen_at = now();

  WITH alvo AS (
    SELECT id FROM public.dlv_print_jobs
     WHERE status = 'pendente'
        OR (status = 'reservado' AND reserved_at < now() - interval '2 minutes')
     ORDER BY created_at
     LIMIT least(greatest(coalesce(p_limite, 10), 1), 50)
     FOR UPDATE SKIP LOCKED
  ), reservados AS (
    UPDATE public.dlv_print_jobs j
       SET status = 'reservado', reserved_by = v_terminal, reserved_at = now(), attempts = j.attempts + 1
      FROM alvo WHERE j.id = alvo.id
    RETURNING j.id, j.created_at
  )
  SELECT array_agg(id ORDER BY created_at) INTO v_ids FROM reservados;

  RETURN coalesce((
    SELECT jsonb_agg(public.dlv__conteudo_impressao(t.id) ORDER BY t.ord)
      FROM unnest(v_ids) WITH ORDINALITY AS t(id, ord)
  ), '[]'::jsonb);
END;
$$;

CREATE FUNCTION public.dlv_concluir_impressao(p_trabalho uuid, p_ok boolean, p_erro text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_terminal uuid := public.dlv__exigir_estacao(); j record;
BEGIN
  SELECT * INTO j FROM public.dlv_print_jobs WHERE id = p_trabalho FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Trabalho de impressão não encontrado'; END IF;

  INSERT INTO public.dlv_station_heartbeats (terminal_id, last_seen_at) VALUES (v_terminal, now())
  ON CONFLICT (terminal_id) DO UPDATE SET last_seen_at = now();

  IF j.status <> 'reservado' THEN RETURN; END IF;  -- já resolvido por outro caminho
  IF coalesce(p_ok, false) THEN
    UPDATE public.dlv_print_jobs SET status = 'impresso', printed_at = now(), last_error = NULL WHERE id = j.id;
  ELSE
    UPDATE public.dlv_print_jobs
       SET status = CASE WHEN j.attempts >= 5 THEN 'falha' ELSE 'pendente' END,
           last_error = left(coalesce(nullif(btrim(p_erro), ''), 'erro não informado'), 500)
     WHERE id = j.id;
  END IF;
END;
$$;


-- ---------------------------------------------------------------------
-- Quem pode executar o quê
-- (o Supabase dá EXECUTE para todo mundo por padrão: tirar explicitamente)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  public.dlv_set_updated_at(),
  public.dlv__config(text, text), public.dlv__agora_local(), public.dlv__brl(bigint),
  public.dlv__telefone(text), public.dlv__loja_aberta(), public.dlv__disponivel_hoje(smallint[]),
  public.dlv__distancia_km(double precision, double precision), public.dlv__taxa_entrega(numeric),
  public.dlv__exigir_painel(), public.dlv__exigir_estacao(), public.dlv__exigir_operador_nome(text),
  public.dlv__registrar_evento(uuid, text, text, text, text), public.dlv__expirar_pix(),
  public.dlv__gerar_impressao(uuid), public.dlv__mudar_status(uuid, text, text, text),
  public.dlv__conteudo_impressao(uuid), public.dlv__criar_pedido(jsonb, text, text),
  public.dlv_cardapio_publico(), public.dlv_consultar_entrega(double precision, double precision),
  public.dlv_criar_pedido(jsonb), public.dlv_acompanhar_pedido(text),
  public.dlv_registrar_pix(uuid, text, text), public.dlv_confirmar_pix(text, bigint),
  public.dlv_criar_pedido_painel(jsonb, text), public.dlv_avancar_pedido(uuid, text, text),
  public.dlv_cancelar_pedido(uuid, text, text), public.dlv_definir_motoboy(uuid, uuid, text),
  public.dlv_reimprimir_pedido(uuid, text), public.dlv_status_estacao(),
  public.dlv_reservar_impressoes(int), public.dlv_concluir_impressao(uuid, boolean, text)
FROM PUBLIC, anon, authenticated;

-- cliente do cardápio (com ou sem login)
GRANT EXECUTE ON FUNCTION
  public.dlv_cardapio_publico(), public.dlv_consultar_entrega(double precision, double precision),
  public.dlv_criar_pedido(jsonb), public.dlv_acompanhar_pedido(text)
TO anon, authenticated;

-- painel e estação (a função confere quem é)
GRANT EXECUTE ON FUNCTION
  public.dlv_criar_pedido_painel(jsonb, text), public.dlv_avancar_pedido(uuid, text, text),
  public.dlv_cancelar_pedido(uuid, text, text), public.dlv_definir_motoboy(uuid, uuid, text),
  public.dlv_reimprimir_pedido(uuid, text), public.dlv_status_estacao(),
  public.dlv_reservar_impressoes(int), public.dlv_concluir_impressao(uuid, boolean, text)
TO authenticated;

-- Mercado Pago: só a Edge Function com service role
GRANT EXECUTE ON FUNCTION
  public.dlv_registrar_pix(uuid, text, text), public.dlv_confirmar_pix(text, bigint)
TO service_role;

COMMIT;

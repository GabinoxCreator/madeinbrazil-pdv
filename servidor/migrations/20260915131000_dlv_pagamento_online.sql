-- =====================================================================
-- Made in Brazil Delivery — Pagamento online (Checkout Pro do Mercado Pago)
--
-- Decisão do dono (15/09): no cardápio, "Pagar online" leva ao checkout do
-- Mercado Pago (Pix ou cartão de crédito, escolhidos lá dentro). Nova forma
-- de pagamento 'online'. O pedido nasce "aguardando_pagamento", NÃO imprime
-- e NÃO entra no quadro de produção até a Edge Function do webhook (service
-- role) confirmar o pagamento. Se não pagar no prazo, cancela sozinho.
--
-- Fluxo:
--   1. cardápio → dlv_criar_pedido (forma 'online') → aguardando_pagamento
--   2. Edge Function → dlv_pedido_para_pagamento(codigo) → cria a preferência
--      no Mercado Pago → dlv_registrar_checkout(pedido, preference_id, url)
--   3. cliente paga → webhook → dlv_confirmar_pagamento_online (idempotente)
--   4. tela de acompanhamento mostra o link enquanto aguarda pagamento
--
-- O Pix online antigo ('pix_online', dlv_registrar_pix, dlv_confirmar_pix)
-- continua exatamente como está.
--
-- Mudanças (nada destrutivo; não apaga nem altera dados):
--   * dlv_orders: colunas mp_preference_id, mp_checkout_url, mp_payment_type;
--     CHECK da forma de pagamento aceita 'online'; a regra "só sai de
--     aguardando_pagamento pago" vale para 'pix_online' e 'online'
--   * dlv_settings: online_payment_expiration_minutes = 30
--   * redefinidas a partir da versão mais nova de cada uma:
--       dlv__criar_pedido      (dlv_tamanhos)
--       dlv_cardapio_publico   (dlv_tamanhos)
--       dlv__expirar_pix, dlv_acompanhar_pedido, dlv_cancelar_pedido,
--       dlv__conteudo_impressao (dlv_regras; cupom ganha "mp_payment_type")
--   * novas, só service_role: dlv_pedido_para_pagamento,
--     dlv_registrar_checkout, dlv_confirmar_pagamento_online
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- TABELA
-- ---------------------------------------------------------------------
ALTER TABLE public.dlv_orders
  ADD COLUMN mp_preference_id text,   -- preferência do Checkout Pro
  ADD COLUMN mp_checkout_url  text,   -- link do checkout (init_point)
  ADD COLUMN mp_payment_type  text;   -- como pagou lá dentro: 'pix', 'credit_card'...

-- as duas regras antigas eram sem nome: acha pelo conteúdo, exige exatamente 1 de cada
DO $$
DECLARE
  v_forma  text[];
  v_pago   text[];
  v_nome   text;
BEGIN
  SELECT array_agg(conname) INTO v_forma
    FROM pg_constraint
   WHERE conrelid = 'public.dlv_orders'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%payment_method%'
     AND pg_get_constraintdef(oid) LIKE '%pix_entrega%'
     AND pg_get_constraintdef(oid) NOT LIKE '%paid_at%';
  SELECT array_agg(conname) INTO v_pago
    FROM pg_constraint
   WHERE conrelid = 'public.dlv_orders'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%payment_method%'
     AND pg_get_constraintdef(oid) LIKE '%pix_online%'
     AND pg_get_constraintdef(oid) LIKE '%paid_at%';
  IF coalesce(cardinality(v_forma), 0) <> 1 THEN
    RAISE EXCEPTION 'esperava 1 regra da lista de formas de pagamento, achou %', coalesce(cardinality(v_forma), 0);
  END IF;
  IF coalesce(cardinality(v_pago), 0) <> 1 THEN
    RAISE EXCEPTION 'esperava 1 regra de "Pix online só avança pago", achou %', coalesce(cardinality(v_pago), 0);
  END IF;
  FOREACH v_nome IN ARRAY v_forma || v_pago LOOP
    EXECUTE format('ALTER TABLE public.dlv_orders DROP CONSTRAINT %I', v_nome);
  END LOOP;
END $$;

ALTER TABLE public.dlv_orders ADD CONSTRAINT dlv_orders_payment_method_check
  CHECK (payment_method IN ('pix_online', 'pix_entrega', 'dinheiro', 'credito', 'debito', 'online'));
-- pagamento pela internet só passa de "aguardando pagamento" com pagamento confirmado
ALTER TABLE public.dlv_orders ADD CONSTRAINT dlv_orders_pagamento_online_pago_check
  CHECK (payment_method NOT IN ('pix_online', 'online') OR status IN ('aguardando_pagamento', 'cancelado') OR paid_at IS NOT NULL);


-- ---------------------------------------------------------------------
-- CONFIGURAÇÃO
-- ---------------------------------------------------------------------
INSERT INTO public.dlv_settings (key, value, description) VALUES
  ('online_payment_expiration_minutes', '30', 'Tempo para pagar no checkout do Mercado Pago (Pix ou cartão) antes do pedido cancelar sozinho');


-- ---------------------------------------------------------------------
-- EXPIRAÇÃO: mesmo cancelamento (pix_expirado), texto conforme a forma
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dlv__expirar_pix()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_qtd int;
BEGIN
  WITH vencidos AS (
    UPDATE public.dlv_orders
       SET status = 'cancelado', cancel_kind = 'pix_expirado', cancelled_at = now(),
           cancel_reason = CASE WHEN payment_method = 'online' THEN 'Pagamento online não feito a tempo'
                                ELSE 'Pix não pago a tempo' END,
           last_status_by_name = 'sistema'
     WHERE status = 'aguardando_pagamento' AND pix_expires_at < now()
    RETURNING id, cancel_reason
  ), eventos AS (
    INSERT INTO public.dlv_order_events (order_id, from_status, to_status, by_name, note)
    SELECT id, 'aguardando_pagamento', 'cancelado', 'sistema', cancel_reason FROM vencidos
    RETURNING 1
  )
  SELECT count(*) INTO v_qtd FROM eventos;
  RETURN v_qtd;
END;
$$;


-- ---------------------------------------------------------------------
-- CORAÇÃO DO PEDIDO: igual ao anterior (dlv_tamanhos) + forma 'online' no
-- cardápio, aguardando pagamento com prazo próprio (Pix na entrega continua só no painel)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dlv__criar_pedido(p jsonb, p_origem text, p_operador text)
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
  -- tamanho da linha
  v_tam_txt      text;
  v_tam_id       uuid;
  v_tam_nome     text;
  v_tam_pausado  boolean;
  v_tam_esgotado boolean;
  v_base         bigint;
  v_item_nome    text;
BEGIN
  -- cabeçalho
  IF v_modo IS NULL OR v_modo NOT IN ('entrega', 'retirada') THEN RAISE EXCEPTION 'Escolha entrega ou retirada'; END IF;
  IF length(v_nome) < 2 THEN RAISE EXCEPTION 'Informe seu nome'; END IF;
  IF v_tel IS NULL THEN RAISE EXCEPTION 'Informe um telefone com DDD'; END IF;

  IF p_origem = 'cardapio' THEN
    IF v_forma IS NULL OR v_forma NOT IN ('pix_online', 'online', 'dinheiro', 'credito', 'debito') THEN
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

  -- pagamento pela internet (Pix online ou checkout do Mercado Pago): espera a confirmação
  v_status := CASE WHEN v_forma IN ('pix_online', 'online') THEN 'aguardando_pagamento' ELSE 'em_analise' END;
  IF v_forma = 'pix_online' THEN
    v_expira := now() + make_interval(mins => public.dlv__config('pix_expiration_minutes', '15')::int);
  ELSIF v_forma = 'online' THEN
    v_expira := now() + make_interval(mins => public.dlv__config('online_payment_expiration_minutes', '30')::int);
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

    -- tamanho: obrigatório em prato que tem tamanho; proibido em prato que não tem
    v_tam_txt   := nullif(btrim(coalesce(linha ->> 'tamanho_id', '')), '');
    v_tam_id    := NULL;
    v_tam_nome  := NULL;
    v_base      := it.price_cents;
    v_item_nome := it.name;
    IF EXISTS (SELECT 1 FROM public.dlv_item_sizes WHERE item_id = it.id AND is_active) THEN
      IF v_tam_txt IS NULL THEN RAISE EXCEPTION 'Escolha o tamanho de "%"', it.name; END IF;
      BEGIN
        SELECT s.id, s.name, s.price_cents, s.is_paused, s.is_out_of_stock
          INTO v_tam_id, v_tam_nome, v_base, v_tam_pausado, v_tam_esgotado
          FROM public.dlv_item_sizes s
         WHERE s.id = v_tam_txt::uuid AND s.item_id = it.id AND s.is_active;
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Tamanho inválido em "%"', it.name;
      END;
      IF v_tam_id IS NULL THEN RAISE EXCEPTION 'Tamanho inválido em "%"', it.name; END IF;
      v_item_nome := it.name || ' (' || v_tam_nome || ')';
      IF v_tam_pausado THEN RAISE EXCEPTION '"%" não está disponível hoje', v_item_nome; END IF;
      IF v_tam_esgotado THEN RAISE EXCEPTION '"%" está esgotado', v_item_nome; END IF;
    ELSIF v_tam_txt IS NOT NULL THEN
      RAISE EXCEPTION '"%" não tem opção de tamanho', it.name;
    END IF;

    v_qtd := coalesce((linha ->> 'quantidade')::int, 0);
    IF v_qtd < 1 OR v_qtd > 50 THEN RAISE EXCEPTION 'Quantidade inválida para "%"', v_item_nome; END IF;
    IF jsonb_typeof(coalesce(linha -> 'opcoes', '[]'::jsonb)) <> 'array' THEN
      RAISE EXCEPTION 'Complementos inválidos em "%"', v_item_nome;
    END IF;

    -- cada opção precisa ser de um grupo deste item (ou do tamanho escolhido) e estar disponível
    FOR op IN SELECT value FROM jsonb_array_elements(coalesce(linha -> 'opcoes', '[]'::jsonb)) LOOP
      BEGIN
        SELECT o.* INTO opt
          FROM public.dlv_options o
          JOIN public.dlv_option_groups g2 ON g2.id = o.group_id AND g2.is_active
         WHERE o.id = (op ->> 'opcao_id')::uuid AND o.is_active
           AND o.group_id IN (
             SELECT ig.group_id FROM public.dlv_item_option_groups ig WHERE v_tam_id IS NULL AND ig.item_id = it.id
             UNION ALL
             SELECT sg.group_id FROM public.dlv_item_size_option_groups sg WHERE sg.size_id = v_tam_id
           );
      EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Complemento inválido em "%"', v_item_nome;
      END;
      IF NOT FOUND OR opt.id IS NULL THEN RAISE EXCEPTION 'Complemento inválido em "%"', v_item_nome; END IF;
      IF opt.is_paused OR opt.is_out_of_stock THEN RAISE EXCEPTION '"%" está indisponível', opt.name; END IF;
      IF coalesce((op ->> 'quantidade')::int, 1) < 1 THEN RAISE EXCEPTION 'Quantidade inválida em "%"', opt.name; END IF;
    END LOOP;

    -- mínimo e máximo de cada grupo (do tamanho, se tiver; senão do item)
    FOR g IN
      SELECT regra.group_id, regra.min_choices, regra.max_choices, g2.name
        FROM (
          SELECT ig.group_id, ig.min_choices, ig.max_choices
            FROM public.dlv_item_option_groups ig WHERE v_tam_id IS NULL AND ig.item_id = it.id
          UNION ALL
          SELECT sg.group_id, sg.min_choices, sg.max_choices
            FROM public.dlv_item_size_option_groups sg WHERE sg.size_id = v_tam_id
        ) regra
        JOIN public.dlv_option_groups g2 ON g2.id = regra.group_id
       WHERE g2.is_active
    LOOP
      SELECT coalesce(sum(coalesce((x.value ->> 'quantidade')::int, 1)), 0) INTO v_sel
        FROM jsonb_array_elements(coalesce(linha -> 'opcoes', '[]'::jsonb)) x
        JOIN public.dlv_options o2 ON o2.id = (x.value ->> 'opcao_id')::uuid
       WHERE o2.group_id = g.group_id;
      IF v_sel < g.min_choices THEN
        RAISE EXCEPTION 'Em "%", escolha pelo menos % em "%"', v_item_nome, g.min_choices, g.name;
      END IF;
      IF v_sel > g.max_choices THEN
        RAISE EXCEPTION 'Em "%", escolha no máximo % em "%"', v_item_nome, g.max_choices, g.name;
      END IF;
    END LOOP;

    -- preço por unidade = item (ou tamanho) + complementos (do cardápio do servidor, nunca do navegador)
    SELECT v_base + coalesce(sum(o2.extra_cents * coalesce((x.value ->> 'quantidade')::int, 1)), 0)
      INTO v_unit
      FROM jsonb_array_elements(coalesce(linha -> 'opcoes', '[]'::jsonb)) x
      JOIN public.dlv_options o2 ON o2.id = (x.value ->> 'opcao_id')::uuid;

    v_oi := gen_random_uuid();
    INSERT INTO public.dlv_order_items (id, order_id, item_id, item_name, quantity, unit_price_cents, production_point_id, notes, size_id, size_name)
    VALUES (v_oi, v_pedido, it.id, v_item_nome, v_qtd, v_unit, it.production_point_id,
            nullif(left(btrim(coalesce(linha ->> 'observacao', '')), 200), ''),
            v_tam_id, v_tam_nome);

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

  -- só aceita (e imprime) sozinho o que não espera pagamento
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
-- CARDÁPIO: igual ao anterior (dlv_tamanhos), só muda a lista de formas
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dlv_cardapio_publico()
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
      'formas_pagamento', jsonb_build_array('online', 'dinheiro', 'credito', 'debito')
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
                       -- prato com tamanho: "a partir de" (menor preço entre os tamanhos à venda)
                       'preco_cents', CASE WHEN tem.sim THEN disp.preco ELSE i.price_cents END,
                       'imagem', i.image_url,
                       'esgotado', i.is_out_of_stock OR (tem.sim AND disp.todos_esgotados),
                       'grupos', CASE WHEN tem.sim THEN '[]'::jsonb ELSE public.dlv__grupos_publicos(i.id, NULL) END,
                       'tamanhos', coalesce(disp.lista, '[]'::jsonb)
                     ) ORDER BY i.sort_order, i.name) AS lista
                FROM public.dlv_items i
                CROSS JOIN LATERAL (
                  SELECT EXISTS (SELECT 1 FROM public.dlv_item_sizes s WHERE s.item_id = i.id AND s.is_active) AS sim
                ) tem
                CROSS JOIN LATERAL (
                  SELECT jsonb_agg(jsonb_build_object(
                           'id', s.id, 'nome', s.name, 'sigla', s.short_name, 'preco_cents', s.price_cents,
                           'descricao', coalesce(s.description, i.description), 'esgotado', s.is_out_of_stock,
                           'grupos', public.dlv__grupos_publicos(i.id, s.id)
                         ) ORDER BY s.sort_order, s.price_cents) AS lista,
                         coalesce(min(s.price_cents) FILTER (WHERE NOT s.is_out_of_stock), min(s.price_cents)) AS preco,
                         bool_and(s.is_out_of_stock) AS todos_esgotados
                    FROM public.dlv_item_sizes s
                   WHERE s.item_id = i.id AND s.is_active AND NOT s.is_paused
                ) disp
               WHERE i.category_id = c.id AND i.is_active AND NOT i.is_paused
                 AND public.dlv__disponivel_hoje(i.weekdays)
                 -- prato com tamanho só aparece se algum tamanho estiver à venda
                 AND (NOT tem.sim OR disp.lista IS NOT NULL)
            ) itens
           WHERE c.is_active AND itens.lista IS NOT NULL
        ) x), '[]'::jsonb)
  );
$$;


-- ---------------------------------------------------------------------
-- ACOMPANHAR: igual ao anterior + link e prazo do pagamento online
-- (só enquanto aguarda pagamento)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dlv_acompanhar_pedido(p_codigo text)
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
    'pagamento_link',      CASE WHEN o.status = 'aguardando_pagamento' THEN o.mp_checkout_url END,
    'pagamento_expira_em', CASE WHEN o.status = 'aguardando_pagamento' THEN o.pix_expires_at END,
    'motoboy', CASE WHEN o.status IN ('saiu_entrega', 'finalizado') THEN (SELECT name FROM public.dlv_couriers WHERE id = o.courier_id) END
  );
END;
$$;


-- ---------------------------------------------------------------------
-- CANCELAR PELO PAINEL: igual ao anterior; estorno vale para Pix online e online
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dlv_cancelar_pedido(p_pedido uuid, p_motivo text, p_operador text)
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
    'precisa_estorno', o.payment_method IN ('pix_online', 'online') AND o.paid_at IS NOT NULL
  );
END;
$$;


-- ---------------------------------------------------------------------
-- CUPOM: igual ao anterior (dlv_regras) + "mp_payment_type" no pedido
-- (a estação mostra "Pix" / "Cartão de crédito" no pagamento online)
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


-- ---------------------------------------------------------------------
-- MERCADO PAGO — CHECKOUT PRO (só service role, pelas Edge Functions)
-- ---------------------------------------------------------------------

-- dados para montar a preferência do checkout, pelo código do link de acompanhamento
CREATE FUNCTION public.dlv_pedido_para_pagamento(p_codigo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o record;
BEGIN
  IF p_codigo IS NULL OR p_codigo !~ '^[0-9a-f]{32}$' THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;
  PERFORM public.dlv__expirar_pix();
  SELECT * INTO o FROM public.dlv_orders WHERE public_code = p_codigo;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado'; END IF;

  RETURN jsonb_build_object(
    'id', o.id, 'numero', o.number, 'status', o.status, 'forma', o.payment_method,
    'total_cents', o.total_cents,
    'cliente_nome', o.customer_name, 'cliente_telefone', o.customer_phone,
    'expira_em', o.pix_expires_at,
    'preference_id', o.mp_preference_id, 'checkout_url', o.mp_checkout_url,
    'itens', coalesce((
      SELECT jsonb_agg(jsonb_build_object('nome', oi.item_name, 'quantidade', oi.quantity, 'total_cents', oi.total_cents)
                       ORDER BY oi.created_at, oi.id)
        FROM public.dlv_order_items oi WHERE oi.order_id = o.id), '[]'::jsonb)
  );
END;
$$;

-- guarda a preferência criada no Mercado Pago (pode ser chamada de novo para trocar)
CREATE FUNCTION public.dlv_registrar_checkout(p_pedido uuid, p_preference_id text, p_checkout_url text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF length(btrim(coalesce(p_preference_id, ''))) = 0 THEN RAISE EXCEPTION 'Checkout sem identificador'; END IF;
  IF p_checkout_url IS NULL OR p_checkout_url !~ '^https://\S+$' OR length(p_checkout_url) > 2000 THEN
    RAISE EXCEPTION 'Link do checkout inválido: precisa começar com https://';
  END IF;
  UPDATE public.dlv_orders
     SET mp_preference_id = btrim(p_preference_id), mp_checkout_url = p_checkout_url
   WHERE id = p_pedido AND status = 'aguardando_pagamento' AND payment_method = 'online';
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não está aguardando pagamento online'; END IF;
END;
$$;

-- idempotente: o webhook pode chegar mais de uma vez
CREATE FUNCTION public.dlv_confirmar_pagamento_online(p_pedido uuid, p_mp_payment_id text, p_valor_cents bigint, p_tipo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  o       record;
  v_id    text := btrim(coalesce(p_mp_payment_id, ''));
  v_tipo  text := nullif(left(btrim(coalesce(p_tipo, '')), 40), '');
BEGIN
  IF length(v_id) = 0 THEN RAISE EXCEPTION 'Pagamento sem identificador'; END IF;

  SELECT * INTO o FROM public.dlv_orders WHERE id = p_pedido FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pagamento % não pertence a nenhum pedido', v_id; END IF;
  IF o.payment_method <> 'online' THEN
    RAISE EXCEPTION 'O pedido #% não é de pagamento online (forma "%")', o.number, o.payment_method;
  END IF;

  IF o.paid_at IS NOT NULL THEN
    IF o.mp_payment_id = v_id THEN
      RETURN jsonb_build_object('numero', o.number, 'status', o.status, 'ja_confirmado', true);
    END IF;
    -- cliente pagou duas vezes o mesmo pedido: registra e avisa que precisa estornar o segundo
    PERFORM public.dlv__registrar_evento(o.id, o.status, o.status, 'Mercado Pago',
      'Pagamento online DUPLICADO (id ' || v_id || '): ESTORNAR');
    RETURN jsonb_build_object('numero', o.number, 'status', o.status, 'precisa_estorno', true, 'motivo', 'duplicado');
  END IF;

  IF p_valor_cents IS DISTINCT FROM o.total_cents THEN
    RAISE EXCEPTION 'Valor pago (%) diferente do total do pedido #% (%)',
      public.dlv__brl(p_valor_cents), o.number, public.dlv__brl(o.total_cents);
  END IF;
  IF EXISTS (SELECT 1 FROM public.dlv_orders WHERE mp_payment_id = v_id AND id <> o.id) THEN
    RAISE EXCEPTION 'Pagamento % já está ligado a outro pedido', v_id;
  END IF;

  IF o.status = 'cancelado' AND o.cancel_kind = 'pix_expirado' THEN
    -- pagou depois do prazo: o dinheiro entrou, então o pedido volta
    UPDATE public.dlv_orders
       SET status = 'aguardando_pagamento', cancel_kind = NULL, cancelled_at = NULL, cancel_reason = NULL
     WHERE id = o.id;
    PERFORM public.dlv__registrar_evento(o.id, 'cancelado', 'aguardando_pagamento', 'Mercado Pago',
      'Pagamento online feito depois do prazo: pedido reaberto');
  ELSIF o.status = 'cancelado' THEN
    -- cancelado pela loja e pago mesmo assim: registra e avisa que precisa estornar
    UPDATE public.dlv_orders SET paid_at = now(), mp_payment_id = v_id, mp_payment_type = v_tipo WHERE id = o.id;
    PERFORM public.dlv__registrar_evento(o.id, 'cancelado', 'cancelado', 'Mercado Pago',
      'Pagamento online em pedido cancelado: ESTORNAR');
    RETURN jsonb_build_object('numero', o.number, 'status', 'cancelado', 'precisa_estorno', true, 'motivo', 'cancelado');
  ELSIF o.status <> 'aguardando_pagamento' THEN
    RAISE EXCEPTION 'O pedido #% está "%" e não esperava pagamento', o.number, o.status;
  END IF;

  UPDATE public.dlv_orders SET paid_at = now(), mp_payment_id = v_id, mp_payment_type = v_tipo WHERE id = o.id;
  PERFORM public.dlv__mudar_status(o.id, 'em_analise', 'Mercado Pago', 'Pagamento online confirmado');
  IF public.dlv__config('auto_accept', 'false') = 'true' THEN
    PERFORM public.dlv__mudar_status(o.id, 'em_producao', 'aceite automático');
  END IF;

  RETURN jsonb_build_object('numero', o.number, 'status', (SELECT status FROM public.dlv_orders WHERE id = o.id), 'ja_confirmado', false);
END;
$$;


-- ---------------------------------------------------------------------
-- Quem pode executar (CREATE OR REPLACE mantém as permissões das que já existiam)
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  public.dlv_pedido_para_pagamento(text),
  public.dlv_registrar_checkout(uuid, text, text),
  public.dlv_confirmar_pagamento_online(uuid, text, bigint, text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.dlv_pedido_para_pagamento(text),
  public.dlv_registrar_checkout(uuid, text, text),
  public.dlv_confirmar_pagamento_online(uuid, text, bigint, text)
TO service_role;


-- ---------------------------------------------------------------------
-- Conferência: se algo não bater, nada fica gravado
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_publicas text[] := ARRAY['dlv_acompanhar_pedido', 'dlv_cardapio_publico', 'dlv_consultar_entrega', 'dlv_criar_pedido', 'dlv_status_loja'];
  v_novas    text[] := ARRAY['dlv_confirmar_pagamento_online', 'dlv_pedido_para_pagamento', 'dlv_registrar_checkout'];
  v_anon     text[];
  v_def      text;
BEGIN
  -- anônimo executa só as 5 públicas
  SELECT coalesce(array_agg(p.proname::text ORDER BY p.proname), '{}') INTO v_anon
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND left(p.proname, 4) = 'dlv_'
     AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF v_anon <> v_publicas THEN
    RAISE EXCEPTION 'anônimo executa funções diferentes das 5 públicas: %', v_anon;
  END IF;

  -- as 3 novas: só service_role
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = ANY (v_novas)) <> 3 THEN
    RAISE EXCEPTION 'esperava as 3 funções novas de pagamento online';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname = ANY (v_novas)
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
                     OR NOT has_function_privilege('service_role', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'funções novas de pagamento online com permissão errada';
  END IF;

  -- colunas, configuração e regras da tabela
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'dlv_orders'
         AND column_name IN ('mp_preference_id', 'mp_checkout_url', 'mp_payment_type')) <> 3 THEN
    RAISE EXCEPTION 'colunas novas de dlv_orders não estão todas lá';
  END IF;
  IF public.dlv__config('online_payment_expiration_minutes', NULL) IS DISTINCT FROM '30' THEN
    RAISE EXCEPTION 'configuração online_payment_expiration_minutes não ficou 30';
  END IF;
  IF (SELECT count(*) FROM pg_constraint
       WHERE conrelid = 'public.dlv_orders'::regclass AND contype = 'c'
         AND pg_get_constraintdef(oid) LIKE '%payment_method%') <> 3 THEN
    -- 3 = lista de formas + pago antes de avançar + troco só em dinheiro
    RAISE EXCEPTION 'regras de forma de pagamento em dlv_orders não batem';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.dlv_orders'::regclass
                  AND conname = 'dlv_orders_payment_method_check' AND pg_get_constraintdef(oid) LIKE '%''online''%') THEN
    RAISE EXCEPTION 'regra da lista de formas sem ''online''';
  END IF;

  -- criar pedido: cardápio aceita online (Pix na entrega não); painel aceita Pix na entrega e não aceita online
  v_def := pg_get_functiondef('public.dlv__criar_pedido(jsonb, text, text)'::regprocedure);
  IF strpos(v_def, $t$NOT IN ('pix_online', 'online', 'dinheiro', 'credito', 'debito')$t$) = 0
     OR strpos(v_def, $t$NOT IN ('pix_entrega', 'dinheiro', 'credito', 'debito')$t$) = 0 THEN
    RAISE EXCEPTION 'dlv__criar_pedido sem as listas de formas esperadas';
  END IF;
END $$;

COMMIT;

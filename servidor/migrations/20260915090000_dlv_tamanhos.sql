-- =====================================================================
-- Made in Brazil Delivery — Tamanhos dentro do prato (Pequena / Média / Grande)
--
-- Por quê: o cardápio veio do Anota com cada tamanho como um prato separado
-- ("Bife Pequena", "Bife Média", "Bife Grande"). O dono decidiu que vira UM
-- prato ("Bife") com os tamanhos escolhidos logo abaixo da foto. As regras
-- continuam iguais ao Anota: cada tamanho tem preço próprio, descrição
-- própria (quando muda, ex.: "2 filés") e complementos próprios
-- (ex.: Pequena escolhe 1 acompanhamento, Média escolhe 2).
--
-- O que esta migration faz:
--   * cria dlv_item_sizes (os tamanhos de cada prato) e
--     dlv_item_size_option_groups (complementos de cada tamanho, com mínimo
--     e máximo próprios, mesmo papel de dlv_item_option_groups);
--   * guarda o tamanho no item do pedido (dlv_order_items.size_id/size_name);
--   * junta os 10 trios de pratos (achados pelo id do Anota): o "Pequena" vira
--     o prato principal (nome sem o tamanho), os 3 itens viram 3 tamanhos e os
--     complementos de cada item são copiados para o seu tamanho;
--   * os antigos "Média" e "Grande" ficam INATIVOS (não some nada: pedidos
--     antigos continuam apontando para eles, com o nome congelado de sempre);
--   * ajusta dlv_cardapio_publico (lista "tamanhos"), dlv__criar_pedido
--     (tamanho obrigatório em prato que tem tamanho) e cria dlv_ajustar_tamanho
--     (pausar / esgotar / preço de um tamanho, com histórico).
--
-- Regra: prato COM tamanho ativo usa os complementos do tamanho escolhido.
-- Prato SEM tamanho (lanches, porções, bebidas, "Só Feijoada 500g",
-- "Lasanha 700g") continua exatamente como antes.
--
-- Não apaga nada, não muda pedido existente. Se algum trio não bater
-- (nome, categoria, já migrado), NADA fica gravado.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- TABELAS
-- ---------------------------------------------------------------------
CREATE TABLE public.dlv_item_sizes (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id          uuid NOT NULL REFERENCES public.dlv_items(id),
  name             text NOT NULL CHECK (length(btrim(name)) > 0),                  -- 'Pequena'
  short_name       text NOT NULL CHECK (length(btrim(short_name)) BETWEEN 1 AND 3), -- 'P'
  price_cents      bigint NOT NULL CHECK (price_cents >= 0),
  description      text,     -- NULL = usa a descrição do prato; preenchida = substitui
  is_paused        boolean NOT NULL DEFAULT false,   -- some do cardápio
  is_out_of_stock  boolean NOT NULL DEFAULT false,   -- aparece como esgotado
  sort_order       int  NOT NULL DEFAULT 0,
  is_active        boolean NOT NULL DEFAULT true,    -- "apagado" sem perder histórico
  -- item antigo (separado por tamanho) que deu origem a este tamanho, só para rastrear
  legacy_item_id   uuid UNIQUE REFERENCES public.dlv_items(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dlv_item_sizes_item_idx ON public.dlv_item_sizes (item_id);
-- o mesmo prato não tem dois tamanhos ativos com o mesmo nome
CREATE UNIQUE INDEX dlv_item_sizes_nome_ativo_idx ON public.dlv_item_sizes (item_id, lower(name)) WHERE is_active;

CREATE TABLE public.dlv_item_size_option_groups (
  size_id      uuid NOT NULL REFERENCES public.dlv_item_sizes(id),
  group_id     uuid NOT NULL REFERENCES public.dlv_option_groups(id),
  min_choices  int  NOT NULL DEFAULT 0 CHECK (min_choices >= 0),
  max_choices  int  NOT NULL DEFAULT 1 CHECK (max_choices >= 1),
  sort_order   int  NOT NULL DEFAULT 0,
  PRIMARY KEY (size_id, group_id),
  CHECK (max_choices >= min_choices)
);

-- tamanho congelado no item do pedido (NULL em pedido antigo e em item sem tamanho)
ALTER TABLE public.dlv_order_items
  ADD COLUMN size_id   uuid REFERENCES public.dlv_item_sizes(id) ON DELETE SET NULL,
  ADD COLUMN size_name text;

CREATE TRIGGER dlv_item_sizes_updated_at BEFORE UPDATE ON public.dlv_item_sizes
  FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();

-- histórico do cardápio passa a aceitar mudança de tamanho
DO $$
DECLARE v_nome text;
BEGIN
  FOR v_nome IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'public.dlv_menu_changes'::regclass AND contype = 'c'
       AND pg_get_constraintdef(oid) LIKE '%target%'
  LOOP
    EXECUTE format('ALTER TABLE public.dlv_menu_changes DROP CONSTRAINT %I', v_nome);
  END LOOP;
END $$;
ALTER TABLE public.dlv_menu_changes ADD CONSTRAINT dlv_menu_changes_target_check
  CHECK (target IN ('item', 'opcao', 'loja', 'tamanho'));


-- ---------------------------------------------------------------------
-- ACESSO (igual às outras tabelas de cardápio: painel lê, ninguém escreve
-- direto, anônimo nada)
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['dlv_item_sizes', 'dlv_item_size_option_groups'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.pdv_is_panel_user())',
      'painel le ' || t, t
    );
  END LOOP;
END $$;


-- ---------------------------------------------------------------------
-- JUNTAR OS PRATOS SEPARADOS POR TAMANHO
-- (Pequena, Média, Grande) pelo id do Anota — ver migration dlv_cardapio
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t record; p record; m record; g record;
  v_base text; v_sp uuid; v_sm uuid; v_sg uuid;
BEGIN
  FOR t IN
    SELECT * FROM (VALUES
      -- PF do Dia
      ('68b70ba8ef53a8516017b84e', '691c5e50d92e8132e2f3e0b3', '691c635ca59cce4b5e6afd2d'),  -- Stronogoff
      ('691b0a3ee4971a19a5b4e77e', '691b0e2623adb90b044b13b2', '691b0e827ed3a2d776c8f4a6'),  -- Filé de Frango
      ('691db889562a48b720a53760', '691db979865edc5ee2adfde3', '691db990865edc5ee2ae00e1'),  -- Feijoada Completa
      ('691ef772bdb7398032bb8dff', '691ef808aec9b436d9bc6274', '691ef81faec9b436d9bc6576'),  -- Bife
      ('692046ea562a48b720e0a6df', '69204767aec9b436d9dbde42', '692048a5865edc5ee2e99e28'),  -- Parmegiana
      -- Especiais
      ('68b70ba8ef53a8516017b859', '68b70ba8ef53a8516017b85d', '68b70ba8ef53a8516017b861'),  -- Carne: Bife
      ('68b70ba8ef53a8516017b86c', '68b70ba8ef53a8516017b871', '68b70ba8ef53a8516017b867'),  -- Frango: Filé de Frango
      ('68b70ba8ef53a8516017b87d', '68b70ba8ef53a8516017b882', '68b70ba8ef53a8516017b878'),  -- Peixe: Filé de Tilápia
      ('68b70ba8ef53a8516017b88d', '68b70ba8ef53a8516017b891', '68b70ba8ef53a8516017b889'),  -- Parmegianas: Parmegiana
      ('68b70ba8ef53a8516017b89a', '68b70ba8ef53a8516017b89f', '68b70ba8ef53a8516017b895')   -- Strogonoff: Strogonoff
    ) AS v(pequena, media, grande)
  LOOP
    SELECT * INTO p FROM public.dlv_items WHERE anota_id = t.pequena FOR UPDATE;
    SELECT * INTO m FROM public.dlv_items WHERE anota_id = t.media   FOR UPDATE;
    SELECT * INTO g FROM public.dlv_items WHERE anota_id = t.grande  FOR UPDATE;

    IF p.id IS NULL OR m.id IS NULL OR g.id IS NULL THEN
      RAISE EXCEPTION 'Trio % / % / % não encontrado no cardápio', t.pequena, t.media, t.grande;
    END IF;
    IF NOT (p.is_active AND m.is_active AND g.is_active) THEN
      RAISE EXCEPTION 'Trio "%" tem item inativo: conferir antes de juntar', p.name;
    END IF;
    IF p.name !~ '\sPequena$' THEN
      RAISE EXCEPTION 'Item "%" não termina em "Pequena"', p.name;
    END IF;
    v_base := regexp_replace(p.name, '\s+Pequena$', '');
    IF m.name <> v_base || ' Média' OR g.name <> v_base || ' Grande' THEN
      RAISE EXCEPTION 'Trio "%" não bate: "%" / "%"', p.name, m.name, g.name;
    END IF;
    IF m.category_id <> p.category_id OR g.category_id <> p.category_id THEN
      RAISE EXCEPTION 'Trio "%" está em categorias diferentes', v_base;
    END IF;
    IF EXISTS (SELECT 1 FROM public.dlv_item_sizes WHERE item_id IN (p.id, m.id, g.id)) THEN
      RAISE EXCEPTION 'Trio "%" já tem tamanhos', v_base;
    END IF;

    -- 3 tamanhos; a descrição só fica gravada no tamanho quando é diferente da do prato
    INSERT INTO public.dlv_item_sizes (item_id, name, short_name, price_cents, description, is_paused, is_out_of_stock, sort_order, legacy_item_id)
    VALUES (p.id, 'Pequena', 'P', p.price_cents, NULL, p.is_paused, p.is_out_of_stock, 0, p.id)
    RETURNING id INTO v_sp;
    INSERT INTO public.dlv_item_sizes (item_id, name, short_name, price_cents, description, is_paused, is_out_of_stock, sort_order, legacy_item_id)
    VALUES (p.id, 'Média', 'M', m.price_cents,
            CASE WHEN m.description IS DISTINCT FROM p.description THEN m.description END,
            m.is_paused, m.is_out_of_stock, 1, m.id)
    RETURNING id INTO v_sm;
    INSERT INTO public.dlv_item_sizes (item_id, name, short_name, price_cents, description, is_paused, is_out_of_stock, sort_order, legacy_item_id)
    VALUES (p.id, 'Grande', 'G', g.price_cents,
            CASE WHEN g.description IS DISTINCT FROM p.description THEN g.description END,
            g.is_paused, g.is_out_of_stock, 2, g.id)
    RETURNING id INTO v_sg;

    -- complementos de cada item antigo vão para o seu tamanho, com as mesmas regras
    INSERT INTO public.dlv_item_size_option_groups (size_id, group_id, min_choices, max_choices, sort_order)
    SELECT s.id, ig.group_id, ig.min_choices, ig.max_choices, ig.sort_order
      FROM public.dlv_item_option_groups ig
      JOIN (VALUES (v_sp, p.id), (v_sm, m.id), (v_sg, g.id)) AS s(id, item) ON s.item = ig.item_id;

    -- prato principal: nome sem o tamanho; mantém categoria, foto, dias e ordem
    UPDATE public.dlv_items SET
      name            = v_base,
      price_cents     = least(p.price_cents, m.price_cents, g.price_cents),
      is_paused       = p.is_paused AND m.is_paused AND g.is_paused,
      is_out_of_stock = p.is_out_of_stock AND m.is_out_of_stock AND g.is_out_of_stock
    WHERE id = p.id;

    -- Média e Grande saem do cardápio, sem apagar (pedidos antigos apontam para eles)
    UPDATE public.dlv_items SET is_active = false WHERE id IN (m.id, g.id);
  END LOOP;
END $$;

-- Conferência: se não bater, nada fica gravado
DO $$
BEGIN
  IF (SELECT count(*) FROM public.dlv_item_sizes) <> 30 THEN RAISE EXCEPTION 'tamanhos: esperado 30'; END IF;
  IF (SELECT count(DISTINCT item_id) FROM public.dlv_item_sizes) <> 10 THEN RAISE EXCEPTION 'pratos com tamanho: esperado 10'; END IF;
  IF (SELECT count(*) FROM public.dlv_item_size_option_groups) <>
     (SELECT count(*) FROM public.dlv_item_option_groups ig JOIN public.dlv_item_sizes s ON s.legacy_item_id = ig.item_id) THEN
    RAISE EXCEPTION 'complementos dos tamanhos não batem com os dos itens antigos';
  END IF;
  IF EXISTS (SELECT 1 FROM public.dlv_items WHERE is_active AND name ~ '\s(Pequena|Média|Grande)$') THEN
    RAISE EXCEPTION 'ainda existe prato ativo com o tamanho no nome';
  END IF;
END $$;


-- ---------------------------------------------------------------------
-- FUNÇÕES
-- ---------------------------------------------------------------------

-- grupos de complementos no formato do cardápio: do tamanho (p_tamanho) ou do item
CREATE FUNCTION public.dlv__grupos_publicos(p_item uuid, p_tamanho uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', g.id, 'nome', g.name, 'min', r.min_choices, 'max', r.max_choices,
           'opcoes', coalesce((
             SELECT jsonb_agg(jsonb_build_object(
                      'id', o.id, 'nome', o.name, 'adicional_cents', o.extra_cents, 'esgotado', o.is_out_of_stock)
                    ORDER BY o.sort_order, o.name)
               FROM public.dlv_options o
              WHERE o.group_id = g.id AND o.is_active AND NOT o.is_paused), '[]'::jsonb)
         ) ORDER BY r.sort_order), '[]'::jsonb)
    FROM (
      SELECT group_id, min_choices, max_choices, sort_order
        FROM public.dlv_item_option_groups
       WHERE p_tamanho IS NULL AND item_id = p_item
      UNION ALL
      SELECT group_id, min_choices, max_choices, sort_order
        FROM public.dlv_item_size_option_groups
       WHERE size_id = p_tamanho
    ) r
    JOIN public.dlv_option_groups g ON g.id = r.group_id
   WHERE g.is_active;
$$;

-- cardápio: igual ao anterior + "tamanhos" em cada item
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

-- coração do pedido: igual ao anterior + tamanho por linha
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

-- pausar (some do cardápio), esgotar (aparece esgotado) e preço de um tamanho (NULL = não mexe)
CREATE FUNCTION public.dlv_ajustar_tamanho(p_tamanho uuid, p_pausado boolean, p_esgotado boolean, p_preco_cents bigint, p_operador text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s record; v_por text; v_nome text;
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);
  SELECT x.*, i.name AS item_name INTO s
    FROM public.dlv_item_sizes x JOIN public.dlv_items i ON i.id = x.item_id AND i.is_active
   WHERE x.id = p_tamanho AND x.is_active FOR UPDATE OF x;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tamanho não encontrado'; END IF;
  IF p_preco_cents IS NOT NULL AND p_preco_cents < 0 THEN RAISE EXCEPTION 'Preço não pode ser negativo'; END IF;
  v_nome := s.item_name || ' (' || s.name || ')';

  UPDATE public.dlv_item_sizes SET
    is_paused       = coalesce(p_pausado, is_paused),
    is_out_of_stock = coalesce(p_esgotado, is_out_of_stock),
    price_cents     = coalesce(p_preco_cents, price_cents)
  WHERE id = s.id;

  IF p_pausado IS NOT NULL THEN
    PERFORM public.dlv__registrar_mudanca('tamanho', s.id, v_nome, 'pausado', s.is_paused::text, p_pausado::text, v_por);
  END IF;
  IF p_esgotado IS NOT NULL THEN
    PERFORM public.dlv__registrar_mudanca('tamanho', s.id, v_nome, 'esgotado', s.is_out_of_stock::text, p_esgotado::text, v_por);
  END IF;
  IF p_preco_cents IS NOT NULL THEN
    PERFORM public.dlv__registrar_mudanca('tamanho', s.id, v_nome, 'preço', public.dlv__brl(s.price_cents), public.dlv__brl(p_preco_cents), v_por);
  END IF;
END;
$$;

-- Quem pode executar (CREATE OR REPLACE mantém as permissões das funções que já existiam)
REVOKE ALL ON FUNCTION
  public.dlv__grupos_publicos(uuid, uuid),
  public.dlv_ajustar_tamanho(uuid, boolean, boolean, bigint, text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.dlv_ajustar_tamanho(uuid, boolean, boolean, bigint, text) TO authenticated;

COMMIT;

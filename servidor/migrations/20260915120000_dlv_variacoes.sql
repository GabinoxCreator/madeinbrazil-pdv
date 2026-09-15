-- =====================================================================
-- Made in Brazil Delivery — Um prato por variação
--
-- Por quê (decisão do dono, 15/09): hoje o cliente escolhe o tamanho e
-- depois a variação ("Escolha Sua Carne: A Cavalo +R$ 2 / Acebolado").
-- Passa a existir UM PRATO POR VARIAÇÃO ("Bife a Cavalo", "Bife Acebolado"),
-- cada um com os seus tamanhos P/M/G e o adicional da variação já somado no
-- preço de cada tamanho. O cliente só escolhe o tamanho e os complementos
-- que continuam (acompanhamento, + proteína, bebidas, com/sem feijão...).
--
-- Grupos de variação transformados (id do Anota — ver migration dlv_cardapio):
--   Escolha Sua Carne            A Cavalo / Acebolado   → Bife a Cavalo / Bife Acebolado
--   Escolha Seu Strogonoff       de Carne / de Frango   → Strogonoff de Carne / de Frango
--   Escolhe seu Filé de Frango   Grelhado / Empanado    → Filé de Frango Grelhado / Empanado
--   Escolha seu Filé de Tilápia  Empanado / Grelhado    → Filé de Tilápia Empanado / Grelhado
--   Escolha Sua Parmegiana       de Frango / de Carne   → Parmegiana de Frango / de Carne
-- ("Stronogoff" do PF do Dia sai corrigido para "Strogonoff".)
--
-- Como os pratos são achados: pelo dado real — todo prato ATIVO que tem, nos
-- seus tamanhos ativos, um vínculo com um desses grupos
-- (dlv_item_size_option_groups). Hoje são 9 (5 do PF do Dia menos a
-- Feijoada, + 5 Especiais).
--
-- Para cada prato achado e cada opção ativa do grupo:
--   * cria um prato novo na mesma categoria: foto, descrição, ponto de
--     produção, dias, pausado/esgotado do original (pausado/esgotado também se
--     a própria opção estiver pausada/esgotada), ordem logo após a outra
--     variação, anota_id NULL;
--   * copia os tamanhos ativos com preço = preço do tamanho + adicional ATUAL
--     da opção (descrição, pausado, esgotado iguais);
--   * copia os complementos de cada tamanho, SEM o grupo de variação.
-- O prato original e os seus tamanhos ficam INATIVOS (pedidos antigos
-- apontam para eles). Grupos e opções de variação continuam existindo
-- (histórico), só sem vínculo com prato ativo.
--
-- Não apaga nada, não mexe em pedido. dlv_cardapio_publico e
-- dlv__criar_pedido não mudam. Qualquer inconsistência (grupo num tamanho e
-- não em outro, regra diferente de "escolha 1", nome ou categoria
-- inesperados, contagem final diferente): RAISE e NADA fica gravado.
-- =====================================================================

BEGIN;

-- de-para das variações: (grupo no Anota, nome do grupo, opção no Anota, nome da opção, nomes aceitos do prato original, nome do prato novo)
CREATE TEMP TABLE dlv_tmp_variacao (
  grupo_anota  text NOT NULL,
  grupo_nome   text NOT NULL,
  opcao_anota  text NOT NULL,
  opcao_nome   text NOT NULL,
  pratos_base  text[] NOT NULL,
  novo_nome    text NOT NULL
) ON COMMIT DROP;

INSERT INTO dlv_tmp_variacao VALUES
  ('68b70ba7ef53a8516017ab3b', 'Escolha Sua Carne',           '691f112f562a48b720c4db31', 'A Cavalo',  '{Bife}',                   'Bife a Cavalo'),
  ('68b70ba7ef53a8516017ab3b', 'Escolha Sua Carne',           '691f112f562a48b720c4db5a', 'Acebolado', '{Bife}',                   'Bife Acebolado'),
  ('68b70ba7ef53a8516017ab36', 'Escolha Seu Strogonoff',      '693837d9ca6bfcf893329a25', 'de Carne',  '{Strogonoff,Stronogoff}',  'Strogonoff de Carne'),
  ('68b70ba7ef53a8516017ab36', 'Escolha Seu Strogonoff',      '693837d9ca6bfcf893329a40', 'de Frango', '{Strogonoff,Stronogoff}',  'Strogonoff de Frango'),
  ('68b70ba7ef53a8516017ab3e', 'Escolhe seu Filé de Frango',  '68b70ba8ef53a8516017b865', 'Grelhado',  '{"Filé de Frango"}',       'Filé de Frango Grelhado'),
  ('68b70ba7ef53a8516017ab3e', 'Escolhe seu Filé de Frango',  '68b70ba8ef53a8516017b866', 'Empanado',  '{"Filé de Frango"}',       'Filé de Frango Empanado'),
  ('68b70ba7ef53a8516017ab40', 'Escolha seu Filé de Tilápia', '68b70ba8ef53a8516017b877', 'Empanado',  '{"Filé de Tilápia"}',      'Filé de Tilápia Empanado'),
  ('68b70ba7ef53a8516017ab40', 'Escolha seu Filé de Tilápia', '68b70ba8ef53a8516017b876', 'Grelhado',  '{"Filé de Tilápia"}',      'Filé de Tilápia Grelhado'),
  ('68b70ba7ef53a8516017ab42', 'Escolha Sua Parmegiana',      '68b70ba8ef53a8516017b888', 'de Frango', '{Parmegiana}',             'Parmegiana de Frango'),
  ('68b70ba7ef53a8516017ab42', 'Escolha Sua Parmegiana',      '68b70ba8ef53a8516017b887', 'de Carne',  '{Parmegiana}',             'Parmegiana de Carne');

-- rastro do que foi criado, só para a conferência no fim
CREATE TEMP TABLE dlv_tmp_novos (
  original_id  uuid NOT NULL,
  opcao_id     uuid NOT NULL,
  novo_id      uuid NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
  v_grupos   uuid[];
  gr         record;
  pr         record;
  op         record;
  tm         record;
  v_grupo    uuid;
  v_qtd      int;
  v_novo     uuid;
  v_tam_novo uuid;
  v_ordem    int;
BEGIN
  -- 1. grupos e opções do de-para batem com o banco
  FOR gr IN SELECT DISTINCT grupo_anota, grupo_nome FROM dlv_tmp_variacao LOOP
    SELECT id INTO v_grupo FROM public.dlv_option_groups
     WHERE anota_id = gr.grupo_anota AND name = gr.grupo_nome AND is_active;
    IF v_grupo IS NULL THEN
      RAISE EXCEPTION 'Grupo de variação "%" não encontrado (ou inativo / renomeado)', gr.grupo_nome;
    END IF;
    v_grupos := v_grupos || v_grupo;

    -- toda opção ativa do grupo precisa estar no de-para, e vice-versa
    IF EXISTS (
         SELECT 1 FROM public.dlv_options o
          WHERE o.group_id = v_grupo AND o.is_active
            AND NOT EXISTS (SELECT 1 FROM dlv_tmp_variacao v WHERE v.opcao_anota = o.anota_id AND v.opcao_nome = o.name)
       ) OR EXISTS (
         SELECT 1 FROM dlv_tmp_variacao v
          WHERE v.grupo_anota = gr.grupo_anota
            AND NOT EXISTS (SELECT 1 FROM public.dlv_options o
                             WHERE o.group_id = v_grupo AND o.is_active AND o.anota_id = v.opcao_anota AND o.name = v.opcao_nome)
       ) THEN
      RAISE EXCEPTION 'Opções ativas do grupo "%" não batem com as variações esperadas', gr.grupo_nome;
    END IF;
  END LOOP;

  -- 2. prato ativo SEM tamanho usando grupo de variação: não era esperado
  IF EXISTS (
       SELECT 1 FROM public.dlv_items i
         JOIN public.dlv_item_option_groups ig ON ig.item_id = i.id
        WHERE i.is_active AND ig.group_id = ANY (v_grupos)
          AND NOT EXISTS (SELECT 1 FROM public.dlv_item_sizes s WHERE s.item_id = i.id AND s.is_active)
     ) THEN
    RAISE EXCEPTION 'Existe prato ativo sem tamanho usando grupo de variação: conferir antes';
  END IF;

  -- 3. pratos com tamanho que usam grupo de variação (pelo vínculo real)
  FOR pr IN
    SELECT i.*, c.name AS categoria
      FROM public.dlv_items i
      JOIN public.dlv_categories c ON c.id = i.category_id
     WHERE i.is_active
       AND EXISTS (
         SELECT 1 FROM public.dlv_item_sizes s
           JOIN public.dlv_item_size_option_groups sg ON sg.size_id = s.id
          WHERE s.item_id = i.id AND s.is_active AND sg.group_id = ANY (v_grupos))
     ORDER BY c.sort_order, i.sort_order, i.name
     FOR UPDATE OF i
  LOOP
    IF pr.categoria NOT IN ('PF do Dia', 'Especiais de Carne', 'Especiais de Frango', 'Especiais de Peixe',
                            'Especiais Parmegianas', 'Especiais Strogonoff') THEN
      RAISE EXCEPTION 'Prato "%" usa variação mas está na categoria "%", fora do combinado', pr.name, pr.categoria;
    END IF;

    -- um grupo de variação só
    SELECT count(DISTINCT sg.group_id), min(sg.group_id::text)::uuid INTO v_qtd, v_grupo
      FROM public.dlv_item_sizes s
      JOIN public.dlv_item_size_option_groups sg ON sg.size_id = s.id
     WHERE s.item_id = pr.id AND s.is_active AND sg.group_id = ANY (v_grupos);
    IF v_qtd <> 1 THEN
      RAISE EXCEPTION 'Prato "%" (%) tem % grupos de variação diferentes', pr.name, pr.categoria, v_qtd;
    END IF;

    -- em TODOS os tamanhos ativos, com a regra "escolha exatamente 1"
    IF EXISTS (
         SELECT 1 FROM public.dlv_item_sizes s
          WHERE s.item_id = pr.id AND s.is_active
            AND NOT EXISTS (SELECT 1 FROM public.dlv_item_size_option_groups sg
                             WHERE sg.size_id = s.id AND sg.group_id = v_grupo
                               AND sg.min_choices = 1 AND sg.max_choices = 1)
       ) THEN
      RAISE EXCEPTION 'Prato "%" (%): o grupo de variação não está em todos os tamanhos com "escolha 1"', pr.name, pr.categoria;
    END IF;

    IF NOT EXISTS (
         SELECT 1 FROM dlv_tmp_variacao v JOIN public.dlv_option_groups g ON g.anota_id = v.grupo_anota
          WHERE g.id = v_grupo AND pr.name = ANY (v.pratos_base)
       ) THEN
      RAISE EXCEPTION 'Prato "%" (%) não tem o nome esperado para a sua variação', pr.name, pr.categoria;
    END IF;

    v_ordem := 0;
    FOR op IN
      SELECT o.*, v.novo_nome
        FROM public.dlv_options o
        JOIN dlv_tmp_variacao v ON v.opcao_anota = o.anota_id
       WHERE o.group_id = v_grupo AND o.is_active
       ORDER BY o.sort_order, o.name
    LOOP
      IF EXISTS (SELECT 1 FROM public.dlv_items WHERE category_id = pr.category_id AND is_active AND name = op.novo_nome) THEN
        RAISE EXCEPTION 'Já existe "%" ativo em "%": variação já transformada?', op.novo_nome, pr.categoria;
      END IF;

      INSERT INTO public.dlv_items (category_id, name, description, price_cents, image_url, production_point_id,
                                    weekdays, is_paused, is_out_of_stock, sort_order, is_active, anota_id)
      VALUES (pr.category_id, op.novo_nome, pr.description, pr.price_cents + op.extra_cents, pr.image_url, pr.production_point_id,
              pr.weekdays, pr.is_paused OR op.is_paused, pr.is_out_of_stock OR op.is_out_of_stock,
              pr.sort_order + v_ordem, true, NULL)
      RETURNING id INTO v_novo;
      INSERT INTO dlv_tmp_novos VALUES (pr.id, op.id, v_novo);
      v_ordem := v_ordem + 1;

      FOR tm IN SELECT * FROM public.dlv_item_sizes WHERE item_id = pr.id AND is_active ORDER BY sort_order LOOP
        INSERT INTO public.dlv_item_sizes (item_id, name, short_name, price_cents, description,
                                           is_paused, is_out_of_stock, sort_order, is_active, legacy_item_id)
        VALUES (v_novo, tm.name, tm.short_name, tm.price_cents + op.extra_cents, tm.description,
                tm.is_paused, tm.is_out_of_stock, tm.sort_order, true, NULL)
        RETURNING id INTO v_tam_novo;

        INSERT INTO public.dlv_item_size_option_groups (size_id, group_id, min_choices, max_choices, sort_order)
        SELECT v_tam_novo, sg.group_id, sg.min_choices, sg.max_choices, sg.sort_order
          FROM public.dlv_item_size_option_groups sg
         WHERE sg.size_id = tm.id AND sg.group_id <> v_grupo;
      END LOOP;
    END LOOP;

    IF v_ordem < 2 THEN
      RAISE EXCEPTION 'Prato "%" (%) ficaria com menos de 2 variações', pr.name, pr.categoria;
    END IF;

    -- original sai do cardápio, sem apagar (pedidos antigos apontam para ele)
    UPDATE public.dlv_item_sizes SET is_active = false WHERE item_id = pr.id AND is_active;
    UPDATE public.dlv_items SET is_active = false WHERE id = pr.id;
  END LOOP;
END $$;

-- Conferência: se não bater, nada fica gravado
DO $$
DECLARE v_grupos uuid[];
BEGIN
  SELECT array_agg(DISTINCT g.id) INTO v_grupos
    FROM public.dlv_option_groups g JOIN dlv_tmp_variacao v ON v.grupo_anota = g.anota_id;

  IF (SELECT count(DISTINCT original_id) FROM dlv_tmp_novos) <> 9 THEN
    RAISE EXCEPTION 'pratos originais transformados: esperado 9, veio %', (SELECT count(DISTINCT original_id) FROM dlv_tmp_novos);
  END IF;
  IF (SELECT count(*) FROM dlv_tmp_novos) <> 18 THEN RAISE EXCEPTION 'pratos novos: esperado 18'; END IF;
  IF (SELECT count(*) FROM public.dlv_items i JOIN dlv_tmp_novos n ON n.original_id = i.id WHERE i.is_active) > 0 THEN
    RAISE EXCEPTION 'prato original ainda ativo';
  END IF;
  IF (SELECT count(*) FROM public.dlv_item_sizes s JOIN dlv_tmp_novos n ON n.original_id = s.item_id WHERE s.is_active) > 0 THEN
    RAISE EXCEPTION 'tamanho de prato original ainda ativo';
  END IF;
  IF (SELECT count(*) FROM public.dlv_item_sizes s JOIN dlv_tmp_novos n ON n.novo_id = s.item_id WHERE s.is_active) <> 54 THEN
    RAISE EXCEPTION 'tamanhos novos: esperado 54';
  END IF;
  -- regras: (regras de cada tamanho original - o grupo de variação) × número de variações
  IF (SELECT count(*) FROM public.dlv_item_size_option_groups sg
        JOIN public.dlv_item_sizes s ON s.id = sg.size_id
        JOIN dlv_tmp_novos n ON n.novo_id = s.item_id) <> 156
     OR (SELECT count(*) FROM public.dlv_item_size_option_groups sg
           JOIN public.dlv_item_sizes s ON s.id = sg.size_id
           JOIN dlv_tmp_novos n ON n.novo_id = s.item_id)
        <> (SELECT count(*) FROM public.dlv_item_size_option_groups sg
              JOIN public.dlv_item_sizes s ON s.id = sg.size_id
              JOIN (SELECT original_id, count(*) AS variacoes FROM dlv_tmp_novos GROUP BY original_id) o ON o.original_id = s.item_id
              CROSS JOIN LATERAL generate_series(1, o.variacoes)
             WHERE NOT (sg.group_id = ANY (v_grupos))) THEN
    RAISE EXCEPTION 'complementos dos tamanhos novos: esperado 156 e igual aos originais sem a variação';
  END IF;
  -- nenhum prato ativo ligado a grupo de variação
  IF EXISTS (SELECT 1 FROM public.dlv_items i
               JOIN public.dlv_item_sizes s ON s.item_id = i.id AND s.is_active
               JOIN public.dlv_item_size_option_groups sg ON sg.size_id = s.id
              WHERE i.is_active AND sg.group_id = ANY (v_grupos))
     OR EXISTS (SELECT 1 FROM public.dlv_items i
                  JOIN public.dlv_item_option_groups ig ON ig.item_id = i.id
                 WHERE i.is_active AND ig.group_id = ANY (v_grupos)) THEN
    RAISE EXCEPTION 'ainda existe prato ativo com grupo de variação';
  END IF;
  -- preço de cada tamanho novo = tamanho original + adicional da opção
  IF EXISTS (SELECT 1 FROM dlv_tmp_novos n
               JOIN public.dlv_options o ON o.id = n.opcao_id
               JOIN public.dlv_item_sizes sn ON sn.item_id = n.novo_id
               LEFT JOIN public.dlv_item_sizes so ON so.item_id = n.original_id AND so.name = sn.name
              WHERE so.id IS NULL OR sn.price_cents <> so.price_cents + o.extra_cents) THEN
    RAISE EXCEPTION 'preço de tamanho novo não bate com original + adicional';
  END IF;
  IF EXISTS (SELECT 1 FROM public.dlv_items WHERE is_active AND name ILIKE '%stronogoff%') THEN
    RAISE EXCEPTION 'ainda existe prato ativo com "Stronogoff"';
  END IF;
  IF (SELECT count(*) FROM public.dlv_items) <> 98 OR (SELECT count(*) FROM public.dlv_items WHERE NOT is_active) <> 29 THEN
    RAISE EXCEPTION 'itens: esperado 98 no total e 29 inativos';
  END IF;
END $$;

COMMIT;

-- =====================================================================
-- Made in Brazil Delivery — Editar prato, horários e foto pelo painel
--
-- Mesmo padrão da gestão: o painel NUNCA escreve direto em tabela. Tudo por
-- função SECURITY DEFINER que começa conferindo o usuário do painel e
-- registra o histórico em dlv_menu_changes.
--
--   * dlv_editar_item      nome, descrição, categoria, dias e foto de um prato
--   * dlv_salvar_horarios  substitui TODOS os horários de funcionamento
--   * bucket público "dlv-fotos" no Storage para as fotos dos pratos
--     (leitura pública só desse bucket; enviar / trocar / apagar só usuário
--     do painel; só imagem jpeg/png/webp até 2 MB)
--
-- Não apaga nem altera dados de pedido ou de cardápio.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- APOIO (texto legível para o histórico)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv__dias_texto(p_dias smallint[])
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_dias IS NULL THEN 'todos os dias'
    WHEN cardinality(p_dias) = 0 THEN 'nenhum dia'
    ELSE (SELECT string_agg((ARRAY['dom','seg','ter','qua','qui','sex','sáb'])[d + 1], ', ' ORDER BY d)
            FROM (SELECT DISTINCT unnest(p_dias) AS d) x)
  END;
$$;

CREATE FUNCTION public.dlv__horarios_texto()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce(string_agg(
           (ARRAY['dom','seg','ter','qua','qui','sex','sáb'])[weekday + 1] || ' '
             || to_char(opens_at, 'HH24:MI') || '-' || to_char(closes_at, 'HH24:MI'),
           '; ' ORDER BY weekday, opens_at), 'nenhum horário')
    FROM public.dlv_opening_hours;
$$;


-- ---------------------------------------------------------------------
-- EDITAR PRATO
-- NULL = não muda. Descrição ou foto em branco ('') = tira.
-- Dias: muda quando p_dias vem preenchido OU p_mudar_dias = true;
--       p_dias NULL com p_mudar_dias = true = todos os dias.
--       '{}' = nenhum dia (o prato não aparece).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv_editar_item(
  p_item        uuid,
  p_nome        text,
  p_descricao   text,
  p_categoria   uuid,
  p_dias        smallint[],
  p_mudar_dias  boolean,
  p_imagem_url  text,
  p_operador    text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  i            record;
  v_por        text;
  v_nome       text;
  v_desc       text;
  v_cat        uuid;
  v_cat_antiga text;
  v_cat_nova   text;
  v_dias       smallint[];
  v_img        text;
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);

  SELECT * INTO i FROM public.dlv_items WHERE id = p_item AND is_active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item não encontrado'; END IF;

  v_nome := i.name;
  IF p_nome IS NOT NULL THEN
    v_nome := btrim(p_nome);
    IF length(v_nome) = 0 THEN RAISE EXCEPTION 'O nome do prato não pode ficar vazio'; END IF;
    IF length(v_nome) > 80 THEN RAISE EXCEPTION 'Nome muito longo (máximo 80 caracteres)'; END IF;
  END IF;

  v_desc := i.description;
  IF p_descricao IS NOT NULL THEN
    v_desc := nullif(btrim(p_descricao), '');
    IF length(v_desc) > 500 THEN RAISE EXCEPTION 'Descrição muito longa (máximo 500 caracteres)'; END IF;
  END IF;

  v_cat := i.category_id;
  SELECT name INTO v_cat_antiga FROM public.dlv_categories WHERE id = i.category_id;
  v_cat_nova := v_cat_antiga;
  IF p_categoria IS NOT NULL THEN
    SELECT name INTO v_cat_nova FROM public.dlv_categories WHERE id = p_categoria AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Categoria não encontrada ou inativa'; END IF;
    v_cat := p_categoria;
  END IF;

  v_dias := i.weekdays;
  IF p_dias IS NOT NULL OR coalesce(p_mudar_dias, false) THEN
    IF p_dias IS NULL THEN
      v_dias := NULL;
    ELSE
      IF EXISTS (SELECT 1 FROM unnest(p_dias) AS d WHERE d IS NULL OR d NOT BETWEEN 0 AND 6) THEN
        RAISE EXCEPTION 'Dias da semana vão de 0 (domingo) a 6 (sábado)';
      END IF;
      v_dias := ARRAY(SELECT DISTINCT d FROM unnest(p_dias) AS d ORDER BY d)::smallint[];
    END IF;
  END IF;

  v_img := i.image_url;
  IF p_imagem_url IS NOT NULL THEN
    v_img := nullif(btrim(p_imagem_url), '');
    IF v_img IS NOT NULL AND (
         length(v_img) > 1000
         OR v_img ~ '\s'
         OR strpos(v_img, chr(92)) > 0                        -- barra invertida ("/\site" vira outro site no navegador)
         OR NOT (v_img ~* '^https://[^/]+' OR (v_img LIKE '/%' AND v_img NOT LIKE '//%'))
       ) THEN
      RAISE EXCEPTION 'Endereço da foto inválido: use https:// ou um caminho que começa com "/"';
    END IF;
  END IF;

  UPDATE public.dlv_items SET
    name        = v_nome,
    description = v_desc,
    category_id = v_cat,
    weekdays    = v_dias,
    image_url   = v_img
  WHERE id = i.id;

  PERFORM public.dlv__registrar_mudanca('item', i.id, v_nome, 'nome', i.name, v_nome, v_por);
  PERFORM public.dlv__registrar_mudanca('item', i.id, v_nome, 'descrição', i.description, v_desc, v_por);
  IF v_cat <> i.category_id THEN
    PERFORM public.dlv__registrar_mudanca('item', i.id, v_nome, 'categoria', v_cat_antiga, v_cat_nova, v_por);
  END IF;
  PERFORM public.dlv__registrar_mudanca('item', i.id, v_nome, 'dias', public.dlv__dias_texto(i.weekdays), public.dlv__dias_texto(v_dias), v_por);
  PERFORM public.dlv__registrar_mudanca('item', i.id, v_nome, 'foto', i.image_url, v_img, v_por);

  RETURN jsonb_build_object(
    'id', i.id, 'nome', v_nome, 'descricao', v_desc, 'categoria_id', v_cat,
    'dias', to_jsonb(v_dias), 'imagem_url', v_img
  );
END;
$$;


-- ---------------------------------------------------------------------
-- HORÁRIOS DE FUNCIONAMENTO
-- p_horarios = [{ "dia": 0-6, "abre": "HH:MM", "fecha": "HH:MM" }, ...]
-- (0 = domingo). Substitui todos. Lista vazia = no modo automático a loja
-- nunca abre (ainda dá para forçar aberta pelo dlv_configurar_loja).
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv_salvar_horarios(p_horarios jsonb, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_por    text;
  v_nomes  text[] := ARRAY['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  e        jsonb;
  v_dias   int[]  := '{}';
  v_abres  time[] := '{}';
  v_fechas time[] := '{}';
  v_dia    int;
  v_abre   time;
  v_fecha  time;
  r        record;
  v_antes  text;
  v_depois text;
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);

  IF p_horarios IS NULL OR jsonb_typeof(p_horarios) <> 'array' THEN
    RAISE EXCEPTION 'Horários precisam vir numa lista';
  END IF;
  IF jsonb_array_length(p_horarios) > 21 THEN RAISE EXCEPTION 'No máximo 3 faixas por dia'; END IF;

  FOR e IN SELECT value FROM jsonb_array_elements(p_horarios) LOOP
    IF jsonb_typeof(e) <> 'object'
       OR jsonb_typeof(e -> 'dia') IS DISTINCT FROM 'number' OR (e ->> 'dia') !~ '^[0-6]$'
       OR jsonb_typeof(e -> 'abre') IS DISTINCT FROM 'string' OR (e ->> 'abre') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
       OR jsonb_typeof(e -> 'fecha') IS DISTINCT FROM 'string' OR (e ->> 'fecha') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
      RAISE EXCEPTION 'Horário inválido: %. Use { "dia": 0 a 6, "abre": "HH:MM", "fecha": "HH:MM" }', left(e::text, 120);
    END IF;
    v_dia   := (e ->> 'dia')::int;
    v_abre  := (e ->> 'abre')::time;
    v_fecha := (e ->> 'fecha')::time;
    IF v_fecha <= v_abre THEN
      RAISE EXCEPTION 'Na %, o horário de fechar (%) precisa ser depois do de abrir (%)', v_nomes[v_dia + 1], e ->> 'fecha', e ->> 'abre';
    END IF;
    v_dias   := v_dias || v_dia;
    v_abres  := v_abres || v_abre;
    v_fechas := v_fechas || v_fecha;
  END LOOP;

  SELECT dia, count(*) AS n INTO r
    FROM unnest(v_dias) AS dia GROUP BY dia HAVING count(*) > 3 ORDER BY dia LIMIT 1;
  IF FOUND THEN RAISE EXCEPTION 'Na %, no máximo 3 faixas de horário', v_nomes[r.dia + 1]; END IF;

  SELECT a.dia, a.abre AS a_abre, a.fecha AS a_fecha, b.abre AS b_abre, b.fecha AS b_fecha INTO r
    FROM unnest(v_dias, v_abres, v_fechas) WITH ORDINALITY AS a(dia, abre, fecha, n)
    JOIN unnest(v_dias, v_abres, v_fechas) WITH ORDINALITY AS b(dia, abre, fecha, n)
      ON b.dia = a.dia AND b.n > a.n AND a.abre < b.fecha AND b.abre < a.fecha
   ORDER BY a.dia, a.abre LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Na %, as faixas %-% e %-% se sobrepõem', v_nomes[r.dia + 1],
      to_char(r.a_abre, 'HH24:MI'), to_char(r.a_fecha, 'HH24:MI'), to_char(r.b_abre, 'HH24:MI'), to_char(r.b_fecha, 'HH24:MI');
  END IF;

  -- dois painéis salvando ao mesmo tempo: um espera o outro
  LOCK TABLE public.dlv_opening_hours IN SHARE ROW EXCLUSIVE MODE;
  v_antes := public.dlv__horarios_texto();

  -- "WHERE true": o Supabase recusa DELETE sem WHERE vindo da API
  DELETE FROM public.dlv_opening_hours WHERE true;
  INSERT INTO public.dlv_opening_hours (weekday, opens_at, closes_at)
  SELECT dia, abre, fecha FROM unnest(v_dias, v_abres, v_fechas) AS t(dia, abre, fecha);

  v_depois := public.dlv__horarios_texto();
  PERFORM public.dlv__registrar_mudanca('loja', NULL, 'loja', 'horários', v_antes, v_depois, v_por);

  RETURN public.dlv_status_loja();
END;
$$;


-- ---------------------------------------------------------------------
-- STORAGE: fotos dos pratos
-- (só roda onde existe o schema storage — no teste local com PGlite o
--  teste cria um storage mínimo; sem ele, este bloco é pulado)
-- ---------------------------------------------------------------------
DO $$
DECLARE p record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'storage') THEN
    RAISE NOTICE 'schema storage não existe: bucket dlv-fotos não criado';
    RETURN;
  END IF;

  EXECUTE $s$
    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    VALUES ('dlv-fotos', 'dlv-fotos', true, 2097152, ARRAY['image/jpeg', 'image/png', 'image/webp'])
    ON CONFLICT (id) DO UPDATE SET
      public             = true,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types
  $s$;

  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'dlv-fotos leitura publica') THEN
    EXECUTE $s$
      CREATE POLICY "dlv-fotos leitura publica" ON storage.objects
        FOR SELECT TO anon, authenticated
        USING (bucket_id = 'dlv-fotos')
    $s$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'dlv-fotos painel envia') THEN
    EXECUTE $s$
      CREATE POLICY "dlv-fotos painel envia" ON storage.objects
        FOR INSERT TO authenticated
        WITH CHECK (bucket_id = 'dlv-fotos' AND public.pdv_is_panel_user())
    $s$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'dlv-fotos painel troca') THEN
    EXECUTE $s$
      CREATE POLICY "dlv-fotos painel troca" ON storage.objects
        FOR UPDATE TO authenticated
        USING (bucket_id = 'dlv-fotos' AND public.pdv_is_panel_user())
        WITH CHECK (bucket_id = 'dlv-fotos' AND public.pdv_is_panel_user())
    $s$;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'dlv-fotos painel apaga') THEN
    EXECUTE $s$
      CREATE POLICY "dlv-fotos painel apaga" ON storage.objects
        FOR DELETE TO authenticated
        USING (bucket_id = 'dlv-fotos' AND public.pdv_is_panel_user())
    $s$;
  END IF;

  -- Conferência: as 4 políticas existem e todas filtram o bucket (se já
  -- existia uma com o mesmo nome e outra regra, nada fica gravado)
  IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'dlv-fotos %') <> 4 THEN
    RAISE EXCEPTION 'storage: esperado 4 políticas dlv-fotos';
  END IF;
  FOR p IN SELECT * FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'dlv-fotos %' LOOP
    IF p.permissive <> 'PERMISSIVE'
       OR (p.qual IS NOT NULL AND p.qual NOT LIKE '%''dlv-fotos''%')
       OR (p.with_check IS NOT NULL AND p.with_check NOT LIKE '%''dlv-fotos''%')
       OR (p.cmd = 'SELECT' AND (p.qual IS NULL
                                 OR NOT (p.roles::text[] @> ARRAY['anon', 'authenticated'] AND p.roles::text[] <@ ARRAY['anon', 'authenticated'])))
       OR (p.cmd = 'INSERT' AND (p.with_check IS NULL OR p.with_check NOT LIKE '%pdv_is_panel_user()%'))
       OR (p.cmd = 'UPDATE' AND (p.qual IS NULL OR p.with_check IS NULL
                                 OR p.qual NOT LIKE '%pdv_is_panel_user()%' OR p.with_check NOT LIKE '%pdv_is_panel_user()%'))
       OR (p.cmd = 'DELETE' AND (p.qual IS NULL OR p.qual NOT LIKE '%pdv_is_panel_user()%'))
       OR (p.cmd <> 'SELECT' AND p.roles::text[] <> ARRAY['authenticated'])
       OR p.cmd = 'ALL' THEN
      RAISE EXCEPTION 'storage: política "%" não tem a regra esperada', p.policyname;
    END IF;
  END LOOP;
  IF NOT EXISTS (
       SELECT 1 FROM storage.buckets
        WHERE id = 'dlv-fotos' AND public AND file_size_limit = 2097152
          AND allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
     ) THEN
    RAISE EXCEPTION 'storage: bucket dlv-fotos sem a configuração esperada';
  END IF;
END $$;


-- ---------------------------------------------------------------------
-- Quem pode executar
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION
  public.dlv__dias_texto(smallint[]),
  public.dlv__horarios_texto(),
  public.dlv_editar_item(uuid, text, text, uuid, smallint[], boolean, text, text),
  public.dlv_salvar_horarios(jsonb, text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.dlv_editar_item(uuid, text, text, uuid, smallint[], boolean, text, text),
  public.dlv_salvar_horarios(jsonb, text)
TO authenticated;

COMMIT;

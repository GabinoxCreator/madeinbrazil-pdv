-- =====================================================================
-- Made in Brazil Delivery — Gestão da loja e do cardápio pelo painel
--
-- Padrão combinado com o PDV: o navegador NUNCA escreve direto em tabela,
-- só por função. Esta migration:
--   * cria as funções de gestão (abrir/fechar loja, aceite automático,
--     pausar / esgotar / mudar preço de item e de complemento);
--   * registra toda mudança do cardápio em dlv_menu_changes (quem, quando,
--     de quanto para quanto);
--   * tira do painel a escrita direta nas tabelas de cardápio e configuração
--     (a fundação tinha liberado; as regras de linha ficam, sem efeito).
-- Não apaga nem altera nenhum dado.
-- =====================================================================

BEGIN;

CREATE TABLE public.dlv_menu_changes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target      text NOT NULL CHECK (target IN ('item', 'opcao', 'loja')),
  target_id   uuid,
  target_name text NOT NULL,
  field       text NOT NULL,
  old_value   text,
  new_value   text,
  by_name     text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dlv_menu_changes_created_idx ON public.dlv_menu_changes (created_at DESC);
ALTER TABLE public.dlv_menu_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dlv_menu_changes FROM anon, authenticated;
GRANT SELECT ON TABLE public.dlv_menu_changes TO authenticated;
CREATE POLICY "painel le dlv_menu_changes" ON public.dlv_menu_changes
  FOR SELECT TO authenticated USING (public.pdv_is_panel_user());

-- escrita só por função
REVOKE INSERT, UPDATE, DELETE ON TABLE
  public.dlv_settings, public.dlv_opening_hours, public.dlv_delivery_bands,
  public.dlv_categories, public.dlv_items, public.dlv_option_groups, public.dlv_options,
  public.dlv_item_option_groups, public.dlv_couriers
FROM authenticated;


CREATE FUNCTION public.dlv__registrar_mudanca(p_alvo text, p_id uuid, p_nome text, p_campo text, p_de text, p_para text, p_por text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.dlv_menu_changes (target, target_id, target_name, field, old_value, new_value, by_name)
  SELECT p_alvo, p_id, p_nome, p_campo, p_de, p_para, p_por
   WHERE p_de IS DISTINCT FROM p_para;
$$;

-- abrir/fechar a loja e ligar/desligar o aceite automático (NULL = não mexe)
CREATE FUNCTION public.dlv_configurar_loja(p_modo text, p_aceite_automatico boolean, p_operador text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_por text; v_modo_atual text; v_aceite_atual text;
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);
  IF p_modo IS NOT NULL AND p_modo NOT IN ('auto', 'aberta', 'fechada') THEN
    RAISE EXCEPTION 'Situação da loja inválida: %', p_modo;
  END IF;

  SELECT value INTO v_modo_atual   FROM public.dlv_settings WHERE key = 'store_mode'  FOR UPDATE;
  SELECT value INTO v_aceite_atual FROM public.dlv_settings WHERE key = 'auto_accept' FOR UPDATE;

  IF p_modo IS NOT NULL THEN
    UPDATE public.dlv_settings SET value = p_modo WHERE key = 'store_mode';
    PERFORM public.dlv__registrar_mudanca('loja', NULL, 'loja', 'situação', v_modo_atual, p_modo, v_por);
  END IF;
  IF p_aceite_automatico IS NOT NULL THEN
    UPDATE public.dlv_settings SET value = p_aceite_automatico::text WHERE key = 'auto_accept';
    PERFORM public.dlv__registrar_mudanca('loja', NULL, 'loja', 'aceite automático', v_aceite_atual, p_aceite_automatico::text, v_por);
  END IF;

  RETURN jsonb_build_object(
    'modo', public.dlv__config('store_mode', 'auto'),
    'aceite_automatico', public.dlv__config('auto_accept', 'false') = 'true',
    'aberta', public.dlv__loja_aberta()
  );
END;
$$;

-- pausar (some do cardápio), esgotar (aparece esgotado) e preço de um item (NULL = não mexe)
CREATE FUNCTION public.dlv_ajustar_item(p_item uuid, p_pausado boolean, p_esgotado boolean, p_preco_cents bigint, p_operador text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE i record; v_por text;
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);
  SELECT * INTO i FROM public.dlv_items WHERE id = p_item AND is_active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item não encontrado'; END IF;
  IF p_preco_cents IS NOT NULL AND p_preco_cents < 0 THEN RAISE EXCEPTION 'Preço não pode ser negativo'; END IF;

  UPDATE public.dlv_items SET
    is_paused       = coalesce(p_pausado, is_paused),
    is_out_of_stock = coalesce(p_esgotado, is_out_of_stock),
    price_cents     = coalesce(p_preco_cents, price_cents)
  WHERE id = i.id;

  IF p_pausado IS NOT NULL THEN
    PERFORM public.dlv__registrar_mudanca('item', i.id, i.name, 'pausado', i.is_paused::text, p_pausado::text, v_por);
  END IF;
  IF p_esgotado IS NOT NULL THEN
    PERFORM public.dlv__registrar_mudanca('item', i.id, i.name, 'esgotado', i.is_out_of_stock::text, p_esgotado::text, v_por);
  END IF;
  IF p_preco_cents IS NOT NULL THEN
    PERFORM public.dlv__registrar_mudanca('item', i.id, i.name, 'preço', public.dlv__brl(i.price_cents), public.dlv__brl(p_preco_cents), v_por);
  END IF;
END;
$$;

CREATE FUNCTION public.dlv_ajustar_opcao(p_opcao uuid, p_pausada boolean, p_esgotada boolean, p_adicional_cents bigint, p_operador text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o record; v_por text; v_nome text;
BEGIN
  PERFORM public.dlv__exigir_painel();
  v_por := public.dlv__exigir_operador_nome(p_operador);
  SELECT x.*, g.name AS group_name INTO o
    FROM public.dlv_options x JOIN public.dlv_option_groups g ON g.id = x.group_id
   WHERE x.id = p_opcao AND x.is_active FOR UPDATE OF x;
  IF NOT FOUND THEN RAISE EXCEPTION 'Complemento não encontrado'; END IF;
  IF p_adicional_cents IS NOT NULL AND p_adicional_cents < 0 THEN RAISE EXCEPTION 'Adicional não pode ser negativo'; END IF;
  v_nome := o.group_name || ' › ' || o.name;

  UPDATE public.dlv_options SET
    is_paused       = coalesce(p_pausada, is_paused),
    is_out_of_stock = coalesce(p_esgotada, is_out_of_stock),
    extra_cents     = coalesce(p_adicional_cents, extra_cents)
  WHERE id = o.id;

  IF p_pausada IS NOT NULL THEN
    PERFORM public.dlv__registrar_mudanca('opcao', o.id, v_nome, 'pausada', o.is_paused::text, p_pausada::text, v_por);
  END IF;
  IF p_esgotada IS NOT NULL THEN
    PERFORM public.dlv__registrar_mudanca('opcao', o.id, v_nome, 'esgotada', o.is_out_of_stock::text, p_esgotada::text, v_por);
  END IF;
  IF p_adicional_cents IS NOT NULL THEN
    PERFORM public.dlv__registrar_mudanca('opcao', o.id, v_nome, 'adicional', public.dlv__brl(o.extra_cents), public.dlv__brl(p_adicional_cents), v_por);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION
  public.dlv__registrar_mudanca(text, uuid, text, text, text, text, text),
  public.dlv_configurar_loja(text, boolean, text),
  public.dlv_ajustar_item(uuid, boolean, boolean, bigint, text),
  public.dlv_ajustar_opcao(uuid, boolean, boolean, bigint, text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.dlv_configurar_loja(text, boolean, text),
  public.dlv_ajustar_item(uuid, boolean, boolean, bigint, text),
  public.dlv_ajustar_opcao(uuid, boolean, boolean, bigint, text)
TO authenticated;

COMMIT;

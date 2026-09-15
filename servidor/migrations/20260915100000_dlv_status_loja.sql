-- =====================================================================
-- Made in Brazil Delivery — Situação da loja, leitura leve
--
-- Por quê: o Dashboard do painel perguntava "a loja está aberta?" chamando
-- dlv_cardapio_publico a cada 30 s, o que baixa o cardápio inteiro só para
-- ler um sim/não (nota da conversa do PDV na revisão de 15/09).
-- Esta função devolve só a situação e os horários.
-- Não altera nada; só cria uma função de leitura.
-- =====================================================================

BEGIN;

CREATE FUNCTION public.dlv_status_loja()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'aberta', public.dlv__loja_aberta(),
    -- auto = segue o horário · aberta / fechada = forçada pelo painel
    'modo', public.dlv__config('store_mode', 'auto'),
    'horarios', coalesce((
      SELECT jsonb_agg(jsonb_build_object('dia', weekday, 'abre', to_char(opens_at, 'HH24:MI'), 'fecha', to_char(closes_at, 'HH24:MI'))
                       ORDER BY weekday, opens_at)
        FROM public.dlv_opening_hours), '[]'::jsonb)
  );
$$;

REVOKE ALL ON FUNCTION public.dlv_status_loja() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dlv_status_loja() TO anon, authenticated;

COMMIT;

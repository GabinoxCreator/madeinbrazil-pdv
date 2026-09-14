-- =====================================================================
-- Made in Brazil Delivery — Limite geral de pedidos pelo cardápio
--
-- O cardápio é público: qualquer um com a chave pública chama
-- dlv_criar_pedido. Já existia limite por telefone (3 em andamento) e
-- tamanho máximo nos textos. Faltava o caso de pedidos falsos em massa com
-- telefones diferentes: agora há um teto de pedidos do cardápio numa janela
-- de minutos. O pedido lançado pelo painel não entra na conta.
--
-- Referência: o dia mais forte do Anota teve ~50 pedidos no dia inteiro;
-- 15 em 5 minutos fica bem acima do movimento real. Ajustável em dlv_settings.
-- Não apaga nem altera dados.
-- =====================================================================

BEGIN;

INSERT INTO public.dlv_settings (key, value, description) VALUES
  ('max_orders_per_window', '15', 'Máximo de pedidos do cardápio online dentro da janela abaixo (contra pedido falso em massa)'),
  ('orders_window_minutes', '5',  'Janela, em minutos, do limite de pedidos do cardápio online');

CREATE FUNCTION public.dlv__limite_geral_pedidos()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.source = 'cardapio' AND (
       SELECT count(*) FROM public.dlv_orders
        WHERE source = 'cardapio'
          AND created_at > now() - make_interval(mins => public.dlv__config('orders_window_minutes', '5')::int)
     ) >= public.dlv__config('max_orders_per_window', '15')::int THEN
    RAISE EXCEPTION 'Estamos recebendo muitos pedidos agora. Tente de novo em alguns minutos ou chame a loja no WhatsApp.';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.dlv__limite_geral_pedidos() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER dlv_orders_limite_geral
  BEFORE INSERT ON public.dlv_orders
  FOR EACH ROW EXECUTE FUNCTION public.dlv__limite_geral_pedidos();

COMMIT;

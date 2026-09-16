-- =====================================================================
-- Made in Brazil PDV — notificações push no celular/computador da equipe
--
-- Pedido do dono (16/09): quem usa o painel dá o aceite uma vez em cada
-- aparelho e passa a receber aviso de pedido novo do delivery, mesmo com o
-- painel fechado (no iPhone, com o painel instalado na tela de início).
--
-- Fluxo:
--   1. painel → pdv_push_inscrever(endpoint, chaves, aparelho): grava o
--      aparelho para o usuário logado (usuário ativo do painel)
--   2. pedido do cardápio entra na cozinha (em análise ou produção, direto
--      ou depois do pagamento online) → gatilho chama a Edge Function
--      pdv-push por pg_net (sem esperar; se falhar, o pedido segue normal)
--   3. pdv-push (service role) → pdv_push_reivindicar_pedido: marca o
--      pedido como avisado uma única vez e devolve o resumo
--   4. pdv-push envia para pdv_push_destinos() e desliga, com
--      pdv_push_desativar, os aparelhos que o navegador deu como vencidos
--
-- As chaves VAPID (par de chaves do push) são criadas pela própria Edge
-- Function na primeira vez e ficam só no banco, sem passar por chat ou git.
-- O gatilho manda um token aleatório (gerado aqui, guardado numa tabela
-- fechada) no header x-pdv-push-token; sem ele a função não avisa ninguém.
--
-- Mudanças (nada destrutivo; não apaga nem altera dados existentes):
--   * extensão pg_net (chamada HTTP de dentro do banco)
--   * coluna dlv_orders.push_avisado_em
--   * tabelas pdv_push_chaves, pdv_push_segredo e pdv_push_inscricoes,
--     fechadas (RLS sem política; só as funções abaixo mexem nelas)
--   * painel: pdv_push_inscrever, pdv_push_cancelar
--   * só service_role: pdv_push_token_valido, pdv_push_obter_chaves, pdv_push_gravar_chaves,
--     pdv_push_reivindicar_pedido, pdv_push_destinos, pdv_push_desativar
--   * gatilho dlv_orders_avisar_push
-- =====================================================================

BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_net') THEN
    CREATE EXTENSION IF NOT EXISTS pg_net;
  END IF;
END $$;

ALTER TABLE public.dlv_orders ADD COLUMN push_avisado_em timestamptz;

CREATE TABLE public.pdv_push_chaves (
  id        smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  publica   text NOT NULL,
  privada   text NOT NULL,
  criada_em timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pdv_push_chaves ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pdv_push_chaves FROM PUBLIC, anon, authenticated;

CREATE TABLE public.pdv_push_segredo (
  id    smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  token text NOT NULL CHECK (length(token) = 64)
);
ALTER TABLE public.pdv_push_segredo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pdv_push_segredo FROM PUBLIC, anon, authenticated;
INSERT INTO public.pdv_push_segredo (id, token)
VALUES (1, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));

CREATE TABLE public.pdv_push_inscricoes (
  endpoint      text PRIMARY KEY CHECK (endpoint LIKE 'https://%' AND length(endpoint) <= 1000),
  user_id       uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  p256dh        text NOT NULL CHECK (length(p256dh) BETWEEN 1 AND 200),
  auth          text NOT NULL CHECK (length(auth) BETWEEN 1 AND 100),
  aparelho      text CHECK (length(aparelho) <= 300),
  ativo         boolean NOT NULL DEFAULT true,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pdv_push_inscricoes_user ON public.pdv_push_inscricoes (user_id) WHERE ativo;
ALTER TABLE public.pdv_push_inscricoes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pdv_push_inscricoes FROM PUBLIC, anon, authenticated;


-- ---------------------------------------------------------------------
-- Painel: aceite e cancelamento no aparelho
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv_push_inscrever(p_endpoint text, p_p256dh text, p_auth text, p_aparelho text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.pdv_panel_users WHERE user_id = auth.uid() AND is_active) THEN
    RAISE EXCEPTION 'Sem permissão para receber notificações' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_endpoint, '') NOT LIKE 'https://%' OR coalesce(p_p256dh, '') = '' OR coalesce(p_auth, '') = '' THEN
    RAISE EXCEPTION 'Inscrição de notificação inválida';
  END IF;

  -- o mesmo aparelho pode trocar de usuário (tablet do balcão): fica com quem ativou por último
  INSERT INTO public.pdv_push_inscricoes (endpoint, user_id, p256dh, auth, aparelho)
  VALUES (p_endpoint, auth.uid(), p_p256dh, p_auth, left(p_aparelho, 300))
  ON CONFLICT (endpoint) DO UPDATE
     SET user_id = EXCLUDED.user_id, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth,
         aparelho = EXCLUDED.aparelho, ativo = true, atualizado_em = now();
END;
$$;

CREATE FUNCTION public.pdv_push_cancelar(p_endpoint text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sem permissão' USING ERRCODE = '42501';
  END IF;
  UPDATE public.pdv_push_inscricoes
     SET ativo = false, atualizado_em = now()
   WHERE endpoint = p_endpoint AND user_id = auth.uid();
END;
$$;


-- ---------------------------------------------------------------------
-- Edge Function pdv-push (service role)
-- ---------------------------------------------------------------------
-- confere o token que o gatilho mandou (a função não chega a ver o valor guardado)
CREATE FUNCTION public.pdv_push_token_valido(p_token text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT coalesce((SELECT token = p_token FROM public.pdv_push_segredo WHERE id = 1), false);
$$;

CREATE FUNCTION public.pdv_push_obter_chaves()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('publica', publica, 'privada', privada) FROM public.pdv_push_chaves WHERE id = 1;
$$;

-- grava só se ainda não existir; sempre devolve o par que valeu
CREATE FUNCTION public.pdv_push_gravar_chaves(p_publica text, p_privada text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.pdv_push_chaves (id, publica, privada) VALUES (1, p_publica, p_privada)
  ON CONFLICT (id) DO NOTHING;
  RETURN public.pdv_push_obter_chaves();
END;
$$;

-- marca o pedido como avisado uma única vez; null quando não deve avisar
CREATE FUNCTION public.pdv_push_reivindicar_pedido(p_pedido uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  o record;
BEGIN
  UPDATE public.dlv_orders
     SET push_avisado_em = now()
   WHERE id = p_pedido
     AND push_avisado_em IS NULL
     AND source = 'cardapio'
     AND status IN ('em_analise', 'em_producao')
     AND created_at > now() - interval '3 hours'
  RETURNING number, status, mode, total_cents, customer_name, payment_method, paid_at
       INTO o;
  IF NOT FOUND THEN RETURN NULL; END IF;

  RETURN jsonb_build_object(
    'numero', o.number, 'status', o.status, 'modo', o.mode, 'total_cents', o.total_cents,
    'cliente', o.customer_name, 'pagamento', o.payment_method, 'pago', o.paid_at IS NOT NULL);
END;
$$;

CREATE FUNCTION public.pdv_push_destinos()
RETURNS TABLE (endpoint text, p256dh text, auth text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.endpoint, i.p256dh, i.auth
    FROM public.pdv_push_inscricoes i
    JOIN public.pdv_panel_users u ON u.user_id = i.user_id AND u.is_active
   WHERE i.ativo;
$$;

CREATE FUNCTION public.pdv_push_desativar(p_endpoint text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.pdv_push_inscricoes SET ativo = false, atualizado_em = now() WHERE endpoint = p_endpoint;
$$;


-- ---------------------------------------------------------------------
-- Gatilho: pedido do cardápio entrou na cozinha → chama a pdv-push
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv__avisar_push()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.source = 'cardapio'
     AND NEW.push_avisado_em IS NULL
     AND NEW.status IN ('em_analise', 'em_producao')
     AND (TG_OP = 'INSERT' OR OLD.status = 'aguardando_pagamento') THEN
    BEGIN
      PERFORM net.http_post(
        url := 'https://ykhywmtauljpjuqxxpez.supabase.co/functions/v1/pdv-push',
        body := jsonb_build_object('acao', 'pedido', 'pedido', NEW.id),
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-pdv-push-token', (SELECT token FROM public.pdv_push_segredo WHERE id = 1))
      );
    EXCEPTION WHEN OTHERS THEN
      -- aviso nunca pode travar o pedido
      RAISE WARNING 'push do pedido % não saiu: %', NEW.number, SQLERRM;
    END;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER dlv_orders_avisar_push
  AFTER INSERT OR UPDATE OF status ON public.dlv_orders
  FOR EACH ROW EXECUTE FUNCTION public.dlv__avisar_push();


-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.pdv_push_inscrever(text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pdv_push_cancelar(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdv_push_inscrever(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pdv_push_cancelar(text) TO authenticated;

REVOKE ALL ON FUNCTION public.pdv_push_token_valido(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pdv_push_obter_chaves() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pdv_push_gravar_chaves(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pdv_push_reivindicar_pedido(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pdv_push_destinos() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.pdv_push_desativar(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dlv__avisar_push() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdv_push_token_valido(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.pdv_push_obter_chaves() TO service_role;
GRANT EXECUTE ON FUNCTION public.pdv_push_gravar_chaves(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.pdv_push_reivindicar_pedido(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.pdv_push_destinos() TO service_role;
GRANT EXECUTE ON FUNCTION public.pdv_push_desativar(text) TO service_role;

COMMIT;

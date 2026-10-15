-- =====================================================================
-- Made in Brazil PDV — aviso no celular quando um cupom do delivery
-- não imprime (MB-132)
--
-- Em 22/09 a térmica da cozinha ficou fora por 27 minutos: 12 cupons
-- desistiram depois de 5 tentativas e 5 pedidos saíram sem via na cozinha,
-- sem ninguém saber. Agora, quando um cupom desiste, a equipe recebe o mesmo
-- tipo de aviso do pedido novo e reimprime só a via que faltou.
--
-- Fluxo (reaproveita o caminho do aviso de pedido novo, 20260916180000):
--   1. a estação conclui a 5ª tentativa sem sucesso → dlv_print_jobs vira
--      'falha' (dlv_concluir_impressao, sem mudança)
--   2. gatilho dlv_print_jobs_avisar_falha chama a pdv-push por pg_net com
--      { acao: 'cupom', trabalho } (sem esperar; se falhar, nada trava)
--   3. pdv-push → pdv_push_reivindicar_cupom: marca o cupom como avisado uma
--      única vez e devolve o pedido, a via e as vias que ainda faltam
--
-- Não avisa: cupom que falhou há mais de 1 hora, pedido cancelado (a não ser
-- que o cupom que falhou seja o próprio aviso de cancelamento) e via que já
-- foi mandada de novo para a fila.
--
-- Mudanças (nada destrutivo; não apaga nem altera dados existentes):
--   * coluna dlv_print_jobs.push_avisado_em
--   * só service_role: pdv_push_reivindicar_cupom
--   * gatilho dlv_print_jobs_avisar_falha
-- =====================================================================

BEGIN;

ALTER TABLE public.dlv_print_jobs ADD COLUMN push_avisado_em timestamptz;


-- marca o cupom como avisado uma única vez; null quando não deve avisar
CREATE FUNCTION public.pdv_push_reivindicar_cupom(p_trabalho uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  j record; o record; v_via text; v_faltando text[];
BEGIN
  UPDATE public.dlv_print_jobs
     SET push_avisado_em = now()
   WHERE id = p_trabalho
     AND status = 'falha'
     AND push_avisado_em IS NULL
     AND updated_at > now() - interval '1 hour'
  RETURNING order_id, production_point_id, kind INTO j;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT number, status, customer_name INTO o FROM public.dlv_orders WHERE id = j.order_id;
  IF NOT FOUND OR (o.status = 'cancelado' AND j.kind <> 'cancelamento') THEN RETURN NULL; END IF;

  SELECT name INTO v_via FROM public.pdv_production_points WHERE id = j.production_point_id;

  -- vias do pedido cuja última tentativa terminou em falha (reimpressa = não falta mais)
  SELECT array_agg(u.name ORDER BY u.name) INTO v_faltando
    FROM (SELECT DISTINCT ON (x.production_point_id, x.kind) pp.name, x.status
            FROM public.dlv_print_jobs x
            JOIN public.pdv_production_points pp ON pp.id = x.production_point_id
           WHERE x.order_id = j.order_id AND x.kind <> 'cancelamento'
           ORDER BY x.production_point_id, x.kind, x.created_at DESC) u
   WHERE u.status = 'falha';

  IF j.kind <> 'cancelamento' AND v_faltando IS NULL THEN RETURN NULL; END IF;

  RETURN jsonb_build_object(
    'numero', o.number, 'cliente', o.customer_name, 'tipo', j.kind, 'via', v_via,
    'faltando', coalesce(to_jsonb(v_faltando), '[]'::jsonb));
END;
$$;


-- ---------------------------------------------------------------------
-- Gatilho: cupom desistiu → chama a pdv-push
-- ---------------------------------------------------------------------
CREATE FUNCTION public.dlv__avisar_cupom_falhou()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  BEGIN
    PERFORM net.http_post(
      url := 'https://ykhywmtauljpjuqxxpez.supabase.co/functions/v1/pdv-push',
      body := jsonb_build_object('acao', 'cupom', 'trabalho', NEW.id),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-pdv-push-token', (SELECT token FROM public.pdv_push_segredo WHERE id = 1))
    );
  EXCEPTION WHEN OTHERS THEN
    -- aviso nunca pode travar a fila de impressão
    RAISE WARNING 'push do cupom % não saiu: %', NEW.id, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

CREATE TRIGGER dlv_print_jobs_avisar_falha
  AFTER UPDATE OF status ON public.dlv_print_jobs
  FOR EACH ROW
  WHEN (NEW.status = 'falha' AND OLD.status IS DISTINCT FROM 'falha')
  EXECUTE FUNCTION public.dlv__avisar_cupom_falhou();


-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.pdv_push_reivindicar_cupom(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.dlv__avisar_cupom_falhou() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pdv_push_reivindicar_cupom(uuid) TO service_role;

COMMIT;

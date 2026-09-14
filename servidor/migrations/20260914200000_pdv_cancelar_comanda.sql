-- =====================================================================
-- Made in Brazil PDV — Cancelar comanda aberta por engano
--
-- Achado testando as regras: uma comanda aberta sem nenhum item nunca
-- podia ser recebida (total zero) e travava o fechamento do caixa pra
-- sempre. Agora dá pra cancelar, com motivo, desde que:
--   * não tenha pagamento registrado;
--   * não tenha item ativo (itens são cancelados antes, um a um, com motivo
--     — assim a auditoria do que foi lançado não se perde).
-- =====================================================================

BEGIN;

CREATE FUNCTION public.pdv_cancelar_comanda(p_comanda uuid, p_motivo text, p_operador text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c record;
BEGIN
  PERFORM public.pdv__exigir_operador();
  IF length(btrim(coalesce(p_motivo, ''))) = 0 THEN RAISE EXCEPTION 'Informe o motivo do cancelamento'; END IF;
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;
  SELECT * INTO c FROM public.pdv_cards WHERE id = p_comanda FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comanda não encontrada'; END IF;
  IF c.status NOT IN ('aberta', 'fechada') THEN
    RAISE EXCEPTION 'Comanda % já está %', c.card_number, c.status;
  END IF;
  IF EXISTS (SELECT 1 FROM public.pdv_payments WHERE card_id = c.id) THEN
    RAISE EXCEPTION 'A comanda % já tem pagamento registrado e não pode ser cancelada', c.card_number;
  END IF;
  IF EXISTS (SELECT 1 FROM public.pdv_card_items WHERE card_id = c.id AND status = 'ativo') THEN
    RAISE EXCEPTION 'A comanda % tem itens lançados: cancele os itens (com motivo) antes de cancelar a comanda', c.card_number;
  END IF;
  UPDATE public.pdv_cards
     SET status = 'cancelada', cancelled_reason = btrim(p_motivo), closed_at = coalesce(closed_at, now()),
         last_activity_by_name = p_operador, last_activity_at = now()
   WHERE id = c.id;
END;
$$;

REVOKE ALL ON FUNCTION public.pdv_cancelar_comanda(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdv_cancelar_comanda(uuid, text, text) TO authenticated;

COMMIT;

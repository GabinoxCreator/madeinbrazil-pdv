-- =====================================================================
-- Made in Brazil PDV — Autor dos registros pelo NOME, enquanto a equipe
-- não está cadastrada no servidor
--
-- Por quê: a fundação exigia o id de um colaborador em quem abre comanda,
-- lança pedido, recebe e mexe no caixa. A equipe vai ser cadastrada depois
-- (decisão do Gabriel, 14/09/2026), então o terminal não tem esse id.
-- Sem esta mudança, NENHUMA comanda conseguiria subir pro servidor.
--
-- O que muda:
--   * o id do colaborador passa a ser opcional;
--   * cada registro guarda também o NOME de quem fez, congelado no momento
--     (mesma ideia do nome e preço do item, que já são congelados);
--   * toda regra exige pelo menos um dos dois (id ou nome) — autoria nunca
--     fica em branco.
-- Quando a equipe existir, o app passa a mandar o id também.
-- Não apaga nem altera nenhum dado (as tabelas operacionais estão vazias).
-- =====================================================================

BEGIN;

-- sessões de caixa
ALTER TABLE public.pdv_cash_sessions
  ALTER COLUMN opened_by DROP NOT NULL,
  ADD COLUMN opened_by_name text,
  ADD COLUMN closed_by_name text;
ALTER TABLE public.pdv_cash_sessions DROP CONSTRAINT pdv_cash_sessions_check;
ALTER TABLE public.pdv_cash_sessions
  ADD CONSTRAINT pdv_cash_sessions_autor_abertura
    CHECK (opened_by IS NOT NULL OR length(btrim(coalesce(opened_by_name, ''))) > 0),
  ADD CONSTRAINT pdv_cash_sessions_fechamento
    CHECK (
      (status = 'aberta' AND closed_at IS NULL)
      OR
      (status = 'fechada' AND closed_at IS NOT NULL AND counted_cents IS NOT NULL
       AND (closed_by IS NOT NULL OR length(btrim(coalesce(closed_by_name, ''))) > 0))
    );

-- sangria e suprimento
ALTER TABLE public.pdv_cash_movements
  ALTER COLUMN created_by DROP NOT NULL,
  ADD COLUMN created_by_name text;
ALTER TABLE public.pdv_cash_movements
  ADD CONSTRAINT pdv_cash_movements_autor
    CHECK (created_by IS NOT NULL OR length(btrim(coalesce(created_by_name, ''))) > 0);

-- comandas
ALTER TABLE public.pdv_cards
  ALTER COLUMN opened_by DROP NOT NULL,
  ADD COLUMN opened_by_name text,
  ADD COLUMN last_activity_by_name text;
ALTER TABLE public.pdv_cards
  ADD CONSTRAINT pdv_cards_autor_abertura
    CHECK (opened_by IS NOT NULL OR length(btrim(coalesce(opened_by_name, ''))) > 0);

-- pedidos
ALTER TABLE public.pdv_card_orders
  ALTER COLUMN created_by DROP NOT NULL,
  ADD COLUMN created_by_name text;
ALTER TABLE public.pdv_card_orders
  ADD CONSTRAINT pdv_card_orders_autor
    CHECK (created_by IS NOT NULL OR length(btrim(coalesce(created_by_name, ''))) > 0);

-- itens: cancelamento aceita o nome de quem cancelou
ALTER TABLE public.pdv_card_items
  ADD COLUMN cancelled_by_name text;
ALTER TABLE public.pdv_card_items DROP CONSTRAINT pdv_card_items_check;
ALTER TABLE public.pdv_card_items
  ADD CONSTRAINT pdv_card_items_cancelamento
    CHECK (
      status = 'ativo'
      OR (cancelled_at IS NOT NULL
          AND length(btrim(coalesce(cancelled_reason, ''))) > 0
          AND (cancelled_by IS NOT NULL OR length(btrim(coalesce(cancelled_by_name, ''))) > 0))
    );

-- transferências
ALTER TABLE public.pdv_card_transfers
  ALTER COLUMN created_by DROP NOT NULL,
  ADD COLUMN created_by_name text;
ALTER TABLE public.pdv_card_transfers
  ADD CONSTRAINT pdv_card_transfers_autor
    CHECK (created_by IS NOT NULL OR length(btrim(coalesce(created_by_name, ''))) > 0);

-- pagamentos
ALTER TABLE public.pdv_payments
  ALTER COLUMN received_by DROP NOT NULL,
  ADD COLUMN received_by_name text;
ALTER TABLE public.pdv_payments
  ADD CONSTRAINT pdv_payments_autor
    CHECK (received_by IS NOT NULL OR length(btrim(coalesce(received_by_name, ''))) > 0);

-- o terminal pode atualizar os novos campos de nome nas mesmas situações
-- em que já podia atualizar o id correspondente
GRANT UPDATE (last_activity_by_name) ON public.pdv_cards         TO authenticated;
GRANT UPDATE (cancelled_by_name)     ON public.pdv_card_items    TO authenticated;
GRANT UPDATE (closed_by_name)        ON public.pdv_cash_sessions TO authenticated;

COMMIT;

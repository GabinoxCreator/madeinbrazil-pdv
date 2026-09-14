-- =====================================================================
-- Made in Brazil PDV — Acesso do terminal ao servidor
--
-- Como funciona:
--   * Cada terminal tem uma CONTA DE LOGIN própria (Supabase Auth).
--     A conta é criada à parte, sem versionar a senha; esta migration só
--     cria a ligação conta -> terminal e as regras de acesso.
--   * A chave pública do projeto (que vai dentro do app e do site) NÃO dá
--     acesso a nada: o visitante anônimo perde qualquer permissão.
--   * Estar logado não basta: a conta precisa estar ligada a um terminal
--     ATIVO em pdv_terminal_accounts. Qualquer outra conta logada é barrada.
--
-- O que o terminal pode fazer (mínimo necessário):
--   * LER: parâmetros, térmicas, terminais, colaboradores, cardápio.
--   * LER e CRIAR: comandas, pedidos, itens, transferências, pagamentos,
--     sessões e movimentos de caixa.
--   * ALTERAR só colunas específicas: situação da comanda, cancelamento de
--     item, status de impressão do pedido e fechamento do caixa.
--   * APAGAR: nada, em tabela nenhuma.
--   * Cardápio, térmicas, parâmetros e colaboradores: só leitura.
--
-- Conhecido e aceito nesta etapa: o terminal informa quem é o colaborador
-- em cada registro (opened_by, received_by...). Não há login por garçom
-- ainda; isso vem com o cadastro da equipe.
-- =====================================================================

BEGIN;

-- Ligação conta de login -> terminal
CREATE TABLE public.pdv_terminal_accounts (
  user_id      uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  terminal_id  uuid NOT NULL UNIQUE REFERENCES public.pdv_terminals(id),
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pdv_terminal_accounts ENABLE ROW LEVEL SECURITY;

-- "Quem está logado é um terminal ativo?"
CREATE FUNCTION public.pdv_is_terminal()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.pdv_terminal_accounts a
    JOIN public.pdv_terminals t ON t.id = a.terminal_id
    WHERE a.user_id = auth.uid()
      AND a.is_active
      AND t.is_active
  );
$$;
REVOKE ALL ON FUNCTION public.pdv_is_terminal() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pdv_is_terminal() TO authenticated;


-- ---------------------------------------------------------------------
-- Permissões: tira tudo do anônimo e do logado, devolve só o mínimo
-- ---------------------------------------------------------------------
REVOKE ALL ON TABLE
  public.pdv_settings, public.pdv_production_points, public.pdv_terminals,
  public.pdv_collaborators, public.pdv_menu_categories, public.pdv_menu_items,
  public.pdv_cash_sessions, public.pdv_cash_movements,
  public.pdv_cards, public.pdv_card_orders, public.pdv_card_items,
  public.pdv_card_transfers, public.pdv_payments,
  public.pdv_terminal_accounts
FROM anon, authenticated;

-- só leitura
GRANT SELECT ON TABLE
  public.pdv_settings, public.pdv_production_points, public.pdv_terminals,
  public.pdv_collaborators, public.pdv_menu_categories, public.pdv_menu_items,
  public.pdv_terminal_accounts
TO authenticated;

-- ler e criar
GRANT SELECT, INSERT ON TABLE
  public.pdv_cash_sessions, public.pdv_cash_movements,
  public.pdv_cards, public.pdv_card_orders, public.pdv_card_items,
  public.pdv_card_transfers, public.pdv_payments
TO authenticated;

-- alterar só estas colunas
GRANT UPDATE (table_number, status, customer_name, people_count, service_fee_pct,
              discount_cents, first_order_at, closed_at, received_at,
              cancelled_reason, last_activity_by, last_activity_at)
  ON public.pdv_cards TO authenticated;

GRANT UPDATE (status, cancelled_by, cancelled_reason, cancelled_at)
  ON public.pdv_card_items TO authenticated;

GRANT UPDATE (print_status)
  ON public.pdv_card_orders TO authenticated;

GRANT UPDATE (status, closed_by, closed_at, counted_cents, expected_cents, notes)
  ON public.pdv_cash_sessions TO authenticated;


-- ---------------------------------------------------------------------
-- Regras de linha: todas exigem terminal ativo
-- ---------------------------------------------------------------------

-- leitura de configuração e cadastros
CREATE POLICY "terminal le parametros"   ON public.pdv_settings          FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal le termicas"     ON public.pdv_production_points FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal le terminais"    ON public.pdv_terminals         FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal le colaboradores" ON public.pdv_collaborators    FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal le categorias"   ON public.pdv_menu_categories   FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal le cardapio"     ON public.pdv_menu_items        FOR SELECT TO authenticated USING (public.pdv_is_terminal());

-- a conta enxerga só a própria ligação
CREATE POLICY "conta le a propria ligacao" ON public.pdv_terminal_accounts
  FOR SELECT TO authenticated USING (user_id = auth.uid());

-- operação: ler e criar
CREATE POLICY "terminal le caixa"         ON public.pdv_cash_sessions  FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal abre caixa"       ON public.pdv_cash_sessions  FOR INSERT TO authenticated WITH CHECK (public.pdv_is_terminal());
CREATE POLICY "terminal le movimentos"    ON public.pdv_cash_movements FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal cria movimento"   ON public.pdv_cash_movements FOR INSERT TO authenticated WITH CHECK (public.pdv_is_terminal());
CREATE POLICY "terminal le comandas"      ON public.pdv_cards          FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal abre comanda"     ON public.pdv_cards          FOR INSERT TO authenticated WITH CHECK (public.pdv_is_terminal());
CREATE POLICY "terminal le pedidos"       ON public.pdv_card_orders    FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal cria pedido"      ON public.pdv_card_orders    FOR INSERT TO authenticated WITH CHECK (public.pdv_is_terminal());
CREATE POLICY "terminal le itens"         ON public.pdv_card_items     FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal lanca item"       ON public.pdv_card_items     FOR INSERT TO authenticated WITH CHECK (public.pdv_is_terminal());
CREATE POLICY "terminal le transferencias" ON public.pdv_card_transfers FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal transfere"        ON public.pdv_card_transfers FOR INSERT TO authenticated WITH CHECK (public.pdv_is_terminal());
CREATE POLICY "terminal le pagamentos"    ON public.pdv_payments       FOR SELECT TO authenticated USING (public.pdv_is_terminal());
CREATE POLICY "terminal recebe"           ON public.pdv_payments       FOR INSERT TO authenticated WITH CHECK (public.pdv_is_terminal());

-- operação: alterar (as colunas já estão limitadas pelas permissões acima)
CREATE POLICY "terminal atualiza comanda" ON public.pdv_cards         FOR UPDATE TO authenticated USING (public.pdv_is_terminal()) WITH CHECK (public.pdv_is_terminal());
CREATE POLICY "terminal cancela item"     ON public.pdv_card_items    FOR UPDATE TO authenticated USING (public.pdv_is_terminal()) WITH CHECK (public.pdv_is_terminal());
CREATE POLICY "terminal marca impressao"  ON public.pdv_card_orders   FOR UPDATE TO authenticated USING (public.pdv_is_terminal()) WITH CHECK (public.pdv_is_terminal());
CREATE POLICY "terminal fecha caixa"      ON public.pdv_cash_sessions FOR UPDATE TO authenticated USING (public.pdv_is_terminal()) WITH CHECK (public.pdv_is_terminal());

COMMIT;

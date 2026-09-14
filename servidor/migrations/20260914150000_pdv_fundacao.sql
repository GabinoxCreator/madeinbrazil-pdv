-- =====================================================================
-- Made in Brazil PDV — Fundação do banco do servidor
-- Projeto Lovable: 477c32ee-21dd-404d-b2a5-fd76286419f8 (separado do bar)
--
-- Adaptado de _docs/rascunhos/pdv-schema-rascunho.sql (repo do bar).
-- Diferenças em relação ao rascunho:
--   * Não depende de NADA do banco do bar: colaboradores, cardápio e
--     papéis de acesso passam a ser tabelas próprias do PDV.
--   * Dinheiro em CENTAVOS (bigint), igual ao app. Nunca ponto flutuante.
--   * Ids gerados no próprio aparelho (uuid): o terminal lança offline e
--     sobe depois sem colidir com outro terminal.
--   * Fila de impressão NÃO fica no servidor: quem imprime é o terminal,
--     direto na térmica. O servidor só guarda o status no pedido.
--   * Uma única sessão de caixa aberta por vez (regra atual do app).
--
-- Acesso: RLS ligado em todas as tabelas e NENHUMA política criada.
-- Ou seja, a chave pública do projeto não lê nem grava nada. O jeito de o
-- terminal entrar vem no próximo passo, com SQL próprio para revisão.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Função padrão de updated_at
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


-- =====================================================================
-- CONFIGURAÇÃO
-- =====================================================================

-- Parâmetros da operação (nada de número fixo no código)
CREATE TABLE public.pdv_settings (
  key          text PRIMARY KEY,
  value        text NOT NULL,
  description  text,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- Pontos de produção = as térmicas Elgin i9 da rede do bar
CREATE TABLE public.pdv_production_points (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code          text NOT NULL UNIQUE CHECK (code ~ '^[a-z_]+$'),  -- igual ao app: cozinha, drink, cerveja, caixa
  name          text NOT NULL,
  printer_ip    inet NOT NULL,
  printer_port  int  NOT NULL DEFAULT 9100 CHECK (printer_port BETWEEN 1 AND 65535),
  is_active     boolean NOT NULL DEFAULT true,
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Terminais físicos (Cielo Smart / L400)
CREATE TABLE public.pdv_terminals (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label            text NOT NULL,
  serial_number    text UNIQUE,
  cielo_store_id   text,
  terminal_number  int,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- Colaboradores do PDV (cadastro próprio, sem ligação com o bar)
CREATE TABLE public.pdv_collaborators (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  role        text NOT NULL,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Cardápio do PDV (cópia própria; semeado em passo separado)
CREATE TABLE public.pdv_menu_categories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text NOT NULL UNIQUE,
  name        text NOT NULL,
  sort_order  int  NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.pdv_menu_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id          uuid NOT NULL REFERENCES public.pdv_menu_categories(id),
  name                 text NOT NULL,
  short_code           text UNIQUE,
  price_cents          bigint NOT NULL CHECK (price_cents >= 0),
  production_point_id  uuid NOT NULL REFERENCES public.pdv_production_points(id),
  sort_order           int  NOT NULL DEFAULT 0,
  is_active            boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pdv_menu_items_category_idx ON public.pdv_menu_items (category_id);


-- =====================================================================
-- CAIXA
-- =====================================================================

CREATE TABLE public.pdv_cash_sessions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  terminal_id          uuid REFERENCES public.pdv_terminals(id),
  opened_by            uuid NOT NULL REFERENCES public.pdv_collaborators(id),
  opened_at            timestamptz NOT NULL DEFAULT now(),
  opening_float_cents  bigint NOT NULL DEFAULT 0 CHECK (opening_float_cents >= 0),
  closed_by            uuid REFERENCES public.pdv_collaborators(id),
  closed_at            timestamptz,
  counted_cents        bigint CHECK (counted_cents >= 0),
  expected_cents       bigint,
  -- contado - esperado. Negativo = falta dinheiro na gaveta.
  difference_cents     bigint GENERATED ALWAYS AS (counted_cents - expected_cents) STORED,
  status               text NOT NULL DEFAULT 'aberta' CHECK (status IN ('aberta','fechada')),
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  -- sessão fechada precisa ter quem fechou, quando e quanto contou
  CHECK (
    (status = 'aberta'  AND closed_at IS NULL)
    OR
    (status = 'fechada' AND closed_at IS NOT NULL AND closed_by IS NOT NULL AND counted_cents IS NOT NULL)
  )
);
-- Só uma sessão de caixa aberta por vez
CREATE UNIQUE INDEX pdv_cash_sessions_uma_aberta
  ON public.pdv_cash_sessions (status) WHERE status = 'aberta';

-- Sangria e suprimento
CREATE TABLE public.pdv_cash_movements (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id    uuid NOT NULL REFERENCES public.pdv_cash_sessions(id),
  type          text NOT NULL CHECK (type IN ('sangria','suprimento')),
  amount_cents  bigint NOT NULL CHECK (amount_cents > 0),
  reason        text NOT NULL CHECK (length(btrim(reason)) > 0),
  created_by    uuid NOT NULL REFERENCES public.pdv_collaborators(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pdv_cash_movements_session_idx ON public.pdv_cash_movements (session_id);


-- =====================================================================
-- COMANDAS
-- =====================================================================

CREATE TABLE public.pdv_cards (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  card_number       int  NOT NULL CHECK (card_number >= 0),
  table_number      text,
  status            text NOT NULL DEFAULT 'aberta'
                      CHECK (status IN ('aberta','fechada','recebida','cancelada')),
  customer_name     text,
  people_count      int  NOT NULL DEFAULT 1 CHECK (people_count > 0),
  -- banda, almoço da equipe: fica aberta de propósito e não cobra serviço
  is_control_card   boolean NOT NULL DEFAULT false,
  service_fee_pct   numeric(5,2) NOT NULL DEFAULT 10 CHECK (service_fee_pct BETWEEN 0 AND 100),
  discount_cents    bigint NOT NULL DEFAULT 0 CHECK (discount_cents >= 0),
  opened_by         uuid NOT NULL REFERENCES public.pdv_collaborators(id),
  opened_at         timestamptz NOT NULL DEFAULT now(),
  first_order_at    timestamptz,
  closed_at         timestamptz,
  received_at       timestamptz,
  cancelled_reason  text,
  last_activity_by  uuid REFERENCES public.pdv_collaborators(id),
  last_activity_at  timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
-- Um número de comanda só pode estar em uso por uma comanda viva por vez
CREATE UNIQUE INDEX pdv_cards_numero_em_uso
  ON public.pdv_cards (card_number) WHERE status IN ('aberta','fechada');
CREATE INDEX pdv_cards_status_idx ON public.pdv_cards (status);

-- Pedido = um "ENVIAR PEDIDO"
CREATE TABLE public.pdv_card_orders (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  card_id       uuid NOT NULL REFERENCES public.pdv_cards(id),
  terminal_id   uuid REFERENCES public.pdv_terminals(id),
  created_by    uuid NOT NULL REFERENCES public.pdv_collaborators(id),
  table_number  text,
  print_status  text NOT NULL DEFAULT 'pendente'
                  CHECK (print_status IN ('pendente','enviado','falha','parcial')),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pdv_card_orders_card_idx ON public.pdv_card_orders (card_id);

-- Itens lançados. Só acrescenta; cancelar marca, não apaga.
CREATE TABLE public.pdv_card_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id             uuid NOT NULL REFERENCES public.pdv_card_orders(id),
  -- redundante de propósito: na transferência a comanda muda, o pedido não
  card_id              uuid NOT NULL REFERENCES public.pdv_cards(id),
  menu_item_id         uuid REFERENCES public.pdv_menu_items(id) ON DELETE SET NULL,
  item_name            text   NOT NULL,                        -- congelado no lançamento
  quantity             int    NOT NULL CHECK (quantity > 0),
  unit_price_cents     bigint NOT NULL CHECK (unit_price_cents >= 0),  -- congelado no lançamento
  total_cents          bigint GENERATED ALWAYS AS (quantity * unit_price_cents) STORED,
  production_point_id  uuid NOT NULL REFERENCES public.pdv_production_points(id),
  notes                text,
  status               text NOT NULL DEFAULT 'ativo' CHECK (status IN ('ativo','cancelado')),
  cancelled_by         uuid REFERENCES public.pdv_collaborators(id),
  cancelled_reason     text,
  cancelled_at         timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  -- cancelamento sempre com autor e motivo
  CHECK (
    status = 'ativo'
    OR (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL
        AND length(btrim(coalesce(cancelled_reason, ''))) > 0)
  )
);
CREATE INDEX pdv_card_items_card_idx  ON public.pdv_card_items (card_id);
CREATE INDEX pdv_card_items_order_idx ON public.pdv_card_items (order_id);

-- Auditoria de transferência entre comandas
CREATE TABLE public.pdv_card_transfers (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_card_id  uuid NOT NULL REFERENCES public.pdv_cards(id),
  to_card_id    uuid NOT NULL REFERENCES public.pdv_cards(id),
  items         jsonb  NOT NULL,
  amount_cents  bigint NOT NULL CHECK (amount_cents >= 0),
  created_by    uuid NOT NULL REFERENCES public.pdv_collaborators(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (from_card_id <> to_card_id)
);

-- Recebimentos. Aceita parcial e várias formas na mesma conta.
-- amount_cents = o que abate da conta e o que entra na gaveta.
-- change_cents = troco (mecânica física; NÃO soma na gaveta).
CREATE TABLE public.pdv_payments (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  card_id               uuid NOT NULL REFERENCES public.pdv_cards(id),
  session_id            uuid NOT NULL REFERENCES public.pdv_cash_sessions(id),
  method                text NOT NULL
                          CHECK (method IN ('dinheiro','pix','credito','debito','voucher')),
  amount_cents          bigint NOT NULL CHECK (amount_cents > 0),
  change_cents          bigint NOT NULL DEFAULT 0 CHECK (change_cents >= 0),
  -- troco só existe em dinheiro
  CHECK (method = 'dinheiro' OR change_cents = 0),
  cielo_transaction_id  text,
  cielo_nsu             text,
  cielo_authorization   text,
  received_by           uuid NOT NULL REFERENCES public.pdv_collaborators(id),
  received_at           timestamptz NOT NULL DEFAULT now(),
  fiscal_reference      text   -- reservado para o módulo fiscal (fora da v1)
);
CREATE INDEX pdv_payments_card_idx    ON public.pdv_payments (card_id);
CREATE INDEX pdv_payments_session_idx ON public.pdv_payments (session_id);


-- =====================================================================
-- GUARDA NO BANCO: dinheiro só entra em caixa ABERTO
-- (risco "divergência de caixa por pagamento fora da sessão", §9 da spec)
-- Vale para recebimento e para sangria/suprimento.
-- Obs.: itens lançados NÃO têm essa trava de propósito. Se um terminal
-- lançou offline e a comanda foi fechada em outro, recusar o item perderia
-- consumo que já saiu da cozinha. Esse conflito é tratado na sincronização.
-- =====================================================================
CREATE FUNCTION public.pdv_exige_caixa_aberto()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.pdv_cash_sessions
    WHERE id = NEW.session_id AND status = 'aberta'
  ) THEN
    RAISE EXCEPTION 'Recusado: a sessão de caixa % não está aberta', NEW.session_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER pdv_payments_exige_caixa_aberto
  BEFORE INSERT ON public.pdv_payments
  FOR EACH ROW EXECUTE FUNCTION public.pdv_exige_caixa_aberto();

CREATE TRIGGER pdv_cash_movements_exige_caixa_aberto
  BEFORE INSERT ON public.pdv_cash_movements
  FOR EACH ROW EXECUTE FUNCTION public.pdv_exige_caixa_aberto();


-- =====================================================================
-- updated_at automático
-- =====================================================================
CREATE TRIGGER pdv_settings_updated_at          BEFORE UPDATE ON public.pdv_settings          FOR EACH ROW EXECUTE FUNCTION public.pdv_set_updated_at();
CREATE TRIGGER pdv_production_points_updated_at BEFORE UPDATE ON public.pdv_production_points FOR EACH ROW EXECUTE FUNCTION public.pdv_set_updated_at();
CREATE TRIGGER pdv_terminals_updated_at         BEFORE UPDATE ON public.pdv_terminals         FOR EACH ROW EXECUTE FUNCTION public.pdv_set_updated_at();
CREATE TRIGGER pdv_collaborators_updated_at     BEFORE UPDATE ON public.pdv_collaborators     FOR EACH ROW EXECUTE FUNCTION public.pdv_set_updated_at();
CREATE TRIGGER pdv_menu_categories_updated_at   BEFORE UPDATE ON public.pdv_menu_categories   FOR EACH ROW EXECUTE FUNCTION public.pdv_set_updated_at();
CREATE TRIGGER pdv_menu_items_updated_at        BEFORE UPDATE ON public.pdv_menu_items        FOR EACH ROW EXECUTE FUNCTION public.pdv_set_updated_at();
CREATE TRIGGER pdv_cash_sessions_updated_at     BEFORE UPDATE ON public.pdv_cash_sessions     FOR EACH ROW EXECUTE FUNCTION public.pdv_set_updated_at();
CREATE TRIGGER pdv_cards_updated_at             BEFORE UPDATE ON public.pdv_cards             FOR EACH ROW EXECUTE FUNCTION public.pdv_set_updated_at();


-- =====================================================================
-- RLS: ligado em tudo, NENHUMA política.
-- A chave pública não enxerga nada até o próximo passo definir o acesso.
-- =====================================================================
ALTER TABLE public.pdv_settings          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_production_points ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_terminals         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_collaborators     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_menu_categories   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_menu_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_cash_sessions     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_cash_movements    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_cards             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_card_orders       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_card_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_card_transfers    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pdv_payments          ENABLE ROW LEVEL SECURITY;


-- =====================================================================
-- DADOS INICIAIS (só configuração; cardápio e equipe em passo separado)
-- =====================================================================

-- As 4 térmicas, IPs confirmados em campo em 03/09/2026
INSERT INTO public.pdv_production_points (code, name, printer_ip, notes) VALUES
  ('caixa',   'Caixa',          '192.168.0.70', 'Elgin i9 S/N 23575294 · firmware CV2.00.13 · também é ponto de produção dos sorvetes'),
  ('cozinha', 'Cozinha',        '192.168.0.71', 'Elgin i9 · IP confirmado em campo 03/09/2026'),
  ('drink',   'Bar de drink',   '192.168.0.72', 'Elgin i9 S/N 23010650 · firmware CV2.00.19 · botão AVANÇO suspeito (autoteste espontâneo 03/09)'),
  ('cerveja', 'Bar de cerveja', '192.168.0.73', 'Elgin i9 S/N 23015402 · firmware CV2.00.19');

-- Único terminal inventariado até agora (há pelo menos 3 na operação)
INSERT INTO public.pdv_terminals (label, serial_number, cielo_store_id, terminal_number) VALUES
  ('L400 · Terminal 10', '4AK38M35I', '9400', 10);

INSERT INTO public.pdv_settings (key, value, description) VALUES
  ('service_fee_percent',      '10',   'Taxa de serviço. Confirmada com a operação (Aurimar, 03/09/2026)'),
  ('card_number_min',          '0',    'Menor número de comanda (Aurimar, 03/09/2026)'),
  ('card_number_max',          '100',  'Maior número de comanda (Aurimar, 03/09/2026). [A CONFIRMAR] o levantamento de 31/08 viu comandas 124, 1959, 2000 e 2001 no TOTVS'),
  ('receipt_header',           'MADE IN BRAZIL BAR', 'Cabeçalho dos cupons'),
  ('receipt_footer',           'NÃO É DOCUMENTO FISCAL', 'Rodapé obrigatório enquanto o módulo fiscal está fora do escopo'),
  ('print_retry_max',          '3',    'Tentativas de impressão antes de marcar falha'),
  ('print_connect_timeout_ms', '2000', 'Tempo máximo para conectar na térmica (porta 9100)');

COMMIT;

-- =====================================================================
-- Made in Brazil Delivery — Fundação do banco
-- Projeto Lovable: 477c32ee-21dd-404d-b2a5-fd76286419f8 (mesmo servidor do PDV)
-- Spec: _docs/especificacao-modulo-delivery.md (repo do bar)
--
-- Regras de convivência com o PDV:
--   * Tudo com prefixo dlv_. NENHUMA tabela ou função pdv_* é alterada.
--   * Reaproveita (só leitura): pdv_production_points (térmicas),
--     pdv_panel_users / pdv_is_panel_user() (login do painel) e
--     pdv_terminals / pdv_is_terminal() (estação de impressão).
--
-- Mesmas regras de dinheiro do PDV: centavos (bigint), nome e preço
-- congelados no pedido, preço sempre recalculado no servidor.
--
-- Acesso: RLS ligado em tudo. O anônimo NÃO lê nem grava tabela nenhuma;
-- o cliente do cardápio só chama as funções públicas da migration de regras.
-- O painel lê tudo e edita cardápio/entrega/motoboys; pedido só muda por função.
-- =====================================================================

BEGIN;

CREATE FUNCTION public.dlv_set_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


-- =====================================================================
-- CONFIGURAÇÃO DA LOJA
-- =====================================================================

CREATE TABLE public.dlv_settings (
  key          text PRIMARY KEY,
  value        text NOT NULL,
  description  text,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- Horário de funcionamento. weekday igual ao Postgres: 0 = domingo ... 6 = sábado
CREATE TABLE public.dlv_opening_hours (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  weekday    smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  opens_at   time NOT NULL,
  closes_at  time NOT NULL,
  CHECK (closes_at > opens_at)
);

-- Taxa por distância em faixas: vale a menor faixa que cobre a distância
CREATE TABLE public.dlv_delivery_bands (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  max_km      numeric(5,2) NOT NULL UNIQUE CHECK (max_km > 0),
  fee_cents   bigint NOT NULL CHECK (fee_cents >= 0),
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);


-- =====================================================================
-- CARDÁPIO DO DELIVERY (próprio, separado dos 180 itens do PDV — decisão D1)
-- =====================================================================

CREATE TABLE public.dlv_categories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(btrim(name)) > 0),
  sort_order  int  NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true,
  anota_id    text UNIQUE,  -- origem no Anota, só para rastrear a importação
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.dlv_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id          uuid NOT NULL REFERENCES public.dlv_categories(id),
  name                 text NOT NULL CHECK (length(btrim(name)) > 0),
  description          text,
  price_cents          bigint NOT NULL CHECK (price_cents >= 0),
  image_url            text,
  production_point_id  uuid NOT NULL REFERENCES public.pdv_production_points(id),
  -- dias em que o item aparece (0 = domingo). NULL = todos os dias que a loja abre
  weekdays             smallint[] CHECK (weekdays IS NULL OR weekdays <@ ARRAY[0,1,2,3,4,5,6]::smallint[]),
  is_paused            boolean NOT NULL DEFAULT false,   -- some do cardápio
  is_out_of_stock      boolean NOT NULL DEFAULT false,   -- aparece como esgotado
  sort_order           int  NOT NULL DEFAULT 0,
  is_active            boolean NOT NULL DEFAULT true,    -- "apagado" sem perder histórico
  anota_id             text UNIQUE,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dlv_items_category_idx ON public.dlv_items (category_id);

-- Grupo de complementos ("Escolha o Acompanhamento", "+ Proteína"...)
CREATE TABLE public.dlv_option_groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(btrim(name)) > 0),
  sort_order  int  NOT NULL DEFAULT 0,
  is_active   boolean NOT NULL DEFAULT true,
  anota_id    text UNIQUE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.dlv_options (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id             uuid NOT NULL REFERENCES public.dlv_option_groups(id),
  name                 text NOT NULL CHECK (length(btrim(name)) > 0),
  extra_cents          bigint NOT NULL DEFAULT 0 CHECK (extra_cents >= 0),
  -- NULL = sai junto com o item (ex.: acompanhamento). Preenchido = outro ponto (ex.: bebida)
  production_point_id  uuid REFERENCES public.pdv_production_points(id),
  is_paused            boolean NOT NULL DEFAULT false,
  is_out_of_stock      boolean NOT NULL DEFAULT false,
  sort_order           int  NOT NULL DEFAULT 0,
  is_active            boolean NOT NULL DEFAULT true,
  anota_id             text UNIQUE,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dlv_options_group_idx ON public.dlv_options (group_id);

-- Quais grupos cada item pede, com mínimo e máximo PRÓPRIOS do item
-- (no Anota o mesmo grupo tem regra diferente em cada prato)
CREATE TABLE public.dlv_item_option_groups (
  item_id      uuid NOT NULL REFERENCES public.dlv_items(id),
  group_id     uuid NOT NULL REFERENCES public.dlv_option_groups(id),
  min_choices  int  NOT NULL DEFAULT 0 CHECK (min_choices >= 0),
  max_choices  int  NOT NULL DEFAULT 1 CHECK (max_choices >= 1),
  sort_order   int  NOT NULL DEFAULT 0,
  PRIMARY KEY (item_id, group_id),
  CHECK (max_choices >= min_choices)
);


-- =====================================================================
-- CLIENTES
-- =====================================================================

CREATE TABLE public.dlv_customers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone              text NOT NULL UNIQUE CHECK (phone ~ '^[0-9]{10,11}$'),  -- DDD + número, só dígitos
  name               text NOT NULL CHECK (length(btrim(name)) > 0),
  -- consentimento para mensagem de marketing no WhatsApp: nasce DESMARCADO (LGPD)
  marketing_consent  boolean NOT NULL DEFAULT false,
  consent_at         timestamptz,
  orders_count       int NOT NULL DEFAULT 0 CHECK (orders_count >= 0),
  last_order_at      timestamptz,
  source             text NOT NULL DEFAULT 'cardapio' CHECK (source IN ('cardapio', 'painel', 'anota')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.dlv_customer_addresses (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id   uuid NOT NULL REFERENCES public.dlv_customers(id),
  street        text NOT NULL,
  number        text,
  neighborhood  text,
  complement    text,
  reference     text,
  postal_code   text,
  city          text,
  lat           double precision CHECK (lat BETWEEN -90 AND 90),
  lng           double precision CHECK (lng BETWEEN -180 AND 180),
  last_used_at  timestamptz NOT NULL DEFAULT now(),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dlv_customer_addresses_customer_idx ON public.dlv_customer_addresses (customer_id);


-- =====================================================================
-- ENTREGA PRÓPRIA
-- =====================================================================

CREATE TABLE public.dlv_couriers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(btrim(name)) > 0),
  phone       text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);


-- =====================================================================
-- PEDIDOS
-- =====================================================================

-- Numeração curta para a operação. Começa em 5000 para não confundir com o Anota (#44xx)
CREATE SEQUENCE public.dlv_order_number_seq START 5000;

CREATE TABLE public.dlv_orders (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  number                int  NOT NULL UNIQUE DEFAULT nextval('public.dlv_order_number_seq'),
  -- código do link de acompanhamento: longo e impossível de adivinhar
  public_code           text NOT NULL UNIQUE DEFAULT replace(gen_random_uuid()::text, '-', ''),
  mode                  text NOT NULL CHECK (mode IN ('entrega', 'retirada')),
  status                text NOT NULL CHECK (status IN (
                          'aguardando_pagamento', 'em_analise', 'em_producao',
                          'pronto', 'saiu_entrega', 'finalizado', 'cancelado')),
  cancel_kind           text CHECK (cancel_kind IN ('recusado', 'cancelado', 'pix_expirado')),
  source                text NOT NULL DEFAULT 'cardapio' CHECK (source IN ('cardapio', 'painel')),

  -- cliente congelado no pedido
  customer_id           uuid REFERENCES public.dlv_customers(id),
  customer_name         text NOT NULL,
  customer_phone        text NOT NULL,

  -- endereço congelado no pedido (só entrega)
  address_street        text,
  address_number        text,
  address_neighborhood  text,
  address_complement    text,
  address_reference     text,
  address_postal_code   text,
  address_city          text,
  lat                   double precision,
  lng                   double precision,
  distance_km           numeric(6,2),

  -- dinheiro
  subtotal_cents        bigint NOT NULL CHECK (subtotal_cents >= 0),
  delivery_fee_cents    bigint NOT NULL DEFAULT 0 CHECK (delivery_fee_cents >= 0),
  discount_cents        bigint NOT NULL DEFAULT 0 CHECK (discount_cents >= 0),
  total_cents           bigint GENERATED ALWAYS AS (subtotal_cents + delivery_fee_cents - discount_cents) STORED,
  payment_method        text NOT NULL CHECK (payment_method IN ('pix_online', 'pix_entrega', 'dinheiro', 'credito', 'debito')),
  change_for_cents      bigint CHECK (change_for_cents > 0),   -- "troco para quanto"
  paid_at               timestamptz,
  mp_payment_id         text UNIQUE,     -- Mercado Pago (Pix online)
  pix_copy_paste        text,
  pix_expires_at        timestamptz,

  courier_id            uuid REFERENCES public.dlv_couriers(id),
  notes                 text,

  -- horário de cada etapa
  accepted_at           timestamptz,
  ready_at              timestamptz,
  dispatched_at         timestamptz,
  finished_at           timestamptz,
  cancelled_at          timestamptz,
  cancel_reason         text,
  last_status_by_name   text,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),

  CHECK (discount_cents <= subtotal_cents + delivery_fee_cents),
  CHECK (mode = 'retirada' OR (address_street IS NOT NULL AND lat IS NOT NULL AND lng IS NOT NULL)),
  CHECK (change_for_cents IS NULL OR payment_method = 'dinheiro'),
  CHECK (status <> 'cancelado' OR (cancel_kind IS NOT NULL AND cancelled_at IS NOT NULL)),
  -- Pix online só passa de "aguardando pagamento" com pagamento confirmado
  CHECK (payment_method <> 'pix_online' OR status IN ('aguardando_pagamento', 'cancelado') OR paid_at IS NOT NULL),
  -- saiu para entrega exige ser entrega e ter motoboy
  CHECK (status <> 'saiu_entrega' OR (mode = 'entrega' AND courier_id IS NOT NULL))
);
CREATE INDEX dlv_orders_status_idx     ON public.dlv_orders (status);
CREATE INDEX dlv_orders_created_idx    ON public.dlv_orders (created_at DESC);
CREATE INDEX dlv_orders_customer_idx   ON public.dlv_orders (customer_id);
CREATE INDEX dlv_orders_phone_open_idx ON public.dlv_orders (customer_phone)
  WHERE status IN ('aguardando_pagamento', 'em_analise', 'em_producao', 'pronto', 'saiu_entrega');

CREATE TABLE public.dlv_order_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id             uuid NOT NULL REFERENCES public.dlv_orders(id),
  item_id              uuid REFERENCES public.dlv_items(id) ON DELETE SET NULL,
  item_name            text   NOT NULL,                                 -- congelado
  quantity             int    NOT NULL CHECK (quantity > 0),
  unit_price_cents     bigint NOT NULL CHECK (unit_price_cents >= 0),  -- item + complementos, por unidade, congelado
  total_cents          bigint GENERATED ALWAYS AS (quantity * unit_price_cents) STORED,
  production_point_id  uuid NOT NULL REFERENCES public.pdv_production_points(id),
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dlv_order_items_order_idx ON public.dlv_order_items (order_id);

CREATE TABLE public.dlv_order_item_options (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id        uuid NOT NULL REFERENCES public.dlv_order_items(id),
  option_id            uuid REFERENCES public.dlv_options(id) ON DELETE SET NULL,
  group_name           text   NOT NULL,                             -- congelado
  option_name          text   NOT NULL,                             -- congelado
  quantity             int    NOT NULL DEFAULT 1 CHECK (quantity > 0),  -- por unidade do item
  extra_cents          bigint NOT NULL CHECK (extra_cents >= 0),        -- congelado
  production_point_id  uuid NOT NULL REFERENCES public.pdv_production_points(id)
);
CREATE INDEX dlv_order_item_options_item_idx ON public.dlv_order_item_options (order_item_id);

-- Auditoria: toda mudança de etapa, com quem e quando
CREATE TABLE public.dlv_order_events (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id     uuid NOT NULL REFERENCES public.dlv_orders(id),
  from_status  text,
  to_status    text NOT NULL,
  by_name      text NOT NULL,
  note         text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dlv_order_events_order_idx ON public.dlv_order_events (order_id);


-- =====================================================================
-- IMPRESSÃO (a estação dentro do bar consome esta fila)
-- =====================================================================

CREATE TABLE public.dlv_print_jobs (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id             uuid NOT NULL REFERENCES public.dlv_orders(id),
  production_point_id  uuid NOT NULL REFERENCES public.pdv_production_points(id),
  -- producao = o que o ponto prepara · via_entrega = pedido completo (caixa/motoboy)
  -- cancelamento = aviso "PEDIDO CANCELADO" para quem já recebeu o cupom de produção
  kind                 text NOT NULL CHECK (kind IN ('producao', 'via_entrega', 'cancelamento')),
  status               text NOT NULL DEFAULT 'pendente' CHECK (status IN ('pendente', 'reservado', 'impresso', 'falha', 'cancelado')),
  attempts             int  NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  reserved_by          uuid REFERENCES public.pdv_terminals(id),
  reserved_at          timestamptz,
  printed_at           timestamptz,
  last_error           text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dlv_print_jobs_pending_idx ON public.dlv_print_jobs (created_at) WHERE status IN ('pendente', 'reservado');
CREATE INDEX dlv_print_jobs_order_idx   ON public.dlv_print_jobs (order_id);

-- Último sinal de vida de cada estação (o painel mostra "estação fora do ar")
CREATE TABLE public.dlv_station_heartbeats (
  terminal_id   uuid PRIMARY KEY REFERENCES public.pdv_terminals(id),
  last_seen_at  timestamptz NOT NULL DEFAULT now()
);


-- =====================================================================
-- updated_at automático
-- =====================================================================
CREATE TRIGGER dlv_settings_updated_at        BEFORE UPDATE ON public.dlv_settings        FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();
CREATE TRIGGER dlv_delivery_bands_updated_at  BEFORE UPDATE ON public.dlv_delivery_bands  FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();
CREATE TRIGGER dlv_categories_updated_at      BEFORE UPDATE ON public.dlv_categories      FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();
CREATE TRIGGER dlv_items_updated_at           BEFORE UPDATE ON public.dlv_items           FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();
CREATE TRIGGER dlv_option_groups_updated_at   BEFORE UPDATE ON public.dlv_option_groups   FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();
CREATE TRIGGER dlv_options_updated_at         BEFORE UPDATE ON public.dlv_options         FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();
CREATE TRIGGER dlv_customers_updated_at       BEFORE UPDATE ON public.dlv_customers       FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();
CREATE TRIGGER dlv_couriers_updated_at        BEFORE UPDATE ON public.dlv_couriers        FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();
CREATE TRIGGER dlv_orders_updated_at          BEFORE UPDATE ON public.dlv_orders          FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();
CREATE TRIGGER dlv_print_jobs_updated_at      BEFORE UPDATE ON public.dlv_print_jobs      FOR EACH ROW EXECUTE FUNCTION public.dlv_set_updated_at();


-- =====================================================================
-- ACESSO
-- =====================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'dlv_settings','dlv_opening_hours','dlv_delivery_bands',
    'dlv_categories','dlv_items','dlv_option_groups','dlv_options','dlv_item_option_groups',
    'dlv_customers','dlv_customer_addresses','dlv_couriers',
    'dlv_orders','dlv_order_items','dlv_order_item_options','dlv_order_events',
    'dlv_print_jobs','dlv_station_heartbeats'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM anon, authenticated', t);
    -- painel lê tudo
    EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.pdv_is_panel_user())',
      'painel le ' || t, t
    );
  END LOOP;

  -- painel edita cardápio, loja, entrega e motoboys (sem apagar: desativa)
  FOREACH t IN ARRAY ARRAY[
    'dlv_settings','dlv_opening_hours','dlv_delivery_bands',
    'dlv_categories','dlv_items','dlv_option_groups','dlv_options','dlv_item_option_groups',
    'dlv_couriers'
  ] LOOP
    EXECUTE format('GRANT INSERT, UPDATE ON TABLE public.%I TO authenticated', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (public.pdv_is_panel_user())',
      'painel cria ' || t, t
    );
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (public.pdv_is_panel_user()) WITH CHECK (public.pdv_is_panel_user())',
      'painel edita ' || t, t
    );
  END LOOP;
END $$;

-- exceções de apagar: horário e vínculo item↔grupo são configuração pura, sem histórico
GRANT DELETE ON TABLE public.dlv_opening_hours, public.dlv_item_option_groups TO authenticated;
CREATE POLICY "painel apaga dlv_opening_hours"      ON public.dlv_opening_hours      FOR DELETE TO authenticated USING (public.pdv_is_panel_user());
CREATE POLICY "painel apaga dlv_item_option_groups" ON public.dlv_item_option_groups FOR DELETE TO authenticated USING (public.pdv_is_panel_user());

-- pedido novo aparece sozinho no painel
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.dlv_orders, public.dlv_print_jobs, public.dlv_station_heartbeats;
  END IF;
END $$;


-- =====================================================================
-- DADOS INICIAIS (levantados no Anota em 14/09/2026 + decisões do Gabriel)
-- =====================================================================
INSERT INTO public.dlv_settings (key, value, description) VALUES
  ('store_mode',              'auto',       'auto = segue o horário · aberta = força aberta · fechada = força fechada'),
  ('min_order_cents',         '1500',       'Pedido mínimo, sem contar a taxa de entrega (Gabriel, 14/09: R$ 15)'),
  ('delivery_time_min',       '45',         'Tempo prometido de entrega, mínimo (min) — igual ao Anota'),
  ('delivery_time_max',       '60',         'Tempo prometido de entrega, máximo (min)'),
  ('pickup_time_min',         '20',         'Tempo prometido de retirada, mínimo (min)'),
  ('pickup_time_max',         '30',         'Tempo prometido de retirada, máximo (min)'),
  ('auto_accept',             'true',       'Aceita pedido sozinho e já manda imprimir (hoje ligado no Anota)'),
  ('bar_lat',                 '-20.81425',  'Latitude do bar: centro das áreas de entrega do Anota. [A CONFIRMAR] no mapa'),
  ('bar_lng',                 '-49.37520',  'Longitude do bar: centro das áreas de entrega do Anota. [A CONFIRMAR] no mapa'),
  ('pix_expiration_minutes',  '15',         'Tempo para pagar o Pix online antes do pedido cancelar sozinho'),
  ('max_open_orders_per_phone','3',         'Pedidos em andamento por telefone (contra trote)'),
  ('receipt_point_code',      'caixa',      'Térmica que imprime a via completa do pedido (entrega/retirada)'),
  ('station_offline_seconds', '90',         'Sem sinal da estação por mais que isso = painel avisa "estação fora do ar"');

-- segunda a sexta, 10h às 14h (sábado e domingo não abre)
INSERT INTO public.dlv_opening_hours (weekday, opens_at, closes_at)
SELECT d, '10:00', '14:00' FROM generate_series(1, 5) AS d;

-- faixas do Anota (círculos a partir do bar)
INSERT INTO public.dlv_delivery_bands (max_km, fee_cents) VALUES
  (2, 0), (4, 500), (7, 1000), (9, 1500), (10, 1800);

INSERT INTO public.dlv_couriers (name) VALUES ('Italo'), ('Lucas');

COMMIT;

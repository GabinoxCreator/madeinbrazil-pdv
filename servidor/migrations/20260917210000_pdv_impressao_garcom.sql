-- =====================================================================
-- Impressão dos pedidos lançados fora do app (painel do caixa e tela /garcom)
--
-- Quem fala com as térmicas é sempre um aparelho Android na rede do bar.
-- O app que lança o pedido imprime sozinho; o navegador não alcança a
-- impressora, então o pedido lançado por ele vira trabalho nesta fila e a
-- estação de impressão (o mesmo aparelho que já atende o delivery) imprime.
--
-- SEM CUPOM EM DOBRO: o app Android grava os itens direto nas tabelas
-- (pdv_card_orders / pdv_card_items) pelo motor de sincronização e NUNCA
-- chama pdv_lancar_pedido. Só o que passa por esta função enfileira.
--
-- Espelha a fila do delivery de propósito (mesmas colunas, mesmos estados,
-- mesma reserva de 2 min, mesmo teto de 5 tentativas) e reaproveita a
-- identidade da estação (dlv__exigir_estacao) e o sinal de vida
-- (dlv_station_heartbeats): uma estação só, duas filas.
-- =====================================================================

BEGIN;

CREATE TABLE public.pdv_print_jobs (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id             uuid NOT NULL REFERENCES public.pdv_card_orders(id),
  card_id              uuid NOT NULL REFERENCES public.pdv_cards(id),
  production_point_id  uuid NOT NULL REFERENCES public.pdv_production_points(id),
  -- por enquanto só produção; cancelamento e reimpressão ficam para depois
  kind                 text NOT NULL DEFAULT 'producao' CHECK (kind IN ('producao')),
  status               text NOT NULL DEFAULT 'pendente' CHECK (status IN ('pendente', 'reservado', 'impresso', 'falha', 'cancelado')),
  attempts             int  NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  reserved_by          uuid REFERENCES public.pdv_terminals(id),
  reserved_at          timestamptz,
  printed_at           timestamptz,
  last_error           text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pdv_print_jobs_pending_idx ON public.pdv_print_jobs (created_at) WHERE status IN ('pendente', 'reservado');
CREATE INDEX pdv_print_jobs_order_idx   ON public.pdv_print_jobs (order_id);

CREATE TRIGGER pdv_print_jobs_updated_at BEFORE UPDATE ON public.pdv_print_jobs
  FOR EACH ROW EXECUTE FUNCTION public.pdv_set_updated_at();

-- ---------------------------------------------------------------------
-- Conteúdo do cupom: o que a estação recebe para imprimir
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv__conteudo_impressao(p_trabalho uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE j record; o record; c record; pp record; v_itens jsonb;
BEGIN
  SELECT * INTO j FROM public.pdv_print_jobs WHERE id = p_trabalho;
  SELECT * INTO o FROM public.pdv_card_orders WHERE id = j.order_id;
  SELECT * INTO c FROM public.pdv_cards WHERE id = j.card_id;
  SELECT code, name, host(printer_ip) AS ip, printer_port INTO pp
    FROM public.pdv_production_points WHERE id = j.production_point_id;

  -- item cancelado depois do lançamento não vai para a produção
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'nome', i.item_name, 'quantidade', i.quantity, 'observacao', i.notes
         ) ORDER BY i.created_at, i.id), '[]'::jsonb)
    INTO v_itens
    FROM public.pdv_card_items i
   WHERE i.order_id = o.id
     AND i.production_point_id = j.production_point_id
     AND i.status = 'ativo';

  RETURN jsonb_build_object(
    'trabalho_id', j.id,
    'tipo', j.kind,
    'ponto', jsonb_build_object('codigo', pp.code, 'nome', pp.name, 'ip', pp.ip, 'porta', pp.printer_port),
    'comanda', jsonb_build_object(
      'numero', c.card_number, 'mesa', coalesce(o.table_number, c.table_number),
      'cliente', c.customer_name, 'pessoas', c.people_count, 'controle', c.is_control_card
    ),
    'pedido', jsonb_build_object(
      'criado_em', o.created_at, 'operador', o.created_by_name, 'origem', 'navegador'
    ),
    'itens', v_itens
  );
END;
$$;

-- ---------------------------------------------------------------------
-- Um cupom por ponto de produção do pedido
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv__gerar_impressao(p_pedido uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_qtd int;
BEGIN
  INSERT INTO public.pdv_print_jobs (order_id, card_id, production_point_id, kind)
  SELECT DISTINCT p_pedido, o.card_id, i.production_point_id, 'producao'
    FROM public.pdv_card_items i
    JOIN public.pdv_card_orders o ON o.id = i.order_id
   WHERE i.order_id = p_pedido AND i.status = 'ativo';
  GET DIAGNOSTICS v_qtd = ROW_COUNT;
  RETURN v_qtd;
END;
$$;

-- ---------------------------------------------------------------------
-- Estação: reservar e concluir (mesma conta e mesmo sinal de vida do delivery)
-- ---------------------------------------------------------------------
CREATE FUNCTION public.pdv_reservar_impressoes(p_limite int DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_terminal uuid := public.dlv__exigir_estacao(); v_ids uuid[];
BEGIN
  INSERT INTO public.dlv_station_heartbeats (terminal_id, last_seen_at) VALUES (v_terminal, now())
  ON CONFLICT (terminal_id) DO UPDATE SET last_seen_at = now();

  WITH alvo AS (
    SELECT id FROM public.pdv_print_jobs
     WHERE status = 'pendente'
        OR (status = 'reservado' AND reserved_at < now() - interval '2 minutes')
     ORDER BY created_at
     LIMIT least(greatest(coalesce(p_limite, 10), 1), 50)
     FOR UPDATE SKIP LOCKED
  ), reservados AS (
    UPDATE public.pdv_print_jobs j
       SET status = 'reservado', reserved_by = v_terminal, reserved_at = now(), attempts = j.attempts + 1
      FROM alvo WHERE j.id = alvo.id
    RETURNING j.id, j.created_at
  )
  SELECT array_agg(id ORDER BY created_at) INTO v_ids FROM reservados;

  RETURN coalesce((
    SELECT jsonb_agg(public.pdv__conteudo_impressao(t.id) ORDER BY t.ord)
      FROM unnest(v_ids) WITH ORDINALITY AS t(id, ord)
  ), '[]'::jsonb);
END;
$$;

CREATE FUNCTION public.pdv_concluir_impressao(p_trabalho uuid, p_ok boolean, p_erro text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_terminal uuid := public.dlv__exigir_estacao(); j record;
BEGIN
  SELECT * INTO j FROM public.pdv_print_jobs WHERE id = p_trabalho FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Trabalho de impressão não encontrado'; END IF;

  INSERT INTO public.dlv_station_heartbeats (terminal_id, last_seen_at) VALUES (v_terminal, now())
  ON CONFLICT (terminal_id) DO UPDATE SET last_seen_at = now();

  IF j.status <> 'reservado' THEN RETURN; END IF;  -- já resolvido por outro caminho
  IF coalesce(p_ok, false) THEN
    UPDATE public.pdv_print_jobs SET status = 'impresso', printed_at = now(), last_error = NULL WHERE id = j.id;
    UPDATE public.pdv_card_orders SET print_status = 'enviado'
     WHERE id = j.order_id
       AND NOT EXISTS (SELECT 1 FROM public.pdv_print_jobs x
                        WHERE x.order_id = j.order_id AND x.id <> j.id AND x.status <> 'impresso');
  ELSE
    UPDATE public.pdv_print_jobs
       SET status = CASE WHEN j.attempts >= 5 THEN 'falha' ELSE 'pendente' END,
           last_error = left(coalesce(nullif(btrim(p_erro), ''), 'erro não informado'), 500)
     WHERE id = j.id;
    UPDATE public.pdv_card_orders SET print_status = 'falha'
     WHERE id = j.order_id AND j.attempts >= 5;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- Lançamento pelo navegador passa a enfileirar a impressão
-- (corpo igual ao de 20260914190000, com a chamada no fim)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pdv_lancar_pedido(p_comanda uuid, p_itens jsonb, p_operador text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c record; m record; r record;
  v_pedido uuid := gen_random_uuid();
BEGIN
  PERFORM public.pdv__exigir_operador();
  IF length(btrim(coalesce(p_operador, ''))) = 0 THEN RAISE EXCEPTION 'Informe quem está operando'; END IF;
  SELECT * INTO c FROM public.pdv_cards WHERE id = p_comanda FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comanda não encontrada'; END IF;
  IF c.status <> 'aberta' THEN
    RAISE EXCEPTION 'Comanda % está %, não aceita lançamento', c.card_number, c.status;
  END IF;
  IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' OR jsonb_array_length(p_itens) = 0 THEN
    RAISE EXCEPTION 'Nenhum item escolhido';
  END IF;

  INSERT INTO public.pdv_card_orders (id, card_id, created_by_name, table_number)
  VALUES (v_pedido, c.id, p_operador, c.table_number);

  FOR r IN SELECT * FROM jsonb_to_recordset(p_itens) AS x(menu_item_id uuid, quantidade integer, observacao text) LOOP
    SELECT * INTO m FROM public.pdv_menu_items WHERE id = r.menu_item_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Item do cardápio não encontrado ou inativo'; END IF;
    IF coalesce(r.quantidade, 0) <= 0 THEN RAISE EXCEPTION 'Quantidade inválida para %', m.name; END IF;
    -- nome, preço e ponto de produção vêm do cardápio do servidor e ficam congelados
    INSERT INTO public.pdv_card_items (
      order_id, card_id, menu_item_id, item_name, quantity, unit_price_cents, production_point_id, notes
    ) VALUES (
      v_pedido, c.id, m.id, m.name, r.quantidade, m.price_cents, m.production_point_id, nullif(btrim(r.observacao), '')
    );
  END LOOP;

  UPDATE public.pdv_cards
     SET first_order_at = coalesce(first_order_at, now()),
         last_activity_by_name = p_operador, last_activity_at = now()
   WHERE id = c.id;

  -- navegador não alcança a térmica: a estação de impressão imprime por ele
  PERFORM public.pdv__gerar_impressao(v_pedido);
  RETURN v_pedido;
END;
$$;

-- ---------------------------------------------------------------------
-- Acesso
-- ---------------------------------------------------------------------
ALTER TABLE public.pdv_print_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.pdv_print_jobs FROM anon, authenticated;
GRANT SELECT ON TABLE public.pdv_print_jobs TO authenticated;
CREATE POLICY "painel le pdv_print_jobs" ON public.pdv_print_jobs
  FOR SELECT TO authenticated USING (public.pdv_is_panel_user());

REVOKE ALL ON FUNCTION
  public.pdv__conteudo_impressao(uuid), public.pdv__gerar_impressao(uuid),
  public.pdv_reservar_impressoes(int), public.pdv_concluir_impressao(uuid, boolean, text)
FROM PUBLIC, anon, authenticated;

-- estação de impressão (a função confere se a conta é de terminal)
GRANT EXECUTE ON FUNCTION
  public.pdv_reservar_impressoes(int), public.pdv_concluir_impressao(uuid, boolean, text)
TO authenticated;

COMMIT;

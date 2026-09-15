-- =====================================================================
-- Made in Brazil Delivery — Descrições e fotos dos pratos separados
--
-- Depois de dlv_variacoes, os 18 pratos novos herdaram a descrição do prato
-- original ("bife acebolado ou bife a cavalo", "carne ou frango"...). Aqui
-- cada um passa a citar só a própria variação, e os pratos ganham as fotos
-- novas (servidas pelo painel em /fotos-pratos/<nome>.jpg).
--
-- Aplicada no servidor em 15/09/2026 (via MCP, com OK do Gabriel).
-- Idempotente: só troca descrição que ainda tem " ou " e só grava histórico
-- quando o valor muda. Acha os pratos por categoria + nome (ids mudam entre
-- bancos). Não apaga nada.
-- =====================================================================

BEGIN;

CREATE TEMP TABLE dlv_tmp_ajuste (
  categoria  text NOT NULL,
  prato      text NOT NULL,
  descricao  text,
  foto       text
) ON COMMIT DROP;

INSERT INTO dlv_tmp_ajuste VALUES
  ('PF do Dia', 'Strogonoff de Carne',      'PF Executiva Individual. Acompanha arroz, feijão opcional, strogonoff de carne, batata palha e salada.', '/fotos-pratos/strogonoff-carne.jpg'),
  ('PF do Dia', 'Strogonoff de Frango',     'PF Executiva Individual. Acompanha arroz, feijão opcional, strogonoff de frango, batata palha e salada.', '/fotos-pratos/strogonoff-frango.jpg'),
  ('PF do Dia', 'Filé de Frango Grelhado',  'PF Executiva Individual. Acompanha arroz, feijão, filé de frango grelhado, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/file-frango-grelhado.jpg'),
  ('PF do Dia', 'Filé de Frango Empanado',  'PF Executiva Individual. Acompanha arroz, feijão, filé de frango empanado, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/file-frango-empanado.jpg'),
  ('PF do Dia', 'Bife a Cavalo',            'Pf do dia. Acompanha arroz, feijão, bife a cavalo, acompanhamento a sua escolha, legumes do dia e salada.', '/fotos-pratos/bife-a-cavalo.jpg'),
  ('PF do Dia', 'Bife Acebolado',           'Pf do dia. Acompanha arroz, feijão, bife acebolado, acompanhamento a sua escolha, legumes do dia e salada.', '/fotos-pratos/bife-acebolado.jpg'),
  ('PF do Dia', 'Parmegiana de Frango',     'Pf do dia. Acompanha arroz, feijão opcional, parmegiana de frango, acompanhamento a sua escolha e salada.', '/fotos-pratos/parmegiana-frango.jpg'),
  ('PF do Dia', 'Parmegiana de Carne',      'Pf do dia. Acompanha arroz, feijão opcional, parmegiana de carne, acompanhamento a sua escolha e salada.', '/fotos-pratos/parmegiana-carne.jpg'),
  ('PF do Dia', 'Feijoada Completa',        NULL, '/fotos-pratos/feijoada-completa.jpg'),
  ('PF do Dia', 'Só Feijoada 500g',         NULL, '/fotos-pratos/so-feijoada.jpg'),
  ('Especiais de Carne',    'Bife a Cavalo',            'Acompanha arroz, feijão, bife a cavalo, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/bife-a-cavalo.jpg'),
  ('Especiais de Carne',    'Bife Acebolado',           'Acompanha arroz, feijão, bife acebolado, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/bife-acebolado.jpg'),
  ('Especiais de Frango',   'Filé de Frango Grelhado',  'A marmita acompanha arroz, feijão, filé de frango grelhado, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/file-frango-grelhado.jpg'),
  ('Especiais de Frango',   'Filé de Frango Empanado',  'A marmita acompanha arroz, feijão, filé de frango empanado, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/file-frango-empanado.jpg'),
  ('Especiais de Peixe',    'Filé de Tilápia Empanado', 'Acompanha arroz, feijão, filé de tilápia empanado, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/tilapia-empanada.jpg'),
  ('Especiais de Peixe',    'Filé de Tilápia Grelhado', 'Acompanha arroz, feijão, filé de tilápia grelhado, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/tilapia-grelhada.jpg'),
  ('Especiais Parmegianas', 'Parmegiana de Frango',     'A marmita acompanha arroz, feijão, 1 parmegiana de frango, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/parmegiana-frango.jpg'),
  ('Especiais Parmegianas', 'Parmegiana de Carne',      'A marmita acompanha arroz, feijão, 1 parmegiana de carne, acompanhamento a sua escolha, legumes do Dia e salada.', '/fotos-pratos/parmegiana-carne.jpg'),
  ('Especiais Strogonoff',  'Strogonoff de Carne',      'A marmita acompanha arroz, feijão opcional, strogonoff de carne, batata palha e salada.', '/fotos-pratos/strogonoff-carne.jpg'),
  ('Especiais Strogonoff',  'Strogonoff de Frango',     'A marmita acompanha arroz, feijão opcional, strogonoff de frango, batata palha e salada.', '/fotos-pratos/strogonoff-frango.jpg');

CREATE TEMP TABLE dlv_tmp_alvo ON COMMIT DROP AS
SELECT i.id, i.name, i.description, i.image_url, a.descricao, a.foto
  FROM dlv_tmp_ajuste a
  JOIN public.dlv_categories c ON c.name = a.categoria
  JOIN public.dlv_items i ON i.category_id = c.id AND i.name = a.prato AND i.is_active;

DO $$
BEGIN
  IF (SELECT count(*) FROM dlv_tmp_alvo) <> 20 THEN
    RAISE EXCEPTION 'esperado 20 pratos ativos, achou %', (SELECT count(*) FROM dlv_tmp_alvo);
  END IF;
END $$;

SELECT public.dlv__registrar_mudanca('item', id, name, 'descrição', description, descricao, 'Claude (separação dos pratos)')
  FROM dlv_tmp_alvo WHERE descricao IS NOT NULL AND description ILIKE '% ou %';
SELECT public.dlv__registrar_mudanca('item', id, name, 'foto', image_url, foto, 'Claude (fotos novas)')
  FROM dlv_tmp_alvo;

UPDATE public.dlv_items i SET description = t.descricao
  FROM dlv_tmp_alvo t
 WHERE t.id = i.id AND t.descricao IS NOT NULL AND i.description ILIKE '% ou %';

UPDATE public.dlv_items i SET image_url = t.foto
  FROM dlv_tmp_alvo t
 WHERE t.id = i.id AND i.image_url IS DISTINCT FROM t.foto;

COMMIT;

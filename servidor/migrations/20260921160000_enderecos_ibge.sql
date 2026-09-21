-- Base de endereços do IBGE (CNEFE, Censo 2022) do município de São José do Rio Preto.
-- Rua + número + CEP com a coordenada da porta, dentro do nosso banco: a taxa de
-- entrega deixa de depender de adivinhação de mapa externo na hora do pedido.

CREATE TABLE IF NOT EXISTS public.dlv_enderecos (
  cep     text    NOT NULL,
  rua     text    NOT NULL,              -- normalizada: MAIÚSCULA, sem acento
  numero  integer NOT NULL,
  bairro  text,
  lat     double precision NOT NULL,
  lng     double precision NOT NULL,
  PRIMARY KEY (cep, rua, numero)
);
CREATE INDEX IF NOT EXISTS dlv_enderecos_rua_numero ON public.dlv_enderecos (rua, numero);
CREATE INDEX IF NOT EXISTS dlv_enderecos_cep_numero ON public.dlv_enderecos (cep, numero);

ALTER TABLE public.dlv_enderecos ENABLE ROW LEVEL SECURITY;
-- Ninguém lê a tabela direto: só pelas funções abaixo.
REVOKE ALL ON TABLE public.dlv_enderecos FROM PUBLIC, anon, authenticated;

-- Texto de rua comparável: maiúscula, sem acento, sem espaço sobrando.
CREATE OR REPLACE FUNCTION public.dlv__texto_rua(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT btrim(regexp_replace(
           translate(upper(coalesce(p, '')),
                     'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
                     'AAAAAEEEEIIIIOOOOOUUUUCN'),
           '\s+', ' ', 'g'));
$function$;

REVOKE ALL ON FUNCTION public.dlv__texto_rua(text) FROM PUBLIC, anon, authenticated;

-- Busca a coordenada da porta. Devolve também o quanto confiar no resultado.
CREATE OR REPLACE FUNCTION public.dlv_buscar_endereco(p_cep text, p_numero text, p_rua text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cep  text := nullif(regexp_replace(coalesce(p_cep, ''), '\D', '', 'g'), '');
  v_num  integer := nullif(regexp_replace(coalesce(p_numero, ''), '\D', '', 'g'), '')::integer;
  v_rua  text := public.dlv__texto_rua(p_rua);
  e record;
BEGIN
  IF v_num IS NOT NULL AND v_cep IS NOT NULL THEN
    SELECT * INTO e FROM public.dlv_enderecos WHERE cep = v_cep AND numero = v_num LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('lat', e.lat, 'lng', e.lng, 'bairro', e.bairro, 'precisao', 'exata');
    END IF;
  END IF;

  IF v_num IS NOT NULL AND v_rua <> '' THEN
    SELECT * INTO e FROM public.dlv_enderecos WHERE rua = v_rua AND numero = v_num LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('lat', e.lat, 'lng', e.lng, 'bairro', e.bairro, 'precisao', 'exata');
    END IF;

    -- número que não existe na base (prédio novo, numeração nova): pega o vizinho
    -- mais próximo da mesma rua, no mesmo CEP quando houver.
    SELECT * INTO e FROM public.dlv_enderecos
     WHERE rua = v_rua AND (v_cep IS NULL OR cep = v_cep) AND abs(numero - v_num) <= 300
     ORDER BY abs(numero - v_num) LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('lat', e.lat, 'lng', e.lng, 'bairro', e.bairro, 'precisao', 'aproximada');
    END IF;
  END IF;

  -- sem a rua: usa o miolo do CEP, que já é um trecho curto de rua
  IF v_cep IS NOT NULL THEN
    SELECT avg(lat) AS lat, avg(lng) AS lng, min(bairro) AS bairro INTO e
      FROM public.dlv_enderecos WHERE cep = v_cep;
    IF e.lat IS NOT NULL THEN
      RETURN jsonb_build_object('lat', e.lat, 'lng', e.lng, 'bairro', e.bairro, 'precisao', 'cep');
    END IF;
  END IF;

  RETURN jsonb_build_object('lat', NULL, 'lng', NULL, 'precisao', NULL);
END;
$function$;
REVOKE ALL ON FUNCTION public.dlv_buscar_endereco(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dlv_buscar_endereco(text, text, text) TO anon, authenticated;

-- Carga da base (lotes). Só o painel importa.
CREATE OR REPLACE FUNCTION public.dlv_importar_enderecos(p_linhas jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_qtd integer;
BEGIN
  PERFORM public.dlv__exigir_painel();
  IF jsonb_typeof(p_linhas) <> 'array' THEN RAISE EXCEPTION 'Esperava uma lista de endereços'; END IF;

  INSERT INTO public.dlv_enderecos (cep, rua, numero, bairro, lat, lng)
  SELECT regexp_replace(x->>'cep', '\D', '', 'g'),
         public.dlv__texto_rua(x->>'rua'),
         (x->>'numero')::integer,
         x->>'bairro',
         (x->>'lat')::double precision,
         (x->>'lng')::double precision
    FROM jsonb_array_elements(p_linhas) x
   WHERE x->>'cep' IS NOT NULL AND x->>'rua' IS NOT NULL AND x->>'numero' IS NOT NULL
  ON CONFLICT (cep, rua, numero) DO UPDATE
    SET lat = excluded.lat, lng = excluded.lng, bairro = excluded.bairro;

  GET DIAGNOSTICS v_qtd = ROW_COUNT;
  RETURN v_qtd;
END;
$function$;
REVOKE ALL ON FUNCTION public.dlv_importar_enderecos(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.dlv_importar_enderecos(jsonb) TO authenticated;

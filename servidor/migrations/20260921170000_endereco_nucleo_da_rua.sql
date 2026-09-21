-- O cliente digita a rua de qualquer jeito: com o número junto ("Rua Imperial 1105"),
-- sem o "Rua" ("Antônio de Godoy") ou com espaço sobrando. A busca passa a comparar
-- só o miolo do nome, que é o que identifica a rua.

CREATE OR REPLACE FUNCTION public.dlv__nucleo_rua(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT nullif(btrim(regexp_replace(
           regexp_replace(
             regexp_replace(public.dlv__texto_rua(p), '[,.]', ' ', 'g'),
             '^(RUA|AVENIDA|AV|ALAMEDA|AL|TRAVESSA|PRACA|RODOVIA|ESTRADA|VIELA|LARGO|VIA|PASSAGEM) ', ''),
           '\s+\d+\s*$', '')), '');
$function$;
REVOKE ALL ON FUNCTION public.dlv__nucleo_rua(text) FROM PUBLIC, anon, authenticated;

-- Índice por expressão: não reescreve a tabela (156 mil linhas) para nada.
CREATE INDEX IF NOT EXISTS dlv_enderecos_nucleo_numero
  ON public.dlv_enderecos (public.dlv__nucleo_rua(rua), numero);

-- Acrescenta as tentativas pelo miolo do nome, mantendo as que já existiam.
DO $do$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.dlv_buscar_endereco(text,text,text)'::regprocedure);
  a := '  -- sem a rua: usa o miolo do CEP, que já é um trecho curto de rua';
  IF position(a in d) = 0 THEN RAISE EXCEPTION 'nao achei o bloco do CEP na busca de endereco'; END IF;
  EXECUTE replace(d, a,
'  IF v_num IS NOT NULL AND v_nucleo IS NOT NULL THEN
    SELECT * INTO e FROM public.dlv_enderecos WHERE public.dlv__nucleo_rua(rua) = v_nucleo AND numero = v_num LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object(''lat'', e.lat, ''lng'', e.lng, ''bairro'', e.bairro, ''precisao'', ''exata'');
    END IF;

    SELECT * INTO e FROM public.dlv_enderecos
     WHERE public.dlv__nucleo_rua(rua) = v_nucleo AND (v_cep IS NULL OR cep = v_cep) AND abs(numero - v_num) <= 300
     ORDER BY abs(numero - v_num) LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object(''lat'', e.lat, ''lng'', e.lng, ''bairro'', e.bairro, ''precisao'', ''aproximada'');
    END IF;
  END IF;

' || a);
END
$do$;

-- declara a variável do miolo na função
DO $do$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.dlv_buscar_endereco(text,text,text)'::regprocedure);
  a := '  v_rua  text := public.dlv__texto_rua(p_rua);';
  IF position(a in d) = 0 THEN RAISE EXCEPTION 'nao achei a declaracao da rua'; END IF;
  EXECUTE replace(d, a, a || '
  v_nucleo text := public.dlv__nucleo_rua(p_rua);');
END
$do$;

-- e o número também pode vir grudado no nome da rua ("Rua Imperial 1105")
DO $do$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.dlv_buscar_endereco(text,text,text)'::regprocedure);
  a := '  v_num  integer := nullif(regexp_replace(coalesce(p_numero, ''''), ''\D'', '''', ''g''), '''')::integer;';
  IF position(a in d) = 0 THEN RAISE EXCEPTION 'nao achei a declaracao do numero'; END IF;
  EXECUTE replace(d, a, a || '
  v_num_rua integer := nullif((regexp_match(public.dlv__texto_rua(p_rua), ''\s(\d+)\s*$''))[1], '''')::integer;');
END
$do$;

DO $do$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.dlv_buscar_endereco(text,text,text)'::regprocedure);
  a := 'BEGIN
  IF v_num IS NOT NULL AND v_cep IS NOT NULL THEN';
  IF position(a in d) = 0 THEN RAISE EXCEPTION 'nao achei o inicio do corpo'; END IF;
  EXECUTE replace(d, a,
'BEGIN
  -- número digitado dentro do nome da rua conta como o número do endereço
  IF v_num IS NULL THEN v_num := v_num_rua; END IF;

  IF v_num IS NOT NULL AND v_cep IS NOT NULL THEN');
END
$do$;

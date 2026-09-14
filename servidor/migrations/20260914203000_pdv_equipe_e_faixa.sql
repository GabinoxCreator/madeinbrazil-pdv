-- PDV · equipe cadastrável pelo painel + faixa de comandas até 10000
-- Decisões do Gabriel (14/09): "maior número da comanda pode pôr 10000";
-- "equipe depois eu cadastro, mas pode colocar eu como exemplo de primeiro".

-- 1) Faixa de numeração das comandas: 0 a 10000
UPDATE public.pdv_settings SET value = '10000' WHERE key = 'card_number_max';

-- 2) Só administrador do painel mexe na equipe (helper interno, cliente não executa)
CREATE OR REPLACE FUNCTION public.pdv__exigir_admin()
RETURNS void
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.pdv_panel_users
     WHERE user_id = auth.uid() AND is_active AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Só administrador do painel pode cadastrar a equipe' USING ERRCODE = '42501';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.pdv__exigir_admin() FROM PUBLIC, anon, authenticated;

-- 3) Cadastrar ou editar colaborador (p_id nulo = novo). Desativar = p_ativo false.
--    O nome é o que aparece como operador no terminal e no painel, então não
--    pode haver dois ativos com o mesmo nome.
CREATE OR REPLACE FUNCTION public.pdv_salvar_colaborador(
  p_id uuid, p_nome text, p_funcao text, p_ativo boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_nome   text := btrim(coalesce(p_nome, ''));
  v_funcao text := btrim(coalesce(p_funcao, ''));
  v_ativo  boolean := coalesce(p_ativo, true);
  v_id     uuid;
BEGIN
  PERFORM public.pdv__exigir_admin();
  IF length(v_nome) = 0 THEN RAISE EXCEPTION 'Informe o nome do colaborador'; END IF;
  IF length(v_funcao) = 0 THEN RAISE EXCEPTION 'Informe a função do colaborador'; END IF;

  IF v_ativo AND EXISTS (
    SELECT 1 FROM public.pdv_collaborators
     WHERE is_active AND lower(btrim(name)) = lower(v_nome)
       AND (p_id IS NULL OR id <> p_id)
  ) THEN
    RAISE EXCEPTION 'Já existe colaborador ativo com o nome %', v_nome;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.pdv_collaborators (name, role, is_active)
    VALUES (v_nome, v_funcao, v_ativo)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.pdv_collaborators
       SET name = v_nome, role = v_funcao, is_active = v_ativo
     WHERE id = p_id
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Colaborador não encontrado'; END IF;
  END IF;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.pdv_salvar_colaborador(uuid, text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdv_salvar_colaborador(uuid, text, text, boolean) TO authenticated;

-- 4) Equipe inicial: Gabriel (exemplo) + os 11 nomes que já vinham dentro do
--    app (cardapio.json). Gabriel aprovou em 14/09; quem não for, desativa no painel.
INSERT INTO public.pdv_collaborators (name, role)
SELECT v.nome, v.funcao
  FROM (VALUES
    ('Gabriel', 'Gerente'),
    ('Beto', 'Atendente'), ('Eduardo', 'Atendente'), ('Jenifer', 'Atendente'), ('Leonardo', 'Atendente'),
    ('Helen', 'Bar'),
    ('Angela', 'Cozinha'), ('Karolyne', 'Cozinha'), ('Leticia', 'Cozinha'), ('Veronica', 'Cozinha'),
    ('Dani', 'Outro'), ('Jennifer', 'Outro')
  ) AS v(nome, funcao)
 WHERE NOT EXISTS (
   SELECT 1 FROM public.pdv_collaborators c WHERE lower(btrim(c.name)) = lower(v.nome)
 );

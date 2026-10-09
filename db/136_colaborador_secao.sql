-- ════════════════════════════════════════════════════════════════════════
--  COLABORADOR restrito a UMA seção (área)  (db/136)
--
--  A "Área de acesso" do colaborador (campo `secao`: p1..p5) passa a ser
--  CODIFICADA na função como "COLABORADOR P1" (definida no cadastro a partir da
--  área; o admin não digita a função). Assim os gates por seção — que já olham
--  a `funcao` — barram colaborador de OUTRA área mesmo via URL direta.
--  Ex.: colaborador P1 = "COLABORADOR P1" → passa só nos gates de RH.
--
--  Depende de: 135 (categoria, gates com cláusula 'colaborador'). Idempotente.
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1) CRIAR USUÁRIO: função do colaborador = "COLABORADOR <ÁREA>" ──────
create or replace function public.auth_criar_usuario(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_nivel text; v_cat text; v_digits text; v_clean text; v_matr text; v_funcao text; v_secao text;
  v_existe uuid; v_novo public.militares;
begin
  select nivel_acesso into v_nivel from public._sessao_militar(p_token);
  if v_nivel is null or public._nivel_num(v_nivel) < public._nivel_num('admin') then
    return jsonb_build_object('ok', false, 'erro', 'Permissão insuficiente para criar usuários.');
  end if;
  if coalesce(p_dados->>'matricula','') = '' or coalesce(p_dados->>'nome_completo','') = '' then
    return jsonb_build_object('ok', false, 'erro', 'Matrícula e nome são obrigatórios.');
  end if;

  v_cat    := coalesce(nullif(p_dados->>'categoria',''), 'militar');
  v_secao  := lower(nullif(p_dados->>'secao',''));
  v_digits := regexp_replace(p_dados->>'matricula', '\D', '', 'g');

  if v_cat = 'militar' then
    v_clean := lpad(v_digits, 7, '0');
    v_matr  := case when length(v_clean) = 7
                 then substr(v_clean,1,3) || '.' || substr(v_clean,4,3) || '-' || substr(v_clean,7,1)
                 else v_clean end;
  else
    v_clean := v_digits;                      -- não-militar: dígitos crus
    v_matr  := upper(btrim(p_dados->>'matricula'));
  end if;

  select id into v_existe from public.militares where matricula_clean = v_clean;
  if v_existe is not null then
    return jsonb_build_object('ok', false, 'erro', 'Matrícula já cadastrada.', 'dup', true);
  end if;

  -- Colaborador: a função codifica a ÁREA ("COLABORADOR P1") — é o que os gates
  -- por seção olham. Sem área definida, fica só "COLABORADOR" (sem acesso de módulo).
  v_funcao := nullif(p_dados->>'funcao','');
  if v_cat = 'colaborador' then
    v_funcao := btrim('COLABORADOR ' || upper(coalesce(v_secao,'')));
  end if;

  insert into public.militares (
    matricula, matricula_clean, posto_graduacao, nome_completo, nome_guerra,
    funcao, grupamento_id, secao, nivel_acesso, categoria, senha_hash, primeiro_acesso, ativo
  ) values (
    v_matr, v_clean, nullif(p_dados->>'posto_graduacao',''), p_dados->>'nome_completo',
    nullif(p_dados->>'nome_guerra',''), v_funcao,
    nullif(p_dados->>'grupamento_id',''), v_secao,
    case when v_cat = 'colaborador' then 'operacional'
         else coalesce(nullif(p_dados->>'nivel_acesso',''), 'operacional') end,
    v_cat, crypt('Mudar@123', gen_salt('bf')), true, true
  ) returning * into v_novo;

  return jsonb_build_object('ok', true, 'user', to_jsonb(v_novo) - 'senha_hash');
end;
$$;

-- ─── 2) GATES P1: colaborador só passa se a função for da ÁREA P1 ────────
-- (antes: funcao ~* 'colaborador'  →  agora exige também p1).
create or replace function public._efetivo_pode(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* 'colaborador' and coalesce(p_funcao,'') ~* 'p\s*1');
$$;

create or replace function public._ferias_pode_p1(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* 'pel')
      or (coalesce(p_funcao,'') ~* 'colaborador' and coalesce(p_funcao,'') ~* 'p\s*1');
$$;

create or replace function public._reqjud_pode_controlar(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* 'colaborador' and coalesce(p_funcao,'') ~* 'p\s*1');
$$;

create or replace function public._reqjud_pode_editar(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* 'colaborador' and coalesce(p_funcao,'') ~* 'p\s*1');
$$;

create or replace function public._oficio_escopo_total(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') in ('admin_geral','admin')
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* 'colaborador' and coalesce(p_funcao,'') ~* 'p\s*1');
$$;

-- ─── 3) Ajusta o Mateus p/ o novo padrão (P1) ───────────────────────────
update public.militares set funcao = 'COLABORADOR P1', secao = 'p1'
 where categoria = 'colaborador' and matricula_clean = lpad('932305', 7, '0');

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 135). create or replace mantém grants.
-- ════════════════════════════════════════════════════════════════════════

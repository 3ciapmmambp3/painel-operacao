-- ════════════════════════════════════════════════════════════════════════
--  COLABORADORES (não-militares) — login + acesso ao hub P1, fora do efetivo  (db/135)
--
--  Permite cadastrar um colaborador que NÃO é militar nem assistente adm
--  (ex.: matrícula "C932305", 6 dígitos). Ele loga, acessa TODO o hub P1
--  (perfil fixo "Colaborador RH") e NÃO entra na contagem/quadro do efetivo
--  nem nos pickers de militar (TTA).
--
--  Marca: coluna `categoria` em militares ('militar'|'assistente_adm'|'colaborador').
--  Perfil fixo = nivel_acesso 'operacional' + categoria 'colaborador' + função
--  contendo "COLABORADOR" (esta última destrava os gates do efetivo, que olham
--  a função). Depende de: 04 (auth/sessão), 102 (efetivo), 07 (tta). Idempotente.
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1) COLUNA ──────────────────────────────────────────────────────────
alter table public.militares add column if not exists categoria text not null default 'militar';

-- ─── 2) LOGIN aceita matrícula não-PM (não força 7 dígitos) + devolve categoria ──
create or replace function public.auth_login(p_matricula text, p_senha text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_clean text := regexp_replace(coalesce(p_matricula,''), '\D', '', 'g');
  v_row   public.militares;
  v_ok    boolean := false;
  v_token uuid;
begin
  perform public._sessoes_limpar_expiradas();

  -- Militares são gravados com clean lpad(7); colaboradores com os dígitos crus
  -- (ex.: "932305"). Casa os dois e prefere o match EXATO.
  select * into v_row from public.militares
    where (matricula_clean = v_clean or matricula_clean = lpad(v_clean, 7, '0')) and ativo = true
    order by (matricula_clean = v_clean) desc
    limit 1;
  if v_row.id is null then
    return jsonb_build_object('ok', false, 'erro', 'Usuário não encontrado ou inativo.');
  end if;

  if left(v_row.senha_hash, 4) in ('$2a$', '$2b$', '$2y$') then
    v_ok := (crypt(p_senha, v_row.senha_hash) = v_row.senha_hash);
  else
    v_ok := (v_row.senha_hash = encode(digest(p_senha, 'sha256'), 'hex'));
    if v_ok then
      update public.militares set senha_hash = crypt(p_senha, gen_salt('bf')) where id = v_row.id;
    end if;
  end if;

  if not v_ok then
    return jsonb_build_object('ok', false, 'erro', 'Senha incorreta.');
  end if;

  insert into public.sessoes (militar_id) values (v_row.id) returning token into v_token;

  return jsonb_build_object('ok', true, 'primeiroAcesso', v_row.primeiro_acesso,
    'user', jsonb_build_object(
      'id', v_row.id, 'token', v_token, 'matricula', v_row.matricula,
      'matricula_clean', v_row.matricula_clean, 'nome', v_row.nome_completo,
      'guerra', v_row.nome_guerra, 'pg', v_row.posto_graduacao,
      'nivel_acesso', v_row.nivel_acesso, 'funcao', v_row.funcao,
      'grupamento_id', v_row.grupamento_id, 'categoria', v_row.categoria,
      'primeiro_acesso', v_row.primeiro_acesso
    ));
end;
$$;

-- ─── 3) CRIAR USUÁRIO aceita categoria e matrícula não-PM (sem lpad) ─────
create or replace function public.auth_criar_usuario(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_nivel text; v_cat text; v_digits text; v_clean text; v_matr text; v_funcao text;
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
  v_digits := regexp_replace(p_dados->>'matricula', '\D', '', 'g');

  if v_cat = 'militar' then
    v_clean := lpad(v_digits, 7, '0');
    v_matr  := case when length(v_clean) = 7
                 then substr(v_clean,1,3) || '.' || substr(v_clean,4,3) || '-' || substr(v_clean,7,1)
                 else v_clean end;
  else
    -- não-militar (colaborador/assistente não-PM): guarda os dígitos crus e a
    -- matrícula como digitada (ex.: "C932305").
    v_clean := v_digits;
    v_matr  := upper(btrim(p_dados->>'matricula'));
  end if;

  select id into v_existe from public.militares where matricula_clean = v_clean;
  if v_existe is not null then
    return jsonb_build_object('ok', false, 'erro', 'Matrícula já cadastrada.', 'dup', true);
  end if;

  -- Colaborador: a FUNÇÃO precisa conter "COLABORADOR" — é o que destrava os gates
  -- do efetivo (_efetivo_pode) para o perfil fixo "Colaborador RH".
  v_funcao := nullif(p_dados->>'funcao','');
  if v_cat = 'colaborador' and coalesce(v_funcao,'') !~* 'colaborador' then
    v_funcao := btrim('COLABORADOR RH ' || coalesce(v_funcao,''));
  end if;

  insert into public.militares (
    matricula, matricula_clean, posto_graduacao, nome_completo, nome_guerra,
    funcao, grupamento_id, nivel_acesso, categoria, senha_hash, primeiro_acesso, ativo
  ) values (
    v_matr, v_clean, nullif(p_dados->>'posto_graduacao',''), p_dados->>'nome_completo',
    nullif(p_dados->>'nome_guerra',''), v_funcao,
    nullif(p_dados->>'grupamento_id',''),
    case when v_cat = 'colaborador' then 'operacional'
         else coalesce(nullif(p_dados->>'nivel_acesso',''), 'operacional') end,
    v_cat, crypt('Mudar@123', gen_salt('bf')), true, true
  ) returning * into v_novo;

  return jsonb_build_object('ok', true, 'user', to_jsonb(v_novo) - 'senha_hash');
end;
$$;

-- ─── 4) LISTAR USUÁRIOS devolve categoria (p/ badge no Admin) ────────────
drop function if exists public.auth_listar_usuarios(uuid);
create or replace function public.auth_listar_usuarios(p_token uuid)
returns table (id uuid, matricula text, matricula_clean text, posto_graduacao text,
               nome_completo text, nome_guerra text, email text, primeiro_acesso boolean,
               ativo boolean, nivel_acesso text, funcao text, grupamento_id text,
               categoria text, created_at timestamptz, updated_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare v_nivel text;
begin
  select sm.nivel_acesso into v_nivel from public._sessao_militar(p_token) sm;
  if v_nivel is null or public._nivel_num(v_nivel) < public._nivel_num('admin_gp') then
    raise exception 'Permissão insuficiente.';
  end if;
  return query
    select m.id, m.matricula, m.matricula_clean, m.posto_graduacao, m.nome_completo,
           m.nome_guerra, m.email, m.primeiro_acesso, m.ativo, m.nivel_acesso, m.funcao,
           m.grupamento_id, m.categoria, m.created_at, m.updated_at
    from public.militares m order by m.nome_completo;
end;
$$;
grant execute on function public.auth_listar_usuarios(uuid) to anon;

-- ─── 5) EFETIVO: gate libera "Colaborador RH"; listagem devolve categoria ─
-- _efetivo_pode é chamado por TODOS os RPCs do efetivo (listar/salvar/baixar/
-- reativar/importar); acrescentando "colaborador" aqui, o perfil fixo passa a
-- ter o mesmo acesso de RH em todos eles, sem recriá-los.
create or replace function public._efetivo_pode(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* 'colaborador');
$$;

create or replace function public.efetivo_listar(p_token uuid, p_incluir_inativos boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_out jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Acesso ao efetivo restrito ao Aux P1 / Comando.';
  end if;

  select coalesce(jsonb_agg(to_jsonb(t) order by t.ord_antig, t.rank_posto, t.ultima_promocao nulls last, t.matricula_clean), '[]'::jsonb)
    into v_out
  from (
    select m.id, m.matricula, m.matricula_clean, m.posto_graduacao, m.nome_completo,
           m.nome_guerra, m.funcao, m.email, m.ativo, m.nivel_acesso, m.grupamento_id,
           m.categoria,
           m.cod_rpm, m.nome_rpm, m.cod_unidade_principal, m.nome_unidade_principal,
           m.cod_unidade, m.nome_unidade, m.cod_siad, m.tipo_atividade, m.cod_municipio,
           m.ultima_promocao, m.classificacao_curso, m.antiguidade_ordem,
           coalesce(m.situacao_efetivo,'ATIVO') as situacao_efetivo,
           m.transf_destino, m.transf_pasta_funcional, m.transf_data_envio,
           m.transf_oficio_numero, m.transf_obs, m.transf_anexo,
           coalesce(m.antiguidade_ordem, 999999) as ord_antig,
           public._posto_rank(m.posto_graduacao) as rank_posto
      from public.militares m
     where m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and (p_incluir_inativos or m.ativo = true)
  ) t;

  return v_out;
end;
$$;

-- ─── 6) TTA: colaborador não é militar → fora do picker de escala ────────
create or replace function public.tta_listar_militares(p_token uuid)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text)
language plpgsql security definer set search_path = public as $$
begin
  if (select sm.id from public._sessao_militar(p_token) sm) is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  return query
    select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra, m.grupamento_id
    from public.militares m
    where m.ativo = true
      and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
      and coalesce(m.categoria,'militar') <> 'colaborador'
    order by m.matricula_clean;
end;
$$;
-- ─── 7) DEMAIS GATES DO HUB P1 liberam "Colaborador RH" (mesmo lever) ────
-- Todos são helpers (p_nivel, p_funcao); acrescentando "colaborador" o perfil
-- fixo passa a ter acesso a Férias, Requisição Judicial e Ofícios também.
-- (Versões vigentes: férias=db/125, reqjud controlar=db/62, reqjud editar=db/71,
--  ofício=db/63. Reproduzidas aqui + a cláusula do colaborador.)
create or replace function public._ferias_pode_p1(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* 'pel')
      or (coalesce(p_funcao,'') ~* 'colaborador');
$$;

create or replace function public._reqjud_pode_controlar(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* 'colaborador');
$$;

create or replace function public._reqjud_pode_editar(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* 'colaborador');
$$;

create or replace function public._oficio_escopo_total(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') in ('admin_geral','admin')
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* 'colaborador');
$$;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 04/07/62/63/71/102/125). Reusa
-- _sessao_militar, _nivel_num, _posto_rank, militares (RLS já ativo).
-- As funções recriadas mantêm os grants anteriores (create or replace).
-- ════════════════════════════════════════════════════════════════════════

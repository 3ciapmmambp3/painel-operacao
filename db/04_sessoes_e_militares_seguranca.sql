-- ══════════════════════════════════════════════════════════════════════
--  SESSÕES + ENDURECIMENTO DE MILITARES — 3ª Cia PM MAmb
--  Rodar no Supabase (SQL Editor), DEPOIS de a tabela public.militares já
--  existir (SQL comentado no topo de src/auth.js). Idempotente.
--
--  Problema que resolve:
--  - Hoje toda autorização (quem pode criar/editar/excluir/promover
--    usuário, resetar senha) é decidida só no JavaScript do navegador.
--    Quem tem a chave anon (pública, está em auth.js) pode ignorar isso
--    e escrever direto na tabela militares via REST.
--  - senha_hash é SHA-256 sem salt, calculado no navegador, e a coluna
--    podia ser lida por qualquer um com a chave anon (rainbow table).
--
--  Como resolve: login passa a acontecer DENTRO do banco — a senha nunca
--  mais sai como hash reversível pro navegador — e emite um token opaco
--  (imprevisível). Toda operação sensível exige esse token; a função no
--  banco resolve QUEM está chamando a partir dele, não do que o navegador
--  disser. Mesmo padrão "security definer" já usado em criar_denuncia
--  (01_denuncias.sql) — nada novo na filosofia, só estendido para
--  militares.
--
--  IMPORTANTE — depois de rodar isto, todas as sessões abertas no
--  navegador de quem já estiver logado ficam inválidas (o formato da
--  sessão muda). Rode fora do horário de uso.
-- ══════════════════════════════════════════════════════════════════════

-- No Supabase o pgcrypto costuma instalar no schema "extensions", não em
-- "public" — por isso as funções abaixo que usam crypt/gen_salt/digest
-- declaram search_path = public, extensions (sem isso dá o erro
-- "function digest(text, unknown) does not exist").
create extension if not exists pgcrypto;

/* ─── 1) SESSÕES ────────────────────────────────────────────────────── */
create table if not exists public.sessoes (
  token       uuid primary key default gen_random_uuid(),
  militar_id  uuid not null references public.militares(id) on delete cascade,
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz not null default now() + interval '12 hours'
);
create index if not exists idx_sessoes_militar on public.sessoes(militar_id);
create index if not exists idx_sessoes_expira  on public.sessoes(expira_em);

create or replace function public._sessoes_limpar_expiradas()
returns void language sql as $$
  delete from public.sessoes where expira_em < now();
$$;

-- Resolve um token em quem é o militar (id, nível, grupamento etc.).
-- Retorna vazio (sem linhas) se o token não existir, tiver expirado, ou
-- o usuário estiver inativo — nunca confia em nada que o navegador mande.
create or replace function public._sessao_militar(p_token uuid)
returns table (id uuid, matricula text, matricula_clean text, nome_completo text,
               nome_guerra text, posto_graduacao text, nivel_acesso text,
               funcao text, grupamento_id text)
language sql security definer set search_path = public as $$
  select m.id, m.matricula, m.matricula_clean, m.nome_completo, m.nome_guerra,
         m.posto_graduacao, m.nivel_acesso, m.funcao, m.grupamento_id
  from public.sessoes s
  join public.militares m on m.id = s.militar_id
  where s.token = p_token and s.expira_em > now() and m.ativo = true;
$$;

create or replace function public._nivel_num(p_nivel text)
returns int language sql immutable as $$
  select case p_nivel
    when 'operacional'   then 0
    when 'admin_gp'      then 1
    when 'admin_pelotao' then 2
    when 'admin'         then 3
    when 'admin_geral'   then 4
    else 0
  end;
$$;

/* ─── 2) LOGIN ───────────────────────────────────────────────────────
   Aceita o hash SHA-256 legado (sem salt) só para comparar; se bater,
   regrava a senha em bcrypt (com salt) na hora, sem exigir troca do
   usuário. Hash já em bcrypt (prefixo $2) usa comparação bcrypt normal. */
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

  select * into v_row from public.militares
    where matricula_clean = lpad(v_clean, 7, '0') and ativo = true
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
      'grupamento_id', v_row.grupamento_id, 'primeiro_acesso', v_row.primeiro_acesso
    ));
end;
$$;

/* Troca a PRÓPRIA senha — vinculada ao token, nunca a um id arbitrário.
   (A versão antiga em JS aceitava qualquer id como parâmetro sem checar
   se era o dono da sessão; aqui isso deixa de ser possível.) */
create or replace function public.auth_trocar_senha(p_token uuid, p_nova_senha text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid;
begin
  if p_nova_senha is null or length(p_nova_senha) < 6 then
    return jsonb_build_object('ok', false, 'erro', 'A senha deve ter pelo menos 6 caracteres.');
  end if;
  if p_nova_senha = 'Mudar@123' then
    return jsonb_build_object('ok', false, 'erro', 'A nova senha não pode ser igual à senha padrão.');
  end if;
  select id into v_id from public._sessao_militar(p_token);
  if v_id is null then
    return jsonb_build_object('ok', false, 'erro', 'Sessão expirada. Faça login novamente.');
  end if;
  update public.militares set senha_hash = crypt(p_nova_senha, gen_salt('bf')), primeiro_acesso = false
    where id = v_id;
  return jsonb_build_object('ok', true);
end;
$$;

/* ─── 3) CRUD DE USUÁRIOS — mesmas regras de auth.js, agora no banco ── */

create or replace function public.auth_listar_usuarios(p_token uuid)
returns table (id uuid, matricula text, matricula_clean text, posto_graduacao text,
               nome_completo text, nome_guerra text, email text, primeiro_acesso boolean,
               ativo boolean, nivel_acesso text, funcao text, grupamento_id text,
               created_at timestamptz, updated_at timestamptz)
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
           m.grupamento_id, m.created_at, m.updated_at
    from public.militares m order by m.nome_completo;
end;
$$;

create or replace function public.auth_criar_usuario(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_nivel text;
  v_clean text;
  v_existe uuid;
  v_novo public.militares;
begin
  select nivel_acesso into v_nivel from public._sessao_militar(p_token);
  if v_nivel is null or public._nivel_num(v_nivel) < public._nivel_num('admin') then
    return jsonb_build_object('ok', false, 'erro', 'Permissão insuficiente para criar usuários.');
  end if;
  if coalesce(p_dados->>'matricula','') = '' or coalesce(p_dados->>'nome_completo','') = '' then
    return jsonb_build_object('ok', false, 'erro', 'Matrícula e nome são obrigatórios.');
  end if;

  v_clean := lpad(regexp_replace(p_dados->>'matricula', '\D', '', 'g'), 7, '0');
  select id into v_existe from public.militares where matricula_clean = v_clean;
  if v_existe is not null then
    return jsonb_build_object('ok', false, 'erro', 'Matrícula já cadastrada.', 'dup', true);
  end if;

  insert into public.militares (
    matricula, matricula_clean, posto_graduacao, nome_completo, nome_guerra,
    funcao, grupamento_id, nivel_acesso, senha_hash, primeiro_acesso, ativo
  ) values (
    case when length(v_clean) = 7
      then substr(v_clean,1,3) || '.' || substr(v_clean,4,3) || '-' || substr(v_clean,7,1)
      else v_clean end,
    v_clean, nullif(p_dados->>'posto_graduacao',''), p_dados->>'nome_completo',
    nullif(p_dados->>'nome_guerra',''), nullif(p_dados->>'funcao',''),
    nullif(p_dados->>'grupamento_id',''), coalesce(nullif(p_dados->>'nivel_acesso',''), 'operacional'),
    crypt('Mudar@123', gen_salt('bf')), true, true
  ) returning * into v_novo;

  return jsonb_build_object('ok', true, 'user', to_jsonb(v_novo) - 'senha_hash');
end;
$$;

create or replace function public.auth_atualizar_usuario(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me_id uuid; v_me_nivel text;
  v_alvo public.militares;
  v_outros_ag int;
  v_novo_nivel text := nullif(p_dados->>'nivel_acesso', '');
begin
  select id, nivel_acesso into v_me_id, v_me_nivel from public._sessao_militar(p_token);
  if v_me_id is null then
    return jsonb_build_object('ok', false, 'erro', 'Sessão expirada. Faça login novamente.');
  end if;

  select * into v_alvo from public.militares where id = p_id;
  if v_alvo.id is null then
    return jsonb_build_object('ok', false, 'erro', 'Usuário não encontrado.');
  end if;

  if v_novo_nivel is not null and v_novo_nivel <> 'admin_geral' and v_alvo.nivel_acesso = 'admin_geral' then
    select count(*) into v_outros_ag from public.militares
      where nivel_acesso = 'admin_geral' and id <> p_id and ativo = true;
    if v_outros_ag = 0 then
      return jsonb_build_object('ok', false, 'erro', 'Não é possível rebaixar o único Admin Geral ativo.');
    end if;
  end if;

  if v_novo_nivel = 'admin_geral' and public._nivel_num(v_me_nivel) < public._nivel_num('admin_geral') then
    return jsonb_build_object('ok', false, 'erro', 'Apenas Admin Geral pode promover outros Admin Gerais.');
  end if;

  if v_me_id <> p_id
     and not (v_me_nivel = 'admin_geral' and v_alvo.nivel_acesso = 'admin_geral')
     and public._nivel_num(v_alvo.nivel_acesso) >= public._nivel_num(v_me_nivel) then
    return jsonb_build_object('ok', false, 'erro', 'Você não pode editar um usuário de nível igual ou superior ao seu.');
  end if;

  if (p_dados ? 'ativo') and (p_dados->>'ativo')::boolean = false and v_alvo.nivel_acesso = 'admin_geral' then
    select count(*) into v_outros_ag from public.militares
      where nivel_acesso = 'admin_geral' and id <> p_id and ativo = true;
    if v_outros_ag = 0 then
      return jsonb_build_object('ok', false, 'erro', 'Não é possível desativar o único Admin Geral ativo.');
    end if;
  end if;

  update public.militares set
    posto_graduacao = case when p_dados ? 'posto_graduacao' then p_dados->>'posto_graduacao' else posto_graduacao end,
    nome_completo    = case when p_dados ? 'nome_completo'   then p_dados->>'nome_completo'   else nome_completo   end,
    nome_guerra      = case when p_dados ? 'nome_guerra'     then p_dados->>'nome_guerra'      else nome_guerra    end,
    funcao           = case when p_dados ? 'funcao'          then p_dados->>'funcao'           else funcao         end,
    grupamento_id    = case when p_dados ? 'grupamento_id'   then p_dados->>'grupamento_id'    else grupamento_id  end,
    nivel_acesso     = coalesce(v_novo_nivel, nivel_acesso),
    ativo            = case when p_dados ? 'ativo' then (p_dados->>'ativo')::boolean else ativo end
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.auth_resetar_senha(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_me_id uuid; v_me_nivel text; v_alvo public.militares;
begin
  select id, nivel_acesso into v_me_id, v_me_nivel from public._sessao_militar(p_token);
  if v_me_id is null then
    return jsonb_build_object('ok', false, 'erro', 'Sessão expirada. Faça login novamente.');
  end if;
  select * into v_alvo from public.militares where id = p_id;
  if v_alvo.id is null then
    return jsonb_build_object('ok', false, 'erro', 'Usuário não encontrado.');
  end if;
  if v_me_id <> p_id
     and not (v_me_nivel = 'admin_geral' and v_alvo.nivel_acesso = 'admin_geral')
     and public._nivel_num(v_me_nivel) <= public._nivel_num(v_alvo.nivel_acesso) then
    return jsonb_build_object('ok', false, 'erro', 'Permissão insuficiente para resetar esta senha.');
  end if;
  update public.militares set senha_hash = crypt('Mudar@123', gen_salt('bf')), primeiro_acesso = true
    where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.auth_excluir_usuario(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me_id uuid; v_me_nivel text; v_alvo public.militares; v_outros_ag int;
begin
  select id, nivel_acesso into v_me_id, v_me_nivel from public._sessao_militar(p_token);
  if v_me_id is null then
    return jsonb_build_object('ok', false, 'erro', 'Sessão expirada. Faça login novamente.');
  end if;
  if v_me_id = p_id then
    return jsonb_build_object('ok', false, 'erro', 'Você não pode excluir sua própria conta.');
  end if;
  select * into v_alvo from public.militares where id = p_id;
  if v_alvo.id is null then
    return jsonb_build_object('ok', false, 'erro', 'Usuário não encontrado.');
  end if;
  if v_alvo.nivel_acesso = 'admin_geral' then
    select count(*) into v_outros_ag from public.militares
      where nivel_acesso = 'admin_geral' and id <> p_id and ativo = true;
    if v_outros_ag = 0 then
      return jsonb_build_object('ok', false, 'erro', 'Não é possível excluir o único Admin Geral.');
    end if;
  end if;
  if not (v_me_nivel = 'admin_geral' and v_alvo.nivel_acesso = 'admin_geral')
     and public._nivel_num(v_alvo.nivel_acesso) >= public._nivel_num(v_me_nivel) then
    return jsonb_build_object('ok', false, 'erro', 'Você não pode excluir um usuário de nível igual ou superior.');
  end if;
  delete from public.militares where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

/* ─── 4) FECHA O ACESSO DIRETO — só passa pelas funções acima ────────
   RLS ligado e SEM nenhuma policy = anon não lê nem escreve uma linha
   sequer direto via REST. As funções acima são "security definer" e
   continuam funcionando normalmente (mesmo padrão de criar_denuncia). */
revoke all on public.militares from anon, authenticated;
revoke all on public.sessoes    from anon, authenticated;
alter table public.militares enable row level security;
alter table public.sessoes    enable row level security;

grant execute on function public.auth_login(text, text)               to anon;
grant execute on function public.auth_trocar_senha(uuid, text)        to anon;
grant execute on function public.auth_listar_usuarios(uuid)           to anon;
grant execute on function public.auth_criar_usuario(uuid, jsonb)      to anon;
grant execute on function public.auth_atualizar_usuario(uuid, uuid, jsonb) to anon;
grant execute on function public.auth_resetar_senha(uuid, uuid)       to anon;
grant execute on function public.auth_excluir_usuario(uuid, uuid)     to anon;

-- ─── Teste rápido (no SQL Editor), troque pela matrícula/senha reais ───
-- select public.auth_login('146.322-3', 'sua-senha-atual');
-- deve devolver {"ok":true, "user": {... "token": "uuid-aqui" ...}}

-- ─── DESFAZER (só se algo quebrar e precisar reverter às pressas) ─────
-- drop function if exists public.auth_login(text,text);
-- drop function if exists public.auth_trocar_senha(uuid,text);
-- drop function if exists public.auth_listar_usuarios(uuid);
-- drop function if exists public.auth_criar_usuario(uuid,jsonb);
-- drop function if exists public.auth_atualizar_usuario(uuid,uuid,jsonb);
-- drop function if exists public.auth_resetar_senha(uuid,uuid);
-- drop function if exists public.auth_excluir_usuario(uuid,uuid);
-- drop table if exists public.sessoes;
-- alter table public.militares disable row level security;
-- grant all on public.militares to anon;

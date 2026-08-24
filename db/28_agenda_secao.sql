-- ════════════════════════════════════════════════════════════════════════
-- 28_agenda_secao.sql — Agenda por Seção (P1–P5)
--
-- Cada seção do EM (P1..P5) ganha uma agenda de tarefas: título/descrição,
-- status (pendente/em_andamento/concluída), prioridade, quem DEVE fazer
-- (responsável), quem FEZ (executor), prazo e conclusão.
--
-- ACESSO (restrito, esconde dos não-membros): vê/gerencia a agenda de uma
-- seção quem for MEMBRO dela (militares.secao = 'pN'), ou Comando (função
-- CMT CIA) ou Admin Geral. Demais militares nem enxergam.
--
-- Vínculo à seção = novo campo `militares.secao` (definido no Cadastro de
-- Militares). NÃO deduz da função — mas o formulário sugere a partir de AUX Pn.
--
-- Segurança: RLS ligada SEM policy (só via RPC security definer, token).
-- Depende de: 04 (militares, _sessao_militar, _nivel_num), 07 (tg_touch_updated_at).
-- Idempotente. Rodar no SQL Editor depois do 04 e 07.
-- ════════════════════════════════════════════════════════════════════════

/* ─── 1) coluna `secao` em militares ──────────────────────────────────── */
alter table public.militares
  add column if not exists secao text
  check (secao is null or secao in ('p1','p2','p3','p4','p5'));

/* ─── 2) auth_listar_usuarios — inclui `secao` (muda retorno → drop+create) */
drop function if exists public.auth_listar_usuarios(uuid);
create or replace function public.auth_listar_usuarios(p_token uuid)
returns table (id uuid, matricula text, matricula_clean text, posto_graduacao text,
               nome_completo text, nome_guerra text, email text, primeiro_acesso boolean,
               ativo boolean, nivel_acesso text, funcao text, grupamento_id text,
               secao text, created_at timestamptz, updated_at timestamptz)
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
           m.grupamento_id, m.secao, m.created_at, m.updated_at
    from public.militares m order by m.nome_completo;
end;
$$;
grant execute on function public.auth_listar_usuarios(uuid) to anon;

/* ─── 3) auth_criar_usuario — grava `secao` (retorno jsonb → replace ok) ── */
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
    funcao, grupamento_id, secao, nivel_acesso, senha_hash, primeiro_acesso, ativo
  ) values (
    case when length(v_clean) = 7
      then substr(v_clean,1,3) || '.' || substr(v_clean,4,3) || '-' || substr(v_clean,7,1)
      else v_clean end,
    v_clean, nullif(p_dados->>'posto_graduacao',''), p_dados->>'nome_completo',
    nullif(p_dados->>'nome_guerra',''), nullif(p_dados->>'funcao',''),
    nullif(p_dados->>'grupamento_id',''), lower(nullif(p_dados->>'secao','')),
    coalesce(nullif(p_dados->>'nivel_acesso',''), 'operacional'),
    crypt('Mudar@123', gen_salt('bf')), true, true
  ) returning * into v_novo;

  return jsonb_build_object('ok', true, 'user', to_jsonb(v_novo) - 'senha_hash');
end;
$$;

/* ─── 4) auth_atualizar_usuario — grava `secao` quando enviado ─────────── */
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
    secao            = case when p_dados ? 'secao'           then lower(nullif(p_dados->>'secao','')) else secao   end,
    nivel_acesso     = coalesce(v_novo_nivel, nivel_acesso),
    ativo            = case when p_dados ? 'ativo' then (p_dados->>'ativo')::boolean else ativo end
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

/* ─── 4b) tta_listar_militares — EXCLUI ASPM na fonte (+ inclui `funcao`).
   Regra central: ASPM (assistentes administrativos) NÃO são militares, então
   saem de TODA lista de militares de uma vez — Relatório, TTA, Chamada,
   Viaturas, Missões. A função vem da aba Usuários (tabela `militares`). Muda o
   retorno → drop+create. A AGENDA usa `agenda_pessoas_listar` (inclui ASPM). */
drop function if exists public.tta_listar_militares(uuid);
create or replace function public.tta_listar_militares(p_token uuid)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text, funcao text)
language plpgsql security definer set search_path = public as $$
declare v_me record; v_ge boolean; v_adm boolean; v_pel text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  -- Recorte por grupamento (mesma hierarquia da seleção de equipes do Relatório):
  --  visão total = Admin Geral/Admin ou Comando da Cia (função CMT + CIA);
  --  ADM = quem é lotado na ADM vê todos os da ADM;
  --  Admin Pelotão = todos os grupamentos do SEU pelotão;
  --  demais (GP/Operacional/Admin GP) = só o próprio grupamento.
  v_ge  := coalesce(v_me.nivel_acesso,'') in ('admin_geral','admin')
        or (upper(coalesce(v_me.funcao,'')) like '%CMT%' and upper(coalesce(v_me.funcao,'')) like '%CIA%');
  v_adm := upper(btrim(coalesce(v_me.grupamento_id,''))) like 'ADM%';
  v_pel := (regexp_match(upper(coalesce(v_me.grupamento_id,'')), '(\d+)\s*PEL'))[1];
  return query
    select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra,
           m.grupamento_id, m.funcao
    from public.militares m
    where m.ativo = true
      and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
      and coalesce(upper(btrim(m.funcao)),'') <> 'ASPM'   -- ASPM não é militar
      and (
            v_ge
         or (v_adm and upper(btrim(coalesce(m.grupamento_id,''))) like 'ADM%')
         or (not v_adm and v_me.nivel_acesso = 'admin_pelotao' and v_pel is not null
             and (regexp_match(upper(coalesce(m.grupamento_id,'')), '(\d+)\s*PEL'))[1] = v_pel)
         or (not v_adm and coalesce(v_me.nivel_acesso,'') <> 'admin_pelotao'
             and m.grupamento_id = v_me.grupamento_id)
          )
    order by m.matricula_clean;
end;
$$;
grant execute on function public.tta_listar_militares(uuid) to anon;

/* Roster da AGENDA: militares + ASPM (todos ativos), pois ASPM são lotados em
   seção e podem ser responsáveis por tarefas. Mesma fonte (`militares`). */
create or replace function public.agenda_pessoas_listar(p_token uuid)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text, funcao text)
language plpgsql security definer set search_path = public as $$
begin
  if (select sm.id from public._sessao_militar(p_token) sm) is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  return query
    select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra,
           m.grupamento_id, m.funcao
    from public.militares m
    where m.ativo = true
      and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
    order by m.matricula_clean;
end;
$$;
grant execute on function public.agenda_pessoas_listar(uuid) to anon;

/* ─── 5) TABELA agenda_secao ──────────────────────────────────────────── */
create table if not exists public.agenda_secao (
  id            uuid primary key default gen_random_uuid(),
  secao         text not null check (secao in ('p1','p2','p3','p4','p5')),
  titulo        text not null,
  descricao     text,
  status        text not null default 'pendente'
                  check (status in ('pendente','em_andamento','concluida')),
  prioridade    text not null default 'media'
                  check (prioridade in ('baixa','media','alta')),
  responsavel_matricula text,   -- quem DEVE fazer
  responsavel_nome      text,
  executor_matricula    text,   -- quem FEZ (preenchido ao concluir)
  executor_nome         text,
  prazo          timestamptz,
  data_conclusao timestamptz,
  observacao     text,
  criado_por_matricula text,
  criado_por_nome      text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists idx_agenda_secao_secao on public.agenda_secao(secao, status);
create index if not exists idx_agenda_secao_prazo on public.agenda_secao(prazo) where prazo is not null;

drop trigger if exists trg_agenda_secao_touch on public.agenda_secao;
create trigger trg_agenda_secao_touch before update on public.agenda_secao
  for each row execute function public.tg_touch_updated_at();

alter table public.agenda_secao enable row level security;  -- sem policy: só via RPC

-- Histórico da tarefa (conclusões e complementos), p/ auditoria: cada item
-- = {tipo:'conclusao'|'complemento', por_matricula, por_nome, texto?, em}.
alter table public.agenda_secao
  add column if not exists historico jsonb not null default '[]'::jsonb;
-- prazo passou de date → timestamptz (prazo com hora). Migra a tabela já criada.
alter table public.agenda_secao
  alter column prazo type timestamptz using prazo::timestamptz;

/* ─── helper: pode ver/gerir a agenda da seção p_secao? ───────────────── */
create or replace function public._agenda_pode(p_nivel text, p_funcao text, p_secao_militar text, p_secao_alvo text)
returns boolean language sql immutable as $$
  -- Admin Geral e Comando da Cia (função tem CMT + CIA, ex.: "CMT CIA",
  -- "CMT 3 CIA PM MAMB") veem todas as seções; demais só a sua.
  select coalesce(p_nivel,'') = 'admin_geral'
      or (upper(coalesce(p_funcao,'')) like '%CMT%' and upper(coalesce(p_funcao,'')) like '%CIA%')
      or coalesce(p_secao_militar,'') = coalesce(p_secao_alvo,'');
$$;

/* ═══ RPCs da agenda ══════════════════════════════════════════════════ */

/* Contagem p/ o card do hub. NÃO levanta erro — retorna pode:false p/ quem
   não é da seção (o hub só mostra o card quando pode=true). */
create or replace function public.agenda_contar(p_token uuid, p_secao text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_secao_mil text; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_pend int; v_and int; v_conc int; v_atr int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then return jsonb_build_object('pode', false); end if;
  select secao into v_secao_mil from public.militares where id = v_me.id;
  if not public._agenda_pode(v_me.nivel_acesso, v_me.funcao, v_secao_mil, p_secao) then
    return jsonb_build_object('pode', false);
  end if;
  select
    count(*) filter (where status='pendente'),
    count(*) filter (where status='em_andamento'),
    count(*) filter (where status='concluida'),
    count(*) filter (where status<>'concluida' and prazo is not null and prazo < now())
    into v_pend, v_and, v_conc, v_atr
  from public.agenda_secao where secao = p_secao;
  return jsonb_build_object('pode', true, 'pendentes', v_pend, 'em_andamento', v_and,
                            'concluidas', v_conc, 'atrasadas', v_atr,
                            'abertas', v_pend + v_and);
end;
$$;

/* Lista as tarefas da seção. LEVANTA erro se não for membro (página). */
create or replace function public.agenda_listar(p_token uuid, p_secao text)
returns setof public.agenda_secao
language plpgsql security definer set search_path = public as $$
declare v_me record; v_secao_mil text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select secao into v_secao_mil from public.militares where id = v_me.id;
  if not public._agenda_pode(v_me.nivel_acesso, v_me.funcao, v_secao_mil, p_secao) then
    raise exception 'Acesso restrito à seção %.', upper(p_secao);
  end if;
  return query
    select * from public.agenda_secao where secao = p_secao
     order by (status='concluida'),  -- abertas primeiro
              case prioridade when 'alta' then 0 when 'media' then 1 else 2 end,
              coalesce(prazo, '9999-12-31'::date), created_at;
end;
$$;

/* Criar/editar tarefa. Membro da seção (ou Comando/Admin Geral). */
create or replace function public.agenda_salvar(p_token uuid, p_dados jsonb)
returns public.agenda_secao
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_secao_mil text; v_row public.agenda_secao;
  v_id uuid := nullif(p_dados->>'id','')::uuid;
  v_secao text := lower(coalesce(p_dados->>'secao',''));
  v_status text := coalesce(nullif(p_dados->>'status',''), 'pendente');
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select secao into v_secao_mil from public.militares where id = v_me.id;
  if v_secao not in ('p1','p2','p3','p4','p5') then raise exception 'Seção inválida.'; end if;
  if not public._agenda_pode(v_me.nivel_acesso, v_me.funcao, v_secao_mil, v_secao) then
    raise exception 'Acesso restrito à seção %.', upper(v_secao);
  end if;
  if coalesce(p_dados->>'titulo','') = '' then raise exception 'Informe o título da tarefa.'; end if;

  if v_id is null then
    insert into public.agenda_secao (
      secao, titulo, descricao, status, prioridade,
      responsavel_matricula, responsavel_nome, executor_matricula, executor_nome,
      prazo, data_conclusao, observacao, criado_por_matricula, criado_por_nome)
    values (
      v_secao, p_dados->>'titulo', nullif(p_dados->>'descricao',''), v_status,
      coalesce(nullif(p_dados->>'prioridade',''),'media'),
      nullif(p_dados->>'responsavel_matricula',''), nullif(p_dados->>'responsavel_nome',''),
      nullif(p_dados->>'executor_matricula',''), nullif(p_dados->>'executor_nome',''),
      nullif(p_dados->>'prazo','')::timestamptz,
      case when v_status='concluida' then now() else nullif(p_dados->>'data_conclusao','')::timestamptz end,
      nullif(p_dados->>'observacao',''), v_me.matricula, v_me.nome_completo)
    returning * into v_row;
  else
    -- Tarefa concluída é imutável: para mexer, use agenda_complementar (reabre).
    if exists (select 1 from public.agenda_secao where id = v_id and status = 'concluida') then
      raise exception 'Tarefa concluída não pode ser editada. Use "Complementar" para reabrir.';
    end if;
    update public.agenda_secao set
      titulo      = coalesce(nullif(p_dados->>'titulo',''), titulo),
      descricao   = case when p_dados ? 'descricao' then nullif(p_dados->>'descricao','') else descricao end,
      status      = v_status,
      prioridade  = coalesce(nullif(p_dados->>'prioridade',''), prioridade),
      responsavel_matricula = case when p_dados ? 'responsavel_matricula' then nullif(p_dados->>'responsavel_matricula','') else responsavel_matricula end,
      responsavel_nome      = case when p_dados ? 'responsavel_nome'      then nullif(p_dados->>'responsavel_nome','')      else responsavel_nome end,
      executor_matricula    = case when p_dados ? 'executor_matricula'    then nullif(p_dados->>'executor_matricula','')    else executor_matricula end,
      executor_nome         = case when p_dados ? 'executor_nome'         then nullif(p_dados->>'executor_nome','')         else executor_nome end,
      prazo       = case when p_dados ? 'prazo' then nullif(p_dados->>'prazo','')::timestamptz else prazo end,
      -- ao concluir, carimba data_conclusao (se ainda não tiver); ao reabrir, limpa
      data_conclusao = case when v_status='concluida' then coalesce(data_conclusao, now())
                            else null end,
      observacao  = case when p_dados ? 'observacao' then nullif(p_dados->>'observacao','') else observacao end
    where id = v_id and secao = v_secao
    returning * into v_row;
    if v_row.id is null then raise exception 'Tarefa não encontrada.'; end if;
  end if;
  return v_row;
end;
$$;

/* Mudança rápida de status (cards). Ao concluir, registra QUEM FEZ = eu. */
create or replace function public.agenda_status(p_token uuid, p_id uuid, p_status text)
returns public.agenda_secao
language plpgsql security definer set search_path = public as $$
declare v_me record; v_secao_mil text; v_row public.agenda_secao; v_secao text; v_resp text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_status not in ('pendente','em_andamento','concluida') then raise exception 'Status inválido.'; end if;
  select secao, responsavel_matricula into v_secao, v_resp from public.agenda_secao where id = p_id;
  if v_secao is null then raise exception 'Tarefa não encontrada.'; end if;
  select secao into v_secao_mil from public.militares where id = v_me.id;
  -- pode mudar status: membro da seção / Comando / Admin Geral OU o próprio
  -- responsável pela tarefa (mesmo que não seja da seção — foi delegado a ele).
  if not public._agenda_pode(v_me.nivel_acesso, v_me.funcao, v_secao_mil, v_secao)
     and regexp_replace(coalesce(v_resp,''), '\D', '', 'g') <> v_me.matricula_clean then
    raise exception 'Acesso restrito à seção %.', upper(v_secao);
  end if;
  update public.agenda_secao set
    status = p_status,
    executor_matricula = case when p_status='concluida' then coalesce(executor_matricula, v_me.matricula) else executor_matricula end,
    executor_nome      = case when p_status='concluida' then coalesce(executor_nome, v_me.nome_completo) else executor_nome end,
    data_conclusao     = case when p_status='concluida' then coalesce(data_conclusao, now()) else null end,
    historico          = case when p_status='concluida'
                           then historico || jsonb_build_object('tipo','conclusao',
                                  'por_matricula',v_me.matricula,'por_nome',v_me.nome_completo,'em',now())
                           else historico end
  where id = p_id
  returning * into v_row;
  return v_row;
end;
$$;

/* Executar (para o RESPONSÁVEL): muda status e registra o que foi feito, mesmo
   que não seja da seção. Quem executa quase nunca é lotado na seção que criou a
   tarefa — então isto é o que aparece no "Meu Dia" dele. Permitido a membro da
   seção / Comando / Admin Geral OU ao próprio responsável. */
create or replace function public.agenda_executar(p_token uuid, p_id uuid, p_status text, p_obs text)
returns public.agenda_secao
language plpgsql security definer set search_path = public as $$
declare v_me record; v_secao_mil text; v_row public.agenda_secao; v_secao text; v_resp text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_status not in ('pendente','em_andamento','concluida') then raise exception 'Status inválido.'; end if;
  select secao, responsavel_matricula into v_secao, v_resp from public.agenda_secao where id = p_id;
  if v_secao is null then raise exception 'Tarefa não encontrada.'; end if;
  select secao into v_secao_mil from public.militares where id = v_me.id;
  if not public._agenda_pode(v_me.nivel_acesso, v_me.funcao, v_secao_mil, v_secao)
     and regexp_replace(coalesce(v_resp,''), '\D', '', 'g') <> v_me.matricula_clean then
    raise exception 'Acesso restrito.';
  end if;
  update public.agenda_secao set
    status = p_status,
    executor_matricula = case when p_status='concluida' then coalesce(executor_matricula, v_me.matricula) else executor_matricula end,
    executor_nome      = case when p_status='concluida' then coalesce(executor_nome, v_me.nome_completo) else executor_nome end,
    data_conclusao     = case when p_status='concluida' then coalesce(data_conclusao, now()) else null end,
    historico = historico
      || case when coalesce(p_obs,'') <> '' then jsonb_build_object('tipo','execucao',
             'por_matricula',v_me.matricula,'por_nome',v_me.nome_completo,'texto',p_obs,'em',now())
           else '[]'::jsonb end
      || case when p_status='concluida' then jsonb_build_object('tipo','conclusao',
             'por_matricula',v_me.matricula,'por_nome',v_me.nome_completo,'em',now())
           else '[]'::jsonb end
  where id = p_id
  returning * into v_row;
  return v_row;
end;
$$;

/* Excluir tarefa. Membro da seção (ou Comando/Admin Geral). */
create or replace function public.agenda_excluir(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_secao_mil text; v_secao text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select secao into v_secao from public.agenda_secao where id = p_id;
  if v_secao is null then return jsonb_build_object('ok', true); end if;
  select secao into v_secao_mil from public.militares where id = v_me.id;
  if not public._agenda_pode(v_me.nivel_acesso, v_me.funcao, v_secao_mil, v_secao) then
    raise exception 'Acesso restrito à seção %.', upper(v_secao);
  end if;
  delete from public.agenda_secao where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

/* Complementar uma tarefa CONCLUÍDA: registra o pedido no histórico e reabre
   (volta para pendente). Membro da seção / Comando / Admin Geral ou o próprio
   responsável. Tarefa concluída não é editável — este é o caminho para mexer. */
create or replace function public.agenda_complementar(p_token uuid, p_id uuid, p_texto text)
returns public.agenda_secao
language plpgsql security definer set search_path = public as $$
declare v_me record; v_secao_mil text; v_row public.agenda_secao; v_secao text; v_resp text; v_status text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if coalesce(p_texto,'') = '' then raise exception 'Descreva o que precisa ser complementado.'; end if;
  select secao, responsavel_matricula, status into v_secao, v_resp, v_status
    from public.agenda_secao where id = p_id;
  if v_secao is null then raise exception 'Tarefa não encontrada.'; end if;
  if v_status <> 'concluida' then raise exception 'Só é possível complementar uma tarefa concluída.'; end if;
  select secao into v_secao_mil from public.militares where id = v_me.id;
  if not public._agenda_pode(v_me.nivel_acesso, v_me.funcao, v_secao_mil, v_secao)
     and regexp_replace(coalesce(v_resp,''), '\D', '', 'g') <> v_me.matricula_clean then
    raise exception 'Acesso restrito à seção %.', upper(v_secao);
  end if;
  update public.agenda_secao set
    status = 'pendente',
    executor_matricula = null,       -- próxima conclusão registra o novo executor
    executor_nome      = null,
    data_conclusao     = null,
    historico = historico || jsonb_build_object('tipo','complemento',
                  'por_matricula',v_me.matricula,'por_nome',v_me.nome_completo,'texto',p_texto,'em',now())
  where id = p_id
  returning * into v_row;
  return v_row;
end;
$$;

/* ─── grants (anon; autorização real é por token dentro de cada RPC) ───── */
grant execute on function public.agenda_contar(uuid, text)  to anon;
grant execute on function public.agenda_listar(uuid, text)  to anon;
grant execute on function public.agenda_salvar(uuid, jsonb) to anon;
grant execute on function public.agenda_status(uuid, uuid, text) to anon;
grant execute on function public.agenda_excluir(uuid, uuid) to anon;
grant execute on function public.agenda_complementar(uuid, uuid, text) to anon;
grant execute on function public.agenda_executar(uuid, uuid, text, text) to anon;

/* ═══════════════════════════════════════════════════════════════════════
   AGENDA PESSOAL — tarefas privadas do militar (só o dono vê), exibidas no
   "Meu Dia". Independente das seções. + agregador minhas_tarefas_listar que
   junta as tarefas de SEÇÃO atribuídas a mim (responsável) com as pessoais.
   ═══════════════════════════════════════════════════════════════════════ */

create table if not exists public.agenda_pessoal (
  id             uuid primary key default gen_random_uuid(),
  militar_id     uuid references public.militares(id) on delete cascade,
  militar_matricula text not null,
  titulo         text not null,
  status         text not null default 'pendente'
                   check (status in ('pendente','em_andamento','concluida')),
  prioridade     text not null default 'media'
                   check (prioridade in ('baixa','media','alta')),
  prazo          timestamptz,
  data_conclusao timestamptz,
  observacao     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists idx_agenda_pessoal_mil on public.agenda_pessoal(militar_id, status);

drop trigger if exists trg_agenda_pessoal_touch on public.agenda_pessoal;
create trigger trg_agenda_pessoal_touch before update on public.agenda_pessoal
  for each row execute function public.tg_touch_updated_at();

alter table public.agenda_pessoal enable row level security;  -- sem policy: só via RPC
alter table public.agenda_pessoal
  alter column prazo type timestamptz using prazo::timestamptz;   -- prazo com hora

/* Criar/editar uma tarefa pessoal (do próprio militar logado). */
create or replace function public.agenda_pessoal_salvar(p_token uuid, p_dados jsonb)
returns public.agenda_pessoal
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_row public.agenda_pessoal;
  v_id uuid := nullif(p_dados->>'id','')::uuid;
  v_status text := coalesce(nullif(p_dados->>'status',''), 'pendente');
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if coalesce(p_dados->>'titulo','') = '' then raise exception 'Informe o título da tarefa.'; end if;

  if v_id is null then
    insert into public.agenda_pessoal (
      militar_id, militar_matricula, titulo, status, prioridade, prazo, data_conclusao, observacao)
    values (
      v_me.id, v_me.matricula, p_dados->>'titulo', v_status,
      coalesce(nullif(p_dados->>'prioridade',''),'media'),
      nullif(p_dados->>'prazo','')::timestamptz,
      case when v_status='concluida' then now() else null end,
      nullif(p_dados->>'observacao',''))
    returning * into v_row;
  else
    update public.agenda_pessoal set
      titulo     = coalesce(nullif(p_dados->>'titulo',''), titulo),
      status     = v_status,
      prioridade = coalesce(nullif(p_dados->>'prioridade',''), prioridade),
      prazo      = case when p_dados ? 'prazo' then nullif(p_dados->>'prazo','')::timestamptz else prazo end,
      data_conclusao = case when v_status='concluida' then coalesce(data_conclusao, now()) else null end,
      observacao = case when p_dados ? 'observacao' then nullif(p_dados->>'observacao','') else observacao end
    where id = v_id and militar_id = v_me.id      -- só o dono edita
    returning * into v_row;
    if v_row.id is null then raise exception 'Tarefa não encontrada.'; end if;
  end if;
  return v_row;
end;
$$;

/* Mudança rápida de status da tarefa pessoal (dono). */
create or replace function public.agenda_pessoal_status(p_token uuid, p_id uuid, p_status text)
returns public.agenda_pessoal
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.agenda_pessoal;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_status not in ('pendente','em_andamento','concluida') then raise exception 'Status inválido.'; end if;
  update public.agenda_pessoal set
    status = p_status,
    data_conclusao = case when p_status='concluida' then coalesce(data_conclusao, now()) else null end
  where id = p_id and militar_id = v_me.id
  returning * into v_row;
  if v_row.id is null then raise exception 'Tarefa não encontrada.'; end if;
  return v_row;
end;
$$;

/* Excluir tarefa pessoal (dono). */
create or replace function public.agenda_pessoal_excluir(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  delete from public.agenda_pessoal where id = p_id and militar_id = v_me.id;
  return jsonb_build_object('ok', true);
end;
$$;

/* Agregador do "Meu Dia": tarefas de seção atribuídas a mim (responsável,
   ainda abertas) + todas as minhas tarefas pessoais. */
create or replace function public.minhas_tarefas_listar(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_atrib jsonb; v_pess jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select coalesce(jsonb_agg(t order by t_prazo nulls last, t_created), '[]'::jsonb)
    into v_atrib
  from (
    select jsonb_build_object(
             'id', a.id, 'origem', 'secao', 'secao', a.secao, 'titulo', a.titulo,
             'status', a.status, 'prioridade', a.prioridade, 'prazo', a.prazo,
             'descricao', a.descricao, 'observacao', a.observacao,
             'historico', a.historico) as t,
           a.prazo as t_prazo, a.created_at as t_created
    from public.agenda_secao a
    where a.status <> 'concluida'
      and regexp_replace(coalesce(a.responsavel_matricula,''), '\D', '', 'g') = v_me.matricula_clean
  ) s;

  select coalesce(jsonb_agg(t order by t_conc, t_prazo nulls last, t_created), '[]'::jsonb)
    into v_pess
  from (
    select jsonb_build_object(
             'id', p.id, 'origem', 'pessoal', 'titulo', p.titulo, 'status', p.status,
             'prioridade', p.prioridade, 'prazo', p.prazo, 'observacao', p.observacao,
             'data_conclusao', p.data_conclusao) as t,
           (p.status='concluida') as t_conc, p.prazo as t_prazo, p.created_at as t_created
    from public.agenda_pessoal p
    where p.militar_id = v_me.id
  ) s;

  return jsonb_build_object('atribuidas', v_atrib, 'pessoais', v_pess);
end;
$$;

grant execute on function public.agenda_pessoal_salvar(uuid, jsonb)     to anon;
grant execute on function public.agenda_pessoal_status(uuid, uuid, text) to anon;
grant execute on function public.agenda_pessoal_excluir(uuid, uuid)     to anon;
grant execute on function public.minhas_tarefas_listar(uuid)            to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 04 e 07.
-- ════════════════════════════════════════════════════════════════════════

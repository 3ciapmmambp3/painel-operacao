-- ══════════════════════════════════════════════════════════════════════
--  db/207 — CONTROLE DE TRAMITAÇÃO DAS ORDENS DE SERVIÇO (OS)
--  Data: 2026-11-21
--
--  Módulo NOVO e INDEPENDENTE (não mexe no PAF nem em nada em produção).
--  Acompanha o ciclo da OS: Elaboração → Aguardando autorização → Autorizada
--  → (SDV, só se houver diárias) → Encaminhada ao Grupamento → Em execução.
--  Acesso: Aux P3 + Admin Geral (reusa _pode_gerenciar_os_paf).
--  Anexos (OS em PDF + planilha de diárias) guardam só o LINK do Drive.
-- ══════════════════════════════════════════════════════════════════════

-- 1) Tabelas ---------------------------------------------------------------
create table if not exists public.ordens_servico (
  id               uuid primary key default gen_random_uuid(),
  numero           integer not null,
  ano              integer not null,
  operacao         text,                 -- nome/título da operação
  descricao        text,
  com_diarias      boolean not null default false,
  etapa            text not null default 'elaboracao'
                     check (etapa in ('elaboracao','aguardando_autorizacao','autorizada','sdv','encaminhada','execucao','concluida','cancelada')),
  grupamento       text,                 -- grupamento de destino
  os_url           text,                 -- link do PDF da OS no Drive
  os_arquivo       text,
  planilha_url     text,                 -- link da planilha de diárias no Drive
  planilha_arquivo text,
  criado_por       text,
  criado_em        timestamptz not null default now(),
  atualizado_por   text,
  atualizado_em    timestamptz not null default now(),
  unique (ano, numero)
);
create index if not exists idx_os_ano_num on public.ordens_servico(ano desc, numero desc);
create index if not exists idx_os_etapa   on public.ordens_servico(etapa);

create table if not exists public.os_tramitacao (
  id          uuid primary key default gen_random_uuid(),
  os_id       uuid not null references public.ordens_servico(id) on delete cascade,
  etapa       text not null,
  data        date,
  responsavel text,
  obs         text,
  criado_por  text,
  criado_em   timestamptz not null default now()
);
create index if not exists idx_ostram_os on public.os_tramitacao(os_id, criado_em);

-- RLS: acesso sempre pelos RPCs (security definer). Bloqueia acesso direto.
alter table public.ordens_servico enable row level security;
alter table public.os_tramitacao  enable row level security;

-- 2) Próximo número da OS no ano -----------------------------------------
create or replace function public.os_proximo_numero(p_token uuid, p_ano integer)
returns integer language plpgsql security definer set search_path = public as $$
declare v_me record; v_n integer;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão.'; end if;
  select coalesce(max(numero),0)+1 into v_n from public.ordens_servico where ano = p_ano;
  return v_n;
end $$;

-- 3) Criar / editar OS ----------------------------------------------------
create or replace function public.os_salvar(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.ordens_servico%rowtype; v_novo boolean; v_num integer; v_ano integer;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: controle do Aux P3 / Admin Geral.'; end if;

  v_novo := p_id is null;
  v_ano  := coalesce((p_dados->>'ano')::integer, extract(year from now())::integer);
  v_num  := nullif(btrim(p_dados->>'numero'),'')::integer;
  if v_novo and v_num is null then
    select coalesce(max(numero),0)+1 into v_num from public.ordens_servico where ano = v_ano;
  end if;

  if v_novo then
    insert into public.ordens_servico (numero, ano, operacao, descricao, com_diarias, grupamento,
            os_url, os_arquivo, planilha_url, planilha_arquivo, criado_por, atualizado_por)
    values (v_num, v_ano, nullif(btrim(p_dados->>'operacao'),''), nullif(btrim(p_dados->>'descricao'),''),
            coalesce((p_dados->>'com_diarias')::boolean,false), nullif(btrim(p_dados->>'grupamento'),''),
            nullif(btrim(p_dados->>'os_url'),''), nullif(btrim(p_dados->>'os_arquivo'),''),
            nullif(btrim(p_dados->>'planilha_url'),''), nullif(btrim(p_dados->>'planilha_arquivo'),''),
            v_me.matricula, v_me.matricula)
    returning * into v_row;
    insert into public.os_tramitacao (os_id, etapa, data, responsavel, criado_por)
    values (v_row.id, 'elaboracao', current_date, v_me.matricula, v_me.matricula);
  else
    update public.ordens_servico set
      operacao = coalesce(nullif(btrim(p_dados->>'operacao'),''), operacao),
      descricao = p_dados->>'descricao',
      com_diarias = coalesce((p_dados->>'com_diarias')::boolean, com_diarias),
      grupamento = p_dados->>'grupamento',
      os_url = coalesce(p_dados->>'os_url', os_url),
      os_arquivo = coalesce(p_dados->>'os_arquivo', os_arquivo),
      planilha_url = coalesce(p_dados->>'planilha_url', planilha_url),
      planilha_arquivo = coalesce(p_dados->>'planilha_arquivo', planilha_arquivo),
      atualizado_por = v_me.matricula, atualizado_em = now()
    where id = p_id returning * into v_row;
    if v_row.id is null then raise exception 'OS não encontrada.'; end if;
  end if;
  return to_jsonb(v_row);
end $$;

-- 4) Avançar / mudar etapa (registra no histórico) ------------------------
create or replace function public.os_mudar_etapa(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.ordens_servico%rowtype; v_etapa text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão.'; end if;
  v_etapa := p_dados->>'etapa';
  if v_etapa is null or v_etapa not in ('elaboracao','aguardando_autorizacao','autorizada','sdv','encaminhada','execucao','concluida','cancelada') then
    raise exception 'Etapa inválida.'; end if;

  update public.ordens_servico set etapa = v_etapa, atualizado_por = v_me.matricula, atualizado_em = now()
  where id = p_id returning * into v_row;
  if v_row.id is null then raise exception 'OS não encontrada.'; end if;

  insert into public.os_tramitacao (os_id, etapa, data, responsavel, obs, criado_por)
  values (p_id, v_etapa, coalesce(nullif(btrim(p_dados->>'data'),'')::date, current_date),
          coalesce(nullif(btrim(p_dados->>'responsavel'),''), v_me.matricula),
          nullif(btrim(p_dados->>'obs'),''), v_me.matricula);
  return to_jsonb(v_row);
end $$;

-- 5) Listar OS ------------------------------------------------------------
create or replace function public.os_listar(p_token uuid)
returns setof public.ordens_servico language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then return; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then return; end if;
  return query select * from public.ordens_servico order by ano desc, numero desc;
end $$;

-- 6) Histórico de uma OS --------------------------------------------------
create or replace function public.os_historico(p_token uuid, p_id uuid)
returns setof public.os_tramitacao language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then return; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then return; end if;
  return query select * from public.os_tramitacao where os_id = p_id order by criado_em;
end $$;

-- 7) Excluir OS -----------------------------------------------------------
create or replace function public.os_excluir(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida.'; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then raise exception 'Sem permissão.'; end if;
  delete from public.ordens_servico where id = p_id;
end $$;

grant execute on function public.os_proximo_numero(uuid, integer)  to anon, authenticated;
grant execute on function public.os_salvar(uuid, uuid, jsonb)      to anon, authenticated;
grant execute on function public.os_mudar_etapa(uuid, uuid, jsonb) to anon, authenticated;
grant execute on function public.os_listar(uuid)                   to anon, authenticated;
grant execute on function public.os_historico(uuid, uuid)          to anon, authenticated;
grant execute on function public.os_excluir(uuid, uuid)            to anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════
-- 24_chamada_instrucao.sql — Chamada de Instrução (módulo nativo)
--
-- Substitui o app externo pmmg-chamada (Next.js + Google Sheets) por um
-- módulo nativo do painel: login único (poe_sessao_v2 / tabela militares) +
-- Supabase. Reusa `militares` e `_sessao_militar` (04) e o roster de
-- `tta_listar_militares` (07) — NÃO duplica cadastro de militar.
--
-- Duas entidades:
--   • instrucoes         — o assunto/data/responsável da instrução (uma ATIVA)
--   • chamada_instrucao  — a presença de cada militar naquela instrução
--
-- Acesso: LANÇAR chamada = todos os militares logados. Configurar/Dashboard/
-- Consultas/Relatórios = admin (admin_geral, admin, admin_pelotao).
--
-- Segurança: tudo via RPC security definer; RLS ligada SEM policy permissiva
-- (as tabelas não são lidas direto pelo REST — só pelas funções abaixo).
--
-- Depende de: 04_sessoes_e_militares_seguranca.sql, 07_tta.sql (tg_touch_updated_at).
-- Idempotente. Rodar no SQL Editor depois do 07.
-- ════════════════════════════════════════════════════════════════════════

/* ─── 1) INSTRUÇÕES (assunto/data/responsável; uma ATIVA por vez) ──────── */
create table if not exists public.instrucoes (
  id          uuid primary key default gen_random_uuid(),
  data        date not null,
  assunto     text not null,
  responsavel_instrucao text,
  ativa       boolean not null default true,
  criado_por_matricula text,
  criado_por_nome       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_instrucoes_data  on public.instrucoes(data desc);
create index if not exists idx_instrucoes_ativa on public.instrucoes(ativa) where ativa;

drop trigger if exists trg_instrucoes_touch on public.instrucoes;
create trigger trg_instrucoes_touch before update on public.instrucoes
  for each row execute function public.tg_touch_updated_at();

/* ─── 2) CHAMADA (presença por militar por instrução) ─────────────────── */
create table if not exists public.chamada_instrucao (
  id            uuid primary key default gen_random_uuid(),
  instrucao_id  uuid not null references public.instrucoes(id) on delete cascade,
  militar_id    uuid references public.militares(id),
  matricula     text not null,
  matricula_clean text,
  posto_graduacao text,
  nome_completo text,
  nome_guerra   text,
  grupamento_id text,
  status        text not null check (status in ('presente','ausente')),
  justificativa text,
  observacao    text,
  registrado_por_matricula text,
  registrado_por_nome       text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (instrucao_id, matricula)
);
create index if not exists idx_ci_instrucao on public.chamada_instrucao(instrucao_id);

drop trigger if exists trg_ci_touch on public.chamada_instrucao;
create trigger trg_ci_touch before update on public.chamada_instrucao
  for each row execute function public.tg_touch_updated_at();

/* ─── RLS: ligada, sem policy permissiva (acesso só via RPC abaixo) ────── */
alter table public.instrucoes        enable row level security;
alter table public.chamada_instrucao enable row level security;

/* ─── helper: é nível administrativo da Chamada? ──────────────────────── */
create or replace function public._pode_gerir_instrucao(p_nivel text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') in ('admin_geral','admin','admin_pelotao');
$$;

/* ═══ RPCs ════════════════════════════════════════════════════════════ */

/* A instrução ATIVA (a mais recente marcada ativa). Todos os logados. */
create or replace function public.instrucao_ativa_get(p_token uuid)
returns setof public.instrucoes
language plpgsql security definer set search_path = public as $$
begin
  if (select sm.id from public._sessao_militar(p_token) sm) is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  return query
    select * from public.instrucoes
     where ativa = true
     order by data desc, created_at desc
     limit 1;
end;
$$;

/* Histórico de instruções (Consultas/Relatórios). Admin. */
create or replace function public.instrucao_listar(p_token uuid)
returns setof public.instrucoes
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if not public._pode_gerir_instrucao(v_me.nivel_acesso) then
    raise exception 'Acesso restrito (Admin Geral, Admin ou Admin de Pelotão).';
  end if;
  return query select * from public.instrucoes order by data desc, created_at desc;
end;
$$;

/* Criar/editar a instrução. Admin. ativa=true desativa as demais. */
create or replace function public.instrucao_salvar(p_token uuid, p_dados jsonb)
returns public.instrucoes
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.instrucoes;
  v_id   uuid := nullif(p_dados->>'id','')::uuid;
  v_ativa boolean := coalesce((p_dados->>'ativa')::boolean, true);
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if not public._pode_gerir_instrucao(v_me.nivel_acesso) then
    raise exception 'Acesso restrito (Admin Geral, Admin ou Admin de Pelotão).';
  end if;
  if coalesce(p_dados->>'assunto','') = '' then
    raise exception 'Informe o assunto da instrução.';
  end if;

  if v_ativa then
    update public.instrucoes set ativa = false where ativa = true
       and (v_id is null or id <> v_id);
  end if;

  if v_id is null then
    insert into public.instrucoes (data, assunto, responsavel_instrucao, ativa,
                                   criado_por_matricula, criado_por_nome)
    values (coalesce(nullif(p_dados->>'data','')::date, (now() at time zone 'America/Sao_Paulo')::date),
            p_dados->>'assunto',
            nullif(p_dados->>'responsavel_instrucao',''),
            v_ativa, v_me.matricula, v_me.nome_completo)
    returning * into v_row;
  else
    update public.instrucoes set
      data = coalesce(nullif(p_dados->>'data','')::date, data),
      assunto = p_dados->>'assunto',
      responsavel_instrucao = nullif(p_dados->>'responsavel_instrucao',''),
      ativa = v_ativa
    where id = v_id
    returning * into v_row;
    if v_row.id is null then raise exception 'Instrução não encontrada.'; end if;
  end if;
  return v_row;
end;
$$;

/* Lançar chamada — upsert em lote da presença. Todos os logados. */
create or replace function public.chamada_instrucao_lancar(
  p_token uuid, p_instrucao_id uuid, p_registros jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_reg jsonb;
  v_n   int := 0;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if not exists (select 1 from public.instrucoes where id = p_instrucao_id) then
    raise exception 'Instrução não encontrada. Peça ao administrador para configurar a instrução atual.';
  end if;
  if jsonb_typeof(p_registros) <> 'array' then
    raise exception 'Registros inválidos.';
  end if;

  for v_reg in select * from jsonb_array_elements(p_registros) loop
    if coalesce(v_reg->>'matricula','') = '' then continue; end if;
    if coalesce(v_reg->>'status','') not in ('presente','ausente') then continue; end if;
    insert into public.chamada_instrucao (
      instrucao_id, militar_id, matricula, matricula_clean, posto_graduacao,
      nome_completo, nome_guerra, grupamento_id, status, justificativa, observacao,
      registrado_por_matricula, registrado_por_nome)
    values (
      p_instrucao_id,
      nullif(v_reg->>'militar_id','')::uuid,
      v_reg->>'matricula',
      regexp_replace(coalesce(v_reg->>'matricula',''), '\D', '', 'g'),
      nullif(v_reg->>'posto_graduacao',''),
      nullif(v_reg->>'nome_completo',''),
      nullif(v_reg->>'nome_guerra',''),
      nullif(v_reg->>'grupamento_id',''),
      v_reg->>'status',
      nullif(v_reg->>'justificativa',''),
      nullif(v_reg->>'observacao',''),
      v_me.matricula, v_me.nome_completo)
    on conflict (instrucao_id, matricula) do update set
      status        = excluded.status,
      justificativa = excluded.justificativa,
      observacao    = excluded.observacao,
      posto_graduacao = coalesce(excluded.posto_graduacao, public.chamada_instrucao.posto_graduacao),
      nome_completo = coalesce(excluded.nome_completo, public.chamada_instrucao.nome_completo),
      nome_guerra   = coalesce(excluded.nome_guerra, public.chamada_instrucao.nome_guerra),
      grupamento_id = coalesce(excluded.grupamento_id, public.chamada_instrucao.grupamento_id),
      registrado_por_matricula = v_me.matricula,
      registrado_por_nome      = v_me.nome_completo;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'gravados', v_n);
end;
$$;

/* Listar a presença de uma instrução (Lançar prefill + Dashboard). Logados. */
create or replace function public.chamada_instrucao_listar(p_token uuid, p_instrucao_id uuid)
returns setof public.chamada_instrucao
language plpgsql security definer set search_path = public as $$
begin
  if (select sm.id from public._sessao_militar(p_token) sm) is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  return query
    select * from public.chamada_instrucao
     where instrucao_id = p_instrucao_id
     order by grupamento_id, matricula_clean;
end;
$$;

/* ─── grants (anon; a autorização real é por token dentro de cada RPC) ─── */
grant execute on function public.instrucao_ativa_get(uuid)                to anon;
grant execute on function public.instrucao_listar(uuid)                   to anon;
grant execute on function public.instrucao_salvar(uuid, jsonb)            to anon;
grant execute on function public.chamada_instrucao_lancar(uuid, uuid, jsonb) to anon;
grant execute on function public.chamada_instrucao_listar(uuid, uuid)     to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 07_tta.sql.
-- ════════════════════════════════════════════════════════════════════════

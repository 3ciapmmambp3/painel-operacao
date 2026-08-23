-- ════════════════════════════════════════════════════════════════════════
-- 26_paf_fapi.sql — Cadastro de operações PAF e FAPI no painel
--
-- Migra o cadastro do "ID da Operação PAF" e "ID da Operação FAPI" (antes só na
-- aba da planilha) para o painel/Supabase. O Relatório de Serviço passa a ler
-- daqui e sobrescreve referenceCache['PAF'] e ['FAPI'].
--
-- Filtro no relatório (opcional por registro):
--   • se `pelotoes` estiver preenchido → só aparece pro pelotão da Fração;
--   • se `inicio`/`final` estiverem preenchidos → só aparece dentro da vigência;
--   • sem pelotões e sem vigência → aparece sempre.
--
-- Começa VAZIO (sem seed) — o Admin Geral cadastra na aba "PAF / FAPI".
-- Espelha o padrão de 16_operacoes.sql. Depende de 04 (_sessao_militar).
-- Idempotente. Rodar no SQL Editor (depois do 04).
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.operacoes_paf_fapi (
  id             uuid primary key default gen_random_uuid(),
  tipo           text not null check (tipo in ('PAF','FAPI')),
  id_operacao    text not null,          -- o "ID da Operação" que o usuário escolhe
  nome           text,                   -- nome da operação (preenchido junto do ID)
  pelotoes       int[] not null default '{}',  -- 1..5; vazio = todos os pelotões
  inicio         date,
  final          date,
  ativo          boolean not null default true,
  atualizado_por text,
  atualizado_em  timestamptz not null default now(),
  criado_em      timestamptz not null default now()
);
create index if not exists idx_paffapi_ativo on public.operacoes_paf_fapi (ativo);
create index if not exists idx_paffapi_tipo  on public.operacoes_paf_fapi (tipo);

-- ── RPC: listar (anon) — o painel filtra por pelotão/data no cliente ──────
create or replace function public.paf_fapi_listar(p_tipo text default null)
returns setof public.operacoes_paf_fapi
language sql stable security definer set search_path = public as $$
  select * from public.operacoes_paf_fapi
  where ativo = true
    and (p_tipo is null or tipo = p_tipo)
  order by tipo, id_operacao;
$$;

-- ── RPC: salvar (incluir/editar) — restrito Admin Geral ──────────────────
create or replace function public.paf_fapi_salvar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_row public.operacoes_paf_fapi%rowtype;
  v_id uuid; v_tipo text; v_idop text; v_pel int[];
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: o cadastro de PAF/FAPI é do Admin Geral.';
  end if;

  v_tipo := upper(nullif(trim(p_dados->>'tipo'),''));
  if v_tipo is null or v_tipo not in ('PAF','FAPI') then
    raise exception 'Tipo inválido (use PAF ou FAPI).';
  end if;
  v_idop := nullif(trim(p_dados->>'id_operacao'),'');
  if v_idop is null then raise exception 'Informe o ID da Operação.'; end if;

  -- pelotoes: jsonb array [1,2,3] -> int[]  (vazio se ausente)
  v_pel := coalesce(
    (select array_agg(x::int)
       from jsonb_array_elements_text(coalesce(p_dados->'pelotoes','[]'::jsonb)) as t(x)
       where x ~ '^\d+$'),
    '{}'::int[]
  );

  v_id := nullif(p_dados->>'id','')::uuid;

  if v_id is null then
    insert into public.operacoes_paf_fapi
      (tipo, id_operacao, nome, pelotoes, inicio, final, ativo, atualizado_por)
    values
      (v_tipo, v_idop, nullif(trim(p_dados->>'nome'),''), v_pel,
       nullif(p_dados->>'inicio','')::date, nullif(p_dados->>'final','')::date,
       coalesce((p_dados->>'ativo')::boolean, true), v_me.matricula)
    returning * into v_row;
  else
    update public.operacoes_paf_fapi set
      tipo = v_tipo,
      id_operacao = v_idop,
      nome = nullif(trim(p_dados->>'nome'),''),
      pelotoes = v_pel,
      inicio = nullif(p_dados->>'inicio','')::date,
      final  = nullif(p_dados->>'final','')::date,
      ativo = coalesce((p_dados->>'ativo')::boolean, ativo),
      atualizado_por = v_me.matricula, atualizado_em = now()
    where id = v_id
    returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- ── RPC: remover (soft por padrão: ativo=false; hard apaga) ──────────────
create or replace function public.paf_fapi_remover(p_token uuid, p_id uuid, p_hard boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: o cadastro de PAF/FAPI é do Admin Geral.';
  end if;
  if coalesce(p_hard,false) then
    delete from public.operacoes_paf_fapi where id = p_id;
    return jsonb_build_object('ok', true, 'hard', true);
  end if;
  update public.operacoes_paf_fapi set ativo=false, atualizado_por=v_me.matricula, atualizado_em=now()
  where id = p_id;
  return jsonb_build_object('ok', true, 'hard', false);
end;
$$;

-- ── RLS ─────────────────────────────────────────────────────────────────
alter table public.operacoes_paf_fapi enable row level security;
drop policy if exists paffapi_sel on public.operacoes_paf_fapi;
create policy paffapi_sel on public.operacoes_paf_fapi for select using (true);

grant execute on function public.paf_fapi_listar(text) to anon;
grant execute on function public.paf_fapi_salvar(uuid, jsonb) to anon;
grant execute on function public.paf_fapi_remover(uuid, uuid, boolean) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 04.
-- ════════════════════════════════════════════════════════════════════════

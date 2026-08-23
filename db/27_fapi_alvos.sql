-- ════════════════════════════════════════════════════════════════════════
-- 27_fapi_alvos.sql — FAPI: alvos por campanha + grupamento pelo MUNICÍPIO
--                     e PAF: grupamentos-alvo na operação
--
-- Modelo novo do FAPI (substitui o "ID + nome" simples):
--   • A campanha FAPI continua em operacoes_paf_fapi (tipo='FAPI').
--   • Cada ALVO fica em fapi_alvos (ID, Razão Social, CNPJ, Município).
--   • O GRUPAMENTO do alvo é DERIVADO do município, usando as tabelas que já
--     existem: municipios_grupos (municipio→gp_responsavel) + grupos
--     (gp_responsavel→grupamento_completo "1 GP / 3 PEL / 3 CIA PM MAMB / …").
--   • A baixa (Data, Nº REDS, Nº Ato de Fiscalização, Status) é lançada no
--     Relatório de Serviço (card FAPI) — não fica aqui.
--
-- PAF: a operação (tipo='PAF') passa a ter, além de pelotoes, uma lista de
--      grupamentos-alvo (gp_responsavel) — nem sempre o pelotão inteiro atua.
--
-- Depende de 04 (_sessao_militar), 26 (operacoes_paf_fapi), e das tabelas
-- municipios_grupos e grupos (já existentes). Idempotente. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

-- Normalizador de acento/caixa (municipios_grupos usa ASCII: "MANHUACU";
-- o alvo pode vir com acento: "MANHUAÇU"). Sem depender da extensão unaccent.
create or replace function public._norm_mun(t text)
returns text language sql immutable set search_path = public as $$
  select upper(trim(translate(coalesce(t,''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')));
$$;

-- PAF: grupamentos-alvo (gp_responsavel) na operação (além de pelotoes) --------
alter table public.operacoes_paf_fapi
  add column if not exists grupamentos text[] not null default '{}';

-- Alvos do FAPI --------------------------------------------------------------
create table if not exists public.fapi_alvos (
  id             uuid primary key default gen_random_uuid(),
  operacao_id    uuid references public.operacoes_paf_fapi(id) on delete cascade,
  id_alvo        text,            -- o "ID" do alvo (ex.: 4, 27, 103…)
  razao_social   text,
  cnpj           text,
  municipio      text,            -- fonte do grupamento (via municipios_grupos)
  ativo          boolean not null default true,
  atualizado_por text,
  atualizado_em  timestamptz not null default now(),
  criado_em      timestamptz not null default now()
);
create index if not exists idx_fapialvo_op   on public.fapi_alvos (operacao_id);
create index if not exists idx_fapialvo_ativo on public.fapi_alvos (ativo);
create index if not exists idx_fapialvo_mun  on public.fapi_alvos (public._norm_mun(municipio));

-- View: alvo + grupamento RESOLVIDO pelo município ---------------------------
create or replace view public.v_fapi_alvos as
  select
    a.id, a.operacao_id, a.id_alvo, a.razao_social, a.cnpj, a.municipio, a.ativo,
    a.atualizado_por, a.atualizado_em, a.criado_em,
    mg.gp_responsavel,
    g.grupamento_completo,
    g.pelotao
  from public.fapi_alvos a
  left join public.municipios_grupos mg
    on public._norm_mun(mg.municipio) = public._norm_mun(a.municipio)
  left join public.grupos g
    on g.gp_responsavel = mg.gp_responsavel;

-- ── RPC: listar alvos (anon) — opcionalmente por campanha ────────────────
create or replace function public.fapi_alvos_listar(p_operacao_id uuid default null)
returns setof public.v_fapi_alvos
language sql stable security definer set search_path = public as $$
  select * from public.v_fapi_alvos
  where ativo = true
    and (p_operacao_id is null or operacao_id = p_operacao_id)
  order by nullif(regexp_replace(coalesce(id_alvo,''), '\D', '', 'g'),'')::bigint nulls last, id_alvo;
$$;

-- ── RPC: salvar 1 alvo (incluir/editar) — Admin Geral ────────────────────
create or replace function public.fapi_alvo_salvar(p_token uuid, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.fapi_alvos%rowtype; v_id uuid;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: o cadastro de FAPI é do Admin Geral.';
  end if;
  v_id := nullif(p_dados->>'id','')::uuid;
  if v_id is null then
    insert into public.fapi_alvos (operacao_id, id_alvo, razao_social, cnpj, municipio, atualizado_por)
    values (nullif(p_dados->>'operacao_id','')::uuid, nullif(trim(p_dados->>'id_alvo'),''),
            nullif(trim(p_dados->>'razao_social'),''), nullif(trim(p_dados->>'cnpj'),''),
            nullif(trim(p_dados->>'municipio'),''), v_me.matricula)
    returning * into v_row;
  else
    update public.fapi_alvos set
      operacao_id = coalesce(nullif(p_dados->>'operacao_id','')::uuid, operacao_id),
      id_alvo = nullif(trim(p_dados->>'id_alvo'),''),
      razao_social = nullif(trim(p_dados->>'razao_social'),''),
      cnpj = nullif(trim(p_dados->>'cnpj'),''),
      municipio = nullif(trim(p_dados->>'municipio'),''),
      atualizado_por = v_me.matricula, atualizado_em = now()
    where id = v_id returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- ── RPC: importar vários alvos de uma vez (paste da planilha) — Admin Geral ─
-- p_linhas = [ {id_alvo, razao_social, cnpj, municipio}, … ]
create or replace function public.fapi_alvos_importar(p_token uuid, p_operacao_id uuid, p_linhas jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record; v_l jsonb; v_n int := 0;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: o cadastro de FAPI é do Admin Geral.';
  end if;
  if p_operacao_id is null then raise exception 'Informe a campanha (operacao_id).'; end if;
  for v_l in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb)) loop
    if nullif(trim(coalesce(v_l->>'id_alvo', v_l->>'municipio','')),'') is null then continue; end if;
    insert into public.fapi_alvos (operacao_id, id_alvo, razao_social, cnpj, municipio, atualizado_por)
    values (p_operacao_id, nullif(trim(v_l->>'id_alvo'),''), nullif(trim(v_l->>'razao_social'),''),
            nullif(trim(v_l->>'cnpj'),''), nullif(trim(v_l->>'municipio'),''), v_me.matricula);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'importados', v_n);
end;
$$;

-- ── RPC: remover alvo (soft/hard) — Admin Geral ──────────────────────────
create or replace function public.fapi_alvo_remover(p_token uuid, p_id uuid, p_hard boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: o cadastro de FAPI é do Admin Geral.';
  end if;
  if coalesce(p_hard,false) then
    delete from public.fapi_alvos where id = p_id;
    return jsonb_build_object('ok', true, 'hard', true);
  end if;
  update public.fapi_alvos set ativo=false, atualizado_por=v_me.matricula, atualizado_em=now() where id = p_id;
  return jsonb_build_object('ok', true, 'hard', false);
end;
$$;

-- ── RPC auxiliar: lista de grupamentos (p/ selects do Admin/PAF) ─────────
create or replace function public.grupamentos_listar()
returns table(gp_responsavel text, grupamento_completo text, pelotao text)
language sql stable security definer set search_path = public as $$
  select gp_responsavel, grupamento_completo, pelotao from public.grupos order by grupamento_completo;
$$;

-- ── RLS + grants ─────────────────────────────────────────────────────────
alter table public.fapi_alvos enable row level security;
drop policy if exists fapialvo_sel on public.fapi_alvos;
create policy fapialvo_sel on public.fapi_alvos for select using (true);

grant select on public.v_fapi_alvos to anon;
grant execute on function public.fapi_alvos_listar(uuid)            to anon;
grant execute on function public.fapi_alvo_salvar(uuid, jsonb)      to anon;
grant execute on function public.fapi_alvos_importar(uuid, uuid, jsonb) to anon;
grant execute on function public.fapi_alvo_remover(uuid, uuid, boolean) to anon;
grant execute on function public.grupamentos_listar()              to anon;
grant execute on function public._norm_mun(text)                   to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 26.
-- ════════════════════════════════════════════════════════════════════════

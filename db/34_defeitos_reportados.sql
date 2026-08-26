-- ════════════════════════════════════════════════════════════════════════
-- 34_defeitos_reportados.sql — Defeitos de viatura reportados (controle unificado)
--
-- Um defeito pode ser reportado de DOIS jeitos, e ambos caem na MESMA lista:
--   (a) AVULSO   — botão 🔧 na Revisão da frota (tabela defeitos_reportados).
--   (b) FICHA    — seção "Manutenção/defeito" da Ficha de Movimentação
--                  (mov_viaturas.dados->'manutencao', tem_manutencao=true).
-- O grupamento reporta/ vê os das SUAS viaturas; Aux P4 / Admin Geral vê TODOS
-- e resolve (decide a baixa, feita na Gestão de Viaturas).
--
-- Depende de: 04 (_sessao_militar), 08 (viaturas / mov_viaturas / _pode_gerenciar_viaturas).
-- Idempotente. Rodar no SQL Editor depois do 08.
-- ════════════════════════════════════════════════════════════════════════

-- Defeitos AVULSOS (botão 🔧)
create table if not exists public.defeitos_reportados (
  id                    uuid primary key default gen_random_uuid(),
  prefixo               text not null,
  placa                 text,
  gp                    text,
  municipio             text,
  tipo                  text,
  urgencia              text,
  odometro              text,
  defeito               text not null,
  impede_uso            text,
  observacoes           text,
  status                text not null default 'aberto',  -- aberto | resolvido
  reportado_por_matricula text,
  reportado_por_nome      text,
  resolvido_por           text,
  resolvido_em            timestamptz,
  criado_em             timestamptz not null default now()
);
create index if not exists idx_defeitos_status on public.defeitos_reportados (status, criado_em desc);

-- Resolução dos defeitos vindos das FICHAS (mov_viaturas não tem status próprio)
create table if not exists public.defeito_ficha_resolvido (
  mov_id        uuid primary key,
  resolvido_por text,
  resolvido_em  timestamptz not null default now()
);

-- ── RPC: reportar defeito AVULSO (qualquer militar logado) ──────────────
create or replace function public.defeito_reportar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_v record; v_row public.defeitos_reportados%rowtype;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if nullif(btrim(p_dados->>'prefixo'),'') is null then raise exception 'Informe a viatura.'; end if;
  if nullif(btrim(p_dados->>'defeito'),'') is null then raise exception 'Descreva o defeito.'; end if;
  select prefixo, placa, gp, municipio into v_v from public.viaturas where prefixo = btrim(p_dados->>'prefixo');
  insert into public.defeitos_reportados (
    prefixo, placa, gp, municipio, tipo, urgencia, odometro, defeito, impede_uso, observacoes,
    reportado_por_matricula, reportado_por_nome
  ) values (
    btrim(p_dados->>'prefixo'), v_v.placa, v_v.gp, v_v.municipio,
    nullif(p_dados->>'tipo',''), nullif(p_dados->>'urgencia',''), nullif(p_dados->>'odometro',''),
    btrim(p_dados->>'defeito'), nullif(p_dados->>'impede_uso',''), nullif(p_dados->>'observacoes',''),
    v_me.matricula, coalesce(v_me.nome_completo, v_me.nome_guerra, v_me.matricula)
  ) returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- ── RPC: listar defeitos (UNIÃO avulso + ficha) ─────────────────────────
-- gestor vê todos; demais veem os do seu grupamento (município do grupamento_id).
create or replace function public.defeitos_listar(p_token uuid, p_status text default null)
returns table (
  origem text, ref_id uuid, prefixo text, placa text, gp text, municipio text,
  tipo text, urgencia text, odometro text, defeito text, impede_uso text, observacoes text,
  status text, reportado_por_nome text, criado_em timestamptz
)
language plpgsql stable security definer set search_path = public as $$
declare v_me record; v_gestor boolean; v_muni text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  v_gestor := public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao);
  v_muni   := upper(btrim(split_part(coalesce(v_me.grupamento_id,''), '/', -1)));

  return query
  with avulsos as (
    select 'avulso'::text as origem, d.id as ref_id, d.prefixo, d.placa, d.gp, d.municipio,
           d.tipo, d.urgencia, d.odometro, d.defeito, d.impede_uso, d.observacoes,
           d.status, d.reportado_por_nome, d.criado_em
    from public.defeitos_reportados d
  ),
  fichas as (
    select 'ficha'::text as origem, m.id as ref_id, m.prefixo::text, m.placa::text,
           m.gp_responsavel::text as gp, v.municipio::text as municipio,
           nullif(m.dados->'manutencao'->>'tipo','')::text,
           nullif(m.dados->'manutencao'->>'urgencia','')::text,
           nullif(m.dados->'manutencao'->>'odometro','')::text,
           coalesce(nullif(m.dados->'manutencao'->>'defeito',''),'(defeito informado na ficha)')::text,
           nullif(m.dados->'manutencao'->>'impede_uso','')::text,
           nullif(m.dados->'manutencao'->>'obs','')::text,
           case when r.mov_id is not null then 'resolvido' else 'aberto' end::text as status,
           m.motorista_nome::text as reportado_por_nome,
           coalesce(m.inicio, m.criado_em)::timestamptz as criado_em
    from public.mov_viaturas m
    left join public.viaturas v on v.prefixo = m.prefixo
    left join public.defeito_ficha_resolvido r on r.mov_id = m.id
    where m.ativo = true and coalesce(m.tem_manutencao,false) = true
  ),
  todos as ( select * from avulsos union all select * from fichas )
  select * from todos t
  where (p_status is null or t.status = p_status)
    and (v_gestor or (v_muni <> '' and upper(coalesce(t.municipio,'')) = v_muni))
  order by (t.status='aberto') desc, t.criado_em desc;
end;
$$;

-- ── RPC: resolver defeito (restrito gestor) — avulso ou ficha ────────────
create or replace function public.defeito_resolver(p_token uuid, p_origem text, p_ref uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: só o Aux P4 / Admin Geral resolve defeitos.';
  end if;
  if p_origem = 'ficha' then
    insert into public.defeito_ficha_resolvido (mov_id, resolvido_por, resolvido_em)
    values (p_ref, v_me.matricula, now())
    on conflict (mov_id) do update set resolvido_por = excluded.resolvido_por, resolvido_em = now();
  else
    update public.defeitos_reportados
      set status='resolvido', resolvido_por=v_me.matricula, resolvido_em=now()
      where id = p_ref;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

alter table public.defeitos_reportados      enable row level security;
alter table public.defeito_ficha_resolvido  enable row level security;

grant execute on function public.defeito_reportar(uuid, jsonb) to anon;
grant execute on function public.defeitos_listar(uuid, text) to anon;
grant execute on function public.defeito_resolver(uuid, text, uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 08.
-- ════════════════════════════════════════════════════════════════════════

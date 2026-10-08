-- ════════════════════════════════════════════════════════════════════════
--  DEMANDAS EM ANDAMENTO — controle de atendimento do Relatório de Serviço  (db/134)
--
--  Hoje toda demanda preenchida num card do Relatório vai pra planilha (via
--  Apps Script) e "sai de pendente". Passamos a ter 3 estados por demanda:
--    • FINALIZADA    → vai pra planilha + baixa (comportamento atual)
--    • EM_ANDAMENTO  → NÃO vai pra planilha; fica AQUI, para reaparecer
--                      sinalizada no próximo serviço e ter continuidade
--    • NAO_ATENDIDA  → NÃO vai pra planilha e NÃO grava aqui (fica intocada;
--                      segue pendente na planilha; o Cartão já mostra ao
--                      despachante que não foi atendida, p/ redistribuir)
--
--  Esta tabela guarda só as EM_ANDAMENTO. O frontend do Relatório lê via
--  demanda_andamento_listar e mescla nos cards (igual carregarDemandasSupabase),
--  marcando "🟡 (em andamento)". Ao finalizar num relatório posterior, a linha
--  sai daqui (ativo=false) e aí sim a demanda alimenta a planilha.
--
--  Depende de: 04 (_sessao_militar), 127 (_cartao_pode_ver p/ escopo por nível).
--  Idempotente. Rodar no SQL Editor do Supabase (depois do 127).
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1) TABELA ──────────────────────────────────────────────────────────
create table if not exists public.demandas_andamento (
  id            uuid primary key default gen_random_uuid(),
  source_key    text not null,                 -- NUDEN/DDU181/DEN_BALCAO/MC/EMERGENCIA/RI/REQUISICAO
  identificador text not null,                 -- VALOR escolhido no card (nº / geocode) — chave de casamento
  rotulo        text,                           -- rótulo amigável mostrado no card
  municipio     text,
  fracao        text not null default '',       -- grupamento_completo (escopo)
  gp_responsavel text,
  dados         jsonb not null default '{}'::jsonb,  -- {reds,auto_infracao,ato_fiscalizacao,data_atendimento,obs}
  relatorio_id  text,
  criado_por_matricula text,
  criado_por_nome      text,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  ativo         boolean not null default true
);

-- Upsert por (source_key, identificador, fracao) enquanto ativa.
create unique index if not exists uq_dem_andamento_chave
  on public.demandas_andamento (source_key, identificador, fracao) where ativo;
create index if not exists idx_dem_andamento_source on public.demandas_andamento (source_key) where ativo;
create index if not exists idx_dem_andamento_frac   on public.demandas_andamento (fracao)     where ativo;

alter table public.demandas_andamento enable row level security;
drop policy if exists demandas_andamento_sel on public.demandas_andamento;
create policy demandas_andamento_sel on public.demandas_andamento for select to anon using (true);

-- ─── 2) REGISTRAR (upsert — demanda EM ANDAMENTO) ───────────────────────
create or replace function public.demanda_andamento_registrar(p_token uuid, p_item jsonb)
returns public.demandas_andamento
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.demandas_andamento;
        v_src text; v_id text; v_frac text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  v_src  := upper(btrim(coalesce(p_item->>'source_key','')));
  v_id   := btrim(coalesce(p_item->>'identificador',''));
  v_frac := btrim(coalesce(p_item->>'fracao',''));
  if v_src = '' or v_id = '' then raise exception 'source_key e identificador são obrigatórios.'; end if;

  insert into public.demandas_andamento
    (source_key, identificador, rotulo, municipio, fracao, gp_responsavel, dados, relatorio_id,
     criado_por_matricula, criado_por_nome)
  values
    (v_src, v_id, nullif(p_item->>'rotulo',''), nullif(p_item->>'municipio',''), v_frac,
     nullif(p_item->>'gp_responsavel',''), coalesce(p_item->'dados','{}'::jsonb),
     nullif(p_item->>'relatorio_id',''), v_me.matricula,
     trim(both ' ' from concat(coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo))))
  on conflict (source_key, identificador, fracao) where ativo
  do update set
     rotulo        = coalesce(nullif(excluded.rotulo,''), public.demandas_andamento.rotulo),
     municipio     = coalesce(nullif(excluded.municipio,''), public.demandas_andamento.municipio),
     gp_responsavel= coalesce(nullif(excluded.gp_responsavel,''), public.demandas_andamento.gp_responsavel),
     dados         = excluded.dados,
     relatorio_id  = coalesce(nullif(excluded.relatorio_id,''), public.demandas_andamento.relatorio_id),
     criado_por_matricula = excluded.criado_por_matricula,
     criado_por_nome      = excluded.criado_por_nome,
     atualizado_em = now()
  returning * into v_row;
  return v_row;
end;
$$;

-- ─── 3) FINALIZAR (sai do controle — ativo=false) ───────────────────────
-- Chamada quando a demanda é FINALIZADA num relatório (aí ela alimenta a planilha).
create or replace function public.demanda_andamento_finalizar(
  p_token uuid, p_source_key text, p_identificador text, p_fracao text default null)
returns int language plpgsql security definer set search_path = public as $$
declare v_me record; v_n int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  update public.demandas_andamento set ativo = false, atualizado_em = now()
   where ativo
     and source_key = upper(btrim(coalesce(p_source_key,'')))
     and identificador = btrim(coalesce(p_identificador,''))
     and (p_fracao is null or fracao = btrim(p_fracao));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ─── 4) LISTAR (ativas, escopadas pelo nível do militar) ─────────────────
-- Escopo reaproveita _cartao_pode_ver (db/127): admin_geral/admin/CMT-CIA = tudo;
-- admin_pelotao = seu pelotão; demais = o próprio grupamento. O filtro fino por
-- Fração de Atuação ainda acontece no card (getFilteredItems_).
create or replace function public.demanda_andamento_listar(p_token uuid)
returns setof public.demandas_andamento
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  return query
    select d.* from public.demandas_andamento d
     where d.ativo
       and public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, d.fracao)
     order by d.atualizado_em desc;
end;
$$;

grant execute on function public.demanda_andamento_registrar(uuid, jsonb) to anon;
grant execute on function public.demanda_andamento_finalizar(uuid, text, text, text) to anon;
grant execute on function public.demanda_andamento_listar(uuid) to anon;
-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 127).
-- ════════════════════════════════════════════════════════════════════════

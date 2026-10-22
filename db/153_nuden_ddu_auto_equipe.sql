-- ══════════════════════════════════════════════════════════════════════
--  NUDEN/DDU — Nº Auto de Infração + Equipe/Viatura na baixa (Controle)
--  Rodar no Supabase (SQL Editor). Idempotente. Depende de db/151 e db/152.
--
--  Traz p/ a NUDEN e o DDU os mesmos dados que o Balcão/Requisição já puxam
--  do Relatório de Serviço: Nº do Auto de Infração e a EQUIPE (e viatura) que
--  atendeu. Supersede (create or replace) as funções nuden_baixar/ddu_baixar
--  de db/151/152, agora gravando esses campos.
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) COLUNAS NOVAS ──────────────────────────────────────────────────
alter table public.nuden_demandas add column if not exists numero_auto_infracao text;
alter table public.nuden_demandas add column if not exists equipe  text;
alter table public.nuden_demandas add column if not exists viatura text;

alter table public.ddu_demandas   add column if not exists numero_auto_infracao text;
alter table public.ddu_demandas   add column if not exists equipe  text;
alter table public.ddu_demandas   add column if not exists viatura text;

-- ─── 2) BAIXA (atendimento) — NUDEN ────────────────────────────────────
create or replace function public.nuden_baixar(p_dados jsonb)
returns public.nuden_demandas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_row public.nuden_demandas;
begin
  if v_codigo is null then raise exception 'nuden_baixar: código ausente'; end if;
  update public.nuden_demandas set
    data_atendimento = coalesce(nullif(p_dados->>'data_atendimento','')::date, data_atendimento),
    numero_reds      = coalesce(nullif(p_dados->>'numero_reds',''),  numero_reds),
    numero_gaia      = coalesce(nullif(p_dados->>'numero_gaia',''),  numero_gaia),
    numero_auto_infracao = coalesce(nullif(p_dados->>'numero_auto_infracao',''), numero_auto_infracao),
    resultado        = coalesce(nullif(p_dados->>'resultado',''),    resultado),
    observacoes_resposta = coalesce(nullif(p_dados->>'observacoes_resposta',''), observacoes_resposta),
    equipe  = coalesce(nullif(p_dados->>'equipe',''),  equipe),
    viatura = coalesce(nullif(p_dados->>'viatura',''), viatura),
    atendido_por_matricula = coalesce(nullif(p_dados->>'atendido_por_matricula',''), atendido_por_matricula),
    atendido_por_nome      = coalesce(nullif(p_dados->>'atendido_por_nome',''),      atendido_por_nome),
    situacao = 'RESPONDIDA'
  where codigo = v_codigo
  returning * into v_row;
  if v_row.id is null then raise exception 'nuden_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end;
$$;

-- ─── 3) BAIXA (atendimento) — DDU ──────────────────────────────────────
create or replace function public.ddu_baixar(p_dados jsonb)
returns public.ddu_demandas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_row public.ddu_demandas;
begin
  if v_codigo is null then raise exception 'ddu_baixar: código ausente'; end if;
  update public.ddu_demandas set
    data_atendimento = coalesce(nullif(p_dados->>'data_atendimento','')::date, data_atendimento),
    numero_reds      = coalesce(nullif(p_dados->>'numero_reds',''),  numero_reds),
    numero_gaia      = coalesce(nullif(p_dados->>'numero_gaia',''),  numero_gaia),
    numero_auto_infracao = coalesce(nullif(p_dados->>'numero_auto_infracao',''), numero_auto_infracao),
    resultado        = coalesce(nullif(p_dados->>'resultado',''),    resultado),
    observacoes_resposta = coalesce(nullif(p_dados->>'observacoes_resposta',''), observacoes_resposta),
    equipe  = coalesce(nullif(p_dados->>'equipe',''),  equipe),
    viatura = coalesce(nullif(p_dados->>'viatura',''), viatura),
    atendido_por_matricula = coalesce(nullif(p_dados->>'atendido_por_matricula',''), atendido_por_matricula),
    atendido_por_nome      = coalesce(nullif(p_dados->>'atendido_por_nome',''),      atendido_por_nome),
    situacao = 'RESPONDIDA'
  where codigo = v_codigo
  returning * into v_row;
  if v_row.id is null then raise exception 'ddu_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end;
$$;

grant execute on function public.nuden_baixar(jsonb) to anon;
grant execute on function public.ddu_baixar(jsonb)   to anon;

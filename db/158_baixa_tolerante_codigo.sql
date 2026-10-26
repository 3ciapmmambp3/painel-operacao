-- ══════════════════════════════════════════════════════════════════════
--  Controle de Demandas — BAIXA tolerante a ZERO À ESQUERDA
--  Rodar no Supabase (SQL Editor). Idempotente (create or replace).
--
--  PROBLEMA: o Relatório de Serviço às vezes grava o número da demanda SEM o
--  zero inicial (ex.: 1236092601) enquanto a tabela guarda COM zero
--  (01236092601). As funções *_baixar casavam só por igualdade exata de
--  `codigo` → não achavam → a demanda ficava PENDENTE mesmo com o relatório
--  finalizado (a falha ainda era silenciosa no front).
--
--  CORREÇÃO: antes do UPDATE, se não houver match exato, resolve o `codigo`
--  real ignorando zeros à esquerda — SÓ para códigos puramente numéricos
--  (códigos com '/' ou '.' — RI, NUDEN — continuam casando exato).
--  Recria ddu/nuden/ri/emergencia/mc_baixar; corpos idênticos aos de
--  db/151/152/154/155/157, apenas com o resolvedor adicionado.
-- ══════════════════════════════════════════════════════════════════════

-- ─── DDU ───────────────────────────────────────────────────────────────
create or replace function public.ddu_baixar(p_dados jsonb)
returns public.ddu_demandas
language plpgsql security definer set search_path = public as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_alt text;
  v_row public.ddu_demandas;
begin
  if v_codigo is null then raise exception 'ddu_baixar: código ausente'; end if;
  if not exists (select 1 from public.ddu_demandas where codigo = v_codigo) then
    select codigo into v_alt from public.ddu_demandas
     where v_codigo ~ '^[0-9]+$' and codigo ~ '^[0-9]+$'
       and ltrim(codigo,'0') = ltrim(v_codigo,'0')
     order by codigo limit 1;
    if v_alt is not null then v_codigo := v_alt; end if;
  end if;
  update public.ddu_demandas set
    data_atendimento = coalesce(nullif(p_dados->>'data_atendimento','')::date, data_atendimento),
    numero_reds      = coalesce(nullif(p_dados->>'numero_reds',''),  numero_reds),
    numero_gaia      = coalesce(nullif(p_dados->>'numero_gaia',''),  numero_gaia),
    resultado        = coalesce(nullif(p_dados->>'resultado',''),    resultado),
    observacoes_resposta = coalesce(nullif(p_dados->>'observacoes_resposta',''), observacoes_resposta),
    atendido_por_matricula = coalesce(nullif(p_dados->>'atendido_por_matricula',''), atendido_por_matricula),
    atendido_por_nome      = coalesce(nullif(p_dados->>'atendido_por_nome',''),      atendido_por_nome),
    situacao = 'RESPONDIDA'
  where codigo = v_codigo
  returning * into v_row;
  if v_row.id is null then raise exception 'ddu_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end; $$;

-- ─── NUDEN ─────────────────────────────────────────────────────────────
create or replace function public.nuden_baixar(p_dados jsonb)
returns public.nuden_demandas
language plpgsql security definer set search_path = public as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_alt text;
  v_row public.nuden_demandas;
begin
  if v_codigo is null then raise exception 'nuden_baixar: código ausente'; end if;
  if not exists (select 1 from public.nuden_demandas where codigo = v_codigo) then
    select codigo into v_alt from public.nuden_demandas
     where v_codigo ~ '^[0-9]+$' and codigo ~ '^[0-9]+$'
       and ltrim(codigo,'0') = ltrim(v_codigo,'0')
     order by codigo limit 1;
    if v_alt is not null then v_codigo := v_alt; end if;
  end if;
  update public.nuden_demandas set
    data_atendimento = coalesce(nullif(p_dados->>'data_atendimento','')::date, data_atendimento),
    numero_reds      = coalesce(nullif(p_dados->>'numero_reds',''),  numero_reds),
    numero_gaia      = coalesce(nullif(p_dados->>'numero_gaia',''),  numero_gaia),
    resultado        = coalesce(nullif(p_dados->>'resultado',''),    resultado),
    observacoes_resposta = coalesce(nullif(p_dados->>'observacoes_resposta',''), observacoes_resposta),
    atendido_por_matricula = coalesce(nullif(p_dados->>'atendido_por_matricula',''), atendido_por_matricula),
    atendido_por_nome      = coalesce(nullif(p_dados->>'atendido_por_nome',''),      atendido_por_nome),
    situacao = 'RESPONDIDA'
  where codigo = v_codigo
  returning * into v_row;
  if v_row.id is null then raise exception 'nuden_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end; $$;

-- ─── RI (FTP) ──────────────────────────────────────────────────────────
create or replace function public.ri_baixar(p_dados jsonb)
returns public.ri_demandas
language plpgsql security definer set search_path = public as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_alt text;
  v_row public.ri_demandas;
begin
  if v_codigo is null then raise exception 'ri_baixar: código ausente'; end if;
  if not exists (select 1 from public.ri_demandas where codigo = v_codigo) then
    select codigo into v_alt from public.ri_demandas
     where v_codigo ~ '^[0-9]+$' and codigo ~ '^[0-9]+$'
       and ltrim(codigo,'0') = ltrim(v_codigo,'0')
     order by codigo limit 1;
    if v_alt is not null then v_codigo := v_alt; end if;
  end if;
  update public.ri_demandas set
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
  if v_row.id is null then raise exception 'ri_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end; $$;

-- ─── EMERGÊNCIA ────────────────────────────────────────────────────────
create or replace function public.emergencia_baixar(p_dados jsonb)
returns public.emergencia_demandas
language plpgsql security definer set search_path = public as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_alt text;
  v_row public.emergencia_demandas;
begin
  if v_codigo is null then raise exception 'emergencia_baixar: código ausente'; end if;
  if not exists (select 1 from public.emergencia_demandas where codigo = v_codigo) then
    select codigo into v_alt from public.emergencia_demandas
     where v_codigo ~ '^[0-9]+$' and codigo ~ '^[0-9]+$'
       and ltrim(codigo,'0') = ltrim(v_codigo,'0')
     order by codigo limit 1;
    if v_alt is not null then v_codigo := v_alt; end if;
  end if;
  update public.emergencia_demandas set
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
  if v_row.id is null then raise exception 'emergencia_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end; $$;

-- ─── MONITORAMENTO CONTÍNUO (MC) ───────────────────────────────────────
create or replace function public.mc_baixar(p_dados jsonb)
returns public.mc_demandas
language plpgsql security definer set search_path = public as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_alt text;
  v_row public.mc_demandas;
begin
  if v_codigo is null then raise exception 'mc_baixar: código ausente'; end if;
  if not exists (select 1 from public.mc_demandas where codigo = v_codigo) then
    select codigo into v_alt from public.mc_demandas
     where v_codigo ~ '^[0-9]+$' and codigo ~ '^[0-9]+$'
       and ltrim(codigo,'0') = ltrim(v_codigo,'0')
     order by codigo limit 1;
    if v_alt is not null then v_codigo := v_alt; end if;
  end if;
  update public.mc_demandas set
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
  if v_row.id is null then raise exception 'mc_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end; $$;

grant execute on function public.ddu_baixar(jsonb)        to anon;
grant execute on function public.nuden_baixar(jsonb)      to anon;
grant execute on function public.ri_baixar(jsonb)         to anon;
grant execute on function public.emergencia_baixar(jsonb) to anon;
grant execute on function public.mc_baixar(jsonb)         to anon;

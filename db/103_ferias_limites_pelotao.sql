-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — LIMITES DE % POR PELOTÃO (e por grupamento) individuais
--  Antes havia UM único "% máx por pelotão" para todos. Agora o Aux P1
--  define um limite para CADA pelotão (e grupamento). O limite é o teto de
--  militares em férias no MESMO período dentro daquele pelotão.
--
--  Guardado como mapa jsonb no cronograma: { "1º PEL": 25, "2º PEL": 20, ... }.
--  A comparação com o percentual real é feita na tela (painel Percentuais).
--
--  Depende de: 101 (ferias_cronograma / _salvar). Idempotente. Rodar depois do 102.
-- ══════════════════════════════════════════════════════════════════════

alter table public.ferias_cronograma add column if not exists limites_pelotao    jsonb not null default '{}'::jsonb;
alter table public.ferias_cronograma add column if not exists limites_grupamento jsonb not null default '{}'::jsonb;

-- Redefine o salvar incluindo os dois mapas (resto igual ao db/101).
create or replace function public.ferias_cronograma_salvar(p_token uuid, p_dados jsonb)
returns public.ferias_cronograma
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_ano int := coalesce(nullif(p_dados->>'ano','')::int,
                        extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_row public.ferias_cronograma;
  v_nome text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Apenas o Aux P1 / Comando pode montar o cronograma de férias.';
  end if;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  insert into public.ferias_cronograma (
    ano, titulo, situacao, data_abertura, data_limite,
    pct_max_cia, pct_max_pelotao, pct_max_grupamento, limites_pelotao, limites_grupamento,
    periodos, anexo_pdf, criado_por_matricula, criado_por_nome
  ) values (
    v_ano, nullif(p_dados->>'titulo',''),
    coalesce(nullif(p_dados->>'situacao',''),'RASCUNHO'),
    nullif(p_dados->>'data_abertura','')::date, nullif(p_dados->>'data_limite','')::date,
    nullif(p_dados->>'pct_max_cia','')::numeric,
    nullif(p_dados->>'pct_max_pelotao','')::numeric,
    nullif(p_dados->>'pct_max_grupamento','')::numeric,
    coalesce(p_dados->'limites_pelotao','{}'::jsonb),
    coalesce(p_dados->'limites_grupamento','{}'::jsonb),
    coalesce(p_dados->'periodos','[]'::jsonb), coalesce(p_dados->'anexo_pdf','[]'::jsonb),
    v_me.matricula, v_nome
  )
  on conflict (ano) do update set
    titulo             = case when p_dados ? 'titulo'        then nullif(p_dados->>'titulo','')             else ferias_cronograma.titulo end,
    situacao           = case when p_dados ? 'situacao'      then coalesce(nullif(p_dados->>'situacao',''),'RASCUNHO') else ferias_cronograma.situacao end,
    data_abertura      = case when p_dados ? 'data_abertura' then nullif(p_dados->>'data_abertura','')::date else ferias_cronograma.data_abertura end,
    data_limite        = case when p_dados ? 'data_limite'   then nullif(p_dados->>'data_limite','')::date   else ferias_cronograma.data_limite end,
    pct_max_cia        = case when p_dados ? 'pct_max_cia'        then nullif(p_dados->>'pct_max_cia','')::numeric        else ferias_cronograma.pct_max_cia end,
    pct_max_pelotao    = case when p_dados ? 'pct_max_pelotao'    then nullif(p_dados->>'pct_max_pelotao','')::numeric    else ferias_cronograma.pct_max_pelotao end,
    pct_max_grupamento = case when p_dados ? 'pct_max_grupamento' then nullif(p_dados->>'pct_max_grupamento','')::numeric else ferias_cronograma.pct_max_grupamento end,
    limites_pelotao    = case when p_dados ? 'limites_pelotao'    then coalesce(p_dados->'limites_pelotao','{}'::jsonb)    else ferias_cronograma.limites_pelotao end,
    limites_grupamento = case when p_dados ? 'limites_grupamento' then coalesce(p_dados->'limites_grupamento','{}'::jsonb) else ferias_cronograma.limites_grupamento end,
    periodos           = case when p_dados ? 'periodos'  then coalesce(p_dados->'periodos','[]'::jsonb)  else ferias_cronograma.periodos end,
    anexo_pdf          = case when p_dados ? 'anexo_pdf' then coalesce(p_dados->'anexo_pdf','[]'::jsonb) else ferias_cronograma.anexo_pdf end
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.ferias_cronograma_salvar(uuid, jsonb) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. O painel Percentuais compara cada pelotão/grupamento com o seu
-- limite do mapa (feito na tela). Não precisa re-rodar anteriores.
-- ══════════════════════════════════════════════════════════════════════

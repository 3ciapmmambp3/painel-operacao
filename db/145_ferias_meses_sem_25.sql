-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — meses em que NÃO se pode tirar "25 dias direto" (configurável)
--
--  Antes era FIXO no código do front (jan/jul/dez). A regra mudou de ano para
--  ano, então passa a ser GUARDADA NO CRONOGRAMA DE CADA ANO, num array de
--  meses ("01".."12"). O Aux P1 marca/desmarca na aba Cronograma & Prazos.
--    • Array VAZIO  = sem restrição (todos os períodos liberam os 25 dias).
--    • Ex. ["01","07","12"] = jan/jul/dez só permitem 15 + 10 (fracionado).
--
--  Também RESTAURA no ferias_cronograma_salvar os campos limites_pelotao /
--  limites_grupamento, que o db/119 havia deixado de persistir (eram lidos,
--  mas não gravados). Esta versão do salvar grava TODOS os campos.
--
--  Depende de: 101 (ferias_cronograma / _salvar), 103 (limites_*),
--  119 (contar_reconvocados). Idempotente. Rodar depois do 121.
-- ══════════════════════════════════════════════════════════════════════

-- Garante que todas as colunas usadas pelo salvar existam (ordem-independente).
alter table public.ferias_cronograma add column if not exists limites_pelotao     jsonb   not null default '{}'::jsonb;
alter table public.ferias_cronograma add column if not exists limites_grupamento  jsonb   not null default '{}'::jsonb;
alter table public.ferias_cronograma add column if not exists contar_reconvocados boolean not null default false;
-- Coluna nova. Default = regra clássica (jan/jul/dez) para não mudar anos já
-- salvos (ex.: 2026). O ano novo é liberado logo abaixo.
alter table public.ferias_cronograma add column if not exists meses_sem_25 jsonb not null default '["01","07","12"]'::jsonb;

-- A partir do exercício de 2027 a restrição deixa de valer (decisão do Comando):
-- libera os 25 dias direto em todos os meses. Se precisar voltar a restringir
-- algum ano futuro, basta marcar os meses na tela e salvar.
update public.ferias_cronograma set meses_sem_25 = '[]'::jsonb where ano >= 2027;

-- ─── cronograma: salvar (versão COMPLETA: todos os campos) ─────────────
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
    pct_max_cia, pct_max_pelotao, pct_max_grupamento, contar_reconvocados,
    limites_pelotao, limites_grupamento, meses_sem_25,
    periodos, anexo_pdf, criado_por_matricula, criado_por_nome
  ) values (
    v_ano, nullif(p_dados->>'titulo',''),
    coalesce(nullif(p_dados->>'situacao',''),'RASCUNHO'),
    nullif(p_dados->>'data_abertura','')::date, nullif(p_dados->>'data_limite','')::date,
    nullif(p_dados->>'pct_max_cia','')::numeric,
    nullif(p_dados->>'pct_max_pelotao','')::numeric,
    nullif(p_dados->>'pct_max_grupamento','')::numeric,
    coalesce((p_dados->>'contar_reconvocados')::boolean, false),
    coalesce(p_dados->'limites_pelotao','{}'::jsonb),
    coalesce(p_dados->'limites_grupamento','{}'::jsonb),
    coalesce(p_dados->'meses_sem_25','[]'::jsonb),
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
    contar_reconvocados= case when p_dados ? 'contar_reconvocados' then coalesce((p_dados->>'contar_reconvocados')::boolean,false) else ferias_cronograma.contar_reconvocados end,
    limites_pelotao    = case when p_dados ? 'limites_pelotao'    then coalesce(p_dados->'limites_pelotao','{}'::jsonb)    else ferias_cronograma.limites_pelotao end,
    limites_grupamento = case when p_dados ? 'limites_grupamento' then coalesce(p_dados->'limites_grupamento','{}'::jsonb) else ferias_cronograma.limites_grupamento end,
    meses_sem_25       = case when p_dados ? 'meses_sem_25'       then coalesce(p_dados->'meses_sem_25','[]'::jsonb)       else ferias_cronograma.meses_sem_25 end,
    periodos           = case when p_dados ? 'periodos'  then coalesce(p_dados->'periodos','[]'::jsonb)  else ferias_cronograma.periodos end,
    anexo_pdf          = case when p_dados ? 'anexo_pdf' then coalesce(p_dados->'anexo_pdf','[]'::jsonb) else ferias_cronograma.anexo_pdf end
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function public.ferias_cronograma_salvar(uuid, jsonb) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. O ferias_cronograma_get (db/101) devolve a linha inteira, então o
-- campo meses_sem_25 chega à tela automaticamente. A validação do "25 dias
-- direto" é feita no front a partir desse campo.
-- Reverter: alter table ferias_cronograma drop column meses_sem_25;
--           e reaplicar db/119 (ferias_cronograma_salvar).
-- ══════════════════════════════════════════════════════════════════════

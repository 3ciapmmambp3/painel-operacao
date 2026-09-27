-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — aviso no Meu Dia do militar (Fase 4)
--  Devolve, para o militar logado, a situação das suas férias VALIDADAS:
--   • EM_CURSO  → está de férias hoje (até dd/mm)
--   • PROXIMA   → começam em X dias (dentro de 45 dias)
--   • VALIDADA  → validadas para uma data futura (> 45 dias)
--  Some quando o período já passou por completo.
--  Depende de: 04, 101/110 (ferias_pedidos.parcelas). Idempotente. Rodar depois do 113.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_avisos_get(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_out  jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  with parc as (
    select nullif(p2->>'ini','')::date as ini, nullif(p2->>'fim','')::date as fim,
           p2->>'parcela' as parcela, p2->>'periodo' as periodo
      from public.ferias_pedidos p
      cross join lateral jsonb_array_elements(p.parcelas) p2
     where p.militar_id = v_me.id and p.situacao = 'VALIDADO'
       and nullif(p2->>'ini','') is not null and nullif(p2->>'fim','') is not null
  ),
  fut as ( select * from parc where fim >= v_hoje ),
  resumo as (
    select string_agg(
             parcela || ' dias' || case when coalesce(periodo,'')<>'' then ' · Período '||periodo else '' end
             || ' · ' || to_char(ini,'DD/MM') || '–' || to_char(fim,'DD/MM'),
             '  +  ' order by ini) as r
      from fut
  ),
  ong  as ( select * from fut where v_hoje between ini and fim order by fim desc limit 1 ),
  prox as ( select * from fut where ini > v_hoje order by ini limit 1 )
  select case
    when not exists (select 1 from fut) then jsonb_build_object('tem', false)
    when exists (select 1 from ong) then jsonb_build_object(
      'tem', true, 'tipo', 'EM_CURSO',
      'fim_br', (select to_char(fim,'DD/MM/YYYY') from ong),
      'resumo', (select r from resumo))
    when exists (select 1 from prox) then jsonb_build_object(
      'tem', true,
      'tipo', case when (select ini from prox) - v_hoje <= 45 then 'PROXIMA' else 'VALIDADA' end,
      'ini_br', (select to_char(ini,'DD/MM/YYYY') from prox),
      'dias', (select ini - v_hoje from prox),
      'resumo', (select r from resumo))
    else jsonb_build_object('tem', false)
  end into v_out;

  return coalesce(v_out, jsonb_build_object('tem', false));
end;
$$;
grant execute on function public.ferias_avisos_get(uuid) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do 113.
-- ══════════════════════════════════════════════════════════════════════

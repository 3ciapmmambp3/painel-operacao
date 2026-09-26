-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — percentual NÃO conta Assistentes Administrativos (ASPM) nem
--  funcionários civis. O teto de % é sobre MILITARES.
--
--  Redefine ferias_percentuais (igual ao db/101) trocando só o filtro do
--  efetivo: exclui qualquer função contendo 'ASPM' e postos civis.
--  Depende de: 101 (estrutura), 104 (_ferias_pelotao com ADM), unaccent_safe (101).
--  Idempotente. Rodar depois do 104.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_percentuais(p_token uuid, p_ano int default null, p_data date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_ano  int  := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_dia  date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
  v_out  jsonb;
  v_crono public.ferias_cronograma;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Painel de percentuais restrito ao Aux P1 / Comando.';
  end if;
  select * into v_crono from public.ferias_cronograma where ano = v_ano;

  with efetivo as (
    select m.id, m.grupamento_id, public._ferias_pelotao(m.grupamento_id) as pelotao
      from public.militares m
     where m.ativo = true
       and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and upper(coalesce(m.funcao,'')) not like '%ASPM%'                              -- assistente administrativo
       and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'  -- funcionário civil
  ),
  em_ferias as (
    select distinct p.militar_id, p.pelotao, p.grupamento_id
      from public.ferias_pedidos p
      join efetivo e on e.id = p.militar_id   -- só quem conta no efetivo (exclui ASPM/civil)
      cross join lateral jsonb_array_elements(p.parcelas) parc
     where p.ano = v_ano
       and p.situacao = 'VALIDADO'
       and nullif(parc->>'ini','')::date <= v_dia
       and nullif(parc->>'fim','')::date >= v_dia
  ),
  cia as (
    select (select count(*) from efetivo) as total,
           (select count(*) from em_ferias) as ferias
  ),
  por_pel as (
    select e.pelotao,
           count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.pelotao is not distinct from e.pelotao) as ferias
      from efetivo e group by e.pelotao
  ),
  por_gp as (
    select e.grupamento_id,
           count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.grupamento_id is not distinct from e.grupamento_id) as ferias
      from efetivo e group by e.grupamento_id
  )
  select jsonb_build_object(
    'ano', v_ano, 'data', v_dia,
    'limites', jsonb_build_object(
      'cia', v_crono.pct_max_cia, 'pelotao', v_crono.pct_max_pelotao, 'grupamento', v_crono.pct_max_grupamento),
    'cia', (select jsonb_build_object('total', total, 'ferias', ferias,
              'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end) from cia),
    'pelotoes', coalesce((select jsonb_agg(jsonb_build_object(
              'pelotao', coalesce(pelotao,'(sem pelotão)'), 'total', total, 'ferias', ferias,
              'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end)
              order by pelotao) from por_pel), '[]'::jsonb),
    'grupamentos', coalesce((select jsonb_agg(jsonb_build_object(
              'grupamento', coalesce(grupamento_id,'(sem GP)'), 'total', total, 'ferias', ferias,
              'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end)
              order by grupamento_id) from por_gp), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

grant execute on function public.ferias_percentuais(uuid, int, date) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Não precisa re-rodar anteriores.
-- ══════════════════════════════════════════════════════════════════════

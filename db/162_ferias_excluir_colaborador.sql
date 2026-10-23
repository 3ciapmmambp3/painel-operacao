-- ============================================================================
-- db/162 — Férias: excluir COLABORADOR (não-militar) do roster e do percentual.
--
-- O colaborador (ex. Mateus C932305, categoria='colaborador') está na tabela
-- militares (para acessar o hub P1), mas NÃO deve aparecer para escolher férias
-- nem contar no percentual. As funções de férias já excluíam ASPM e CIVIL, mas
-- não o colaborador. Acrescenta `categoria <> 'colaborador'` (mesma regra do
-- tta_listar_militares, db/135).
--
-- QPR/QOR (reconvocados): agora APARECEM no roster "falta escolher"
-- (ferias_efetivo_escopo) — eles precisam escolher férias. Antes o roster
-- excluía quem tinha "QPR"/"QOR" no posto (ex. "1º Sgt PM QPR"), então esses
-- não apareciam. No PERCENTUAL (ferias_percentuais) eles SEGUEM sem contar.
--
-- Rodar no SQL editor do Supabase. Redefine ferias_efetivo_escopo (db/150) e
-- ferias_percentuais (db/119).
-- ============================================================================

-- ── roster "falta escolher" / efetivo do escopo ────────────────────────────
create or replace function public.ferias_efetivo_escopo(p_token uuid, p_ano int default null)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text, pelotao text, funcao text)
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_ano    int := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_full   boolean;
  v_mypel  text;
  v_reconv boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  v_full := public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao);
  if not v_full
     and coalesce(v_me.nivel_acesso,'') not in ('admin_pelotao','admin_gp')
     and coalesce(v_me.funcao,'') !~* '(cmt|comandante)' then
    raise exception 'Consulta restrita ao Aux P1 / Comando.';
  end if;

  v_mypel := public._ferias_pelotao(v_me.grupamento_id);
  select coalesce(contar_reconvocados, false) into v_reconv
    from public.ferias_cronograma where ano = v_ano;
  v_reconv := coalesce(v_reconv, false);

  return query
    select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra,
           m.grupamento_id, public._ferias_pelotao(m.grupamento_id) as pelotao, m.funcao
      from public.militares m
     where m.ativo = true
       and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and upper(coalesce(m.funcao,'')) not like '%ASPM%'
       and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
       and coalesce(m.categoria,'militar') <> 'colaborador'   -- colaborador não é militar
       -- QPR/QOR (reconvocados) APARECEM no roster (precisam escolher férias);
       -- eles só não CONTAM no percentual (isso fica em ferias_percentuais).
       and (
            v_full
         or (coalesce(v_me.nivel_acesso,'') = 'admin_pelotao'
             and public._ferias_pelotao(m.grupamento_id) is not distinct from v_mypel)
         or (coalesce(v_me.nivel_acesso,'') = 'admin_gp'
             and m.grupamento_id = v_me.grupamento_id)
         or (coalesce(v_me.nivel_acesso,'') not in ('admin_pelotao','admin_gp')
             and m.grupamento_id = v_me.grupamento_id)
       )
     order by pelotao nulls last, m.grupamento_id, m.posto_graduacao, m.nome_completo;
end;
$$;

-- ── percentuais (Cia/pelotão/grupamento) ────────────────────────────────────
create or replace function public.ferias_percentuais(p_token uuid, p_ano int default null, p_data date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_ano  int  := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_dia  date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
  v_out  jsonb;
  v_crono public.ferias_cronograma;
  v_reconv boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Painel de percentuais restrito ao Aux P1 / Comando.';
  end if;
  select * into v_crono from public.ferias_cronograma where ano = v_ano;
  v_reconv := coalesce(v_crono.contar_reconvocados, false);

  with efetivo as (
    select m.id, m.grupamento_id, public._ferias_pelotao(m.grupamento_id) as pelotao
      from public.militares m
     where m.ativo = true
       and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and upper(coalesce(m.funcao,'')) not like '%ASPM%'
       and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
       and coalesce(m.categoria,'militar') <> 'colaborador'   -- colaborador não conta
       and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                         and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
  ),
  em_ferias as (
    select distinct p.militar_id, p.pelotao, p.grupamento_id
      from public.ferias_pedidos p
      join efetivo e on e.id = p.militar_id
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
    select e.pelotao, count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.pelotao is not distinct from e.pelotao) as ferias
      from efetivo e group by e.pelotao
  ),
  por_gp as (
    select e.grupamento_id, count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.grupamento_id is not distinct from e.grupamento_id) as ferias
      from efetivo e group by e.grupamento_id
  )
  select jsonb_build_object(
    'ano', v_ano, 'data', v_dia,
    'contar_reconvocados', v_reconv,
    'limites', jsonb_build_object(
      'cia', coalesce(v_crono.pct_max_cia, 15), 'pelotao', v_crono.pct_max_pelotao, 'grupamento', v_crono.pct_max_grupamento),
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

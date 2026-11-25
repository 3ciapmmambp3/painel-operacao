-- ════════════════════════════════════════════════════════════════════════
-- 218_crimes_avisos_meudia.sql
--
-- AVISO no Meu Dia: "Novidades na base criminal da sua área".
-- Sempre que a importação alimentar o bd_crimes com um REGISTRO NOVO
-- (IMV / CVPE / CVPA / IF), o militar daquele grupamento passa a ver, na
-- home (Meu Dia → 🔔 Avisos para você), um aviso por 7 dias, com o total por
-- indicador e os 3 mais recentes, direcionando para a Análise Criminal.
--
-- Como sabemos o que é "novo"?
--   • Acrescentamos bd_crimes.created_at (timestamptz, default now()).
--   • O UPSERT da importação (on_conflict=numero_reds, merge-duplicates) NÃO
--     envia created_at — logo, a coluna só é gravada na PRIMEIRA vez que o
--     REDS entra. Reimportar um REDS já existente NÃO mexe no created_at.
--   • Os registros que JÁ existiam quando esta migração rodou recebem uma data
--     antiga (a própria data_fato), para não gerar um "flood" de 'tudo novo'
--     no primeiro deploy. Só o que entrar DEPOIS conta como novidade.
--
-- Como ligamos o crime ao grupamento do militar?
--   • bd_crimes.municipio → vw_municipio_grupamento.grupamento_completo.
--   • militares.grupamento_id JÁ é o grupamento_completo do cadastro
--     (ver chamada-instrucao.html:738) → match direto.
--   • Cmt Cia / admin_geral veem a Companhia inteira.
--   • Militar lotado em PELOTÃO (grupamento_id não bate um GP) cai no match
--     por pelotão. Colaborador não-militar não recebe o aviso (feito no front).
--
-- Depende de: 00_grupamentos_view.sql, 04_sessoes_e_militares_seguranca.sql.
-- Idempotente. Seguro rodar mais de uma vez. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

/* ─── 1) carimbo de entrada no bd_crimes ────────────────────────────────── */
-- adiciona SEM default (existentes ficam NULL, sem rewrite da tabela)
alter table public.bd_crimes
  add column if not exists created_at timestamptz;

-- backfill ÚNICO dos registros antigos com data FIXA antiga: assim o primeiro
-- deploy é silencioso e SÓ o que entrar na PRÓXIMA importação conta como novo
-- (o gatilho do aviso é a importação, não a data do fato).
update public.bd_crimes
   set created_at = timestamptz '2000-01-01'
 where created_at is null;

-- a partir de agora, todo registro NOVO (INSERT da importação) nasce com now()
alter table public.bd_crimes
  alter column created_at set default now();

-- janela de 7 dias consultada com frequência → índice ajuda
create index if not exists idx_bd_crimes_created_at
  on public.bd_crimes (created_at);


/* ─── 2) RPC: avisos de novos crimes para o militar do token ────────────── */
create or replace function public.crimes_avisos_get(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me        record;
  v_ve_todas  boolean;
  v_is_gp     boolean;        -- militar lotado num GP (grupamento_id casa com um grupamento_completo)
  v_pel_num   int;            -- nº do pelotão do militar (quando lotado em PEL)
  v_janela    timestamptz := now() - interval '7 days';
  v_total     int := 0;
  v_imv       int := 0;
  v_cvpe      int := 0;
  v_cvpa      int := 0;
  v_if        int := 0;
  v_teasers   jsonb := '[]'::jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    return jsonb_build_object('tem', false);
  end if;

  -- Cmt Cia / admin_geral enxergam a Companhia inteira (mesma regra do aviso de instrução)
  v_ve_todas := coalesce(v_me.nivel_acesso,'') = 'admin_geral'
    or (coalesce(v_me.funcao,'') ~* '(cmt|comandante)'
        and coalesce(v_me.funcao,'') ~* '\ycia\y');

  -- GP-lotado? grupamento_id bate um grupamento_completo da view
  v_is_gp := exists (
    select 1 from public.vw_municipio_grupamento
     where grupamento_completo = v_me.grupamento_id);

  -- nº do pelotão do militar (fallback p/ quem é lotado no PEL, não num GP)
  v_pel_num := nullif((regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1], '')::int;

  -- Registros NOVOS (created_at na janela) da área do militar, com os totais
  with novos as (
    select distinct on (b.id)
           b.id, b.numero_reds, b.municipio, b.data_fato,
           b.descr_natureza_principal,
           coalesce(b.imv_total,0)   as imv,
           coalesce(b.icvpe_total,0) as cvpe,
           coalesce(b.icvpa_total,0) as cvpa,
           coalesce(b.ifzr,0)        as ifz,
           b.created_at
      from public.bd_crimes b
      join public.vw_municipio_grupamento v
        on upper(btrim(v.municipio)) = upper(btrim(b.municipio))
     where b.created_at >= v_janela
       and (
            v_ve_todas
         or (v_is_gp and v.grupamento_completo = v_me.grupamento_id)
         or (not v_is_gp and v_pel_num is not null
             and nullif((regexp_match(coalesce(v.pelotao,''), '(\d+)'))[1], '')::int = v_pel_num)
       )
  )
  select
    count(*)::int,
    count(*) filter (where imv  > 0)::int,
    count(*) filter (where cvpe > 0)::int,
    count(*) filter (where cvpa > 0)::int,
    count(*) filter (where ifz  > 0)::int
  into v_total, v_imv, v_cvpe, v_cvpa, v_if
  from novos;

  if v_total = 0 then
    return jsonb_build_object('tem', false);
  end if;

  -- 3 mais recentes para o "teaser" (indicador de maior gravidade de cada um)
  select coalesce(jsonb_agg(t order by t_created desc), '[]'::jsonb)
    into v_teasers
  from (
    select jsonb_build_object(
             'reds',     numero_reds,
             'municipio',municipio,
             'data',     data_fato,
             'natureza', descr_natureza_principal,
             'ind',      case when imv  > 0 then 'IMV'
                              when cvpe > 0 then 'CVPE'
                              when cvpa > 0 then 'CVPA'
                              else 'IF' end,
             'violento', (imv > 0 or cvpe > 0 or cvpa > 0)
           ) as t,
           created_at as t_created
      from (
        select distinct on (b.id)
               b.id, b.numero_reds, b.municipio, b.data_fato,
               b.descr_natureza_principal,
               coalesce(b.imv_total,0)   as imv,
               coalesce(b.icvpe_total,0) as cvpe,
               coalesce(b.icvpa_total,0) as cvpa,
               coalesce(b.ifzr,0)        as ifz,
               b.created_at
          from public.bd_crimes b
          join public.vw_municipio_grupamento v
            on upper(btrim(v.municipio)) = upper(btrim(b.municipio))
         where b.created_at >= v_janela
           and (
                v_ve_todas
             or (v_is_gp and v.grupamento_completo = v_me.grupamento_id)
             or (not v_is_gp and v_pel_num is not null
                 and nullif((regexp_match(coalesce(v.pelotao,''), '(\d+)'))[1], '')::int = v_pel_num)
           )
      ) q
     order by created_at desc
     limit 3
  ) s;

  return jsonb_build_object(
    'tem',       true,
    've_todas',  v_ve_todas,
    'total',     v_total,
    'imv',       v_imv,
    'cvpe',      v_cvpe,
    'cvpa',      v_cvpa,
    'if',        v_if,
    'violento',  (v_imv > 0 or v_cvpe > 0 or v_cvpa > 0),
    'teasers',   v_teasers
  );
end;
$$;

grant execute on function public.crimes_avisos_get(uuid) to anon;

-- ══════════════════════════════════════════════════════════════════════
--  UEOp por município (aba Administração → Grupamentos)
--  --------------------------------------------------------------------
--  Antes a coluna "BPM" da aba Grupamentos lia grupos.bpm, que estava
--  VAZIA em todas as 33 linhas → coluna saía em branco para toda cidade.
--
--  O batalhão/CIA real de cada cidade é o UEOp (Unidade de Execução
--  Operacional), que já aparece na aba Ocorrências vindo de
--  bd_crimes.unid_area_nivel_5. Como o UEOp é POR MUNICÍPIO (7 GPs têm
--  cidades em batalhões diferentes), ele mora aqui na municipios_grupos,
--  não na grupos (que é por GP).
--
--  Este script:
--   1. cria a coluna municipios_grupos.ueop
--   2. faz o backfill com o UEOp mais frequente de cada cidade em bd_crimes
--
--  Cobertura esperada: ~203 de 221 linhas. As ~18 sem UEOp são cidades
--  sem NENHUMA ocorrência em bd_crimes (ex.: BARRA LONGA, CARMÉSIA,
--  SEM-PEIXE, TAPARUBA) — ficam em branco por falta de fonte; podem ser
--  preenchidas manualmente depois.
--
--  Reexecutável (idempotente): rode quando quiser reatualizar o backfill.
-- ══════════════════════════════════════════════════════════════════════

alter table public.municipios_grupos
  add column if not exists ueop text;

-- Normalização robusta p/ casar os nomes das duas tabelas
-- (acentos, hífen, apóstrofo, ponto e espaços múltiplos).
with best as (
  select distinct on (mun_n) mun_n, ueop
  from (
    select
      trim(regexp_replace(
        translate(upper(municipio),
          'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ-''.',
          'AAAAAEEEEIIIIOOOOOUUUUC   '),
        '\s+', ' ', 'g'))          as mun_n,
      trim(unid_area_nivel_5)      as ueop,
      count(*)                     as n
    from public.bd_crimes
    where coalesce(trim(unid_area_nivel_5), '') <> ''
      and coalesce(trim(municipio), '')        <> ''
    group by 1, 2
  ) t
  order by mun_n, n desc          -- desempate: UEOp mais frequente vence
)
update public.municipios_grupos mg
set ueop = b.ueop
from best b
where trim(regexp_replace(
        translate(upper(mg.municipio),
          'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ-''.',
          'AAAAAEEEEIIIIOOOOOUUUUC   '),
        '\s+', ' ', 'g')) = b.mun_n;

-- Conferência rápida (opcional):
--   select count(*) filter (where ueop is not null and ueop <> '') as com_ueop,
--          count(*)                                                as total
--   from public.municipios_grupos;

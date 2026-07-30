-- ══════════════════════════════════════════════════════════════════════
--  VIEW: município → grupamento COMPLETO
--  Liga a tabela de municípios (municipios_grupos) à de grupamentos (grupos),
--  devolvendo o rótulo completo, ex.:
--    "1 GP / 1 PEL / 3 CIA PM MAMB / GOVERNADOR VALADARES"
--  Rodar ANTES de 01_denuncias.sql.
-- ══════════════════════════════════════════════════════════════════════
create or replace view public.vw_municipio_grupamento as
select
  mg.municipio,
  upper(mg.municipio)                                   as municipio_upper,
  mg.gp_responsavel,                                    -- chave curta: "GP GOVERNADOR VALADARES"
  coalesce(g.grupamento_completo, mg.gp_responsavel)    as grupamento_completo,  -- rótulo completo
  g.pelotao,
  g.rpm,
  g.cia
from public.municipios_grupos mg
left join public.grupos g on g.gp_responsavel = mg.gp_responsavel;

grant select on public.vw_municipio_grupamento to anon;

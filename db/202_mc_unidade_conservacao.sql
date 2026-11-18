-- db/202 — Monitoramento Contínuo: consulta de Unidade de Conservação (UC) por ponto.
--
-- Fonte: IDE OFICIAL de Minas Gerais (geoserver.meioambiente.mg.gov.br/IDE/wfs) —
-- WFS público (CORS liberado), consultado client-side pelo próprio painel por
-- INTERSECTS do ponto (coord_y=lat, coord_x=lon) contra as 3 camadas de UC
-- (estaduais, federais, municipais). O resultado é gravado NA PRÓPRIA LINHA do
-- MC (mesmo padrão do CAR/SICAR), para ficar disponível a todos e evitar que
-- cada militar tenha que reconsultar o mesmo ponto.
--
-- Idempotente (re-runnable).

alter table public.mc_demandas
  add column if not exists uc_dados        jsonb,
  add column if not exists uc_consultado_em timestamptz;

comment on column public.mc_demandas.uc_dados is
  'Unidades de Conservação que contêm o ponto do MC. Array JSON de '
  '{nome_uc, categoria, grupo, esfera, ato_legal, bioma, municipios}. '
  'Array vazio [] = ponto fora de qualquer UC. Fonte: IDE MG (WFS público).';

comment on column public.mc_demandas.uc_consultado_em is
  'Data/hora da última consulta de Unidade de Conservação para este ponto.';

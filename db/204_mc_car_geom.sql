-- ══════════════════════════════════════════════════════════════════════
--  MC — geometria do imóvel rural (polígono do CAR) p/ exportar/mapa
--  Rodar no Supabase (SQL Editor). Idempotente. Aditivo (não quebra nada).
--
--  Guarda o(s) polígono(s) do imóvel (base_sicar_mg do Harpia) por GEOCOD,
--  numa coluna SEPARADA (jsonb) — de propósito FORA do SELECT da lista leve
--  do painel, pra não pesar o carregamento. É lida sob demanda (gaveta, mapa,
--  exportar KML/GeoJSON).
--
--  Formato: array, 1 por imóvel, parelho ao car_dados:
--    [{ "cod_imovel": "MG-...", "geometry": { GeoJSON Polygon/MultiPolygon } }, ...]
--  CRS das coordenadas = EPSG:4674 (SIRGAS 2000) ~ WGS84 (lon,lat) — serve
--  direto p/ Leaflet, KML (Google Earth) e GeoJSON (QGIS/shapefile).
-- ══════════════════════════════════════════════════════════════════════

alter table public.mc_demandas add column if not exists car_geom jsonb;

-- índice parcial leve só p/ achar rápido quem AINDA não tem geometria
-- (usado pelo importador p/ decidir o que falta, sem ler o jsonb inteiro).
create index if not exists ix_mc_car_geom_nulo
  on public.mc_demandas (id)
  where car_geom is null;

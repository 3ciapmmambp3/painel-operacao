-- ══════════════════════════════════════════════════════════════════════
-- db/197 — CAR / SICAR por ponto do Monitoramento Contínuo
-- Guarda o imóvel rural (CAR) que contém a coordenada do GEOCOD, consultado
-- no GeoServer oficial do SICAR (geoserver.car.gov.br) pelo nosso Apps Script
-- (AutomacaoCastro → mc_car_backfill → consultarCarPorCoordenada).
-- Segue o padrão UPDATE-only do mc_set_kml (db/158/160): nunca insere, só
-- atualiza por 'codigo' (GEOCOD_IEF). grant p/ anon (o Apps Script usa a anon).
--   car_imovel        nº(s) do CAR (cod_imovel), vírgula-separado se houver +de1
--   car_qtd           quantos imóveis rurais intersectam o ponto
--   car_dados         [{cod_imovel,municipio,area,status}] p/ detalhe na gaveta
--   car_consultado_em carimbo da consulta (null = ainda não consultado)
-- ══════════════════════════════════════════════════════════════════════

alter table public.mc_demandas
  add column if not exists car_imovel        text,
  add column if not exists car_qtd           int,
  add column if not exists car_dados         jsonb,
  add column if not exists car_consultado_em timestamptz;

create or replace function public.mc_set_car(linhas jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  n int := 0;
begin
  if linhas is null or jsonb_typeof(linhas) <> 'array' then
    raise exception 'mc_set_car: esperado um array JSON';
  end if;

  for r in select * from jsonb_array_elements(linhas)
  loop
    if nullif(trim(r->>'codigo'),'') is null then
      continue;
    end if;
    update public.mc_demandas
       set car_imovel        = nullif(trim(r->>'car_imovel'),''),
           car_qtd           = nullif(r->>'car_qtd','')::int,
           car_dados         = case when r ? 'car_dados' then r->'car_dados' else car_dados end,
           car_consultado_em = now()
     where codigo = trim(r->>'codigo');
    if found then n := n + 1; end if;
  end loop;

  return n;
end;
$$;

grant execute on function public.mc_set_car(jsonb) to anon;

-- Rodar depois do db/196. Não toca em data/baixa — só preenche o CAR.

-- ============================================================================
-- db/160 — mc_set_kml: além do KML (só pendentes), grava também o PONTO
-- (coord_x = longitude, coord_y = latitude) extraído do centroide do KML.
--
-- Por quê: habilitar "demandas próximas (raio)" no MC. O ponto é barato (dois
-- números) e serve até p/ demanda já atendida — então coord é gravada SEMPRE
-- que vier no payload; o kml_content continua só p/ PENDENTES (regra db/159).
--
-- Payload por linha: { codigo, kml, lon, lat, kml_link? }.
-- Continua só UPDATE (nunca INSERT). GEOCOD inexistente é ignorado.
--
-- Rodar no SQL editor do Supabase. Substitui a versão de db/159.
-- ============================================================================

create or replace function public.mc_set_kml(linhas jsonb)
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
    raise exception 'mc_set_kml: esperado um array JSON';
  end if;

  for r in select * from jsonb_array_elements(linhas)
  loop
    if nullif(trim(r->>'codigo'),'') is null then
      continue;
    end if;
    update public.mc_demandas
       set coord_x = coalesce(nullif(r->>'lon',''), coord_x),
           coord_y = coalesce(nullif(r->>'lat',''), coord_y),
           kml_link = coalesce(nullif(r->>'kml_link',''), kml_link),
           kml_content = case
             when data_atendimento is null
              and coalesce(situacao,'') not in ('RESPONDIDA','FINALIZADA')
             then coalesce(nullif(r->>'kml',''), kml_content)
             else kml_content
           end
     where codigo = trim(r->>'codigo');
    if found then n := n + 1; end if;
  end loop;

  return n;
end $$;

grant execute on function public.mc_set_kml(jsonb) to anon;

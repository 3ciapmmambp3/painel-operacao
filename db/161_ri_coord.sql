-- ============================================================================
-- db/161 — FTP/RI: coordenada do incêndio (coord_x = longitude, coord_y = lat).
--
-- A coordenada "COORDENADAS/INCÊNDIO (Graus, Min. e Seg.)" não está na planilha
-- de controle — ela fica DENTRO do documento de cada RI (coluna "CLIQUE PARA
-- BAIXAR"). O backfill no Apps Script lê o doc, converte DMS→decimal e chama
-- esta função. Habilita o "demandas a ≤5 km" no FTP/RI, igual ao MC.
--
-- Só UPDATE (nunca INSERT); grava apenas a coordenada. Rodar no SQL do Supabase.
-- Depende de db/154 (ri_demandas).
-- ============================================================================

alter table public.ri_demandas add column if not exists coord_x text;  -- longitude
alter table public.ri_demandas add column if not exists coord_y text;  -- latitude
create index if not exists idx_ri_coord_y on public.ri_demandas (coord_y);

create or replace function public.ri_set_coord(linhas jsonb)
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
    raise exception 'ri_set_coord: esperado um array JSON';
  end if;

  for r in select * from jsonb_array_elements(linhas)
  loop
    if nullif(trim(r->>'codigo'),'') is null then
      continue;
    end if;
    update public.ri_demandas
       set coord_x = coalesce(nullif(r->>'lon',''), coord_x),
           coord_y = coalesce(nullif(r->>'lat',''), coord_y)
     where codigo = trim(r->>'codigo');
    if found then n := n + 1; end if;
  end loop;

  return n;
end $$;

grant execute on function public.ri_set_coord(jsonb) to anon;

-- ============================================================================
-- db/163 — NUDEN: coordenada da demanda (coord_x = longitude, coord_y = lat).
--
-- A coordenada NÃO está na planilha de controle do NUDEN — ela fica DENTRO do
-- PDF da denúncia, no bloco "Informações Geográficas / Latitude e Longitude:
-- -18.66613936,-41.76145973" (lat primeiro, depois lon, separados por vírgula).
-- O backfill no Apps Script lê o texto do PDF, extrai o par e chama esta função.
-- Habilita no NUDEN o "mesmo local por coordenada" e o "demandas a ≤5 km",
-- igual ao MC e ao FTP/RI. Quando a demanda não tem coordenada, o painel cai
-- no agrupamento por TEXTO (município+endereço) — regra "coord se tiver, senão texto".
--
-- Só UPDATE (nunca INSERT); grava apenas a coordenada. Rodar no SQL do Supabase.
-- Idempotente. Depende de db/151 (nuden_demandas).
-- ============================================================================

alter table public.nuden_demandas add column if not exists coord_x text;  -- longitude
alter table public.nuden_demandas add column if not exists coord_y text;  -- latitude
create index if not exists idx_nuden_coord_y on public.nuden_demandas (coord_y);

create or replace function public.nuden_set_coord(linhas jsonb)
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
    raise exception 'nuden_set_coord: esperado um array JSON';
  end if;

  for r in select * from jsonb_array_elements(linhas)
  loop
    if nullif(trim(r->>'codigo'),'') is null then
      continue;
    end if;
    update public.nuden_demandas
       set coord_x = coalesce(nullif(r->>'lon',''), coord_x),
           coord_y = coalesce(nullif(r->>'lat',''), coord_y)
     where codigo = trim(r->>'codigo');
    if found then n := n + 1; end if;
  end loop;

  return n;
end $$;

grant execute on function public.nuden_set_coord(jsonb) to anon;

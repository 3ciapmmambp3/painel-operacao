-- ============================================================================
-- db/158 — mc_set_kml: preenche SOMENTE o KML individual (kml_content/kml_link)
-- de linhas que JÁ EXISTEM em mc_demandas, casando por GEOCOD (codigo).
--
-- Motivo: "Importar da planilha" (runMC) traz os dados tabulares + casa os PDFs,
-- mas NÃO gera o KML por GEOCOD (a planilha não carrega geometria). O backfill no
-- Apps Script varre os KML mestres das pastas do Drive e chama esta função.
--
-- SEGURANÇA: é só UPDATE (nunca INSERT) e toca APENAS no KML — não altera data,
-- baixa, PDF nem nenhum outro campo. GEOCOD inexistente é ignorado.
--
-- Rodar no SQL editor do Supabase. Depende de db/157.
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
    if nullif(trim(r->>'codigo'),'') is null or nullif(r->>'kml','') is null then
      continue;
    end if;
    update public.mc_demandas
       set kml_content = r->>'kml',
           kml_link    = coalesce(nullif(r->>'kml_link',''), kml_link)
     where codigo = trim(r->>'codigo');
    if found then n := n + 1; end if;
  end loop;

  return n;
end $$;

grant execute on function public.mc_set_kml(jsonb) to anon;

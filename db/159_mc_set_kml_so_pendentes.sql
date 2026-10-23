-- ============================================================================
-- db/159 — mc_set_kml: preenche o KML individual APENAS das demandas PENDENTES.
--
-- Decisão (1ª etapa): demanda já atendida/fiscalizada não precisa do croqui/KML,
-- então o backfill só grava kml_content em quem ainda está pendente. Isso evita
-- inchar o Supabase com geometria que não será usada.
--
-- "Pendente" = mesma regra do painel (atendidaN):
--   data_atendimento IS NULL  E  situacao NÃO em ('RESPONDIDA','FINALIZADA').
--
-- Continua sendo só UPDATE (nunca INSERT) e só toca o KML. GEOCOD inexistente
-- ou já atendido é ignorado (found=false, não conta).
--
-- Rodar no SQL editor do Supabase. Substitui a versão de db/158.
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
     where codigo = trim(r->>'codigo')
       and data_atendimento is null
       and coalesce(situacao,'') not in ('RESPONDIDA','FINALIZADA');
    if found then n := n + 1; end if;
  end loop;

  return n;
end $$;

grant execute on function public.mc_set_kml(jsonb) to anon;

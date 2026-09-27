-- ══════════════════════════════════════════════════════════════════════
--  ANTIGUIDADE — não confundir ASPM com ASP
--   • ASPM  = Assistente Administrativo (NÃO é posto militar) → rank 99.
--   • ASP / Asp Of / Asp Of PM = Aspirante a Oficial (militar) → rank 7.
--  A versão do db/101 casava 'ASP' como substring, o que pegava 'ASPM'
--  por engano. Corrige com guarda de ASPM e limite de palavra em ASP.
--  Depende de: 101 (unaccent_safe). Idempotente. Rodar depois do 105.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public._posto_rank(p_pg text)
returns int language sql immutable as $$
  select case
    when p ~ 'ASPM'                                  then 99  -- Assistente Adm (não é posto)
    when p ~ 'CEL' and p ~ 'TEN'                     then 2   -- Ten Cel
    when p ~ 'CEL'                                    then 1   -- Cel
    when p ~ 'MAJ'                                    then 3
    when p ~ 'CAP'                                    then 4
    when p ~ '1.*TEN'                                 then 5
    when p ~ '2.*TEN'                                 then 6
    when p ~ 'ASPIRANTE' or p ~ '\yASP\y'            then 7   -- Aspirante a Oficial
    when p ~ 'SUB.*TEN' or p ~ '\yST\y'              then 8   -- Sub Ten
    when p ~ '1.*SGT'                                 then 9
    when p ~ '2.*SGT'                                 then 10
    when p ~ '3.*SGT'                                 then 11
    when p ~ '\yCB\y' or p ~ 'CABO'                   then 12
    when p ~ '\ySD\y' or p ~ 'SOLDADO'               then 13
    else 99
  end
  from (select upper(public.unaccent_safe(coalesce(p_pg,''))) as p) t;
$$;
grant execute on function public._posto_rank(text) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Não precisa re-rodar anteriores.
-- ══════════════════════════════════════════════════════════════════════

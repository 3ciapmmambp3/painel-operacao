-- ══════════════════════════════════════════════════════════════════════
--  PADRONIZAÇÃO do Posto/Graduação (militares.posto_graduacao)
--
--  Converte os valores já gravados para a lista ÚNICA do painel (a mesma
--  usada no cadastro de Usuários e no Efetivo). Formato de destino = texto
--  exato (ex.: "3º Sgt PM"), já esperado por _posto_rank (db/106).
--
--  Regras:
--    • 13 postos militares: Cel PM, Ten Cel PM, Maj PM, Cap PM, 1º Ten PM,
--      2º Ten PM, Asp PM, Sub Ten PM, 1º Sgt PM, 2º Sgt PM, 3º Sgt PM,
--      Cb PM, Sd PM.
--    • Reconvocado (valor tinha QOR/QPR) → sufixo re-derivado da graduação:
--        Oficiais (Cel → 2º Ten PM) = QOR ; demais praças = QPR.
--    • ASPM = Assistente Administrativo (NÃO é militar, não reconvocável) →
--      mantém "ASPM". NÃO confundir com ASP/Aspirante (que é militar).
--    • Valor não reconhecido → NÃO é alterado (preserva o dado).
--
--  Depende de: 101 (unaccent_safe). Idempotente (pode rodar de novo).
--  Rodar DEPOIS do 106.
-- ══════════════════════════════════════════════════════════════════════

-- Função auxiliar: devolve o posto padronizado, ou NULL se não reconhecer.
create or replace function public._pg_padroniza(p_pg text)
returns text language sql immutable as $$
  with t as (
    select upper(public.unaccent_safe(coalesce(p_pg, ''))) as p
  ),
  b as (
    select
      (p ~ '\yQOR\y' or p ~ '\yQPR\y') as reconv,
      case
        when p ~ 'ASPM'                               then 'ASPM'        -- assistente (não militar)
        when (p ~ 'CEL' and p ~ 'TEN') or p ~ '\yTC\y' then 'Ten Cel PM'  -- inclui abreviação "TC PM"
        when p ~ '\yCEL\y' or p ~ 'CORONEL'           then 'Cel PM'
        when p ~ 'MAJ'                                then 'Maj PM'
        when p ~ 'CAP'                                then 'Cap PM'
        when p ~ '1.*TEN'                             then '1º Ten PM'
        when p ~ '2.*TEN'                             then '2º Ten PM'
        when p ~ 'ASPIRANTE' or p ~ '\yASP\y'         then 'Asp PM'      -- Aspirante a Oficial (militar)
        when p ~ 'SUB.*TEN' or p ~ '\yST\y'           then 'Sub Ten PM'
        when p ~ '1.*SGT'                             then '1º Sgt PM'
        when p ~ '2.*SGT'                             then '2º Sgt PM'
        when p ~ '3.*SGT'                             then '3º Sgt PM'
        when p ~ '\yCB\y' or p ~ 'CABO'               then 'Cb PM'
        when p ~ '\ySD\y' or p ~ 'SOLDADO'            then 'Sd PM'
        else null
      end as base
    from t
  )
  select case
    when base is null       then null                     -- desconhecido: não mexe
    when base = 'ASPM'      then 'ASPM'                    -- assistente: sem quadro
    when reconv then base || ' ' ||
         (case when base in ('Ten Cel PM','Cel PM','Maj PM','Cap PM','1º Ten PM','2º Ten PM')
               then 'QOR' else 'QPR' end)
    else base
  end
  from b;
$$;

-- ── PRÉVIA (opcional): rode este SELECT antes para conferir o que vai mudar ──
-- select matricula, posto_graduacao as antes,
--        public._pg_padroniza(posto_graduacao) as depois
--   from public.militares
--  where public._pg_padroniza(posto_graduacao) is not null
--    and public._pg_padroniza(posto_graduacao) <> coalesce(posto_graduacao,'')
--  order by public._posto_rank(posto_graduacao), matricula;

-- ── APLICA a padronização (só nas linhas reconhecidas e que de fato mudam) ──
update public.militares m
   set posto_graduacao = public._pg_padroniza(m.posto_graduacao)
 where public._pg_padroniza(m.posto_graduacao) is not null
   and public._pg_padroniza(m.posto_graduacao) <> coalesce(m.posto_graduacao, '');

-- Limpa a função auxiliar (não é usada pelo app em runtime).
drop function if exists public._pg_padroniza(text);

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Confira depois com:
--   select posto_graduacao, count(*) from public.militares
--    group by 1 order by public._posto_rank(posto_graduacao), 1;
-- Qualquer valor fora do padrão aparece aqui e pode ser ajustado à mão
-- pelo Efetivo (lista suspensa) ou por Admin › Usuários.
-- ══════════════════════════════════════════════════════════════════════

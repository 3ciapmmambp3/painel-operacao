-- ════════════════════════════════════════════════════════════════════════
-- 41_mov_horario_fix_dados.sql  —  CORREÇÃO DOS HORÁRIOS JÁ GRAVADOS
--
-- CONTEXTO DO BUG (corrigido no frontend em movimentacao-viaturas.html e
-- movimentacao-publica.html): a criação da ficha enviava o valor do
-- <input datetime-local> SEM converter para UTC. Como a sessão do Postgres
-- roda em UTC, a hora LOCAL de Brasília (ex.: 08:00) era gravada como se
-- fosse 08:00 UTC. Na exibição (navegador em UTC-3) isso aparecia ~3h
-- atrasado (05:00). Ou seja: os registros antigos estão com inicio/termino
-- adiantados 3h em relação ao UTC correto — falta somar +3h.
--
-- ⚠️ ATENÇÃO — QUANDO RODAR:
--   • Rode SOMENTE depois que o fix de código estiver em PRODUÇÃO (branch main
--     mergeado e publicado no Vercel). Enquanto a produção ainda gravar errado,
--     migrar os dados só criaria inconsistência.
--   • Rode UMA ÚNICA VEZ. Rodar duas vezes soma 6h (errado).
--   • Ajuste o CUTOFF abaixo para o INSTANTE do deploy do fix em produção.
--     Só as fichas criadas ANTES desse instante serão corrigidas; as criadas
--     depois já nascem certas (código corrigido) e NÃO devem ser tocadas.
--
-- Faça um backup/expdump da tabela antes, se possível.
-- ════════════════════════════════════════════════════════════════════════

-- Defina o instante do deploy do fix em produção (edite a linha abaixo).
-- Formato aceito: 'YYYY-MM-DD HH:MM:SS-03' (Brasília) ou '...+00' (UTC).
-- Deixe o placeholder para FORÇAR o preenchimento (o SQL falha se não editar).
do $$
declare
  v_cutoff timestamptz := '<<PREENCHER_INSTANTE_DO_DEPLOY_EM_PRODUCAO>>';
  v_n      int;
begin
  update public.mov_viaturas
     set inicio  = case when inicio  is not null then inicio  + interval '3 hours' else null end,
         termino = case when termino is not null then termino + interval '3 hours' else null end
   where criado_em < v_cutoff;
  get diagnostics v_n = row_count;
  raise notice 'Fichas corrigidas (+3h): %', v_n;
end $$;

-- Conferência sugerida (rode antes e depois): as horas de inicio/termino
-- em America/Sao_Paulo devem bater com o que foi digitado na ficha.
--   select id, prefixo,
--          inicio  at time zone 'America/Sao_Paulo' as inicio_brt,
--          termino at time zone 'America/Sao_Paulo' as termino_brt,
--          criado_em at time zone 'America/Sao_Paulo' as criado_brt
--     from public.mov_viaturas
--    order by criado_em desc limit 20;
-- ════════════════════════════════════════════════════════════════════════

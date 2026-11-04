-- 171_concilia_resposta_nao_migrada.sql
-- ─────────────────────────────────────────────────────────────────────────────
-- Conciliação painel × planilhas-fonte (2026-11-04).
-- Contexto: algumas demandas foram migradas para o painel SEM a resposta que já
-- constava atendida na planilha-fonte, ficando como PENDENTE no painel mesmo já
-- tendo sido respondidas. Cruzamento painel × fonte correta por tipo achou 17:
--   NUDEN  1  (1Pp1X2… abas BD_*)
--   DDU   14  (110Y-aQX… aba DDU_3ªCIAMAMB)
--   MC     2  (195fFn… aba MC)
-- (FTP e Emergência: nada a corrigir.)
-- Marca como RESPONDIDA e preenche data_atendimento / numero_gaia / numero_reds
-- com os dados REAIS da planilha. Guard: só altera se ainda PENDENTE/EM ANDAMENTO
-- (não mexe em outros estados). A sync nunca rebaixa RESPONDIDA → correção durável.
-- Idempotente (coalesce preserva valores já presentes; guard impede reaplicar).
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── NUDEN (1) ────────────────────────────────────────────────────────────────
update public.nuden_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2025-07-22'::date), numero_gaia=coalesce(numero_gaia,'324625'), numero_reds=coalesce(numero_reds,'2025-033969822-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='D128357' and situacao in ('PENDENTE','EM ANDAMENTO');

-- ── DDU (14) ─────────────────────────────────────────────────────────────────
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-11'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001754'), numero_reds=coalesce(numero_reds,'2026-042093879-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='00275092603' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-13'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0002000'), numero_reds=coalesce(numero_reds,'2026-042286579-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='00311092652' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-09'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001333'), numero_reds=coalesce(numero_reds,'2026-041735374-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='00324092673' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-11'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001525'), numero_reds=coalesce(numero_reds,'2026-041924401-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='00472092609' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-11'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001703'), numero_reds=coalesce(numero_reds,'2026-042112808-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='00946092692' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-08'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001185'), numero_reds=coalesce(numero_reds,'2026-041571347-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='01190092690' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-11'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001768'), numero_reds=coalesce(numero_reds,'2026-042154508-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='01197092616' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-11'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001740'), numero_reds=coalesce(numero_reds,'2026-042113690-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='01210092694' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-14'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0002188'), numero_reds=coalesce(numero_reds,'2026-042562447-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='01367092660' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-10'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001631'), numero_reds=coalesce(numero_reds,'2026-041904664-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='01555092650' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-10'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001631'), numero_reds=coalesce(numero_reds,'2026-041904664-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='01558092612' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-09'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0001434'), numero_reds=coalesce(numero_reds,'2026-041781674-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='01570092687' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-14'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0002190'), numero_reds=coalesce(numero_reds,'2026-042562120-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='01877092627' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.ddu_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-09-14'::date), numero_gaia=coalesce(numero_gaia,'2026.09.01.362.0002190'), numero_reds=coalesce(numero_reds,'2026-042562120-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='01890092624' and situacao in ('PENDENTE','EM ANDAMENTO');

-- ── MC (2) ───────────────────────────────────────────────────────────────────
update public.mc_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-11-02'::date), numero_reds=coalesce(numero_reds,'2026-051052713-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='285830326' and situacao in ('PENDENTE','EM ANDAMENTO');
update public.mc_demandas set situacao='RESPONDIDA', data_atendimento=coalesce(data_atendimento,'2026-10-24'::date), numero_reds=coalesce(numero_reds,'2026-051001163-001'), observacoes_resposta=coalesce(nullif(observacoes_resposta,''),'Conciliado c/ planilha-fonte em 2026-11-04 (resposta nao migrada)') where codigo='12979307' and situacao in ('PENDENTE','EM ANDAMENTO');

commit;

-- ── Conferência (deve retornar 17 linhas, todas RESPONDIDA) ───────────────────
select 'nuden' t, codigo, situacao, data_atendimento from public.nuden_demandas where codigo='D128357'
union all select 'ddu', codigo, situacao, data_atendimento from public.ddu_demandas where codigo in
  ('00275092603','00311092652','00324092673','00472092609','00946092692','01190092690','01197092616',
   '01210092694','01367092660','01555092650','01558092612','01570092687','01877092627','01890092624')
union all select 'mc', codigo, situacao, data_atendimento from public.mc_demandas where codigo in ('285830326','12979307')
order by 1,2;

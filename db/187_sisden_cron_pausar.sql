-- ══════════════════════════════════════════════════════════════════════
--  187_sisden_cron_pausar.sql
--  PAUSA (reversível) o agendamento do robô sisden-sync (NUDEN 05h/20h).
--
--  Decisão do user (2026-11-12): POR ENQUANTO os dados E o anexo (PDF) das
--  denúncias/requisições NUDEN chegam pelo FLUXO DO SGT ARCARI (Power Automate
--  → Drive → planilha → nuden_sync). O robô próprio inseria os dados SEM o PDF
--  (nossa extração de anexo está desligada, SISDEN_ANEXOS=false), então pausamos
--  o robô para não criar registros "pelados" (sem anexo) à frente do fluxo dele.
--
--  Isto NÃO afeta:
--   • o feed da planilha (Apps Script → nuden_sync) — continua alimentando o painel;
--   • o "📤 Responder no SISDEN" (é sob demanda, no clique — não usa cron).
--
--  Reversível: a definição do job fica guardada, só `active=false`. Para RELIGAR,
--  rode o bloco do fim (ou re-rode o db/167).
--  Rodar no Supabase (SQL Editor).
-- ══════════════════════════════════════════════════════════════════════

-- ── PAUSAR ──
update cron.job set active = false where jobname = 'sisden-sync-diario';

-- conferência (deve mostrar active = false):
select jobid, jobname, schedule, active
  from cron.job where jobname = 'sisden-sync-diario';

-- ══════════════════════════════════════════════════════════════════════
-- ── PARA RELIGAR depois (quando quiser o robô de volta), rode só esta linha:
--   update cron.job set active = true where jobname = 'sisden-sync-diario';
-- ══════════════════════════════════════════════════════════════════════

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
--  Rodar no Supabase (SQL Editor).
--  OBS: `update cron.job set active=false` é NEGADO ao papel do SQL Editor
--  ("permission denied for table job" — a tabela é do superusuário). Por isso
--  usamos a função oficial `cron.unschedule()`, que o dono do job pode chamar
--  (o db/167 já a usou com sucesso ao agendar).
-- ══════════════════════════════════════════════════════════════════════

-- ── PAUSAR (remove o agendamento) ──
select cron.unschedule('sisden-sync-diario')
  from cron.job where jobname = 'sisden-sync-diario';

-- conferência (NÃO deve retornar nenhuma linha = job removido):
select jobid, jobname, schedule, active
  from cron.job where jobname = 'sisden-sync-diario';

-- ══════════════════════════════════════════════════════════════════════
-- ── PARA RELIGAR depois (quando quiser o robô de volta): re-rode o db/167
--    (ele recria o job 'sisden-sync-diario' às 05h/20h; é idempotente).
-- ══════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════
--  AGENDAMENTO da Edge Function sisden-sync (pg_cron + pg_net)
--  Rodar no Supabase (SQL Editor). Idempotente: pode rodar mais de uma vez.
--
--  Faz o robô sincronizar sozinho as denúncias do SISDEN → nuden_demandas,
--  2x por dia. Horário em UTC (o banco Supabase roda em UTC):
--    08:00 UTC = 05h de Brasília   |   23:00 UTC = 20h de Brasília
--  (Brasil não tem mais horário de verão desde 2019 → sempre UTC-3.)
--
--  A função tem "Verify JWT" desligado (é chamada pela URL pública), então o
--  http_post vai sem token. Ela loga sozinha no SISDEN (secrets) e grava.
-- ══════════════════════════════════════════════════════════════════════

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- remove o agendamento anterior (se houver) p/ poder re-rodar este script
select cron.unschedule('sisden-sync-diario')
  from cron.job where jobname = 'sisden-sync-diario';

-- 05h e 20h de Brasília (08:00 e 23:00 UTC), todos os dias
select cron.schedule(
  'sisden-sync-diario',
  '0 8,23 * * *',
  $$
  select net.http_post(
    url := 'https://zrnbebjszwkmquzthjfa.supabase.co/functions/v1/sisden-sync',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 120000
  );
  $$
);

-- conferência:
select jobid, jobname, schedule, active
  from cron.job
 where jobname = 'sisden-sync-diario';

-- (p/ ver as últimas execuções depois:)
--   select * from cron.job_run_details
--    where jobid = (select jobid from cron.job where jobname='sisden-sync-diario')
--    order by start_time desc limit 10;

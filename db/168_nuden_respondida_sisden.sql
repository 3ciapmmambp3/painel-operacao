-- ══════════════════════════════════════════════════════════════════════
--  NUDEN — marca quando a demanda foi RESPONDIDA no SISDEN pelo robô.
--  Rodar no Supabase (SQL Editor). Idempotente.
--
--  A Edge Function sisden-responder envia a resposta ao SISDEN (status
--  "Retorno da área Técnica" + texto com Ato/REDS) e grava aqui a data/hora,
--  p/ não reenviar a mesma. NULL = ainda não respondida no SISDEN pelo robô.
-- ══════════════════════════════════════════════════════════════════════

alter table public.nuden_demandas
  add column if not exists respondida_sisden_em timestamptz;

comment on column public.nuden_demandas.respondida_sisden_em is
  'Quando o robô (sisden-responder) enviou a resposta ao SISDEN. NULL = pendente de envio.';

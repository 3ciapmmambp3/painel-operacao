-- ══════════════════════════════════════════════════════════════════════
--  db/206 — AUDITORIAS: coluna "arquivada" (arquivar / reativar solicitação)
--  Data: 2026-11-21
--
--  CONTEXTO: a aba Auditorias acumula muitas solicitações "Aguardando
--  Documentos". Algumas o Admin decide NÃO tocar por ora (ex.: indicador IF),
--  mas pode retomar depois. Em vez de excluir (perde tudo), agora é possível
--  ARQUIVAR: a solicitação sai da lista ativa, porém:
--    • PRESERVA o status original (continua "Aguardando", etc.);
--    • CONTINUA contando nos cards de resumo (não perde o total);
--    • pode ser REATIVADA (desarquivada) a qualquer momento p/ enviar ao BPM MAmb.
--
--  Basta uma coluna booleana. O front faz PATCH { arquivada: true/false } por 'bo'.
--  Idempotente — pode rodar mais de uma vez sem erro.
-- ══════════════════════════════════════════════════════════════════════

alter table public.auditorias
  add column if not exists arquivada boolean not null default false;

-- Índice leve p/ filtrar as não-arquivadas rapidamente (opcional, mas barato).
create index if not exists auditorias_arquivada_idx
  on public.auditorias (arquivada);

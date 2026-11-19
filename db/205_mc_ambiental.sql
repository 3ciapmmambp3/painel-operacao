-- ══════════════════════════════════════════════════════════════════════
--  MC — contexto ambiental por ponto (camadas públicas do IDE-MG)
--  Rodar no Supabase (SQL Editor). Idempotente. Aditivo.
--
--  Guarda, por GEOCOD, flags "o ponto cai dentro de…" consultadas no IDE
--  oficial de MG (geoserver.meioambiente.mg.gov.br, público — igual à UC):
--    • Área embargada (Sisema)
--    • Reserva Legal a recompor (declarado no CAR)
--    • APP a recompor (declarado no CAR)
--    • Lei da Mata Atlântica (11.428)
--  São dados pequenos (presença + contagem) → entram no SELECT leve da lista.
-- ══════════════════════════════════════════════════════════════════════

alter table public.mc_demandas add column if not exists amb_dados jsonb;
alter table public.mc_demandas add column if not exists amb_consultado_em timestamptz;

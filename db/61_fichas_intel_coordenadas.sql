-- ════════════════════════════════════════════════════════════════════════
-- 61_fichas_intel_coordenadas.sql — coluna de coordenadas na Ficha de Inteligência
--
-- A Ficha de Inteligência (aba Inteligência da Análise Criminal) tinha os
-- campos de coordenadas (lat/lng) no formulário, mas eles NÃO eram gravados
-- nem lidos do banco — então sumiam ao recarregar/editar. Cria a coluna e o
-- painel passa a salvar/ler `coordenadas` (jsonb {lat,lng}).
--
-- Também garante (idempotente) as colunas de classificação usadas pelo painel.
-- Depende de: fichas_intel (criada pelo painel). Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

alter table public.fichas_intel add column if not exists coordenadas   jsonb;
alter table public.fichas_intel add column if not exists data_fato     timestamptz;
alter table public.fichas_intel add column if not exists tipo_criminal text default '';
alter table public.fichas_intel add column if not exists prioridade    text default '';
alter table public.fichas_intel add column if not exists status_ficha  text default 'em_analise';

-- ════════════════════════════════════════════════════════════════════════
-- FIM.
-- ════════════════════════════════════════════════════════════════════════

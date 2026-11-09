-- db/183_bd_crimes_fora_base_cga.sql
-- Marca REDS que SAÍRAM da base do CGA (não vieram no último sync do ano)
-- mas são MANTIDOS por terem auditoria em andamento — para controle/conferência.
-- Esses REDS continuam visíveis nas Auditorias, porém NÃO contam nos indicadores
-- da GDO (o painel passa a excluí-los), fazendo a contagem bater com o SIGOp.
-- Os REDS que saíram da base e NÃO têm auditoria são removidos de fato pelo
-- "Sincronizar base de crimes" (Importar → painel.html), não por este SQL.
-- Reversível. Rodar no SQL editor do Supabase.

ALTER TABLE bd_crimes ADD COLUMN IF NOT EXISTS fora_base_cga boolean NOT NULL DEFAULT false;
ALTER TABLE bd_crimes ADD COLUMN IF NOT EXISTS fora_base_em  timestamptz;

COMMENT ON COLUMN bd_crimes.fora_base_cga IS
  'true = REDS saiu da base do CGA mas foi mantido por ter auditoria; nao conta nos indicadores da GDO.';

-- Índice parcial p/ a consulta do painel (poucas linhas marcadas).
CREATE INDEX IF NOT EXISTS idx_bd_crimes_fora_base ON bd_crimes (numero_reds) WHERE fora_base_cga;

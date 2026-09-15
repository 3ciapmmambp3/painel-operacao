-- ══════════════════════════════════════════════════════════════════════
--  LIMPEZA — pendências/fichas com prefixo no formato RÓTULO COMPLETO
--
--  Bug (corrigido no relatório em ca2f20d): o campo de viatura às vezes ia
--  para a Ficha/pendência com o RÓTULO COMPLETO ("28145 - Toyota / Hilux -
--  QMV1116") em vez do PREFIXO ("28145"), criando duplicata (o painel tratava
--  as duas strings como viaturas diferentes).
--
--  Estado em 2026-09-15 (consultado): mov_viaturas = 0 linhas com rótulo;
--  mov_pendencias = 1 linha (28145 - Toyota / Hilux - QMV1116, dia 2026-09-15),
--  que TEM a gêmea numérica "28145" do mesmo dia → será apagada.
--
--  Regra geral (idempotente, seguro):
--   1) mov_pendencias: apaga a de rótulo completo QUANDO já existe uma
--      numérica do mesmo dia (duplicata real); as demais só têm o prefixo
--      normalizado (não perde a pendência).
--   2) mov_viaturas: apenas NORMALIZA o prefixo (nunca apaga ficha — carrega
--      km/motorista). Hoje é no-op (0 linhas).
--
--  Idempotente. Rodar no SQL Editor.
-- ══════════════════════════════════════════════════════════════════════

-- Diagnóstico (opcional) — rode antes p/ ver o que será afetado:
--   select 'pendencia' t, id, prefixo, dia from public.mov_pendencias where prefixo ~ '\s[-–—]\s'
--   union all
--   select 'ficha' t, id, prefixo, null from public.mov_viaturas where prefixo ~ '\s[-–—]\s';

-- ─── 1) mov_pendencias: apaga a duplicata de rótulo completo ───────────
delete from public.mov_pendencias p
 where p.prefixo ~ '\s[-–—]\s'
   and exists (
     select 1 from public.mov_pendencias q
      where q.id <> p.id
        and q.dia = p.dia
        and q.prefixo = trim(regexp_replace(p.prefixo, '\s[-–—]\s.*$', ''))
   );

-- pendências de rótulo completo SEM gêmea numérica → normaliza o prefixo
update public.mov_pendencias
   set prefixo = trim(regexp_replace(prefixo, '\s[-–—]\s.*$', ''))
 where prefixo ~ '\s[-–—]\s';

-- ─── 2) mov_viaturas: só normaliza o prefixo (nunca apaga) ─────────────
update public.mov_viaturas
   set prefixo = trim(regexp_replace(prefixo, '\s[-–—]\s.*$', ''))
 where prefixo ~ '\s[-–—]\s';

-- Conferência (opcional) — deve voltar 0 linhas nas duas:
--   select count(*) from public.mov_pendencias where prefixo ~ '\s[-–—]\s';
--   select count(*) from public.mov_viaturas   where prefixo ~ '\s[-–—]\s';

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Não mexe em cadastro (viaturas) nem re-roda nada anterior.
-- ══════════════════════════════════════════════════════════════════════

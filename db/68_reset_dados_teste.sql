-- ══════════════════════════════════════════════════════════════════════
--  68_reset_dados_teste.sql — LIMPEZA dos dados de TESTE antes do uso real
--
--  ⚠️ IRREVERSÍVEL. Apaga TODAS as linhas das tabelas OPERACIONAIS abaixo.
--     NÃO mexe em cadastros (militares, viaturas, operações), nem na Chamada
--     de Instrução, Ofícios, contadores, links, listas e configurações.
--
--  Escopo confirmado (2026-09-14):
--    • TTA .................. presenças + auditoria + cronograma de temas + materiais
--    • Ficha de Movimentação  ficha + auditorias + abastecimento(SIAD) + pendências
--                             (abastecimento e acidentes ficam DENTRO da ficha)
--    • Frota ............... Revisão de frota + Defeitos + Baixas/Manutenção
--    • Relatório de Serviço  relatórios + itens
--    • Denúncia/Requisição .. balcão (tabela denuncias: denúncia + requisição)
--                             + Requisição Judicial (tabela separada)
--
--  COMO RODAR (Supabase → SQL Editor):
--    1) Rode a SEÇÃO 1 (conferência) e confira quantas linhas serão apagadas.
--    2) Rode a SEÇÃO 2 (limpeza). Ela está em transação: se algo parecer
--       errado, troque o COMMIT final por ROLLBACK e nada é apagado.
--    3) (opcional) Rode a SEÇÃO 3 se quiser destravar viaturas que ficaram
--       marcadas BAIXADA/EM_MANUTENÇÃO por causa de testes.
-- ══════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────
-- SEÇÃO 1 — CONFERÊNCIA (rode primeiro; não apaga nada)
-- ─────────────────────────────────────────────────────────────────────
select 'tta_chamadas'            as tabela, count(*) from public.tta_chamadas
union all select 'tta_auditoria',           count(*) from public.tta_auditoria
union all select 'tta_temas',               count(*) from public.tta_temas
union all select 'tta_materiais',           count(*) from public.tta_materiais
union all select 'mov_viaturas',            count(*) from public.mov_viaturas
union all select 'mov_viaturas_audit',      count(*) from public.mov_viaturas_audit
union all select 'mov_ficha_auditoria',     count(*) from public.mov_ficha_auditoria
union all select 'mov_pendencias',          count(*) from public.mov_pendencias
union all select 'siad_lancado',            count(*) from public.siad_lancado
union all select 'viatura_revisao',         count(*) from public.viatura_revisao
union all select 'defeitos_reportados',     count(*) from public.defeitos_reportados
union all select 'defeito_ficha_resolvido', count(*) from public.defeito_ficha_resolvido
union all select 'viaturas_baixas',         count(*) from public.viaturas_baixas
union all select 'relatorios',              count(*) from public.relatorios
union all select 'relatorio_itens',         count(*) from public.relatorio_itens
union all select 'denuncias',               count(*) from public.denuncias
union all select 'requisicoes_judiciais',   count(*) from public.requisicoes_judiciais
order by 1;

-- ─────────────────────────────────────────────────────────────────────
-- SEÇÃO 2 — LIMPEZA (em transação). Confira e então COMMIT.
-- ─────────────────────────────────────────────────────────────────────
begin;

-- TTA (apaga presenças antes; tema_id vira NULL sozinho, mas some junto)
delete from public.tta_chamadas;
delete from public.tta_auditoria;
delete from public.tta_materiais;
delete from public.tta_temas;

-- Frota / Ficha de Movimentação
delete from public.siad_lancado;
delete from public.mov_ficha_auditoria;
delete from public.mov_pendencias;
delete from public.defeitos_reportados;
delete from public.defeito_ficha_resolvido;
delete from public.viatura_revisao;
delete from public.viaturas_baixas;
delete from public.mov_viaturas;            -- cascata → mov_viaturas_audit

-- Relatório de Serviço
delete from public.relatorios;              -- cascata → relatorio_itens

-- Denúncia de Balcão + Requisição (balcão) e Requisição Judicial
delete from public.denuncias;
delete from public.requisicoes_judiciais;

commit;   -- << troque por  rollback;  se quiser cancelar sem apagar

-- Conferência pós-limpeza (opcional): reexecute a SEÇÃO 1 — deve dar tudo 0.

-- ─────────────────────────────────────────────────────────────────────
-- SEÇÃO 3 — (OPCIONAL) destravar viaturas que testes deixaram indisponíveis.
--   Só afeta o STATUS operacional do cadastro de viaturas (não apaga viatura).
--   Rode apenas se alguma viatura ficou presa como BAIXADA/EM_MANUTENÇÃO.
-- ─────────────────────────────────────────────────────────────────────
-- update public.viaturas
--   set situacao_operacional = 'DISPONIVEL', atualizado_em = now()
--   where situacao_operacional in ('BAIXADA','EM_MANUTENCAO');
-- ══════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════
--  MC — corrige grupamento_completo INCOMPLETO ("N GP" avulso)
--  Rodar no Supabase (SQL Editor). Idempotente e seguro de repetir.
--
--  PROBLEMA (achado em 2026-11-19):
--  Alguns MC foram importados com grupamento_completo = só "6 GP" / "2 GP"
--  (sem "/ PEL / CIA / cidade"), embora o gp_responsavel estivesse CORRETO.
--  O Relatório de Serviço filtra o dropdown de demandas pela Fração de Atuação
--  comparando (nº GP, nº PEL, cidade) do grupamento_completo. Como "6 GP" não
--  tem PEL nem cidade, ele NÃO casa com "6 GP / 5 PEL / … / RIO DO PRADO" e as
--  demandas ficam INVISÍVEIS para o militar responder — mesmo estando PENDENTE.
--
--  Ex.: MC 347350526 e 347360526 (Felizburgo / GP RIO DO PRADO).
--
--  CORREÇÃO: alinhar grupamento_completo e fracao_responsavel ao padrão dos
--  demais MC do mesmo GP (pega o grupamento_completo canônico da tabela `grupos`).
--  Só toca linhas cujo grupamento_completo está "quebrado" (sem " / ").
-- ══════════════════════════════════════════════════════════════════════

update public.mc_demandas m
set grupamento_completo = g.grupamento_completo,
    fracao_responsavel  = m.gp_responsavel,
    updated_at          = now()
from public.grupos g
where g.gp_responsavel = m.gp_responsavel
  and m.gp_responsavel is not null
  and coalesce(m.grupamento_completo,'') not like '% / %'   -- só os quebrados
  and g.grupamento_completo like '% / %';                    -- só o canônico cheio

-- Conferência (deve voltar 0 linhas pendentes/ativas quebradas após rodar):
-- select codigo, municipio, gp_responsavel, grupamento_completo
-- from public.mc_demandas
-- where ativo and situacao in ('PENDENTE','EM ANDAMENTO') and data_atendimento is null
--   and coalesce(grupamento_completo,'') not like '% / %';

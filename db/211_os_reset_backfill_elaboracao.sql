-- ══════════════════════════════════════════════════════════════════════
--  db/211 — Reset das OS do backfill para "OS Cadastrada" (elaboração)
--  Data: 2026-11-22
--
--  As OS 036/040/044/045/047/048/049-2026 foram lançadas pelo backfill (db/209)
--  como 'concluida'. A pedido: voltar todas para 'elaboracao' para o Aux P3
--  tramitar cada etapa manualmente e o histórico ficar real.
--  Mantém operação, grupamento, datas, anexos etc. — muda só a etapa + histórico.
--  Idempotente (pode rodar de novo; só deixa um registro 'elaboracao').
-- ══════════════════════════════════════════════════════════════════════

update public.ordens_servico
   set etapa = 'elaboracao', atualizado_em = now()
 where ano = 2026 and numero in (36,40,44,45,47,48,49);

delete from public.os_tramitacao t
 using public.ordens_servico o
 where t.os_id = o.id and o.ano = 2026 and o.numero in (36,40,44,45,47,48,49);

insert into public.os_tramitacao (os_id, etapa, data, responsavel, obs, criado_por)
select o.id, 'elaboracao', current_date, 'Backfill', 'OS cadastrada no controle.', 'Backfill'
from public.ordens_servico o
where o.ano = 2026 and o.numero in (36,40,44,45,47,48,49);

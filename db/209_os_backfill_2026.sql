-- ══════════════════════════════════════════════════════════════════════
--  db/209 — BACKFILL das OS de 2026 já existentes (as que estão na pasta)
--  Data: 2026-11-22
--
--  Lança as OS já elaboradas em 2026 como CONCLUÍDAS, para que:
--   (a) fiquem registradas no controle; e
--   (b) a numeração automática continue a partir de 050 (max+1).
--  Idempotente: on conflict (ano,numero) do nothing + not exists na tramitação.
--  Anexos (PDF/planilha) NÃO entram aqui — basta abrir a OS e anexar pelo
--  botão "Editar" quando quiser (os arquivos estão locais, não no Drive ainda).
-- ══════════════════════════════════════════════════════════════════════

insert into public.ordens_servico (numero, ano, operacao, com_diarias, etapa, criado_por, atualizado_por) values
  (36, 2026, 'Dia Mundial da Árvore',                         false, 'concluida', 'Backfill', 'Backfill'),
  (40, 2026, 'Operação Recursos Hídricos 7',                  false, 'concluida', 'Backfill', 'Backfill'),
  (44, 2026, 'Operação Recursos Hídricos 8',                  false, 'concluida', 'Backfill', 'Backfill'),
  (45, 2026, 'Operação Flora 11',                             false, 'concluida', 'Backfill', 'Backfill'),
  (47, 2026, '9º Curso de Policiamento de Meio Ambiente',     false, 'concluida', 'Backfill', 'Backfill'),
  (48, 2026, 'Operação Última Pepita',                        true,  'concluida', 'Backfill', 'Backfill'),
  (49, 2026, 'Operação Extraordinária em Pedra Azul',         false, 'concluida', 'Backfill', 'Backfill')
on conflict (ano, numero) do nothing;

-- Uma entrada de histórico para cada OL backfillada que ainda não tenha nenhuma.
insert into public.os_tramitacao (os_id, etapa, data, responsavel, obs, criado_por)
select o.id, 'concluida', null, 'Backfill', 'Registro histórico (OS anterior ao controle de tramitação).', 'Backfill'
from public.ordens_servico o
where o.ano = 2026 and o.numero in (36,40,44,45,47,48,49)
  and not exists (select 1 from public.os_tramitacao t where t.os_id = o.id);

-- ══════════════════════════════════════════════════════════════════════
--  OFÍCIOS — REGISTRO DE CONTROLE DOS Nº 690/2026 e 691/2026 (EXCLUÍDOS)
--
--  Contexto: 690/2026 e 691/2026 foram gerados em TESTE durante a implantação
--  e excluídos pela lógica ANTIGA (que apagava de vez), virando lacuna na
--  sequência. Como 692 e 693 já existem, esses números NÃO podem ser
--  reaproveitados. Este script recria os dois como registros 'EXCLUIDO' —
--  só para o histórico/controle da P1, para ninguém ficar se perguntando
--  no futuro o que houve com eles.
--
--  • Ocupa os slots 690/691 (numero_seq) → o unique index impede reemissão.
--  • NÃO altera contadores (segue em 693; o próximo ofício será 694).
--  • Idempotente: só insere se ainda não existir aquele nº no ano.
--
--  Depende de: db/69 (situação 'EXCLUIDO' + colunas excluido_*). RODAR DEPOIS
--  do db/69, no SQL Editor do Supabase.
-- ══════════════════════════════════════════════════════════════════════

insert into public.oficios (
  tipo, numero, numero_seq, ano, data_doc, assunto,
  situacao, excluido_em, excluido_por_nome, excluido_motivo,
  registrado_por_nome, observacoes
)
select
  'Saída',
  'Ofício nº ' || lpad(v.seq::text, 3, '0') || '/2026 - 3ª Cia PM MAmb',
  v.seq, 2026, date '2026-09-14',
  '(Número de teste — não corresponde a ofício real)',
  'EXCLUIDO', now(), 'Registro de controle (P1)',
  'Número gerado em teste durante a implantação do módulo e excluído. '
    || 'Registro recriado apenas para manter o histórico da sequência — '
    || 'não houve ofício real com este número.',
  'Registro de controle (P1)',
  'Reconstruído em ' || to_char(now() at time zone 'America/Sao_Paulo','DD/MM/YYYY') || ' para controle.'
from (values (690), (691)) as v(seq)
where not exists (
  select 1 from public.oficios o where o.ano = 2026 and o.numero_seq = v.seq
);

-- Conferência (opcional): deve listar 690 e 691 como EXCLUIDO
-- select numero, situacao, excluido_motivo from public.oficios
--  where ano=2026 and numero_seq in (690,691) order by numero_seq;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Não re-rodar precisa; o WHERE NOT EXISTS evita duplicar.
-- ══════════════════════════════════════════════════════════════════════

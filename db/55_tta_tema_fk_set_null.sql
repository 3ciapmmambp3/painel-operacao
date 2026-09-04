-- 55_tta_tema_fk_set_null.sql
-- Corrige a exclusão de temas do TTA.
-- Antes: apagar um tema referenciado por algum lançamento (tta_chamadas.tema_id)
-- estourava FK 23503 (tta_chamadas_tema_id_fkey) e travava o 🗑 por dia e o
-- "Limpar todos deste mês".
-- Agora: ao apagar o tema, o vínculo em tta_chamadas.tema_id vira NULL. O
-- histórico do lançamento continua intacto — o assunto/referência já ficam
-- gravados em colunas próprias (tema_assunto / tema_referencia) na chamada.

alter table public.tta_chamadas
  drop constraint if exists tta_chamadas_tema_id_fkey;

alter table public.tta_chamadas
  add constraint tta_chamadas_tema_id_fkey
  foreign key (tema_id) references public.tta_temas(id)
  on delete set null;

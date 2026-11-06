-- db/180 — Reforça o UPSERT da importação (RAT / BOS / REDS)
-- ---------------------------------------------------------------------------
-- Objetivo: garantir que REIMPORTAR um registro já existente ATUALIZE os dados
-- (natureza, data, etc.), e não apenas seja ignorado.
--
-- A aba Importação grava com:
--     POST .../bd_operacoes?on_conflict=numero_rat
--     Prefer: resolution=merge-duplicates   (INSERT ... ON CONFLICT DO UPDATE)
-- Para esse UPDATE funcionar, a coluna-chave precisa ter um ÍNDICE/CONSTRAINT
-- ÚNICO. Esta migração garante esse índice de forma IDEMPOTENTE:
--   1) remove duplicatas eventuais mantendo a linha MAIS RECENTE (maior id),
--      de modo que a última importação prevaleça;
--   2) cria o índice único SOMENTE se ainda não houver um índice único de uma
--      coluna sobre a chave (se já existir, é no-op — nada é recriado).
--
-- Caso de uso real: um RAT que deixa de ser POE (ex.: Y12001) e passa a OP RURAL
-- (Y07014). Como o número do RAT não muda, ao reimportar o arquivo COMPLETO de
-- operações o UPSERT troca a natureza no banco — o registro sai da contagem POE
-- e entra na GDO Rural automaticamente. Rode esta migração UMA vez; depois é só
-- reimportar o arquivo completo pela aba Importação.
--
-- Seguro de rodar mais de uma vez.
-- ---------------------------------------------------------------------------

do $$
declare
  t record;
  removidas integer;
begin
  for t in
    select * from (values
      ('bd_operacoes', 'numero_rat',  'uq_bd_operacoes_numero_rat'),
      ('bd_visitas',   'numero_bos',  'uq_bd_visitas_numero_bos'),
      ('bd_crimes',    'numero_reds', 'uq_bd_crimes_numero_reds')
    ) as v(tbl, col, idx)
  loop
    -- Pula tabelas que por acaso não existam neste ambiente.
    if to_regclass('public.' || t.tbl) is null then
      raise notice 'Tabela %.% inexistente — ignorada.', 'public', t.tbl;
      continue;
    end if;

    -- 1) Dedup mantendo a linha MAIS RECENTE (maior id) por chave.
    execute format(
      'delete from public.%1$I a using public.%1$I b '
      || 'where a.%2$I is not null and a.%2$I = b.%2$I and a.id < b.id',
      t.tbl, t.col);
    get diagnostics removidas = row_count;
    if removidas > 0 then
      raise notice '% : % linha(s) duplicada(s) removida(s) (mantida a mais recente).', t.tbl, removidas;
    end if;

    -- 2) Cria índice único só se ainda não houver um único de 1 coluna na chave.
    if not exists (
      select 1
        from pg_index i
        join pg_class c      on c.oid = i.indrelid
        join pg_namespace n  on n.oid = c.relnamespace
        join pg_attribute a  on a.attrelid = c.oid and a.attnum = any(i.indkey)
       where n.nspname = 'public'
         and c.relname = t.tbl
         and i.indisunique
         and i.indnatts = 1
         and a.attname = t.col
    ) then
      execute format('create unique index %I on public.%I (%I)', t.idx, t.tbl, t.col);
      raise notice '% : índice único criado em (%).', t.tbl, t.col;
    else
      raise notice '% : já possui índice único em (%) — mantido.', t.tbl, t.col;
    end if;
  end loop;
end$$;

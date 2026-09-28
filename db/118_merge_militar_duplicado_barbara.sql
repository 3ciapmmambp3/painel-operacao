-- ══════════════════════════════════════════════════════════════════════
--  CORREÇÃO PONTUAL — militar DUPLICADO no efetivo
--  Sd PM Bárbara Borel Satler Pio dos Santos aparecia 2x (GP Manhuaçu):
--    • 192.280-7 (CORRETO)  → id 7ec77c95-1ebc-4d2a-a29c-bcf926de2409  (MANTER)
--    • 191.280-7 (typo)     → id e4a80a2b-fb47-4f56-a517-cfcb62cc0bb0  (REMOVER)
--
--  O "excluir" do app é hard delete e falha por FK (chamada_instrucao etc.).
--  Este script MESCLA: reaponta todas as referências (militar_id) do registro
--  errado para o correto e então apaga o errado. Genérico: percorre TODAS as
--  FKs que apontam para public.militares. Em colisão de unicidade (os dois
--  tinham linha para a mesma chave), descarta a linha do duplicado (a do
--  registro mantido prevalece).
--
--  Rodar UMA vez no SQL Editor do Supabase. Idempotente: se o dup já não
--  existir, não faz nada.
-- ══════════════════════════════════════════════════════════════════════

do $$
declare
  v_keep uuid := '7ec77c95-1ebc-4d2a-a29c-bcf926de2409';  -- 192.280-7 (manter)
  v_dup  uuid := 'e4a80a2b-fb47-4f56-a517-cfcb62cc0bb0';  -- 191.280-7 (remover)
  fk record;
begin
  if not exists (select 1 from public.militares where id = v_dup) then
    raise notice 'Registro duplicado já não existe — nada a fazer.';
    return;
  end if;
  if not exists (select 1 from public.militares where id = v_keep) then
    raise exception 'Registro a manter (%) não existe — abortando.', v_keep;
  end if;

  for fk in
    select con.conrelid::regclass::text as tbl, att.attname as col
    from pg_constraint con
    join pg_attribute att
      on att.attrelid = con.conrelid and att.attnum = con.conkey[1]
    where con.confrelid = 'public.militares'::regclass
      and con.contype = 'f'
      and array_length(con.conkey, 1) = 1
  loop
    begin
      execute format('update %s set %I = $1 where %I = $2', fk.tbl, fk.col, fk.col)
        using v_keep, v_dup;
    exception when unique_violation then
      -- os dois tinham linha para a mesma chave única: mantém a do v_keep
      execute format('delete from %s where %I = $1', fk.tbl, fk.col) using v_dup;
      raise notice 'Colisão em % — linhas duplicadas do registro errado removidas.', fk.tbl;
    end;
  end loop;

  delete from public.militares where id = v_dup;
  raise notice 'OK: registro 191.280-7 removido; referências reapontadas para 192.280-7.';
end $$;

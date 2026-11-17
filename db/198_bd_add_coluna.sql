-- 198_bd_add_coluna.sql
-- Permite ao importador (painel.html) criar, sob demanda, uma coluna nova que
-- apareça na planilha do SIGOp mas ainda não exista na tabela de destino.
-- Usado quando o Aux P1 confirma "criar e guardar" ao importar.
--
-- SEGURANÇA (função SECURITY DEFINER exposta ao papel anon):
--   * só as 3 tabelas de importação (bd_crimes, bd_operacoes, bd_visitas);
--   * nome de coluna validado por regex + quote_ident (%I) — à prova de injeção;
--   * cria SEMPRE como text, IF NOT EXISTS (idempotente);
--   * NOTIFY pgrst p/ o PostgREST recarregar o schema e enxergar a coluna nova.
-- Pior caso de abuso: criar colunas text a mais nessas 3 tabelas (não vaza/apaga dado).

create or replace function public.bd_add_coluna(p_tabela text, p_coluna text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_permitidas text[] := array['bd_crimes','bd_operacoes','bd_visitas'];
  v_col text;
begin
  if p_tabela is null or not (p_tabela = any(v_permitidas)) then
    raise exception 'Tabela nao permitida: %', p_tabela;
  end if;

  v_col := lower(btrim(coalesce(p_coluna, '')));
  if v_col !~ '^[a-z][a-z0-9_]{0,60}$' then
    raise exception 'Nome de coluna invalido: %', p_coluna;
  end if;

  execute format('alter table public.%I add column if not exists %I text', p_tabela, v_col);

  -- força o PostgREST a recarregar o schema cache (senao a coluna nova nao e reconhecida)
  notify pgrst, 'reload schema';

  return v_col;
end;
$$;

revoke all on function public.bd_add_coluna(text, text) from public;
grant execute on function public.bd_add_coluna(text, text) to anon, authenticated;

notify pgrst, 'reload schema';

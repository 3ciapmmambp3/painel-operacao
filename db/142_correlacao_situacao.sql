-- 142_correlacao_situacao.sql
-- Tabela da aba "Correlação Op × Crime" (Análise Criminal) para o botão
-- "⚠ Registrar Situação" — justificativa quando o LOCAL DA ATUAÇÃO difere do
-- LOCAL DO FATO. Espelha a tabela visitas_situacao (mesmo formato/colunas), mas
-- SEPARADA, para que um mesmo crime possa ter situação de Visita E de Correlação
-- sem colidir.
--
-- Modelo de acesso: igual ao módulo Análise Criminal (anon key do PostgREST).
-- As regras de quem pode editar/excluir (autor até 7 dias ou Admin Geral) são
-- aplicadas no front (_sitPodeEditar); aqui a RLS apenas libera o CRUD à role anon.

create table if not exists public.correlacao_situacao (
  bo_crime                 text primary key,
  status                   text,
  motivo                   text not null,
  data_registro            date,
  observacao               text,
  numero_rat               text,
  registros                jsonb default '[]'::jsonb,
  registrado_por           text,
  registrado_por_matricula text,
  registrado_em            timestamptz default now()
);

alter table public.correlacao_situacao enable row level security;

-- Políticas permissivas (mesmo modelo da visitas_situacao). A trava de edição é no front.
drop policy if exists correlacao_situacao_sel on public.correlacao_situacao;
drop policy if exists correlacao_situacao_ins on public.correlacao_situacao;
drop policy if exists correlacao_situacao_upd on public.correlacao_situacao;
drop policy if exists correlacao_situacao_del on public.correlacao_situacao;

create policy correlacao_situacao_sel on public.correlacao_situacao
  for select to anon, authenticated using (true);
create policy correlacao_situacao_ins on public.correlacao_situacao
  for insert to anon, authenticated with check (true);
create policy correlacao_situacao_upd on public.correlacao_situacao
  for update to anon, authenticated using (true) with check (true);
create policy correlacao_situacao_del on public.correlacao_situacao
  for delete to anon, authenticated using (true);

grant select, insert, update, delete on public.correlacao_situacao to anon, authenticated;

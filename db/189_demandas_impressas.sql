-- 189_demandas_impressas.sql
-- Controle de Demandas: marcador GLOBAL "impressa" por demanda (qualquer militar
-- do grupamento marca/desmarca; todos veem). Serve p/ todos os tipos (MC, NUDEN,
-- RI, DDU, Emergência, Denúncia/Requisição) — chave = (tabela, codigo).
-- Rodar no SQL Editor. Idempotente.

create table if not exists public.demandas_impressas (
  tabela         text        not null,                 -- ex.: 'mc_demandas', 'denuncias'
  codigo         text        not null,                 -- codigo da demanda (denuncias = id)
  por_matricula  text,
  por_nome       text,
  em             timestamptz not null default now(),
  primary key (tabela, codigo)
);

alter table public.demandas_impressas enable row level security;
drop policy if exists dimp_sel on public.demandas_impressas;
create policy dimp_sel on public.demandas_impressas for select to anon using (true);
grant select on public.demandas_impressas to anon;

-- Marca (p_impresso=true → upsert) ou desmarca (false → delete). Qualquer militar logado.
create or replace function public.demanda_impresso_set(p_token uuid, p_tabela text, p_codigo text, p_impresso boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if nullif(trim(coalesce(p_tabela,'')),'') is null or nullif(trim(coalesce(p_codigo,'')),'') is null then
    raise exception 'Informe a tabela e o código da demanda.';
  end if;
  if coalesce(p_impresso,false) then
    insert into public.demandas_impressas (tabela, codigo, por_matricula, por_nome, em)
    values (p_tabela, p_codigo, v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo), now())
    on conflict (tabela, codigo) do update set
      por_matricula = excluded.por_matricula, por_nome = excluded.por_nome, em = now();
  else
    delete from public.demandas_impressas where tabela = p_tabela and codigo = p_codigo;
  end if;
  return jsonb_build_object('ok', true, 'impresso', coalesce(p_impresso,false));
end;
$$;

grant execute on function public.demanda_impresso_set(uuid, text, text, boolean) to anon;

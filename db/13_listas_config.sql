-- ════════════════════════════════════════════════════════════════════════
-- 13_listas_config.sql — Listas editáveis pelo ADM (combustíveis, convênios).
-- Editável por Admin Geral e Aux P4 (na Gestão de Viaturas). A Ficha de
-- Movimentação lê essas listas p/ montar os selects (fallback: constantes JS).
-- Depende de: 04 (_sessao_militar) e 08 (_pode_gerenciar_viaturas). Idempotente.
-- ════════════════════════════════════════════════════════════════════════
create table if not exists public.listas_config (
  chave          text primary key,          -- 'combustiveis' | 'convenios' | ...
  itens          jsonb not null default '[]'::jsonb,
  atualizado_por text,
  atualizado_em  timestamptz not null default now()
);

insert into public.listas_config (chave, itens) values
  ('combustiveis', '["Gasolina comum","Gasolina aditivada","Etanol","Diesel S10","Diesel S500","GNV"]'::jsonb),
  ('convenios',    '["Vale","Samarco","Vallourec","SEE / Progea","Emenda parlamentar","Outro"]'::jsonb)
on conflict (chave) do nothing;

create or replace function public.listas_config_get()
returns setof public.listas_config
language sql stable security definer set search_path = public as $$
  select * from public.listas_config;
$$;

create or replace function public.listas_config_salvar(p_token uuid, p_chave text, p_itens jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.listas_config;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: apenas Aux P4 e Admin Geral editam as listas.';
  end if;
  if jsonb_typeof(p_itens) is distinct from 'array' then
    raise exception 'Itens inválidos (esperado um array).';
  end if;
  insert into public.listas_config (chave, itens, atualizado_por, atualizado_em)
    values (p_chave, p_itens, coalesce(v_me.nome_guerra, v_me.nome_completo), now())
  on conflict (chave) do update
    set itens = excluded.itens,
        atualizado_por = excluded.atualizado_por,
        atualizado_em = now()
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

grant execute on function public.listas_config_get() to anon;
grant execute on function public.listas_config_salvar(uuid, text, jsonb) to anon;

alter table public.listas_config enable row level security;
drop policy if exists listas_cfg_sel on public.listas_config;
create policy listas_cfg_sel on public.listas_config for select using (true);

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rode no SQL Editor depois do 08.
-- ════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- 29_user_prefs.sql — Preferências do usuário (Acesso Rápido personalizável)
--
-- Guarda, por militar, os atalhos EXTRAS que ele escolheu para o "Acesso
-- Rápido" do Meu Dia. Os 5 atalhos do SISTEMA (TTA, Relatório, Ficha de
-- Movimentação, Minhas Movimentações, Lançar Chamada) são fixos no front e
-- NÃO entram aqui — aqui vão só as chaves dos atalhos adicionados pelo usuário.
--
-- Depende de: 04_sessoes_e_militares_seguranca.sql (_sessao_militar).
-- Idempotente. Rodar no SQL Editor (depois do 04).
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.user_prefs (
  militar_id     uuid primary key,
  acesso_rapido  jsonb not null default '[]'::jsonb,   -- ["agenda","produtividade",...]
  atualizado_em  timestamptz not null default now()
);

-- ── RPC: ler os atalhos extras do usuário logado ────────────────────────
create or replace function public.prefs_atalhos_listar(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_me record; v_out jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  select acesso_rapido into v_out from public.user_prefs where militar_id = v_me.id;
  return coalesce(v_out, '[]'::jsonb);
end;
$$;

-- ── RPC: salvar (upsert) os atalhos extras do usuário logado ────────────
create or replace function public.prefs_atalhos_salvar(p_token uuid, p_atalhos jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_val jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  v_val := case when jsonb_typeof(p_atalhos) = 'array' then p_atalhos else '[]'::jsonb end;
  insert into public.user_prefs (militar_id, acesso_rapido, atualizado_em)
  values (v_me.id, v_val, now())
  on conflict (militar_id) do update
    set acesso_rapido = excluded.acesso_rapido, atualizado_em = now();
  return v_val;
end;
$$;

-- ── RLS: a tabela só é acessada via RPC (security definer); sem select direto ──
alter table public.user_prefs enable row level security;
-- (sem policy de select para anon: o painel usa só as RPCs acima)

grant execute on function public.prefs_atalhos_listar(uuid) to anon;
grant execute on function public.prefs_atalhos_salvar(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 04.
-- ════════════════════════════════════════════════════════════════════════

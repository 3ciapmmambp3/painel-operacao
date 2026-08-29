-- ════════════════════════════════════════════════════════════════════════
-- 40_mov_ficha_excluir_auditoria.sql
--   Exclusão de Ficha de Movimentação pelo gestor (Aux P4 / Admin Geral),
--   SEMPRE com registro de auditoria (quem, quando, ação, registro anterior,
--   registro novo quando aplicável, justificativa).
--
--   • Exclusão é SOFT-DELETE: a ficha some das listas (ativo=false) mas o
--     registro é preservado no banco + snapshot completo na auditoria.
--   • A auditoria de EDIÇÕES já é feita dentro de mov_ficha_editar (existente);
--     esta tabela também aceita EDICAO/RESTAURACAO para uso futuro.
--
--   Depende de: 04 (_sessao_militar), 08 (mov_viaturas, _pode_gerenciar_viaturas).
--   Idempotente. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

-- 1) Colunas de exclusão (soft-delete) em mov_viaturas ---------------------
alter table public.mov_viaturas add column if not exists excluido_em            timestamptz;
alter table public.mov_viaturas add column if not exists excluido_por_matricula text;
alter table public.mov_viaturas add column if not exists excluido_por_nome      text;
alter table public.mov_viaturas add column if not exists motivo_exclusao        text;

-- 2) Tabela de auditoria da ficha -----------------------------------------
create table if not exists public.mov_ficha_auditoria (
  id                 uuid primary key default gen_random_uuid(),
  ficha_id           uuid not null,
  acao               text not null check (acao in ('EXCLUSAO','EDICAO','RESTAURACAO')),
  usuario_matricula  text,
  usuario_nome       text,
  quando             timestamptz not null default now(),
  registro_anterior  jsonb,        -- estado antes da ação
  registro_novo      jsonb,        -- estado depois (quando aplicável)
  justificativa      text
);
create index if not exists idx_mov_ficha_aud_ficha on public.mov_ficha_auditoria (ficha_id);
create index if not exists idx_mov_ficha_aud_quando on public.mov_ficha_auditoria (quando desc);

-- Auditoria só é lida via RPC (security definer). Sem SELECT para anon.
alter table public.mov_ficha_auditoria enable row level security;

-- 3) RPC: excluir ficha (soft-delete) — só gestor, sempre com justificativa -
create or replace function public.mov_ficha_excluir(
  p_token uuid, p_id uuid, p_justificativa text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_ficha public.mov_viaturas%rowtype;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão inválida ou expirada.';
  end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: a exclusão de fichas é feita pelo setor responsável (Aux P4).';
  end if;
  if coalesce(btrim(p_justificativa),'') = '' then
    raise exception 'Justificativa é obrigatória para excluir uma ficha.';
  end if;

  select * into v_ficha from public.mov_viaturas where id = p_id;
  if v_ficha.id is null then
    raise exception 'Ficha não encontrada.';
  end if;
  if coalesce(v_ficha.ativo, true) = false then
    raise exception 'Esta ficha já está excluída.';
  end if;

  -- Registro de auditoria com snapshot completo ANTES de excluir.
  insert into public.mov_ficha_auditoria
    (ficha_id, acao, usuario_matricula, usuario_nome, registro_anterior, registro_novo, justificativa)
  values
    (v_ficha.id, 'EXCLUSAO', v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo),
     to_jsonb(v_ficha), null, btrim(p_justificativa));

  -- Soft-delete: preserva o registro, mas some das listas (ativo=false).
  update public.mov_viaturas
     set ativo = false,
         excluido_em = now(),
         excluido_por_matricula = v_me.matricula,
         excluido_por_nome = coalesce(v_me.nome_guerra, v_me.nome_completo),
         motivo_exclusao = btrim(p_justificativa)
   where id = p_id;

  return jsonb_build_object('ok', true, 'id', p_id);
end;
$$;

grant execute on function public.mov_ficha_excluir(uuid, uuid, text) to anon;

-- 4) RPC: listar auditoria de uma ficha (só gestor) ------------------------
create or replace function public.mov_ficha_auditoria_listar(
  p_token uuid, p_ficha_id uuid)
returns setof public.mov_ficha_auditoria
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão inválida ou expirada.';
  end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão para ver a auditoria.';
  end if;
  return query
    select * from public.mov_ficha_auditoria
     where ficha_id = p_ficha_id
     order by quando desc;
end;
$$;

grant execute on function public.mov_ficha_auditoria_listar(uuid, uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois de 08_mov_viaturas.sql. Após rodar, recarregar o schema
-- cache do PostgREST (Supabase faz automaticamente em segundos).
-- ════════════════════════════════════════════════════════════════════════

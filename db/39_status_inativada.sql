-- ════════════════════════════════════════════════════════════════════════
-- 39_status_inativada.sql — status "INATIVADA" para demandas
--
-- Antes: inativar uma demanda só setava ativo=false; a situacao continuava
-- "PENDENTE"/"EM ANDAMENTO" no banco (registro ficava "aberto" pra sempre e
-- exigia filtrar ativo=true em toda contagem).
-- Agora: inativar troca a situacao para 'INATIVADA', guardando a situacao
-- anterior em situacao_anterior (restaurada ao reativar).
--
-- Depende de: 01 (denuncias), 05 (denuncia_inativar/reativar).
-- Idempotente. Rodar no SQL Editor depois do 01 e do 05.
-- ════════════════════════════════════════════════════════════════════════

-- 1) coluna p/ lembrar a situacao antes de inativar (restaura ao reativar)
alter table public.denuncias add column if not exists situacao_anterior text;

-- 2) amplia o CHECK de situacao p/ aceitar 'INATIVADA'
--    (dropa qualquer check que mencione situacao, seja qual for o nome)
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.denuncias'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%situacao%'
  loop
    execute format('alter table public.denuncias drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.denuncias
  add constraint denuncias_situacao_check
  check (situacao in ('PENDENTE','EM ANDAMENTO','CONCLUIDA','RESPONDIDA','INATIVADA'));

-- 3) backfill: demandas já inativadas passam a ter situacao 'INATIVADA'
--    (guardando a situacao que tinham em situacao_anterior)
update public.denuncias
   set situacao_anterior = coalesce(situacao_anterior, situacao),
       situacao = 'INATIVADA'
 where ativo = false
   and situacao <> 'INATIVADA';

-- 4) inativar: agora guarda a situacao anterior e marca situacao='INATIVADA'
create or replace function public.denuncia_inativar(p_token uuid, p_id uuid, p_motivo text)
returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.denuncias;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if v_me.nivel_acesso <> 'admin_geral' then
    raise exception 'Inativação restrita ao Admin Geral.';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Informe o motivo da inativação.';
  end if;

  update public.denuncias set
    ativo = false,
    situacao_anterior = case when situacao <> 'INATIVADA' then situacao else situacao_anterior end,
    situacao = 'INATIVADA',
    motivo_inativacao = upper(trim(p_motivo)),
    inativado_por_matricula = v_me.matricula,
    inativado_por_nome = trim(both ' ' from
      concat(v_me.matricula, ' — ', coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo))),
    inativado_em = now()
  where id = p_id
  returning * into v_row;

  if v_row.id is null then raise exception 'Registro não encontrado.'; end if;
  return v_row;
end;
$$;

-- 5) reativar: restaura a situacao anterior (fallback 'PENDENTE')
create or replace function public.denuncia_reativar(p_token uuid, p_id uuid)
returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.denuncias;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if v_me.nivel_acesso <> 'admin_geral' then
    raise exception 'Reativação restrita ao Admin Geral.';
  end if;

  update public.denuncias set
    ativo = true,
    situacao = coalesce(situacao_anterior, 'PENDENTE'),
    situacao_anterior = null,
    motivo_inativacao = null,
    inativado_por_matricula = null, inativado_por_nome = null, inativado_em = null
  where id = p_id
  returning * into v_row;

  if v_row.id is null then raise exception 'Registro não encontrado.'; end if;
  return v_row;
end;
$$;

grant execute on function public.denuncia_inativar(uuid, uuid, text) to anon;
grant execute on function public.denuncia_reativar(uuid, uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do 01 e do 05.
-- ════════════════════════════════════════════════════════════════════════

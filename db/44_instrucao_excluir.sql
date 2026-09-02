-- ════════════════════════════════════════════════════════════════════════
-- 44_instrucao_excluir.sql
--
-- Admin Geral pode EXCLUIR uma instrução lançada. A FK
-- chamada_instrucao.instrucao_id → instrucoes(id) é ON DELETE CASCADE
-- (ver 24_chamada_instrucao.sql), então os lançamentos de presença
-- (presentes e ausentes) daquela instrução são apagados junto.
--
-- Restrito a admin_geral (nível mais alto). Todos os RPCs são security
-- definer com autorização por token.
--
-- Depende de: 24_chamada_instrucao.sql, 04_sessoes_e_militares_seguranca.sql.
-- Idempotente. Rodar no SQL Editor depois do 24.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.instrucao_excluir(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me record;
  v_n  int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Apenas o Admin Geral pode excluir uma instrução.';
  end if;
  if p_id is null then
    raise exception 'Instrução não informada.';
  end if;

  -- quantos lançamentos serão removidos junto (via cascade), só para o retorno
  select count(*) into v_n from public.chamada_instrucao where instrucao_id = p_id;

  delete from public.instrucoes where id = p_id;
  if not found then
    raise exception 'Instrução não encontrada.';
  end if;

  return jsonb_build_object('ok', true, 'lancamentos_removidos', coalesce(v_n, 0));
end;
$$;

grant execute on function public.instrucao_excluir(uuid, uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 24_chamada_instrucao.sql.
-- ════════════════════════════════════════════════════════════════════════

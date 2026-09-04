-- 54_tta_excluir_temas_mes.sql
-- Apaga TODOS os temas de um mês/ano de uma só vez (Gestão do TTA).
-- Mesma regra de permissão do 🗑 por dia (tta_excluir_tema):
--   Aux P1 (lotado em ADM) ou Admin Geral.
-- Retorna a quantidade de temas removidos.

create or replace function public.tta_excluir_temas_mes(p_token uuid, p_ano int, p_mes int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_n int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._pode_gerenciar_tta(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id) then
    raise exception 'Gestão do TTA restrita ao Aux P1 (ADM) ou Admin Geral.';
  end if;

  with del as (
    delete from public.tta_temas
     where ano = p_ano and mes = p_mes
     returning 1
  )
  select count(*) into v_n from del;

  return jsonb_build_object('ok', true, 'removidos', v_n);
end;
$$;

grant execute on function public.tta_excluir_temas_mes(uuid, int, int) to anon;

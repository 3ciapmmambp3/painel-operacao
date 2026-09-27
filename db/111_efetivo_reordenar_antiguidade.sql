-- ══════════════════════════════════════════════════════════════════════
--  EFETIVO — reordenar antiguidade (arrastar) para desempate
--  Quando dois militares têm o mesmo posto e a MESMA data de promoção, a
--  antiguidade é resolvida na mão. O Aux P1 arrasta as linhas e salva; isto
--  grava antiguidade_ordem = posição (1..N) na ordem enviada. A listagem já
--  ordena por antiguidade_ordem primeiro.
--  Depende de: 102 (_efetivo_pode, antiguidade_ordem). Idempotente. Rodar depois do 110.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.efetivo_reordenar(p_token uuid, p_ids uuid[])
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Ordenação restrita ao Aux P1 / Comando.';
  end if;
  if p_ids is null or array_length(p_ids,1) is null then return; end if;

  update public.militares m
     set antiguidade_ordem = t.ord
    from (select id, ordinality::int as ord
            from unnest(p_ids) with ordinality as u(id, ordinality)) t
   where m.id = t.id;
end;
$$;
grant execute on function public.efetivo_reordenar(uuid, uuid[]) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do 110.
-- ══════════════════════════════════════════════════════════════════════

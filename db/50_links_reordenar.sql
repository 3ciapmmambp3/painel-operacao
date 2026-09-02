-- ════════════════════════════════════════════════════════════════════════
-- 50_links_reordenar.sql — Reordenar Links Úteis (arrastar-e-soltar)
--
-- O Admin Geral arrasta os cards na aba Administração → "Links Úteis" para
-- definir a ordem em que aparecem na seção "Links úteis" do Meu Dia. Este RPC
-- recebe os IDs já na ordem desejada e regrava a coluna `ordem` (1..N) numa
-- única chamada.
--
-- Depende de: 32_links_uteis.sql. Idempotente. Rodar no SQL Editor depois do 35.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.links_uteis_reordenar(p_token uuid, p_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: apenas o Admin Geral gerencia os links úteis.';
  end if;
  if p_ids is null or array_length(p_ids,1) is null then
    raise exception 'Nenhum link informado para reordenar.';
  end if;

  update public.links_uteis l
     set ordem = t.ord
    from (select id, row_number() over () as ord
            from unnest(p_ids) as id) t
   where l.id = t.id;

  return jsonb_build_object('ok', true, 'total', array_length(p_ids,1));
end;
$$;

grant execute on function public.links_uteis_reordenar(uuid, uuid[]) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 35.
-- ════════════════════════════════════════════════════════════════════════

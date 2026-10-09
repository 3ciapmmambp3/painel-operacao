-- ════════════════════════════════════════════════════════════════════════
--  CARTÃO PROGRAMA — contatos da equipe (telefone) p/ envio por WhatsApp
--
--  Devolve o telefone pessoal (telefone_pessoal1) dos militares da EQUIPE do
--  cartão (comandante, motorista, patrulheiros), resolvidos pela matrícula que
--  está gravada no cartão. Exposto SOMENTE para quem pode ver aquele cartão
--  (mesma regra de _cartao_pode_ver, ou militar do mesmo grupamento) — o
--  telefone não vaza para fora do escopo do cartão.
--
--  Depende de: 127 (cartoes_programa, _cartao_pode_ver), 107 (telefone_pessoal1
--  em militares), 04 (_sessao_militar). Idempotente. Rodar depois do 127.
-- ════════════════════════════════════════════════════════════════════════
create or replace function public.cartao_contatos(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_c public.cartoes_programa; v_itens jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_c from public.cartoes_programa where id = p_id and ativo = true;
  if v_c.id is null then raise exception 'Cartão não encontrado.'; end if;
  if not public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, v_c.grupamento_id)
     and v_c.grupamento_id <> coalesce(v_me.grupamento_id,'') then
    raise exception 'Sem permissão para os contatos deste cartão.';
  end if;

  with membros as (
    select 1 as ord, 'Comandante'::text as papel, v_c.comandante as val
    union all select 2, 'Motorista', v_c.motorista
    union all select 3, 'Patrulheiro', x.val
      from jsonb_array_elements_text(coalesce(v_c.patrulheiros,'[]'::jsonb)) x(val)
  ),
  resolvido as (
    select me.ord, me.papel, me.val,
           lpad(regexp_replace(split_part(me.val,' - ',1), '\D','','g'), 7, '0') as mc
    from membros me
    where coalesce(btrim(me.val),'') <> '' and me.val !~* 'n[ãa]o h[áa]'
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'papel', r.papel,
             'nome',  coalesce(nullif(btrim(coalesce(m.posto_graduacao,'')||' '||coalesce(m.nome_guerra, m.nome_completo)),''), r.val),
             'matricula', m.matricula,
             'telefone', m.telefone_pessoal1
           ) order by r.ord), '[]'::jsonb)
    into v_itens
  from resolvido r
  left join public.militares m on m.matricula_clean = r.mc;

  return v_itens;
end;
$$;

grant execute on function public.cartao_contatos(uuid, uuid) to anon;
-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 127).
-- ════════════════════════════════════════════════════════════════════════

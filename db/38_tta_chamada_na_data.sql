-- ════════════════════════════════════════════════════════════════════════
-- 38_tta_chamada_na_data.sql — Chamada do TTA que contém o militar em UMA DATA.
--
-- Generaliza tta_chamada_do_militar_hoje p/ uma data qualquer, usada pela Ficha
-- de Movimentação ao preencher uma pendência de DIA PASSADO (pré-preenche
-- viatura/municípios/comandante e o início/fim do turno daquele dia).
--
-- Depende de: 04 (_sessao_militar), 07 (tta_chamadas). Idempotente.
-- Rodar no SQL Editor depois do 07.
-- ════════════════════════════════════════════════════════════════════════
create or replace function public.tta_chamada_do_militar_na_data(p_token uuid, p_data date)
returns public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.tta_chamadas;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_row from public.tta_chamadas
   where (data_hora_chamada at time zone 'America/Sao_Paulo')::date = p_data
     and ( militar_resp_matricula = v_me.matricula
        or militares_presentes @> jsonb_build_array(jsonb_build_object('matricula', v_me.matricula)) )
   order by created_at desc
   limit 1;

  return v_row;   -- linha vazia (id null) se não houver
end;
$$;

grant execute on function public.tta_chamada_do_militar_na_data(uuid, date) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 07.
-- ════════════════════════════════════════════════════════════════════════

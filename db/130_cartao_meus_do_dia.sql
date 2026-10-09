-- ════════════════════════════════════════════════════════════════════════
--  CARTÃO PROGRAMA — "Meu Dia": cartões do dia em que o militar está na equipe
--
--  Alimenta o aviso do Meu Dia (inicio.html): lista os cartões de HOJE em diante
--  em que o militar logado é comandante, motorista ou patrulheiro (casando pela
--  matrícula gravada no cartão), ainda não concluídos. Assim a mesma informação
--  enviada por WhatsApp também aparece no Meu Dia da equipe.
--
--  Depende de: 127 (cartoes_programa), 04 (_sessao_militar). Idempotente.
-- ════════════════════════════════════════════════════════════════════════

-- true se a matrícula (matricula_clean) está em qualquer papel da equipe do cartão
create or replace function public._cartao_tem_militar(c public.cartoes_programa, p_mc text)
returns boolean language plpgsql immutable as $$
declare x text; mc text := nullif(p_mc,'');
begin
  if mc is null then return false; end if;
  if lpad(regexp_replace(split_part(coalesce(c.comandante,''),' - ',1),'\D','','g'),7,'0') = mc then return true; end if;
  if lpad(regexp_replace(split_part(coalesce(c.motorista,''),' - ',1),'\D','','g'),7,'0') = mc then return true; end if;
  for x in select jsonb_array_elements_text(coalesce(c.patrulheiros,'[]'::jsonb)) loop
    if lpad(regexp_replace(split_part(x,' - ',1),'\D','','g'),7,'0') = mc then return true; end if;
  end loop;
  return false;
end;
$$;

create or replace function public.cartao_meus_do_dia(p_token uuid)
returns setof public.cartoes_programa
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  return query
    select c.* from public.cartoes_programa c
    where c.ativo = true
      and c.status <> 'CONCLUIDO'
      and c.data_empenho >= ((now() at time zone 'America/Sao_Paulo')::date)
      and public._cartao_tem_militar(c, v_me.matricula_clean)
    order by c.data_empenho, c.equipe, c.numero_seq;
end;
$$;

grant execute on function public.cartao_meus_do_dia(uuid) to anon;
-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 127).
-- ════════════════════════════════════════════════════════════════════════

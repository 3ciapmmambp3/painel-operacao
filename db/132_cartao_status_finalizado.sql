-- ════════════════════════════════════════════════════════════════════════
--  CARTÃO PROGRAMA — status leva em conta "finalizado" (3 estados)
--
--  Agora cada demanda pode ser respondida como TOTAL (Finalizado), PARCIAL
--  (Em andamento — precisa de nova diligência) ou NAO (Não atendido). O cartão
--  só fica CONCLUIDO quando TODAS as demandas estão FINALIZADAS (TOTAL). Se
--  houver PARCIAL/NAO, fica EM_ATENDIMENTO (em evidência para novo despacho).
--
--  Recria só a função _cartao_status (db/127). Idempotente. Rodar depois do 127.
-- ════════════════════════════════════════════════════════════════════════
create or replace function public._cartao_status(p_demandas jsonb, p_respostas jsonb)
returns text language plpgsql immutable as $$
declare v_total int; v_fin int := 0; v_toc int := 0; d jsonb; v_ord text; a text;
begin
  v_total := coalesce(jsonb_array_length(p_demandas), 0);
  if v_total = 0 then return 'EMITIDO'; end if;
  for d in select * from jsonb_array_elements(p_demandas) loop
    v_ord := coalesce(d->>'ordem', '');
    if p_respostas ? v_ord then
      a := coalesce(p_respostas->v_ord->>'atendida', '');
      if a <> '' then v_toc := v_toc + 1; end if;
      if a = 'TOTAL' then v_fin := v_fin + 1; end if;
    end if;
  end loop;
  if v_toc = 0 then return 'EMITIDO';
  elsif v_fin >= v_total then return 'CONCLUIDO';
  else return 'EM_ATENDIMENTO'; end if;
end;
$$;
-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 127). As funções que chamam
-- _cartao_status (cartao_atender/criar/editar) passam a usar esta versão.
-- ════════════════════════════════════════════════════════════════════════

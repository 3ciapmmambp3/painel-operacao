-- ════════════════════════════════════════════════════════════════════════
-- 11_tta_relatorio.sql — Integração TTA → Relatório de Serviço.
-- Acha o TTA de HOJE que CONTÉM o militar logado (não só o que ele registrou),
-- porque normalmente o mais antigo monta um TTA para toda a equipe/local.
-- Depende de: 04 (_sessao_militar) e 07_tta (tta_chamadas + coluna equipes).
-- Idempotente.
-- ════════════════════════════════════════════════════════════════════════
create or replace function public.tta_chamada_do_militar_hoje(p_token uuid)
returns public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.tta_chamadas;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_row from public.tta_chamadas
   where (data_hora_chamada at time zone 'America/Sao_Paulo')::date = v_hoje
     and ( militar_resp_matricula = v_me.matricula
        or militares_presentes @> jsonb_build_array(jsonb_build_object('matricula', v_me.matricula)) )
   order by created_at desc
   limit 1;

  return v_row;   -- linha vazia (id null) se não houver
end;
$$;

grant execute on function public.tta_chamada_do_militar_hoje(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rode no SQL Editor depois do 07.
-- ════════════════════════════════════════════════════════════════════════

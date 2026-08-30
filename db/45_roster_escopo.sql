-- ════════════════════════════════════════════════════════════════════════
-- 45_roster_escopo.sql
--   Roster de militares COM recorte por grupamento/pelotão — para telas que
--   devem respeitar o escopo do usuário (Missões e Chamada de Instrução).
--   O TTA/Relatório/Viaturas continuam usando tta_listar_militares (Cia inteira,
--   db/44). Mesmo formato de retorno de tta_listar_militares.
--
--   Regra (a mesma que o db/28 aplicava antes do db/44):
--     • visão total = Admin Geral/Admin ou Comando da Cia (função CMT + CIA);
--     • ADM = quem é lotado na ADM vê todos os da ADM;
--     • Admin Pelotão = todos os grupamentos do SEU pelotão;
--     • demais (GP/Operacional/Admin GP) = só o próprio grupamento.
--   Exclui ASPM e contas de teste.
--
--   Depende de: 04 (_sessao_militar), militares. Idempotente. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════
create or replace function public.militares_roster_escopo(p_token uuid)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text, funcao text)
language plpgsql security definer set search_path = public as $$
declare v_me record; v_ge boolean; v_adm boolean; v_pel text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  v_ge  := coalesce(v_me.nivel_acesso,'') in ('admin_geral','admin')
        or (upper(coalesce(v_me.funcao,'')) like '%CMT%' and upper(coalesce(v_me.funcao,'')) like '%CIA%');
  v_adm := upper(btrim(coalesce(v_me.grupamento_id,''))) like 'ADM%';
  v_pel := (regexp_match(upper(coalesce(v_me.grupamento_id,'')), '(\d+)\s*PEL'))[1];
  return query
    select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra,
           m.grupamento_id, m.funcao
    from public.militares m
    where m.ativo = true
      and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
      and coalesce(upper(btrim(m.funcao)),'') <> 'ASPM'
      and (
            v_ge
         or (v_adm and upper(btrim(coalesce(m.grupamento_id,''))) like 'ADM%')
         or (not v_adm and v_me.nivel_acesso = 'admin_pelotao' and v_pel is not null
             and (regexp_match(upper(coalesce(m.grupamento_id,'')), '(\d+)\s*PEL'))[1] = v_pel)
         or (not v_adm and coalesce(v_me.nivel_acesso,'') <> 'admin_pelotao'
             and m.grupamento_id = v_me.grupamento_id)
          )
    order by m.matricula_clean;
end;
$$;
grant execute on function public.militares_roster_escopo(uuid) to anon;
-- ════════════════════════════════════════════════════════════════════════
-- FIM.
-- ════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- 44_tta_roster_cia_inteira.sql
--   tta_listar_militares volta a listar TODA a 3ª Cia — SEM recorte por
--   grupamento/pelotão. Motivo: nas operações e no apoio a equipe mistura
--   militares da Companhia inteira, não só do pelotão/grupamento do autor.
--
--   O db/28_agenda_secao.sql tinha passado a filtrar por grupamento (visão
--   total só p/ Admin/Cmt Cia; pelotão p/ Admin Pelotão; demais só o próprio
--   GP). Isso restringia indevidamente a montagem de equipes do TTA/Relatório.
--
--   Mantém as melhorias do db/28: exclui ASPM e contas de teste; inclui `funcao`.
--   MESMO return type da versão atual → create or replace (sem drop).
--   Afeta TTA, Relatório, Chamada, Viaturas, Missões (todos usam esta função).
--   Idempotente. Rodar no SQL Editor (não precisa re-rodar 07 nem 28).
-- ════════════════════════════════════════════════════════════════════════
create or replace function public.tta_listar_militares(p_token uuid)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text, funcao text)
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  return query
    select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra,
           m.grupamento_id, m.funcao
    from public.militares m
    where m.ativo = true
      and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
      and coalesce(upper(btrim(m.funcao)),'') <> 'ASPM'   -- ASPM não é militar
    order by m.matricula_clean;
end;
$$;
grant execute on function public.tta_listar_militares(uuid) to anon;
-- ════════════════════════════════════════════════════════════════════════
-- FIM.
-- ════════════════════════════════════════════════════════════════════════

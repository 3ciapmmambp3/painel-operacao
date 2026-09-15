-- ════════════════════════════════════════════════════════════════════════
-- 73_roster_adm_para_cmt_1pel_gv.sql
--
--   O CMT do 1º Pelotão (Governador Valadares) normalmente lança a chamada da
--   fração ADM (Administração — Cmt Cia, Aux P1–P5, SRAI, sem GP próprio).
--   Para isso, na CHAMADA DE INSTRUÇÃO, a ADM precisa entrar no escopo dele.
--
--   Feito SÓ na Chamada de Instrução (não mexe em TTA/efetivo): um roster
--   próprio `instrucao_roster` = roster escopado normal + a fração ADM quando
--   o usuário é o CMT do 1º Pel de Gov. Valadares. Como a Chamada usa esse
--   roster como fonte única (picker de grupamentos, validação, dashboard e
--   avisos), a ADM passa a: aparecer no picker, ser aceita na validação,
--   trazer os militares da ADM no dashboard e avisar quem é da ADM.
--
--   Alvo (só ele): nivel_acesso='admin_pelotao' E grupamento contém
--   "GOVERNADOR VALADARES" E nº do pelotão = 1. Ninguém mais é afetado, e o
--   `militares_roster_escopo` (usado por TTA/efetivo) fica INTACTO.
--
--   Depende de: 67 (militares_roster_escopo), 51 (_instrucao_grupamentos_
--   permitidos), 04. Idempotente. Rodar no SQL Editor depois do 67.
-- ════════════════════════════════════════════════════════════════════════

-- ─── Roster da CHAMADA = escopo normal (+ ADM p/ o CMT 1º Pel GV) ──────
create or replace function public.instrucao_roster(p_token uuid)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text, funcao text, nivel_acesso text)
language plpgsql security definer set search_path = public as $$
declare v_me record; v_gv1 boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  v_gv1 := coalesce(v_me.nivel_acesso,'') = 'admin_pelotao'
       and upper(coalesce(v_me.grupamento_id,'')) like '%GOVERNADOR VALADARES%'
       and (regexp_match(upper(coalesce(v_me.grupamento_id,'')), '(\d+)\s*PEL'))[1] = '1';

  -- base: o escopo normal do usuário (inalterado)
  return query select * from public.militares_roster_escopo(p_token);

  -- extra: a fração ADM, só p/ o CMT 1º Pel de Gov. Valadares
  if v_gv1 then
    return query
      select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra,
             m.grupamento_id, m.funcao, m.nivel_acesso
      from public.militares m
      where m.ativo = true
        and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
        and coalesce(upper(btrim(m.funcao)),'') <> 'ASPM'
        and upper(btrim(coalesce(m.grupamento_id,''))) like 'ADM%';
  end if;
end;
$$;
grant execute on function public.instrucao_roster(uuid) to anon;

-- ─── O picker/validação da Chamada passam a derivar de instrucao_roster ─
create or replace function public._instrucao_grupamentos_permitidos(p_token uuid)
returns text[] language sql security definer set search_path = public as $$
  select coalesce(array_agg(distinct g), '{}')
  from (
    select nullif(btrim(grupamento_id),'') as g
    from public.instrucao_roster(p_token)
  ) s
  where g is not null;
$$;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. A Chamada de Instrução (frontend) deve ler instrucao_roster no lugar
-- de militares_roster_escopo. TTA/efetivo seguem no militares_roster_escopo.
-- ════════════════════════════════════════════════════════════════════════

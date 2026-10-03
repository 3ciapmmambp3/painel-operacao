-- ════════════════════════════════════════════════════════════════════════
--  db/125 — CMT de Pelotão com acesso de gestão P1 (Efetivo + Férias)
--  Data: 2026-10-03
--
--  CONTEXTO: na ausência do Comandante da Cia, quem assume o comando são os
--  Comandantes de Pelotão. Portanto eles devem ter o MESMO acesso de gestão
--  que o CMT de Cia nos módulos EFETIVO e FÉRIAS.
--
--  Antes: gestão = Admin Geral  OU  (Aux + P1)  OU  (CMT/COMANDANTE + CIA).
--  Agora: + (CMT/COMANDANTE + PEL)  → identifica o Comandante de Pelotão pela
--  função, no mesmo critério do front-end (podeP1/podeGerir/podeAprovarPel).
--
--  Idempotente: só redefine os dois helpers (create or replace). As demais
--  funções que os chamam passam a enxergar o CMT de Pelotão automaticamente.
--  Rollback: reeditar removendo a última cláusula "~* 'pel'".
-- ════════════════════════════════════════════════════════════════════════

-- FÉRIAS — quem faz a GESTÃO (Aux P1 / Admin Geral / CMT Cia / CMT Pelotão)
create or replace function public._ferias_pode_p1(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* 'pel');
$$;

-- EFETIVO — quem gere o efetivo (Aux P1 / Admin Geral / CMT Cia / CMT Pelotão)
create or replace function public._efetivo_pode(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* 'pel');
$$;

-- grants (preservados pelo create or replace; reafirmados por segurança)
grant execute on function public._ferias_pode_p1(text, text) to anon;
grant execute on function public._efetivo_pode(text, text)   to anon;

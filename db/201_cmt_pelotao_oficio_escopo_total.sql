-- ════════════════════════════════════════════════════════════════════════
--  db/201 — CMT de Pelotão com ACESSO TOTAL no Controle de Ofícios
--  Data: 2026-11-18
--
--  CONTEXTO: na ausência do Comandante da Cia, quem assume o comando são os
--  Comandantes de Pelotão. Ficou combinado que eles teriam o MESMO acesso do
--  CMT de Cia no painel. No módulo de Ofícios, porém, o CMT de Pelotão ainda
--  via só os ofícios do próprio pelotão (recorte de admin_pelotao) e não tinha
--  acesso ao controle de ofícios dos demais pelotões.
--
--  O gate de VISÃO/GESTÃO TOTAL dos ofícios é _oficio_escopo_total, usado por:
--    • oficio_listar  (db/77) — quem vê TODOS os ofícios;
--    • oficio_editar  (db/95) — quem edita QUALQUER ofício sem prazo/autoria;
--    • oficio_excluir (db/69) — quem pode excluir.
--
--  Antes: Admin Geral/Admin  OU  (Aux + P1)  OU  (CMT/COMANDANTE + CIA)
--         OU  (Colaborador + P1).
--  Agora: + (CMT/COMANDANTE + PEL) → identifica o Comandante de Pelotão pela
--  função, no MESMO critério já usado em Efetivo/Férias (db/125) e no front.
--  (Aux de Pelotão NÃO entra: a função dele casa "aux", não "cmt/comandante".)
--
--  Idempotente: só redefine o helper (create or replace preserva os grants).
--  Rollback: reeditar removendo a última cláusula "~* 'pel'".
--  Rodar no SQL Editor (depois do 136, que é a última redefinição do helper).
-- ════════════════════════════════════════════════════════════════════════

create or replace function public._oficio_escopo_total(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') in ('admin_geral','admin')
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* 'pel')
      or (coalesce(p_funcao,'') ~* 'colaborador' and coalesce(p_funcao,'') ~* 'p\s*1');
$$;

grant execute on function public._oficio_escopo_total(text, text) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. create or replace mantém os grants das funções que chamam este helper.
-- ════════════════════════════════════════════════════════════════════════

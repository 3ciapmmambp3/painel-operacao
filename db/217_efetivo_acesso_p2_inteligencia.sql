-- ══════════════════════════════════════════════════════════════════════
--  EFETIVO — acesso para a Seção de Inteligência (Aux P2)
--
--  Pedido (2026-11-24): militares lotados na seção Aux P2 — função
--  "Cmt SI" e "Agente de Inteligência" — devem acessar a aba Efetivo
--  (mesmo controle do Aux P1 / Comando).
--
--  Também RESTAURA a cláusula "(cmt|comandante) + pel" (Cmt de Pelotão),
--  que o db/125 adicionou e o db/136 (colaborador_secao) havia dropado sem
--  querer ao reescrever a função — o front (podeGerir) já liberava o Cmt de
--  Pelotão, mas a RPC negava. Agora os dois lados batem.
--
--  _efetivo_pode é o gate único das RPCs de efetivo (efetivo_listar/_salvar/
--  _inativar/_excluir/_reativar...). Idempotente. Rodar quando quiser.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public._efetivo_pode(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')                     -- Aux P1
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y')      -- Cmt Cia
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* 'pel')          -- Cmt Pelotão (restaurado)
      or (coalesce(p_funcao,'') ~* 'colaborador' and coalesce(p_funcao,'') ~* 'p\s*1')             -- colaborador da área P1
      -- Seção de Inteligência (Aux P2): Cmt SI e Agente de Inteligência
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*2')                     -- Aux P2
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '(\ysi\y|intelig)')  -- Cmt SI
      or (coalesce(p_funcao,'') ~* 'agente' and coalesce(p_funcao,'') ~* 'intelig');               -- Agente de Inteligência
$$;
grant execute on function public._efetivo_pode(text, text) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase.
-- ══════════════════════════════════════════════════════════════════════

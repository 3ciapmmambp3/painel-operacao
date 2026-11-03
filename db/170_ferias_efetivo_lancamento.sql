-- ══════════════════════════════════════════════════════════════════════
--  db/170 — Férias: picker de lançamento manual inclui HIPOTECADOS
--  Data: 2026-11-03
--
--  Problema: o lançamento manual de férias (Aux P1) usa o mesmo roster do
--  TTA (`tta_listar_militares`, db/135), que só lista `ativo = true`. Quando
--  um militar é HIPOTECADO *com suspensão de acesso ao painel*
--  (efetivo_hipotecar(..., true) → ativo=false, db/126), ele some do picker e
--  não dá para lançar as férias dele manualmente — embora continue contando
--  no RH. Esse é hoje o único caso (militar sem acesso ao painel).
--
--  Não dá para mexer no `tta_listar_militares`: ele é compartilhado por
--  Relatório, TTA, Chamada, Viaturas e Missões — incluir inativos ali poluiria
--  todos esses seletores. Por isso criamos uma função DEDICADA ao picker de
--  férias, que lista os ativos MAIS os hipotecados (mesmo com ativo=false).
--
--  Mesmas exclusões do tta_listar_militares (ASPM, colaborador, contas-semente)
--  e mesma gate do lançamento (Aux P1 / Comando, _ferias_pode_p1, db/135).
--  Retorno = o de tta_listar_militares + `situacao_efetivo` (p/ marcar o chip
--  "HIPOTECADO" na lista). Idempotente. Rodar no SQL Editor (depois do db/135).
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.ferias_efetivo_lancamento(p_token uuid)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text, funcao text, situacao_efetivo text)
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Lançamento de férias restrito ao Aux P1 / Comando.';
  end if;
  return query
    select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra,
           m.grupamento_id, m.funcao, m.situacao_efetivo
    from public.militares m
    where (m.ativo = true
           or coalesce(upper(btrim(m.situacao_efetivo)),'') = 'HIPOTECADO')  -- hipotecado entra mesmo sem acesso
      and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
      and coalesce(upper(btrim(m.funcao)),'') <> 'ASPM'          -- ASPM não é militar
      and coalesce(m.categoria,'militar') <> 'colaborador'       -- colaborador não é militar
    order by m.matricula_clean;
end;
$$;

grant execute on function public.ferias_efetivo_lancamento(uuid) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Depois do db/135. O front (ferias.html) passa a chamar esta função
-- no picker de "Novo lançamento de férias", em vez de tta_listar_militares.
-- ══════════════════════════════════════════════════════════════════════

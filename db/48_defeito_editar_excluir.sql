-- ════════════════════════════════════════════════════════════════════════
-- 48_defeito_editar_excluir.sql — Aux P4 edita/exclui defeito AVULSO
--
-- Na lista "Defeitos reportados" (Revisão da frota), a coluna Ações passa a
-- permitir ao gestor EDITAR e EXCLUIR um defeito reportado pelo botão 🔧
-- (linha da tabela defeitos_reportados). Os defeitos vindos de FICHA não são
-- editados aqui — eles pertencem à Ficha de Movimentação (gerida à parte).
--
-- Depende de: 34 (defeitos_reportados), 47 (colunas situacao/endereco/servicos).
-- Idempotente. Rodar no SQL Editor depois do 47.
-- ════════════════════════════════════════════════════════════════════════

-- ── Editar defeito AVULSO (restrito gestor) ─────────────────────────────
create or replace function public.defeito_editar(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: só o Aux P4 / Admin Geral edita defeitos.';
  end if;
  if nullif(btrim(p_dados->>'defeito'),'') is null then raise exception 'Descreva o defeito.'; end if;
  update public.defeitos_reportados set
    tipo                 = nullif(p_dados->>'tipo',''),
    urgencia             = nullif(p_dados->>'urgencia',''),
    odometro             = nullif(p_dados->>'odometro',''),
    defeito              = btrim(p_dados->>'defeito'),
    impede_uso           = nullif(p_dados->>'impede_uso',''),
    observacoes          = nullif(p_dados->>'observacoes',''),
    situacao             = nullif(p_dados->>'situacao',''),
    endereco             = nullif(p_dados->>'endereco',''),
    servicos_solicitados = coalesce(p_dados->'servicos_solicitados','[]'::jsonb)
  where id = p_id;
  if not found then raise exception 'Defeito não encontrado.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ── Excluir defeito AVULSO (restrito gestor) ────────────────────────────
create or replace function public.defeito_excluir(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: só o Aux P4 / Admin Geral exclui defeitos.';
  end if;
  delete from public.defeitos_reportados where id = p_id;
  if not found then raise exception 'Defeito não encontrado.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.defeito_editar(uuid, uuid, jsonb) to anon;
grant execute on function public.defeito_excluir(uuid, uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 47.
-- ════════════════════════════════════════════════════════════════════════

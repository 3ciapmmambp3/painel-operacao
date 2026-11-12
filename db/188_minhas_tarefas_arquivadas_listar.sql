-- 188_minhas_tarefas_arquivadas_listar.sql
-- Meu Dia → Minhas tarefas: a listagem passa a devolver TAMBÉM as ARQUIVADAS,
-- para a nova aba "Arquivadas" (ver / reabrir / informar).
--   • atribuidas  = tarefas de seção atribuídas a mim (inalterado)
--   • pessoais    = tarefas pessoais ATIVAS (status <> 'arquivada')
--   • arquivadas  = tarefas pessoais arquivadas (status = 'arquivada')  ← novo
-- Arquivar segue sendo um status compartilhado (vale p/ todos os participantes),
-- e o db/143 já permite dono OU compartilhado mudar o status.
-- Inclui 'historico' nos dois conjuntos (o card mostra as anotações).
-- Depende de db/28, db/89, db/90, db/143. Idempotente. Rodar no SQL Editor.

create or replace function public.minhas_tarefas_listar(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_atrib jsonb; v_pess jsonb; v_arq jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- ── Tarefas de seção atribuídas a mim (não concluídas) ──
  select coalesce(jsonb_agg(t order by t_prazo nulls last, t_created), '[]'::jsonb)
    into v_atrib
  from (
    select jsonb_build_object(
             'id', a.id, 'origem', 'secao', 'secao', a.secao, 'titulo', a.titulo,
             'status', a.status, 'prioridade', a.prioridade, 'prazo', a.prazo,
             'descricao', a.descricao, 'observacao', a.observacao,
             'historico', a.historico) as t,
           a.prazo as t_prazo, a.created_at as t_created
    from public.agenda_secao a
    where a.status <> 'concluida'
      and regexp_replace(coalesce(a.responsavel_matricula,''), '\D', '', 'g') = v_me.matricula_clean
  ) s;

  -- ── Tarefas pessoais ATIVAS (não arquivadas) ──
  select coalesce(jsonb_agg(t order by t_conc, t_prazo nulls last, t_created), '[]'::jsonb)
    into v_pess
  from (
    select jsonb_build_object(
             'id', p.id, 'origem', 'pessoal', 'titulo', p.titulo, 'status', p.status,
             'prioridade', p.prioridade, 'prazo', p.prazo, 'observacao', p.observacao,
             'data_conclusao', p.data_conclusao,
             'historico', coalesce(p.historico,'[]'::jsonb),
             'compartilhado_com', coalesce(p.compartilhado_com,'[]'::jsonb),
             'sou_dono', (p.militar_id = v_me.id),
             'criador_matricula', p.militar_matricula,
             'criador_nome', mo.nome_completo) as t,
           (p.status='concluida') as t_conc, p.prazo as t_prazo, p.created_at as t_created
    from public.agenda_pessoal p
    left join public.militares mo on mo.id = p.militar_id
    where p.status <> 'arquivada'
      and ( p.militar_id = v_me.id
            or exists (select 1 from jsonb_array_elements(coalesce(p.compartilhado_com,'[]'::jsonb)) e
                        where e->>'matricula_clean' = v_me.matricula_clean) )
  ) s;

  -- ── Tarefas pessoais ARQUIVADAS (mais recentes primeiro) ──
  select coalesce(jsonb_agg(t order by t_arch desc nulls last, t_created desc), '[]'::jsonb)
    into v_arq
  from (
    select jsonb_build_object(
             'id', p.id, 'origem', 'pessoal', 'titulo', p.titulo, 'status', p.status,
             'prioridade', p.prioridade, 'prazo', p.prazo, 'observacao', p.observacao,
             'data_conclusao', p.data_conclusao,
             'historico', coalesce(p.historico,'[]'::jsonb),
             'compartilhado_com', coalesce(p.compartilhado_com,'[]'::jsonb),
             'sou_dono', (p.militar_id = v_me.id),
             'criador_matricula', p.militar_matricula,
             'criador_nome', mo.nome_completo) as t,
           coalesce(p.data_conclusao, p.created_at) as t_arch, p.created_at as t_created
    from public.agenda_pessoal p
    left join public.militares mo on mo.id = p.militar_id
    where p.status = 'arquivada'
      and ( p.militar_id = v_me.id
            or exists (select 1 from jsonb_array_elements(coalesce(p.compartilhado_com,'[]'::jsonb)) e
                        where e->>'matricula_clean' = v_me.matricula_clean) )
  ) s;

  return jsonb_build_object('atribuidas', v_atrib, 'pessoais', v_pess, 'arquivadas', v_arq);
end;
$$;

grant execute on function public.minhas_tarefas_listar(uuid) to anon;

-- Ordem no SQL Editor: depois do 143.

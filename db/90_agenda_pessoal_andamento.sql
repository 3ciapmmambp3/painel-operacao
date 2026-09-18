-- ════════════════════════════════════════════════════════════════════════
-- 90_agenda_pessoal_andamento.sql — anotações (andamento) na tarefa pessoal
--
-- Complementa o 89. Na tarefa pessoal COMPARTILHADA, qualquer participante
-- (dono ou compartilhado) pode registrar ANOTAÇÕES de andamento, que ficam
-- guardadas com nome + data e aparecem para todos (não sobrescreve nada).
-- Ao CONCLUIR, abre um campo opcional de observação, que também vira anotação.
--
-- Guarda em `agenda_pessoal.historico` (jsonb array de
--   {tipo:'nota'|'conclusao', por_matricula, por_nome, texto, em}).
--
-- Depende de: 28 (agenda_pessoal, minhas_tarefas_listar), 89 (compartilhado_com),
--             04 (_sessao_militar).
-- Idempotente. Rodar no SQL Editor depois do 89.
-- ════════════════════════════════════════════════════════════════════════

-- 1) Coluna do histórico
alter table public.agenda_pessoal
  add column if not exists historico jsonb not null default '[]'::jsonb;

-- 2) Registrar andamento (anotação) e, opcionalmente, mudar o status.
--    Permitido ao dono OU a quem a tarefa foi compartilhada.
create or replace function public.agenda_pessoal_andamento(
  p_token uuid, p_id uuid, p_texto text, p_status text default null)
returns public.agenda_pessoal
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.agenda_pessoal; v_txt text := btrim(coalesce(p_texto,''));
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_status is not null and p_status not in ('pendente','em_andamento','concluida') then
    raise exception 'Status inválido.';
  end if;
  if v_txt = '' and p_status is null then raise exception 'Escreva a anotação.'; end if;

  update public.agenda_pessoal set
    status = coalesce(nullif(p_status,''), status),
    data_conclusao = case when p_status='concluida' then coalesce(data_conclusao, now())
                          when p_status in ('pendente','em_andamento') then null
                          else data_conclusao end,
    historico = case when v_txt <> ''
                  then coalesce(historico,'[]'::jsonb) || jsonb_build_object(
                         'tipo', case when p_status='concluida' then 'conclusao' else 'nota' end,
                         'por_matricula', v_me.matricula,
                         'por_nome', coalesce(v_me.nome_completo, v_me.nome_guerra, v_me.matricula),
                         'texto', v_txt, 'em', now())
                  else coalesce(historico,'[]'::jsonb) end
  where id = p_id
    and ( militar_id = v_me.id
          or exists (select 1 from jsonb_array_elements(coalesce(compartilhado_com,'[]'::jsonb)) e
                      where e->>'matricula_clean' = v_me.matricula_clean) )
  returning * into v_row;
  if v_row.id is null then raise exception 'Tarefa não encontrada ou sem permissão.'; end if;
  return v_row;
end;
$$;

-- 3) Listar do Meu Dia — pessoais agora trazem o `historico`
create or replace function public.minhas_tarefas_listar(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_atrib jsonb; v_pess jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

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

  select coalesce(jsonb_agg(t order by t_conc, t_prazo nulls last, t_created), '[]'::jsonb)
    into v_pess
  from (
    select jsonb_build_object(
             'id', p.id, 'origem', 'pessoal', 'titulo', p.titulo, 'status', p.status,
             'prioridade', p.prioridade, 'prazo', p.prazo, 'observacao', p.observacao,
             'data_conclusao', p.data_conclusao,
             'compartilhado_com', coalesce(p.compartilhado_com,'[]'::jsonb),
             'historico', coalesce(p.historico,'[]'::jsonb),
             'sou_dono', (p.militar_id = v_me.id),
             'criador_matricula', p.militar_matricula,
             'criador_nome', mo.nome_completo) as t,
           (p.status='concluida') as t_conc, p.prazo as t_prazo, p.created_at as t_created
    from public.agenda_pessoal p
    left join public.militares mo on mo.id = p.militar_id
    where p.militar_id = v_me.id
       or exists (select 1 from jsonb_array_elements(coalesce(p.compartilhado_com,'[]'::jsonb)) e
                   where e->>'matricula_clean' = v_me.matricula_clean)
  ) s;

  return jsonb_build_object('atribuidas', v_atrib, 'pessoais', v_pess);
end;
$$;

grant execute on function public.agenda_pessoal_andamento(uuid, uuid, text, text) to anon;
grant execute on function public.minhas_tarefas_listar(uuid)                       to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 89.
-- ════════════════════════════════════════════════════════════════════════

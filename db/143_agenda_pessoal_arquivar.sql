-- 143_agenda_pessoal_arquivar.sql
-- Meu Dia → Minhas tarefas: permitir ARQUIVAR uma tarefa pessoal concluída,
-- para ela sumir da lista (sem excluir — fica guardada com status 'arquivada').
-- Depende de db/28 (tabela) e db/89 (versões atuais das funções).

-- 1) Novo status permitido: 'arquivada'
alter table public.agenda_pessoal drop constraint if exists agenda_pessoal_status_check;
alter table public.agenda_pessoal
  add constraint agenda_pessoal_status_check
  check (status in ('pendente','em_andamento','concluida','arquivada'));

-- 2) agenda_pessoal_status aceita 'arquivada' (preserva a data de conclusão).
create or replace function public.agenda_pessoal_status(p_token uuid, p_id uuid, p_status text)
returns public.agenda_pessoal
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.agenda_pessoal;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_status not in ('pendente','em_andamento','concluida','arquivada') then raise exception 'Status inválido.'; end if;
  update public.agenda_pessoal set
    status = p_status,
    data_conclusao = case
                       when p_status='concluida' then coalesce(data_conclusao, now())
                       when p_status='arquivada' then data_conclusao          -- preserva a conclusão
                       else null end
  where id = p_id
    and ( militar_id = v_me.id
          or exists (select 1 from jsonb_array_elements(coalesce(compartilhado_com,'[]'::jsonb)) e
                      where e->>'matricula_clean' = v_me.matricula_clean) )
  returning * into v_row;
  if v_row.id is null then raise exception 'Tarefa não encontrada ou sem permissão.'; end if;
  return v_row;
end;
$$;

-- 3) minhas_tarefas_listar NÃO traz as arquivadas (some do Meu Dia).
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

  return jsonb_build_object('atribuidas', v_atrib, 'pessoais', v_pess);
end;
$$;

grant execute on function public.agenda_pessoal_status(uuid, uuid, text) to anon;
grant execute on function public.minhas_tarefas_listar(uuid)             to anon;

-- Ordem no SQL Editor: depois do 28 e do 89.

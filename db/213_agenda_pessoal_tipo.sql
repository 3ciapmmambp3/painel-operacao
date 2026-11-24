-- ══════════════════════════════════════════════════════════════════════
--  db/213 — agenda_pessoal: TIPO do item individual (lembrete | tarefa)
--  Data: 2026-11-23
--
--  Na Minha Agenda, o item que o militar cria pode ser um LEMBRETE (um aviso)
--  ou uma TAREFA individual dele (algo a fazer, com prazo — ex.: "preencher a
--  lista de férias"). Ambos continuam em agenda_pessoal; muda só o rótulo/cor.
--  Recria agenda_pessoal_salvar (grava tipo) e minhas_tarefas_listar (devolve
--  tipo) a partir das versões db/89 e db/188. Idempotente.
-- ══════════════════════════════════════════════════════════════════════

alter table public.agenda_pessoal add column if not exists tipo text not null default 'lembrete';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'agenda_pessoal_tipo_check') then
    alter table public.agenda_pessoal
      add constraint agenda_pessoal_tipo_check check (tipo in ('lembrete','tarefa'));
  end if;
end $$;

-- ── agenda_pessoal_salvar: agora grava TIPO (base: db/89) ──
create or replace function public.agenda_pessoal_salvar(p_token uuid, p_dados jsonb)
returns public.agenda_pessoal
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_row public.agenda_pessoal;
  v_id uuid := nullif(p_dados->>'id','')::uuid;
  v_status text := coalesce(nullif(p_dados->>'status',''), 'pendente');
  v_compart jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if coalesce(p_dados->>'titulo','') = '' then raise exception 'Informe o título da tarefa.'; end if;

  select coalesce(jsonb_agg(distinct jsonb_build_object(
           'matricula', e->>'matricula',
           'matricula_clean', lpad(regexp_replace(coalesce(e->>'matricula',''),'\D','','g'),7,'0'),
           'nome', e->>'nome')), '[]'::jsonb)
    into v_compart
  from jsonb_array_elements(coalesce(p_dados->'compartilhado_com','[]'::jsonb)) e
  where coalesce(e->>'matricula','') <> ''
    and lpad(regexp_replace(coalesce(e->>'matricula',''),'\D','','g'),7,'0') <> v_me.matricula_clean;

  if v_id is null then
    insert into public.agenda_pessoal (
      militar_id, militar_matricula, titulo, status, prioridade, prazo,
      data_conclusao, observacao, tipo, compartilhado_com)
    values (
      v_me.id, v_me.matricula, p_dados->>'titulo', v_status,
      coalesce(nullif(p_dados->>'prioridade',''),'media'),
      nullif(p_dados->>'prazo','')::timestamptz,
      case when v_status='concluida' then now() else null end,
      nullif(p_dados->>'observacao',''),
      coalesce(nullif(p_dados->>'tipo',''),'lembrete'),
      v_compart)
    returning * into v_row;
  else
    update public.agenda_pessoal set
      titulo     = coalesce(nullif(p_dados->>'titulo',''), titulo),
      status     = v_status,
      prioridade = coalesce(nullif(p_dados->>'prioridade',''), prioridade),
      prazo      = case when p_dados ? 'prazo' then nullif(p_dados->>'prazo','')::timestamptz else prazo end,
      data_conclusao = case when v_status='concluida' then coalesce(data_conclusao, now()) else null end,
      observacao = case when p_dados ? 'observacao' then nullif(p_dados->>'observacao','') else observacao end,
      tipo       = coalesce(nullif(p_dados->>'tipo',''), tipo),
      compartilhado_com = case when (p_dados ? 'compartilhado_com') and militar_id = v_me.id
                               then v_compart else compartilhado_com end
    where id = v_id
      and ( militar_id = v_me.id
            or exists (select 1 from jsonb_array_elements(coalesce(compartilhado_com,'[]'::jsonb)) e
                        where e->>'matricula_clean' = v_me.matricula_clean) )
    returning * into v_row;
    if v_row.id is null then raise exception 'Tarefa não encontrada ou sem permissão.'; end if;
  end if;
  return v_row;
end;
$$;

-- ── minhas_tarefas_listar: devolve TIPO nos itens pessoais (base: db/188) ──
create or replace function public.minhas_tarefas_listar(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_atrib jsonb; v_pess jsonb; v_arq jsonb;
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
             'tipo', coalesce(p.tipo,'lembrete'),
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

  select coalesce(jsonb_agg(t order by t_arch desc nulls last, t_created desc), '[]'::jsonb)
    into v_arq
  from (
    select jsonb_build_object(
             'id', p.id, 'origem', 'pessoal', 'titulo', p.titulo, 'status', p.status,
             'tipo', coalesce(p.tipo,'lembrete'),
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

grant execute on function public.agenda_pessoal_salvar(uuid, jsonb) to anon;
grant execute on function public.minhas_tarefas_listar(uuid)        to anon;

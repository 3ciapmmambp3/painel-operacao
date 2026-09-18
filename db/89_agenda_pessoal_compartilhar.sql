-- ════════════════════════════════════════════════════════════════════════
-- 89_agenda_pessoal_compartilhar.sql — compartilhar tarefa PESSOAL com militares
--
-- No "Meu Dia" › Minhas tarefas, a "Nova tarefa pessoal" passa a poder ser
-- COMPARTILHADA com um ou mais militares. Modelo escolhido:
--   • Tarefa ÚNICA compartilhada (um só registro), que aparece no Meu Dia do
--     criador E de cada militar escolhido.
--   • TODOS os participantes (criador + compartilhados) podem EDITAR o conteúdo
--     e mudar o status — as informações inseridas aparecem para todos.
--   • Só o CRIADOR (dono) pode EXCLUIR e alterar a lista de compartilhamento.
--
-- Guarda os compartilhados em `agenda_pessoal.compartilhado_com` (jsonb array de
-- {matricula, matricula_clean, nome}).
--
-- Depende de: 28 (agenda_pessoal, agenda_pessoal_salvar/status/excluir,
--             minhas_tarefas_listar, agenda_pessoas_listar), 04 (_sessao_militar).
-- Idempotente. Rodar no SQL Editor depois do 28.
-- ════════════════════════════════════════════════════════════════════════

-- 1) Coluna nova
alter table public.agenda_pessoal
  add column if not exists compartilhado_com jsonb not null default '[]'::jsonb;

-- 2) Criar/editar tarefa pessoal — grava compartilhamento (só o dono altera a
--    lista); dono E compartilhados podem editar o conteúdo.
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

  -- Normaliza a lista de compartilhados: {matricula, matricula_clean, nome},
  -- sem o próprio dono e sem duplicidades.
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
      data_conclusao, observacao, compartilhado_com)
    values (
      v_me.id, v_me.matricula, p_dados->>'titulo', v_status,
      coalesce(nullif(p_dados->>'prioridade',''),'media'),
      nullif(p_dados->>'prazo','')::timestamptz,
      case when v_status='concluida' then now() else null end,
      nullif(p_dados->>'observacao',''), v_compart)
    returning * into v_row;
  else
    update public.agenda_pessoal set
      titulo     = coalesce(nullif(p_dados->>'titulo',''), titulo),
      status     = v_status,
      prioridade = coalesce(nullif(p_dados->>'prioridade',''), prioridade),
      prazo      = case when p_dados ? 'prazo' then nullif(p_dados->>'prazo','')::timestamptz else prazo end,
      data_conclusao = case when v_status='concluida' then coalesce(data_conclusao, now()) else null end,
      observacao = case when p_dados ? 'observacao' then nullif(p_dados->>'observacao','') else observacao end,
      -- só o DONO altera a lista de compartilhamento
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

-- 3) Status rápido — dono OU compartilhado
create or replace function public.agenda_pessoal_status(p_token uuid, p_id uuid, p_status text)
returns public.agenda_pessoal
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.agenda_pessoal;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_status not in ('pendente','em_andamento','concluida') then raise exception 'Status inválido.'; end if;
  update public.agenda_pessoal set
    status = p_status,
    data_conclusao = case when p_status='concluida' then coalesce(data_conclusao, now()) else null end
  where id = p_id
    and ( militar_id = v_me.id
          or exists (select 1 from jsonb_array_elements(coalesce(compartilhado_com,'[]'::jsonb)) e
                      where e->>'matricula_clean' = v_me.matricula_clean) )
  returning * into v_row;
  if v_row.id is null then raise exception 'Tarefa não encontrada ou sem permissão.'; end if;
  return v_row;
end;
$$;

-- 4) Excluir — SÓ o dono (mantém militar_id = eu)
--    (inalterada em relação ao 28; recriada aqui só por clareza)
create or replace function public.agenda_pessoal_excluir(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  delete from public.agenda_pessoal where id = p_id and militar_id = v_me.id;
  return jsonb_build_object('ok', true);
end;
$$;

-- 5) Agregador do Meu Dia — pessoais = minhas + as compartilhadas comigo
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
    where p.militar_id = v_me.id
       or exists (select 1 from jsonb_array_elements(coalesce(p.compartilhado_com,'[]'::jsonb)) e
                   where e->>'matricula_clean' = v_me.matricula_clean)
  ) s;

  return jsonb_build_object('atribuidas', v_atrib, 'pessoais', v_pess);
end;
$$;

grant execute on function public.agenda_pessoal_salvar(uuid, jsonb)      to anon;
grant execute on function public.agenda_pessoal_status(uuid, uuid, text) to anon;
grant execute on function public.agenda_pessoal_excluir(uuid, uuid)      to anon;
grant execute on function public.minhas_tarefas_listar(uuid)             to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 28.
-- ════════════════════════════════════════════════════════════════════════

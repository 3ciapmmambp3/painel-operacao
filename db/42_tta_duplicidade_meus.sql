-- ════════════════════════════════════════════════════════════════════════
-- 42_tta_duplicidade_meus.sql
--   TTA: impedir duplicidade (mesmo militar/viatura em 2 TTAs no mesmo dia),
--   auditoria das edições/substituições/exclusões, "Meus TTA" e exclusão
--   pelo Aux P1 / Admin Geral (com justificativa obrigatória).
--
--   Depende de: 04 (_sessao_militar), 07 (tta_chamadas, _pode_gerenciar_tta).
--   Rodar no SQL Editor. Depois RE-RODAR 07 e 22 (têm as versões novas de
--   tta_criar_chamada / tta_editar_chamada que usam _tta_conflitos e auditam).
--   Idempotente.
-- ════════════════════════════════════════════════════════════════════════

-- 1) Auditoria do TTA ------------------------------------------------------
create table if not exists public.tta_auditoria (
  id                 uuid primary key default gen_random_uuid(),
  chamada_id         uuid not null,
  acao               text not null check (acao in ('EDICAO','SUBSTITUICAO','EXCLUSAO')),
  usuario_matricula  text,
  usuario_nome       text,
  quando             timestamptz not null default now(),
  registro_anterior  jsonb,
  registro_novo      jsonb,
  justificativa      text
);
create index if not exists idx_tta_aud_chamada on public.tta_auditoria(chamada_id);
create index if not exists idx_tta_aud_quando  on public.tta_auditoria(quando desc);
alter table public.tta_auditoria enable row level security;   -- só via RPC

-- 2) Conflitos de lançamento (mesmo dia) ----------------------------------
--    Recebe o payload da chamada e devolve uma mensagem (ou '' se não há
--    conflito) listando militares/viaturas já lançados em OUTRA chamada do
--    mesmo dia. p_exclude = id da própria chamada (na edição), p/ não
--    conflitar consigo mesma.
create or replace function public._tta_conflitos(p_dados jsonb, p_data date, p_exclude uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_mil text;
  v_vtr text;
  v_msg text := '';
begin
  -- Militares do payload que já constam em outra chamada do mesmo dia
  select string_agg(distinct t.rotulo, '; ') into v_mil
  from (
    select coalesce(nullif(e->>'nome',''), nullif(e->>'nome_completo',''), 'militar')
             || ' (Nº ' || coalesce(e->>'matricula','?') || ')' as rotulo,
           regexp_replace(coalesce(e->>'matricula',''),'\D','','g')       as mat
    from jsonb_array_elements(coalesce(p_dados->'militares_presentes','[]'::jsonb)) e
  ) t
  where t.mat <> '' and exists (
    select 1
    from public.tta_chamadas c
    cross join lateral jsonb_array_elements(c.militares_presentes) ce
    where (c.data_hora_chamada at time zone 'America/Sao_Paulo')::date = p_data
      and (p_exclude is null or c.id <> p_exclude)
      and regexp_replace(coalesce(ce->>'matricula',''),'\D','','g') = t.mat
  );
  if coalesce(v_mil,'') <> '' then
    v_msg := 'Militar(es) já lançado(s) em outro TTA de hoje: ' || v_mil || '. ';
  end if;

  -- Viaturas do payload que já constam em outra chamada do mesmo dia
  select string_agg(distinct t.pref, '; ') into v_vtr
  from (
    select trim(v->>'prefixo') as pref
      from jsonb_array_elements(coalesce(p_dados->'viaturas','[]'::jsonb)) v
     where trim(coalesce(v->>'prefixo','')) <> ''
    union
    select trim(p_dados->>'prefixo_viatura')
     where trim(coalesce(p_dados->>'prefixo_viatura','')) <> ''
  ) t
  where exists (
    select 1
    from public.tta_chamadas c
    cross join lateral jsonb_array_elements(c.viaturas) cv
    where (c.data_hora_chamada at time zone 'America/Sao_Paulo')::date = p_data
      and (p_exclude is null or c.id <> p_exclude)
      and trim(coalesce(cv->>'prefixo','')) = t.pref
  );
  if coalesce(v_vtr,'') <> '' then
    v_msg := v_msg || 'Viatura(s) já em outro TTA de hoje: ' || v_vtr || '.';
  end if;

  return btrim(v_msg);
end;
$$;

-- 3) "Meus TTA": chamadas do mês em que o militar é responsável OU presente
create or replace function public.tta_listar_meus(p_token uuid, p_ano int, p_mes int)
returns setof public.tta_chamadas
language plpgsql stable security definer set search_path = public as $$
declare v_me record; v_mat text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  v_mat := regexp_replace(coalesce(v_me.matricula,''),'\D','','g');
  return query
    select * from public.tta_chamadas c
     where extract(year from c.data_hora_chamada at time zone 'America/Sao_Paulo')::int = p_ano
       and (p_mes is null or extract(month from c.data_hora_chamada at time zone 'America/Sao_Paulo')::int = p_mes)
       and (
         regexp_replace(coalesce(c.militar_resp_matricula,''),'\D','','g') = v_mat
         or exists (
           select 1 from jsonb_array_elements(c.militares_presentes) e
            where regexp_replace(coalesce(e->>'matricula',''),'\D','','g') = v_mat
         )
       )
     order by c.data_hora_chamada desc;
end;
$$;
grant execute on function public.tta_listar_meus(uuid, int, int) to anon;

-- 4) Excluir TTA — só Aux P1 (ADM) / Admin Geral, com justificativa + audit
create or replace function public.tta_excluir_chamada(p_token uuid, p_id uuid, p_justificativa text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.tta_chamadas;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._pode_gerenciar_tta(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id) then
    raise exception 'A exclusão de TTA é restrita ao Aux P1 (ADM) ou Admin Geral.';
  end if;
  if coalesce(btrim(p_justificativa),'') = '' then
    raise exception 'Justificativa é obrigatória para excluir um TTA.';
  end if;
  select * into v_row from public.tta_chamadas where id = p_id;
  if v_row.id is null then raise exception 'TTA não encontrado.'; end if;

  insert into public.tta_auditoria
    (chamada_id, acao, usuario_matricula, usuario_nome, registro_anterior, registro_novo, justificativa)
  values
    (v_row.id, 'EXCLUSAO', v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo),
     to_jsonb(v_row), null, btrim(p_justificativa));

  delete from public.tta_chamadas where id = p_id;
  return jsonb_build_object('ok', true, 'id', p_id);
end;
$$;
grant execute on function public.tta_excluir_chamada(uuid, uuid, text) to anon;

-- 5) Consulta da auditoria de um TTA — Aux P1 (ADM) / Admin Geral
create or replace function public.tta_auditoria_listar(p_token uuid, p_chamada_id uuid)
returns setof public.tta_auditoria
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._pode_gerenciar_tta(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id) then
    raise exception 'Sem permissão para ver a auditoria do TTA.';
  end if;
  return query
    select * from public.tta_auditoria where chamada_id = p_chamada_id order by quando desc;
end;
$$;
grant execute on function public.tta_auditoria_listar(uuid, uuid) to anon;

-- 6) tta_criar_chamada com anti-duplicidade -------------------------------
--    Redefinida aqui (create-or-replace, mesmo tipo de retorno) para NÃO
--    obrigar a re-rodar todo o 07 (cuja tta_listar_militares diverge da
--    versão em produção e falha com "cannot change return type").
create or replace function public.tta_criar_chamada(p_token uuid, p_dados jsonb)
returns public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.tta_chamadas;
  v_tema public.tta_temas;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_conf text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- Impede duplicidade: militar/viatura já lançado(s) em outro TTA de hoje.
  v_conf := public._tta_conflitos(p_dados, v_hoje, null);
  if v_conf <> '' then
    raise exception 'Lançamento duplicado — %', v_conf;
  end if;

  select * into v_tema from public.tta_temas
    where ano = extract(year from v_hoje)::int
      and mes = extract(month from v_hoje)::int
      and extract(day from v_hoje)::int = any(dias)
    order by created_at
    limit 1;

  insert into public.tta_chamadas (
    gp_responsavel, grupamento_completo,
    militar_resp_matricula, militar_resp_nome,
    militares_presentes, data_hora_chamada,
    tema_id, tema_assunto, tema_referencia,
    inicio_turno, final_turno, prefixo_viatura, viaturas, equipes, tipo_patrulha,
    municipios_atuacao, observacoes,
    registrado_por_matricula, registrado_por_nome
  ) values (
    p_dados->>'gp_responsavel', p_dados->>'grupamento_completo',
    v_me.matricula, v_me.nome_completo,
    coalesce(p_dados->'militares_presentes', '[]'::jsonb), now(),
    v_tema.id, v_tema.assunto, v_tema.referencia,
    nullif(p_dados->>'inicio_turno','')::time, nullif(p_dados->>'final_turno','')::time,
    nullif(p_dados->>'prefixo_viatura',''), coalesce(p_dados->'viaturas','[]'::jsonb), coalesce(p_dados->'equipes','[]'::jsonb), nullif(p_dados->>'tipo_patrulha',''),
    coalesce(p_dados->'municipios_atuacao', '[]'::jsonb), nullif(p_dados->>'observacoes',''),
    v_me.matricula, v_me.nome_completo
  ) returning * into v_row;

  return v_row;
end;
$$;
grant execute on function public.tta_criar_chamada(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem: rodar SÓ este 42 e depois o 22. NÃO precisa re-rodar o 07
-- (tta_criar_chamada já está redefinida aqui).
-- ════════════════════════════════════════════════════════════════════════

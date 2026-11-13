-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS-PRÊMIO — MANIFESTAÇÃO DE INTERESSE + REQUERIMENTO (3ª Cia P1)
--
--  Fluxo novo, DENTRO do módulo Férias (reusa ferias_cronograma / ferias_pedidos
--  / _ferias_pode_p1 / _ferias_pelotao / motor de % do db/119).
--
--  Conceito:
--   • O Aux P1 abre um PRAZO de manifestação da prêmio (independente do prazo
--     das anuais): premio_abertura / premio_limite / premio_situacao.
--   • TODO militar manifesta: COM interesse (interesse=true) ou SEM interesse
--     (interesse=false). Ambos anexam o requerimento assinado digitalmente.
--   • Só os COM interesse entram na cadeia CMT Pelotão → Aux P1 (situacao
--     PENDENTE→APROVADO_PEL→VALIDADO, reusa ferias_pedido_aprovar/validar).
--     SEM interesse = situacao 'SEM_INTERESSE' (fora da aprovação).
--   • É por LUSTRO e com DATAS LIVRES (não presa aos períodos do cronograma).
--     A etapa (1/2/3 meses) define a duração; parcelas:[{parcela:'PREMIO',ini,fim}]
--     são definidas na APROVAÇÃO (CMT escolhe a opção/etapa) e aí contam no
--     mesmo motor de % das anuais (15% Cia + limite da fração) — db/119.
--
--  Depende de: 101 (tabelas/helpers), 119 (motor %), 148/149 (solicitar).
--  Idempotente. Rodar no SQL Editor (depois do 189).
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) CRONOGRAMA: prazo da manifestação da prêmio ────────────────────
alter table public.ferias_cronograma
  add column if not exists premio_abertura date,
  add column if not exists premio_limite   date,
  add column if not exists premio_situacao  text not null default 'RASCUNHO'
    check (premio_situacao in ('RASCUNHO','ABERTO','ENCERRADO'));

-- ─── 2) PEDIDOS: campos da manifestação + anexos do requerimento ───────
alter table public.ferias_pedidos
  add column if not exists interesse boolean,                       -- null=não respondeu; true=com; false=sem
  add column if not exists premio    jsonb not null default '{}'::jsonb,  -- {lustro,etapas,exercicio,opcoes:[{ini}],justificativa}
  add column if not exists anexo_requerimento       jsonb not null default '[]'::jsonb,  -- fase 1 (assinado)
  add column if not exists anexo_requerimento_final jsonb not null default '[]'::jsonb;  -- fase 2 (re-assinado p/ itens 5-6)

-- amplia o check de situacao p/ aceitar 'SEM_INTERESSE' (remove QUALQUER check
-- antigo que mencione situacao, independente do nome auto-gerado)
do $$
declare r record;
begin
  for r in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace n on n.oid = rel.relnamespace
     where n.nspname = 'public' and rel.relname = 'ferias_pedidos'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%situacao%'
  loop
    execute format('alter table public.ferias_pedidos drop constraint %I', r.conname);
  end loop;
  alter table public.ferias_pedidos add constraint ferias_pedidos_situacao_check
    check (situacao in ('PENDENTE','APROVADO_PEL','VALIDADO','REJEITADO','SEM_INTERESSE'));
end$$;

-- ─── 3) PRAZO DA PRÊMIO: salvar (Aux P1 / Comando) ─────────────────────
-- Faz upsert da linha do ano (pode já existir p/ as anuais) só nos campos da prêmio.
create or replace function public.ferias_premio_prazo_salvar(p_token uuid, p_dados jsonb)
returns public.ferias_cronograma
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_ano  int := coalesce(nullif(p_dados->>'ano','')::int,
                         extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_row  public.ferias_cronograma;
  v_nome text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Apenas o Aux P1 / Comando define o prazo da férias-prêmio.';
  end if;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  insert into public.ferias_cronograma (ano, premio_abertura, premio_limite, premio_situacao,
                                        criado_por_matricula, criado_por_nome)
  values (v_ano,
          nullif(p_dados->>'premio_abertura','')::date,
          nullif(p_dados->>'premio_limite','')::date,
          coalesce(nullif(p_dados->>'premio_situacao',''),'RASCUNHO'),
          v_me.matricula, v_nome)
  on conflict (ano) do update set
    premio_abertura = case when p_dados ? 'premio_abertura' then nullif(p_dados->>'premio_abertura','')::date else ferias_cronograma.premio_abertura end,
    premio_limite   = case when p_dados ? 'premio_limite'   then nullif(p_dados->>'premio_limite','')::date  else ferias_cronograma.premio_limite end,
    premio_situacao = case when p_dados ? 'premio_situacao' then coalesce(nullif(p_dados->>'premio_situacao',''),'RASCUNHO') else ferias_cronograma.premio_situacao end
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function public.ferias_premio_prazo_salvar(uuid, jsonb) to anon;

-- ─── 4) MANIFESTAR: o militar cria/edita a PRÓPRIA manifestação ────────
-- Dentro do prazo ABERTO. interesse=true → PENDENTE (entra na aprovação);
-- interesse=false → SEM_INTERESSE. Reenvio/alteração livre enquanto aberto
-- (desde que ainda não APROVADO_PEL/VALIDADO).
create or replace function public.ferias_premio_manifestar(p_token uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_ano   int := coalesce(nullif(p_dados->>'ano','')::int,
                          extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_crono public.ferias_cronograma;
  v_hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  v_int   boolean := coalesce((p_dados->>'interesse')::boolean, false);
  v_premio jsonb;
  v_exerc int;
  v_sit   text;
  v_ex    record;
  v_row   public.ferias_pedidos;
  v_nome  text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_crono from public.ferias_cronograma where ano = v_ano;
  if v_crono.id is null or v_crono.premio_situacao <> 'ABERTO' then
    raise exception 'A manifestação de férias-prêmio não está aberta neste momento.';
  end if;
  if v_crono.premio_abertura is not null and v_hoje < v_crono.premio_abertura then
    raise exception 'A manifestação de férias-prêmio abre em %.', to_char(v_crono.premio_abertura,'DD/MM/YYYY');
  end if;
  if v_crono.premio_limite is not null and v_hoje > v_crono.premio_limite then
    raise exception 'O prazo da manifestação de férias-prêmio encerrou em %.', to_char(v_crono.premio_limite,'DD/MM/YYYY');
  end if;

  -- exercício (ano a que a prêmio se refere)
  v_exerc := nullif(p_dados->>'exercicio','')::int;

  if v_int then
    if jsonb_typeof(coalesce(p_dados->'opcoes','[]'::jsonb)) <> 'array'
       or jsonb_array_length(coalesce(p_dados->'opcoes','[]'::jsonb)) = 0 then
      raise exception 'Informe ao menos a 1ª opção de data de início.';
    end if;
  end if;

  v_premio := jsonb_build_object(
    'lustro',        nullif(p_dados->>'lustro',''),
    'etapas',        nullif(p_dados->>'etapas',''),
    'exercicio',     v_exerc,
    'opcoes',        coalesce(p_dados->'opcoes','[]'::jsonb),
    'justificativa', nullif(p_dados->>'justificativa','')
  );
  v_sit  := case when v_int then 'PENDENTE' else 'SEM_INTERESSE' end;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  select * into v_ex from public.ferias_pedidos
   where militar_id = v_me.id and ano = v_ano and tipo = 'PREMIO'
   order by created_at desc limit 1;

  if v_ex.id is not null and v_ex.situacao in ('APROVADO_PEL','VALIDADO') then
    raise exception 'Sua manifestação de férias-prêmio já está %. Para alterar, procure o Aux P1.',
      case v_ex.situacao when 'VALIDADO' then 'validada' else 'aprovada pelo pelotão' end;
  end if;

  if v_ex.id is not null then
    update public.ferias_pedidos set
      interesse   = v_int,
      premio      = v_premio,
      exercicio   = v_exerc,
      situacao    = v_sit, motivo_rejeicao = null
    where id = v_ex.id
    returning * into v_row;
  else
    insert into public.ferias_pedidos (
      cronograma_id, ano, militar_id, militar, pelotao, grupamento_id,
      tipo, exercicio, interesse, premio, parcelas, situacao,
      criado_por_matricula, criado_por_nome
    ) values (
      v_crono.id, v_ano, v_me.id,
      jsonb_build_object('matricula', v_me.matricula, 'nome', v_me.nome_completo,
                         'guerra', v_me.nome_guerra, 'pg', v_me.posto_graduacao),
      public._ferias_pelotao(v_me.grupamento_id), v_me.grupamento_id,
      'PREMIO', v_exerc, v_int, v_premio, '[]'::jsonb, v_sit,
      v_me.matricula, v_nome
    ) returning * into v_row;
  end if;

  return v_row;
end;
$$;
grant execute on function public.ferias_premio_manifestar(uuid, jsonb) to anon;

-- ─── 5) ANEXAR requerimento (dono do pedido OU Aux P1) ─────────────────
-- fase='req'   → anexo_requerimento (fase 1, assinado)
-- fase='final' → anexo_requerimento_final (fase 2, re-assinado p/ itens 5-6)
create or replace function public.ferias_premio_anexar(p_token uuid, p_id uuid, p_anexo jsonb, p_fase text)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_row public.ferias_pedidos;
  v_p1  boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_row from public.ferias_pedidos where id = p_id;
  if v_row.id is null then raise exception 'Pedido não encontrado.'; end if;
  v_p1 := public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao);
  if not v_p1 and v_row.militar_id is distinct from v_me.id then
    raise exception 'Você só pode anexar no seu próprio requerimento.';
  end if;

  if coalesce(p_fase,'req') = 'final' then
    update public.ferias_pedidos set anexo_requerimento_final = coalesce(p_anexo,'[]'::jsonb)
      where id = p_id returning * into v_row;
  else
    update public.ferias_pedidos set anexo_requerimento = coalesce(p_anexo,'[]'::jsonb)
      where id = p_id returning * into v_row;
  end if;
  return v_row;
end;
$$;
grant execute on function public.ferias_premio_anexar(uuid, uuid, jsonb, text) to anon;

-- ─── 6) MOVER entre Com/Sem interesse (Aux P1 / Comando, a qualquer tempo) ─
create or replace function public.ferias_premio_mover(p_token uuid, p_id uuid, p_interesse boolean)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_row public.ferias_pedidos;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Apenas o Aux P1 / Comando pode mover a manifestação.';
  end if;
  update public.ferias_pedidos set
    interesse = p_interesse,
    situacao  = case when p_interesse then (case when situacao = 'SEM_INTERESSE' then 'PENDENTE' else situacao end)
                     else 'SEM_INTERESSE' end
  where id = p_id and tipo = 'PREMIO'
  returning * into v_row;
  if v_row.id is null then raise exception 'Manifestação de férias-prêmio não encontrada.'; end if;
  return v_row;
end;
$$;
grant execute on function public.ferias_premio_mover(uuid, uuid, boolean) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 189).
-- Rollback manual (se preciso):
--   alter table ferias_pedidos drop column interesse, drop column premio,
--     drop column anexo_requerimento, drop column anexo_requerimento_final;
--   alter table ferias_cronograma drop column premio_abertura, drop column premio_limite,
--     drop column premio_situacao;
--   (e restaurar o check antigo de situacao sem 'SEM_INTERESSE')
-- ══════════════════════════════════════════════════════════════════════

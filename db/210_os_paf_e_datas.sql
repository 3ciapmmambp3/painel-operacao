-- ══════════════════════════════════════════════════════════════════════
--  db/210 — OS: passo condicional do PAF + período da operação (datas)
--  Data: 2026-11-22
--
--  (1) is_paf: quando a OS é de uma operação do PAF, o fluxo ganha o passo
--      "Cadastrada a Op no PAF" (etapa 'paf'), ANTES do Encaminhamento.
--  (2) data_operacao_inicio / _fim: período da operação. "Em execução" e
--      "Concluída" passam a ser derivadas pela DATA (automático no front),
--      não por clique. O Aux P3 conclui manualmente só até o Encaminhamento.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════════

alter table public.ordens_servico add column if not exists is_paf boolean not null default false;
alter table public.ordens_servico add column if not exists data_operacao_inicio date;
alter table public.ordens_servico add column if not exists data_operacao_fim    date;

-- Recria o CHECK de etapa incluindo 'paf' (remove qualquer check antigo da tabela).
do $$
declare r record;
begin
  for r in select conname from pg_constraint
           where conrelid = 'public.ordens_servico'::regclass and contype = 'c'
  loop execute 'alter table public.ordens_servico drop constraint '||quote_ident(r.conname); end loop;
end $$;
alter table public.ordens_servico add constraint ordens_servico_etapa_check
  check (etapa in ('elaboracao','aguardando_autorizacao','autorizada','sdv','paf','encaminhada','execucao','concluida','cancelada'));

-- os_salvar — agora grava is_paf e o período da operação.
create or replace function public.os_salvar(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.ordens_servico%rowtype; v_novo boolean; v_num integer; v_ano integer;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: controle do Aux P3 / Admin Geral.'; end if;

  v_novo := p_id is null;
  v_ano  := coalesce((p_dados->>'ano')::integer, extract(year from now())::integer);
  v_num  := nullif(btrim(p_dados->>'numero'),'')::integer;
  if v_novo and v_num is null then
    select coalesce(max(numero),0)+1 into v_num from public.ordens_servico where ano = v_ano;
  end if;

  if v_novo then
    insert into public.ordens_servico (numero, ano, operacao, descricao, com_diarias, is_paf, grupamento,
            data_operacao_inicio, data_operacao_fim,
            os_url, os_arquivo, planilha_url, planilha_arquivo, doc_origem_url, doc_origem_arquivo,
            criado_por, atualizado_por)
    values (v_num, v_ano, nullif(btrim(p_dados->>'operacao'),''), nullif(btrim(p_dados->>'descricao'),''),
            coalesce((p_dados->>'com_diarias')::boolean,false), coalesce((p_dados->>'is_paf')::boolean,false),
            nullif(btrim(p_dados->>'grupamento'),''),
            nullif(btrim(p_dados->>'data_operacao_inicio'),'')::date, nullif(btrim(p_dados->>'data_operacao_fim'),'')::date,
            nullif(btrim(p_dados->>'os_url'),''), nullif(btrim(p_dados->>'os_arquivo'),''),
            nullif(btrim(p_dados->>'planilha_url'),''), nullif(btrim(p_dados->>'planilha_arquivo'),''),
            nullif(btrim(p_dados->>'doc_origem_url'),''), nullif(btrim(p_dados->>'doc_origem_arquivo'),''),
            v_me.matricula, v_me.matricula)
    returning * into v_row;
    insert into public.os_tramitacao (os_id, etapa, data, responsavel, criado_por)
    values (v_row.id, coalesce(nullif(btrim(p_dados->>'etapa'),''),'elaboracao'), current_date, v_me.matricula, v_me.matricula);
  else
    update public.ordens_servico set
      operacao = coalesce(nullif(btrim(p_dados->>'operacao'),''), operacao),
      descricao = p_dados->>'descricao',
      com_diarias = coalesce((p_dados->>'com_diarias')::boolean, com_diarias),
      is_paf = coalesce((p_dados->>'is_paf')::boolean, is_paf),
      grupamento = p_dados->>'grupamento',
      data_operacao_inicio = nullif(btrim(p_dados->>'data_operacao_inicio'),'')::date,
      data_operacao_fim    = nullif(btrim(p_dados->>'data_operacao_fim'),'')::date,
      os_url = coalesce(p_dados->>'os_url', os_url),
      os_arquivo = coalesce(p_dados->>'os_arquivo', os_arquivo),
      planilha_url = coalesce(p_dados->>'planilha_url', planilha_url),
      planilha_arquivo = coalesce(p_dados->>'planilha_arquivo', planilha_arquivo),
      doc_origem_url = coalesce(p_dados->>'doc_origem_url', doc_origem_url),
      doc_origem_arquivo = coalesce(p_dados->>'doc_origem_arquivo', doc_origem_arquivo),
      atualizado_por = v_me.matricula, atualizado_em = now()
    where id = p_id returning * into v_row;
    if v_row.id is null then raise exception 'OS não encontrada.'; end if;
  end if;
  return to_jsonb(v_row);
end $$;

-- os_mudar_etapa — inclui 'paf' na lista de etapas válidas.
create or replace function public.os_mudar_etapa(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.ordens_servico%rowtype; v_etapa text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão.'; end if;
  v_etapa := p_dados->>'etapa';
  if v_etapa is null or v_etapa not in ('elaboracao','aguardando_autorizacao','autorizada','sdv','paf','encaminhada','execucao','concluida','cancelada') then
    raise exception 'Etapa inválida.'; end if;

  update public.ordens_servico set etapa = v_etapa, atualizado_por = v_me.matricula, atualizado_em = now()
  where id = p_id returning * into v_row;
  if v_row.id is null then raise exception 'OS não encontrada.'; end if;

  insert into public.os_tramitacao (os_id, etapa, data, responsavel, obs, criado_por)
  values (p_id, v_etapa, coalesce(nullif(btrim(p_dados->>'data'),'')::date, current_date),
          coalesce(nullif(btrim(p_dados->>'responsavel'),''), v_me.matricula),
          nullif(btrim(p_dados->>'obs'),''), v_me.matricula);
  return to_jsonb(v_row);
end $$;

grant execute on function public.os_salvar(uuid, uuid, jsonb)      to anon, authenticated;
grant execute on function public.os_mudar_etapa(uuid, uuid, jsonb) to anon, authenticated;

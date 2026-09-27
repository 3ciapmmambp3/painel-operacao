-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — o militar envia até 3 OPÇÕES de escolha (ranqueadas)
--  Se a 1ª não for aceita, o comandante pode usar a 2ª/3ª; e no fracionado
--  pode montar o resultado misturando (ex.: 15 dias da 1ª opção + 10 dias
--  da 3ª). O resultado final aprovado fica em `parcelas` (Fases 3/4).
--
--  `opcoes` jsonb: [{ "ordem":1, "modalidade":"25_DIRETO|15_10_FRACIONADO",
--                     "parcelas":[{parcela,ini,fim,periodo}] }, ...]
--
--  Exercício (ano de ref.) NÃO é escolhido pelo militar aqui — fica com o
--  ano do cronograma; só o Aux P1 altera/atribui outro exercício.
--  Depende de: 108. Idempotente. Rodar depois do 109.
-- ══════════════════════════════════════════════════════════════════════
alter table public.ferias_pedidos add column if not exists opcoes jsonb not null default '[]'::jsonb;

create or replace function public.ferias_pedido_solicitar(p_token uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_ano   int := coalesce(nullif(p_dados->>'ano','')::int,
                          extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_crono public.ferias_cronograma;
  v_hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ex    record;
  v_row   public.ferias_pedidos;
  v_nome  text;
  v_opcoes jsonb := coalesce(p_dados->'opcoes','[]'::jsonb);
  v_op1   jsonb;
  v_parc1 jsonb;
  v_mod1  text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_crono from public.ferias_cronograma where ano = v_ano;
  if v_crono.id is null or v_crono.situacao <> 'ABERTO' then
    raise exception 'As escolhas de férias não estão abertas neste momento.';
  end if;
  if v_crono.data_abertura is not null and v_hoje < v_crono.data_abertura then
    raise exception 'A escolha de férias abre em %.', to_char(v_crono.data_abertura,'DD/MM/YYYY');
  end if;
  if v_crono.data_limite is not null and v_hoje > v_crono.data_limite then
    raise exception 'O prazo para escolha de férias encerrou em %.', to_char(v_crono.data_limite,'DD/MM/YYYY');
  end if;

  if jsonb_typeof(v_opcoes) <> 'array' or jsonb_array_length(v_opcoes) = 0 then
    raise exception 'Informe ao menos a 1ª opção de férias.';
  end if;
  v_op1   := v_opcoes->0;
  v_parc1 := coalesce(v_op1->'parcelas','[]'::jsonb);
  v_mod1  := nullif(v_op1->>'modalidade','');
  if jsonb_array_length(v_parc1) = 0 then
    raise exception 'Escolha o período da 1ª opção.';
  end if;

  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  select * into v_ex from public.ferias_pedidos
   where militar_id = v_me.id and ano = v_ano and tipo = 'ANUAL'
   order by created_at desc limit 1;

  if v_ex.id is not null and v_ex.situacao in ('APROVADO_PEL','VALIDADO') then
    raise exception 'Sua escolha já está %s. Para alterar, procure o Aux P1.',
      case v_ex.situacao when 'VALIDADO' then 'validada' else 'aprovada pelo pelotão' end;
  end if;

  if v_ex.id is not null then
    update public.ferias_pedidos set
      modalidade  = v_mod1,
      opcoes      = v_opcoes,
      parcelas    = v_parc1,               -- 1ª opção como padrão (o aprovador ajusta)
      exercicio   = coalesce(v_ex.exercicio, v_ano),  -- exercício mantido (só P1 muda)
      observacoes = nullif(p_dados->>'observacoes',''),
      situacao    = 'PENDENTE', motivo_rejeicao = null,
      aprovado_pel_por_matricula = null, aprovado_pel_por_nome = null, aprovado_pel_em = null,
      validado_p1_por_matricula  = null, validado_p1_por_nome  = null, validado_p1_em  = null
    where id = v_ex.id
    returning * into v_row;
  else
    insert into public.ferias_pedidos (
      cronograma_id, ano, militar_id, militar, pelotao, grupamento_id,
      tipo, exercicio, modalidade, opcoes, parcelas, observacoes, situacao,
      criado_por_matricula, criado_por_nome
    ) values (
      v_crono.id, v_ano, v_me.id,
      jsonb_build_object('matricula', v_me.matricula, 'nome', v_me.nome_completo,
                         'guerra', v_me.nome_guerra, 'pg', v_me.posto_graduacao),
      public._ferias_pelotao(v_me.grupamento_id), v_me.grupamento_id,
      'ANUAL', v_ano, v_mod1, v_opcoes, v_parc1, nullif(p_dados->>'observacoes',''), 'PENDENTE',
      v_me.matricula, v_nome
    ) returning * into v_row;
  end if;

  return v_row;
end;
$$;

grant execute on function public.ferias_pedido_solicitar(uuid, jsonb) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do 109.
-- ══════════════════════════════════════════════════════════════════════

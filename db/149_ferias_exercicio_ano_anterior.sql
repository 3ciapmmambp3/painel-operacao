-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — EXERCÍCIO restrito ao ANO DE GOZO e ao ANO ANTERIOR
--
--  Regra de negócio (CPE): só se pode gozar férias do próprio ano ou do
--  ano imediatamente anterior. Logo o exercício (ano de referência) de
--  cada parcela só pode ser o ano de gozo ou o ano de gozo - 1.
--  Ex.: gozo em 2027 → exercício 2027 (normal) ou 2026 (atrasadas).
--
--  Ajusta o db/148: troca o piso de 2023 por (ano de gozo - 1).
--  Redefine public.ferias_pedido_solicitar. Depende de: 148. Idempotente.
-- ══════════════════════════════════════════════════════════════════════
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
  v_exerc int;
  v_min   int;
  v_opt   jsonb;
  v_par   jsonb;
  v_pe    int;
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

  v_min := v_ano - 1;  -- só o ano de gozo e o ano imediatamente anterior

  -- valida o EXERCÍCIO de cada parcela de cada opção (ano anterior..ano de gozo)
  for v_opt in select value from jsonb_array_elements(v_opcoes) loop
    for v_par in select value from jsonb_array_elements(coalesce(v_opt->'parcelas','[]'::jsonb)) loop
      v_pe := nullif(v_par->>'exercicio','')::int;
      if v_pe is not null and (v_pe < v_min or v_pe > v_ano) then
        raise exception 'Ano de referência (exercício) inválido numa parcela: só % ou %.', v_min, v_ano;
      end if;
    end loop;
  end loop;

  -- exercício de resumo do pedido = 1ª parcela da 1ª opção (fallback: p_dados.exercicio, depois ano de gozo)
  v_exerc := coalesce(
    nullif(v_parc1->0->>'exercicio','')::int,
    nullif(p_dados->>'exercicio','')::int,
    v_ano);
  if v_exerc < v_min or v_exerc > v_ano then
    raise exception 'Ano de referência inválido: só % ou %.', v_min, v_ano;
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
      exercicio   = v_exerc,               -- resumo = exercício da 1ª parcela da 1ª opção
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
      'ANUAL', v_exerc, v_mod1, v_opcoes, v_parc1, nullif(p_dados->>'observacoes',''), 'PENDENTE',
      v_me.matricula, v_nome
    ) returning * into v_row;
  end if;

  return v_row;
end;
$$;

grant execute on function public.ferias_pedido_solicitar(uuid, jsonb) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 148).
-- ══════════════════════════════════════════════════════════════════════

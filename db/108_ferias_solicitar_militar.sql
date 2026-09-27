-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — FASE 2: o próprio militar solicita/escolhe seu período
--  Regras:
--   • Só quando o cronograma do ano está ABERTO e dentro do prazo
--     (data_abertura .. data_limite).
--   • O militar cria/edita SÓ o próprio pedido (militar_id = ele).
--   • Enquanto PENDENTE ou REJEITADO ele pode reenviar; se já foi
--     APROVADO_PEL ou VALIDADO, não altera mais (procurar o Aux P1).
--   • Sempre nasce/volta para PENDENTE (limpa carimbos de aprovação).
--  Depende de: 101. Idempotente. Rodar depois do 107.
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

  if coalesce(jsonb_array_length(p_dados->'parcelas'),0) = 0 then
    raise exception 'Escolha o período das suas férias.';
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
      modalidade  = nullif(p_dados->>'modalidade',''),
      parcelas    = coalesce(p_dados->'parcelas','[]'::jsonb),
      exercicio   = coalesce(nullif(p_dados->>'exercicio','')::int, v_ano),
      destino     = nullif(p_dados->>'destino',''),
      observacoes = nullif(p_dados->>'observacoes',''),
      situacao    = 'PENDENTE', motivo_rejeicao = null,
      aprovado_pel_por_matricula = null, aprovado_pel_por_nome = null, aprovado_pel_em = null,
      validado_p1_por_matricula  = null, validado_p1_por_nome  = null, validado_p1_em  = null
    where id = v_ex.id
    returning * into v_row;
  else
    insert into public.ferias_pedidos (
      cronograma_id, ano, militar_id, militar, pelotao, grupamento_id,
      tipo, exercicio, modalidade, parcelas, destino, observacoes, situacao,
      criado_por_matricula, criado_por_nome
    ) values (
      v_crono.id, v_ano, v_me.id,
      jsonb_build_object('matricula', v_me.matricula, 'nome', v_me.nome_completo,
                         'guerra', v_me.nome_guerra, 'pg', v_me.posto_graduacao),
      public._ferias_pelotao(v_me.grupamento_id), v_me.grupamento_id,
      'ANUAL', coalesce(nullif(p_dados->>'exercicio','')::int, v_ano),
      nullif(p_dados->>'modalidade',''), coalesce(p_dados->'parcelas','[]'::jsonb),
      nullif(p_dados->>'destino',''), nullif(p_dados->>'observacoes',''), 'PENDENTE',
      v_me.matricula, v_nome
    ) returning * into v_row;
  end if;

  return v_row;
end;
$$;

-- CANCELAR a própria solicitação (enquanto ainda não aprovada/validada)
create or replace function public.ferias_pedido_cancelar(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.ferias_pedidos;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_row from public.ferias_pedidos where id = p_id;
  if v_row.id is null then raise exception 'Pedido não encontrado.'; end if;
  if v_row.militar_id <> v_me.id then raise exception 'Você só pode cancelar a sua própria solicitação.'; end if;
  if v_row.situacao in ('APROVADO_PEL','VALIDADO') then
    raise exception 'A solicitação já foi aprovada/validada. Procure o Aux P1.';
  end if;
  delete from public.ferias_pedidos where id = p_id;
end;
$$;

grant execute on function public.ferias_pedido_solicitar(uuid, jsonb) to anon;
grant execute on function public.ferias_pedido_cancelar(uuid, uuid)   to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do 107.
-- ══════════════════════════════════════════════════════════════════════

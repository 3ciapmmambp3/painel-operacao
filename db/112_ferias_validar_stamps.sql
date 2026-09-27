-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — validação/aprovação carimba quem fez + motivo de rejeição
--  Redefine ferias_pedido_salvar (usado pelo Aux P1) para, além dos campos
--  já existentes, gravar motivo_rejeicao e carimbar:
--    situacao = APROVADO_PEL → aprovado_pel_por_* / _em
--    situacao = VALIDADO     → validado_p1_por_*  / _em
--  Assim o Aux P1 pode montar o período final (parcelas) misturando as
--  opções do militar e validar.  Depende de: 101. Idempotente. Rodar depois do 111.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_pedido_salvar(p_token uuid, p_id uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.ferias_pedidos;
  v_mid  uuid := nullif(p_dados->>'militar_id','')::uuid;
  v_alvo public.militares;
  v_ano  int := coalesce(nullif(p_dados->>'ano','')::int,
                         extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_crono uuid;
  v_nome text;
  v_sit  text := nullif(p_dados->>'situacao','');
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Nesta fase, apenas o Aux P1 / Comando lança/edita/valida os pedidos.';
  end if;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);
  select id into v_crono from public.ferias_cronograma where ano = v_ano;

  if p_id is not null then
    update public.ferias_pedidos set
      tipo        = case when p_dados ? 'tipo'        then coalesce(nullif(p_dados->>'tipo',''),tipo) else tipo end,
      exercicio   = case when p_dados ? 'exercicio'   then nullif(p_dados->>'exercicio','')::int else exercicio end,
      modalidade  = case when p_dados ? 'modalidade'  then nullif(p_dados->>'modalidade','') else modalidade end,
      parcelas    = case when p_dados ? 'parcelas'    then coalesce(p_dados->'parcelas','[]'::jsonb) else parcelas end,
      destino     = case when p_dados ? 'destino'     then nullif(p_dados->>'destino','') else destino end,
      dias        = case when p_dados ? 'dias'        then nullif(p_dados->>'dias','')::int else dias end,
      observacoes = case when p_dados ? 'observacoes' then nullif(p_dados->>'observacoes','') else observacoes end,
      situacao    = case when v_sit is not null then v_sit else situacao end,
      motivo_rejeicao = case when v_sit = 'REJEITADO' then nullif(p_dados->>'motivo_rejeicao','')
                             when v_sit is not null then null else motivo_rejeicao end,
      aprovado_pel_por_matricula = case when v_sit='APROVADO_PEL' then v_me.matricula else aprovado_pel_por_matricula end,
      aprovado_pel_por_nome      = case when v_sit='APROVADO_PEL' then v_nome        else aprovado_pel_por_nome end,
      aprovado_pel_em            = case when v_sit='APROVADO_PEL' then now()          else aprovado_pel_em end,
      validado_p1_por_matricula  = case when v_sit='VALIDADO' then v_me.matricula else validado_p1_por_matricula end,
      validado_p1_por_nome       = case when v_sit='VALIDADO' then v_nome        else validado_p1_por_nome end,
      validado_p1_em             = case when v_sit='VALIDADO' then now()          else validado_p1_em end
    where id = p_id
    returning * into v_row;
    if v_row.id is null then raise exception 'Pedido não encontrado.'; end if;
    return v_row;
  end if;

  -- CRIAÇÃO (lançamento direto do Aux P1)
  if v_mid is null then raise exception 'Informe o militar.'; end if;
  select * into v_alvo from public.militares where id = v_mid;
  if v_alvo.id is null then raise exception 'Militar não encontrado.'; end if;

  insert into public.ferias_pedidos (
    cronograma_id, ano, militar_id, militar, pelotao, grupamento_id,
    tipo, exercicio, modalidade, parcelas, destino, dias, observacoes,
    situacao, criado_por_matricula, criado_por_nome
  ) values (
    v_crono, v_ano, v_alvo.id,
    jsonb_build_object('matricula', v_alvo.matricula, 'nome', v_alvo.nome_completo,
                       'guerra', v_alvo.nome_guerra, 'pg', v_alvo.posto_graduacao),
    public._ferias_pelotao(v_alvo.grupamento_id), v_alvo.grupamento_id,
    coalesce(nullif(p_dados->>'tipo',''),'ANUAL'),
    nullif(p_dados->>'exercicio','')::int, nullif(p_dados->>'modalidade',''),
    coalesce(p_dados->'parcelas','[]'::jsonb), nullif(p_dados->>'destino',''),
    nullif(p_dados->>'dias','')::int, nullif(p_dados->>'observacoes',''),
    coalesce(v_sit,'VALIDADO'), v_me.matricula, v_nome
  ) returning * into v_row;

  if v_row.situacao = 'VALIDADO' then
    update public.ferias_pedidos
      set validado_p1_por_matricula = v_me.matricula, validado_p1_por_nome = v_nome, validado_p1_em = now()
    where id = v_row.id returning * into v_row;
  end if;

  return v_row;
end;
$$;
grant execute on function public.ferias_pedido_salvar(uuid, uuid, jsonb) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do 111.
-- ══════════════════════════════════════════════════════════════════════

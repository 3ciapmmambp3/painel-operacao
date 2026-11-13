-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS-PRÊMIO — gestão do Aux P1 (editar / validar) numa só RPC
--
--  O Aux P1 / Comando edita a manifestação (interesse, lustro, etapas,
--  exercício, opções, justificativa), define a SITUAÇÃO e, ao APROVAR/VALIDAR,
--  grava a parcela efetiva [{parcela:'PREMIO', ini, fim}] — que então conta no
--  mesmo motor de % das anuais (db/119). Excluir reusa ferias_pedido_excluir.
--
--  Depende de: 101 (tabela/_ferias_pode_p1), 190 (colunas premio/interesse).
--  Idempotente. Rodar no SQL Editor (depois do 190).
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_premio_gerir(p_token uuid, p_id uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.ferias_pedidos;
  v_sit  text := nullif(p_dados->>'situacao','');
  v_nome text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Apenas o Aux P1 / Comando pode editar/validar a manifestação.';
  end if;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  update public.ferias_pedidos set
    interesse  = case when p_dados ? 'interesse' then (p_dados->>'interesse')::boolean else interesse end,
    premio     = case when p_dados ? 'premio'    then coalesce(p_dados->'premio','{}'::jsonb) else premio end,
    exercicio  = case when p_dados ? 'exercicio' then nullif(p_dados->>'exercicio','')::int else exercicio end,
    parcelas   = case when p_dados ? 'parcelas'  then coalesce(p_dados->'parcelas','[]'::jsonb) else parcelas end,
    situacao   = case when v_sit is not null then v_sit else situacao end,
    motivo_rejeicao = case when p_dados ? 'motivo_rejeicao' then nullif(p_dados->>'motivo_rejeicao','') else motivo_rejeicao end,
    aprovado_pel_por_matricula = case when v_sit = 'APROVADO_PEL' then v_me.matricula else aprovado_pel_por_matricula end,
    aprovado_pel_por_nome      = case when v_sit = 'APROVADO_PEL' then v_nome        else aprovado_pel_por_nome end,
    aprovado_pel_em            = case when v_sit = 'APROVADO_PEL' then now()         else aprovado_pel_em end,
    validado_p1_por_matricula  = case when v_sit = 'VALIDADO' then v_me.matricula else validado_p1_por_matricula end,
    validado_p1_por_nome       = case when v_sit = 'VALIDADO' then v_nome        else validado_p1_por_nome end,
    validado_p1_em             = case when v_sit = 'VALIDADO' then now()         else validado_p1_em end
  where id = p_id and tipo = 'PREMIO'
  returning * into v_row;

  if v_row.id is null then raise exception 'Manifestação de férias-prêmio não encontrada.'; end if;
  return v_row;
end;
$$;
grant execute on function public.ferias_premio_gerir(uuid, uuid, jsonb) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 190).
-- ══════════════════════════════════════════════════════════════════════

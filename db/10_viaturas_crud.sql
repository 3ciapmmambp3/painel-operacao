-- ════════════════════════════════════════════════════════════════════════
-- 10_viaturas_crud.sql — Gestão da FROTA (incluir / editar / remover viatura)
-- Restrito ao Aux P4 e Admin Geral (_pode_gerenciar_viaturas).
-- Depende de: 08_mov_viaturas.sql (tabela viaturas + _pode_gerenciar_viaturas).
-- Idempotente.
-- ════════════════════════════════════════════════════════════════════════

-- Incluir OU editar viatura (upsert por prefixo). Não toca situacao_operacional
-- (baixa/manutenção) — isso continua sendo pelo baixar/retornar.
create or replace function public.viatura_salvar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.viaturas%rowtype; v_prefixo text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: gestão da frota é do setor responsável (Aux P4).';
  end if;
  v_prefixo := nullif(trim(p_dados->>'prefixo'),'');
  if v_prefixo is null then raise exception 'Informe o prefixo da viatura.'; end if;

  insert into public.viaturas
    (prefixo, placa, marca_modelo, ano, tracao, tipo_bem, pel, gp, municipio,
     situacao_viatura, observacao, ativo, atualizado_em)
  values (
    v_prefixo, nullif(p_dados->>'placa',''), nullif(p_dados->>'marca_modelo',''),
    (p_dados->>'ano')::int, nullif(p_dados->>'tracao',''), nullif(p_dados->>'tipo_bem',''),
    nullif(p_dados->>'pel',''), nullif(p_dados->>'gp',''), nullif(p_dados->>'municipio',''),
    nullif(p_dados->>'situacao_viatura',''), nullif(p_dados->>'observacao',''), true, now())
  on conflict (prefixo) do update set
    placa=excluded.placa, marca_modelo=excluded.marca_modelo, ano=excluded.ano,
    tracao=excluded.tracao, tipo_bem=excluded.tipo_bem, pel=excluded.pel, gp=excluded.gp,
    municipio=excluded.municipio, situacao_viatura=excluded.situacao_viatura,
    observacao=excluded.observacao, ativo=true, atualizado_em=now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

-- Remover viatura: por padrão INATIVA (ativo=false) — some do painel mas o
-- histórico de movimentação (por prefixo) é preservado. p_hard=true apaga de vez.
create or replace function public.viatura_remover(p_token uuid, p_prefixo text, p_hard boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: gestão da frota é do setor responsável (Aux P4).';
  end if;
  if coalesce(p_hard,false) then
    delete from public.viaturas where prefixo = p_prefixo;
    return jsonb_build_object('ok', true, 'hard', true);
  else
    update public.viaturas set ativo=false, atualizado_em=now() where prefixo = p_prefixo;
    return jsonb_build_object('ok', true, 'hard', false);
  end if;
end;
$$;

grant execute on function public.viatura_salvar(uuid, jsonb) to anon;
grant execute on function public.viatura_remover(uuid, text, boolean) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rode no SQL Editor depois do 08.
-- ════════════════════════════════════════════════════════════════════════

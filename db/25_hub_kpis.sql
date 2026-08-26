-- ════════════════════════════════════════════════════════════════════════
-- 25_hub_kpis.sql — Contagens reais dos hubs (Meu Dia + P1/P3/P4)
--
-- Um RPC único que devolve, em um só jsonb, todas as contagens que os hubs
-- e o "Meu Dia" exibem — evita várias requisições. Aggregados não-sensíveis;
-- as pendências pessoais (ficha/TTA) saem do próprio token.
--
-- Depende de: 04 (militares/_sessao_militar), 07 (tta_chamadas), 08 (mov_*),
--             01 (denuncias), 18 (relatorios), viaturas.
-- Idempotente. Rodar no SQL Editor depois dos demais.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.hub_kpis(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me         record;
  v_hoje       date := (now() at time zone 'America/Sao_Paulo')::date;
  v_mat        text;
  v_efetivo    int;
  v_equipes    int;
  v_rel_hoje   int;
  v_demandas   int;
  v_vtr_total  int;
  v_vtr_baixa  int;
  v_fichas     int;
  v_minhas_pend int;
  v_tta_hoje   boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessao expirada. Faca login novamente.';
  end if;
  v_mat := regexp_replace(coalesce(v_me.matricula,''), '\D', '', 'g');

  -- P1: efetivo ativo (exclui contas de teste 0000001..4)
  select count(*) into v_efetivo
    from public.militares
   where ativo = true
     and matricula_clean not in ('0000001','0000002','0000003','0000004');

  -- P3: equipes em serviço hoje (soma das equipes das chamadas do TTA de hoje)
  select coalesce(sum(coalesce(jsonb_array_length(equipes),0)),0) into v_equipes
    from public.tta_chamadas
   where (data_hora_chamada at time zone 'America/Sao_Paulo')::date = v_hoje;

  -- P3: relatórios de serviço com data de hoje
  select count(*) into v_rel_hoje
    from public.relatorios
   where data = v_hoje;

  -- P3: demandas (denúncias/requisições) em aberto
  select count(*) into v_demandas
    from public.denuncias
   where situacao in ('PENDENTE','EM ANDAMENTO');

  -- P4: frota total e viaturas baixadas
  select count(*) into v_vtr_total from public.viaturas;
  select count(*) into v_vtr_baixa from public.viaturas
   where coalesce(situacao_operacional,'DISPONIVEL') = 'BAIXADA';

  -- P4: fichas de movimentação lançadas hoje
  select count(*) into v_fichas
    from public.mov_viaturas
   where (criado_em at time zone 'America/Sao_Paulo')::date = v_hoje;

  -- Meu Dia: minhas fichas de viatura pendentes
  select count(*) into v_minhas_pend
    from public.mov_pendencias
   where atendida = false
     and regexp_replace(coalesce(motorista_matricula,''),'\D','','g') = v_mat;

  -- Meu Dia: lancei o TTA de hoje? (sou responsável de alguma chamada de hoje)
  select exists(
     select 1 from public.tta_chamadas
      where (data_hora_chamada at time zone 'America/Sao_Paulo')::date = v_hoje
        and regexp_replace(coalesce(militar_resp_matricula,''),'\D','','g') = v_mat
  ) into v_tta_hoje;

  return jsonb_build_object(
    'efetivo',                 v_efetivo,
    'equipes_hoje',            v_equipes,
    'relatorios_hoje',         v_rel_hoje,
    'demandas_abertas',        v_demandas,
    'viaturas_total',          v_vtr_total,
    'viaturas_baixadas',       v_vtr_baixa,
    'fichas_hoje',             v_fichas,
    'minhas_pendencias_ficha', v_minhas_pend,
    'tta_hoje_lancado',        v_tta_hoje
  );
end;
$$;

grant execute on function public.hub_kpis(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois dos demais (usa militares, tta_chamadas, mov_*, denuncias,
-- relatorios, viaturas).
-- ════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- 78_hub_kpis_tta_participante.sql — "não lançou o TTA de hoje" indevido
--
-- BUG: no Meu Dia, o aviso "Você ainda não lançou o TTA de hoje" aparecia
-- mesmo para quem JÁ tinha sido lançado no TTA por outra pessoa. Ao tentar
-- lançar, batia na anti-duplicidade ("militar já lançado em outro TTA de hoje").
--
-- CAUSA: hub_kpis (db/25) calculava tta_hoje_lancado só quando o militar era o
-- RESPONSÁVEL da chamada (militar_resp_matricula), ignorando quando ele consta
-- em tta_chamadas.militares_presentes (foi lançado por outro).
--
-- FIX: tta_hoje_lancado = responsável OU presente na equipe — mesmo critério
-- de _tta_conflitos (db/42) e tta_listar_meus. Só recria hub_kpis (retorno
-- jsonb inalterado). Idempotente. Rodar depois do 25.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.hub_kpis(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me         record;
  v_hoje       date := (now() at time zone 'America/Sao_Paulo')::date;
  v_mat        text;
  v_ve_tudo    boolean;
  v_nivel_pel  boolean;
  v_meu_gp     int;
  v_meu_pel    int;
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

  -- ── Escopo do usuário ────────────────────────────────────────────────
  v_ve_tudo := v_me.nivel_acesso in ('admin','admin_geral')
            or coalesce(v_me.grupamento_id,'') ~* '^\s*ADM'
            or (coalesce(v_me.funcao,'') ~* '(CMT|COMANDANTE)' and coalesce(v_me.funcao,'') ~* 'CIA');
  v_nivel_pel := (not v_ve_tudo) and (
                 v_me.nivel_acesso = 'admin_pelotao'
              or (coalesce(v_me.funcao,'') ~* '(CMT|COMANDANTE)' and coalesce(v_me.funcao,'') ~* 'PEL'));
  v_meu_gp  := (regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\s*GP',  'i'))[1]::int;
  v_meu_pel := (regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1]::int;

  -- P1: efetivo ativo do escopo (exclui contas de teste 0000001..4)
  select count(*) into v_efetivo
    from public.militares m
   where m.ativo = true
     and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and public._kpi_inclui(v_ve_tudo, v_nivel_pel, v_meu_gp, v_meu_pel,
           (regexp_match(coalesce(m.grupamento_id,''), '(\d+)\s*GP',  'i'))[1]::int,
           (regexp_match(coalesce(m.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1]::int);

  -- P3: equipes em serviço hoje (soma das equipes das chamadas de hoje) no escopo
  select coalesce(sum(coalesce(jsonb_array_length(equipes),0)),0) into v_equipes
    from public.tta_chamadas c
   where (c.data_hora_chamada at time zone 'America/Sao_Paulo')::date = v_hoje
     and public._kpi_inclui(v_ve_tudo, v_nivel_pel, v_meu_gp, v_meu_pel,
           (regexp_match(coalesce(c.grupamento_completo,''), '(\d+)\s*GP',  'i'))[1]::int,
           (regexp_match(coalesce(c.grupamento_completo,''), '(\d+)\s*PEL', 'i'))[1]::int);

  -- P3: relatórios de serviço de hoje no escopo (fracao_atuacao = grupamento)
  select count(*) into v_rel_hoje
    from public.relatorios r
   where r.data = v_hoje
     and public._kpi_inclui(v_ve_tudo, v_nivel_pel, v_meu_gp, v_meu_pel,
           (regexp_match(coalesce(r.fracao_atuacao,''), '(\d+)\s*GP',  'i'))[1]::int,
           (regexp_match(coalesce(r.fracao_atuacao,''), '(\d+)\s*PEL', 'i'))[1]::int);

  -- P3: demandas em aberto (só ATIVAS) no escopo
  select count(*) into v_demandas
    from public.denuncias d
   where d.situacao in ('PENDENTE','EM ANDAMENTO')
     and coalesce(d.ativo, true) = true
     and public._kpi_inclui(v_ve_tudo, v_nivel_pel, v_meu_gp, v_meu_pel,
           (regexp_match(coalesce(d.grupamento_completo,''), '(\d+)\s*GP',  'i'))[1]::int,
           (regexp_match(coalesce(d.grupamento_completo,''), '(\d+)\s*PEL', 'i'))[1]::int);

  -- P4: frota total e baixadas no escopo (viaturas.pel/gp = "Nº Pel/Nº Gp")
  select count(*) into v_vtr_total
    from public.viaturas v
   where public._kpi_inclui(v_ve_tudo, v_nivel_pel, v_meu_gp, v_meu_pel,
           (regexp_match(coalesce(v.gp,''),  '(\d+)'))[1]::int,
           (regexp_match(coalesce(v.pel,''), '(\d+)'))[1]::int);
  select count(*) into v_vtr_baixa
    from public.viaturas v
   where coalesce(v.situacao_operacional,'DISPONIVEL') = 'BAIXADA'
     and public._kpi_inclui(v_ve_tudo, v_nivel_pel, v_meu_gp, v_meu_pel,
           (regexp_match(coalesce(v.gp,''),  '(\d+)'))[1]::int,
           (regexp_match(coalesce(v.pel,''), '(\d+)'))[1]::int);

  -- P4: fichas de movimentação lançadas hoje no escopo (só ativas)
  select count(*) into v_fichas
    from public.mov_viaturas mv
   where (mv.criado_em at time zone 'America/Sao_Paulo')::date = v_hoje
     and coalesce(mv.ativo, true) = true
     and public._kpi_inclui(v_ve_tudo, v_nivel_pel, v_meu_gp, v_meu_pel,
           (regexp_match(coalesce(mv.grupamento_completo,''), '(\d+)\s*GP',  'i'))[1]::int,
           (regexp_match(coalesce(mv.grupamento_completo,''), '(\d+)\s*PEL', 'i'))[1]::int);

  -- Meu Dia: minhas fichas de viatura pendentes (PESSOAL — por matrícula)
  select count(*) into v_minhas_pend
    from public.mov_pendencias
   where atendida = false
     and regexp_replace(coalesce(motorista_matricula,''),'\D','','g') = v_mat;

  -- Meu Dia: lancei OU fui lançado no TTA de hoje? (responsável OU presente na
  -- equipe — mesmo critério da anti-duplicidade). Antes só olhava o responsável,
  -- então quem era lançado por outro via o aviso indevido e batia na duplicidade.
  select exists(
     select 1 from public.tta_chamadas c
      where (c.data_hora_chamada at time zone 'America/Sao_Paulo')::date = v_hoje
        and (
              regexp_replace(coalesce(c.militar_resp_matricula,''),'\D','','g') = v_mat
           or exists (
                select 1 from jsonb_array_elements(coalesce(c.militares_presentes,'[]'::jsonb)) e
                 where regexp_replace(coalesce(e->>'matricula',''),'\D','','g') = v_mat
              )
        )
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
    'tta_hoje_lancado',        v_tta_hoje,
    'escopo',                  case when v_ve_tudo then 'todos'
                                    when v_nivel_pel then 'pelotao'
                                    else 'grupamento' end
  );
end;
$$;

grant execute on function public.hub_kpis(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 25 (mesma fonte de dados).
-- ════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- 37_mov_pendencia_dia.sql — Baixa da ficha pendente pela DATA DA MOVIMENTAÇÃO.
--
-- Bug: a pendência de ficha (criada pelo TTA p/ o motorista de cada dia, e pelo
-- Relatório) era baixada em mov_viatura_criar casando por `dia = current_date`
-- (dia do SALVAMENTO, em UTC). Se o motorista preenche a ficha em dia diferente
-- do serviço (backfill) — ou por diferença de fuso — a baixa não casava e a
-- ficha JÁ FINALIZADA continuava aparecendo como pendente.
--
-- Correção:
--   • A baixa passa a casar pela data da MOVIMENTAÇÃO (inicio) E pelo dia do
--     salvamento, ambos em horário de Brasília.
--   • mov_pendencia_criar passa a usar a data de Brasília (consistência do `dia`).
--   • Limpeza retroativa: marca como atendida toda pendência que já tem ficha
--     na mesma viatura/dia.
--
-- Depende de: 08_mov_viaturas.sql. Idempotente. Rodar no SQL Editor depois do 08.
-- ════════════════════════════════════════════════════════════════════════

-- ── Criação da pendência (datas em horário de Brasília) ──────────────────
create or replace function public.mov_pendencia_criar(
  p_token uuid, p_prefixo text, p_mot_mat text, p_mot_nome text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.mov_pendencias%rowtype;
  v_dia  date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(p_prefixo,'') = '' then return jsonb_build_object('ok',false); end if;
  -- já existe ficha hoje (Brasília) p/ a viatura? não precisa de pendência
  if exists (select 1 from public.mov_viaturas
             where prefixo=p_prefixo and ativo=true
               and (coalesce(inicio, criado_em) at time zone 'America/Sao_Paulo')::date = v_dia) then
    return jsonb_build_object('ok',true,'ja_tem_ficha',true);
  end if;
  -- já há pendência aberta nesse dia? devolve a existente
  select * into v_row from public.mov_pendencias
   where prefixo=p_prefixo and dia=v_dia and atendida=false limit 1;
  if v_row.id is not null then return to_jsonb(v_row); end if;
  insert into public.mov_pendencias
    (prefixo, dia, motorista_matricula, motorista_nome, solicitado_por_matricula, solicitado_por_nome)
  values (p_prefixo, v_dia,
    nullif(regexp_replace(coalesce(p_mot_mat,''),'\D','','g'),''),
    nullif(p_mot_nome,''), v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo))
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- ── Gravar a ficha (idêntica ao 08, só a BAIXA da pendência mudou) ───────
create or replace function public.mov_viatura_criar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.mov_viaturas%rowtype;
  v_ini  timestamptz;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão inválida ou expirada.';
  end if;

  if exists (select 1 from public.viaturas
             where prefixo = nullif(p_dados->>'prefixo','')
               and coalesce(situacao_operacional,'DISPONIVEL') <> 'DISPONIVEL') then
    raise exception 'Viatura indisponível (baixada/em manutenção). Fale com o setor responsável (Aux P4).';
  end if;

  v_ini := coalesce((p_dados->>'inicio')::timestamptz, now());

  insert into public.mov_viaturas (
    prefixo, placa, motorista_matricula, motorista_nome, lotacao_motorista,
    local_utilizacao, tipo_empenho, km_inicial, km_final, inicio, termino,
    comb_armar, comb_devolver,
    tem_abastecimento, tem_acidente, tem_manutencao, tem_avaria, tem_limpeza, tem_taq, tem_aeronave,
    dados, anexos, observacoes,
    gp_responsavel, grupamento_completo, ano, mes,
    criado_por_matricula, criado_por_nome
  ) values (
    nullif(p_dados->>'prefixo',''), nullif(p_dados->>'placa',''),
    nullif(p_dados->>'motorista_matricula',''), nullif(p_dados->>'motorista_nome',''),
    nullif(p_dados->>'lotacao_motorista',''), nullif(p_dados->>'local_utilizacao',''),
    nullif(p_dados->>'tipo_empenho',''),
    (p_dados->>'km_inicial')::int, (p_dados->>'km_final')::int,
    v_ini, (p_dados->>'termino')::timestamptz,
    nullif(p_dados->>'comb_armar',''), nullif(p_dados->>'comb_devolver',''),
    coalesce((p_dados->>'tem_abastecimento')::boolean,false),
    coalesce((p_dados->>'tem_acidente')::boolean,false),
    coalesce((p_dados->>'tem_manutencao')::boolean,false),
    coalesce((p_dados->>'tem_avaria')::boolean,false),
    coalesce((p_dados->>'tem_limpeza')::boolean,false),
    coalesce((p_dados->>'tem_taq')::boolean,false),
    coalesce((p_dados->>'tem_aeronave')::boolean,false),
    coalesce(p_dados->'dados','{}'::jsonb), coalesce(p_dados->'anexos','[]'::jsonb),
    nullif(p_dados->>'observacoes',''),
    nullif(p_dados->>'gp_responsavel',''), nullif(p_dados->>'grupamento_completo',''),
    extract(year from v_ini)::int, extract(month from v_ini)::int,
    v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo)
  ) returning * into v_row;

  -- fecha pendências abertas desta viatura pela DATA DA MOVIMENTAÇÃO (inicio) e
  -- também pelo dia do salvamento, ambos em horário de Brasília — cobre ficha
  -- lançada em dia diferente do serviço (backfill) e o caso normal (mesmo dia).
  update public.mov_pendencias
     set atendida = true, mov_id = v_row.id
   where prefixo = v_row.prefixo
     and atendida = false
     and dia in (
       (coalesce(v_ini, now()) at time zone 'America/Sao_Paulo')::date,
       (now()                  at time zone 'America/Sao_Paulo')::date
     );

  return to_jsonb(v_row);
end;
$$;

-- ── Limpeza retroativa: pendência com ficha já existente na viatura/dia ──
update public.mov_pendencias p
   set atendida = true
 where p.atendida = false
   and exists (
     select 1 from public.mov_viaturas m
      where m.prefixo = p.prefixo and m.ativo = true
        and (coalesce(m.inicio, m.criado_em) at time zone 'America/Sao_Paulo')::date = p.dia
   );

grant execute on function public.mov_pendencia_criar(uuid, text, text, text) to anon;
grant execute on function public.mov_viatura_criar(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 08.
-- ════════════════════════════════════════════════════════════════════════

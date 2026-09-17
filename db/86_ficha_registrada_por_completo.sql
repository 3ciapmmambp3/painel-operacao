-- ════════════════════════════════════════════════════════════════════════
-- 86_ficha_registrada_por_completo.sql — "Registrada por" com posto + nome
-- completo (não só o nome de guerra).
--
-- No PDF/Ver da Ficha de Movimentação, "Registrada por" mostrava só o nome de
-- guerra (mov_viaturas.criado_por_nome = nome_guerra). Passa a gravar
-- "posto_graduacao + nome_completo"; o Nº PM já está em criado_por_matricula
-- (o front mostra os dois, mascarando o Nº PM). Vale para fichas NOVAS; as
-- antigas continuam com o nome de guerra gravado.
--
-- Recria mov_viatura_criar mantendo o anti-duplicidade e a baixa da pendência
-- (db/84). Idempotente. Rodar depois do 84.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.mov_viatura_criar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_row   public.mov_viaturas%rowtype;
  v_ini   timestamptz;
  v_pref  text := nullif(p_dados->>'prefixo','');
  v_mot   text := regexp_replace(coalesce(p_dados->>'motorista_matricula',''),'\D','','g');
  v_dono  text;
  v_nome  text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;

  -- nome de quem registra: posto/graduação + nome completo (Nº PM vai à parte)
  v_nome := nullif(btrim(concat_ws(' ', v_me.posto_graduacao, coalesce(v_me.nome_completo, v_me.nome_guerra))), '');

  -- bloqueia movimentação de viatura baixada / em manutenção
  if exists (select 1 from public.viaturas
             where prefixo = v_pref
               and coalesce(situacao_operacional,'DISPONIVEL') <> 'DISPONIVEL') then
    raise exception 'Viatura indisponível (baixada/em manutenção). Fale com o setor responsável (Aux P4).';
  end if;

  v_ini := coalesce((p_dados->>'inicio')::timestamptz, now());

  -- anti-duplicidade: já existe ficha ATIVA hoje da MESMA viatura com o MESMO
  -- motorista? (= a equipe já foi lançada). Motorista diferente é permitido.
  if v_mot <> '' then
    select coalesce(m.criado_por_nome, m.motorista_nome) into v_dono
      from public.mov_viaturas m
     where m.ativo = true
       and m.prefixo = v_pref
       and regexp_replace(coalesce(m.motorista_matricula,''),'\D','','g') = v_mot
       and (coalesce(m.inicio, m.criado_em) at time zone 'America/Sao_Paulo')::date
           = (v_ini at time zone 'America/Sao_Paulo')::date
     limit 1;
    if v_dono is not null then
      raise exception 'Já existe Ficha de Movimentação de hoje para esta viatura com este motorista (a equipe já foi lançada por %). Para corrigir, edite a ficha existente.', v_dono;
    end if;
  end if;

  insert into public.mov_viaturas (
    prefixo, placa, motorista_matricula, motorista_nome, lotacao_motorista,
    local_utilizacao, tipo_empenho, km_inicial, km_final, inicio, termino,
    comb_armar, comb_devolver,
    tem_abastecimento, tem_acidente, tem_manutencao, tem_avaria, tem_limpeza, tem_taq, tem_aeronave,
    dados, anexos, observacoes,
    gp_responsavel, grupamento_completo, ano, mes,
    criado_por_matricula, criado_por_nome
  ) values (
    v_pref, nullif(p_dados->>'placa',''),
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
    v_me.matricula, v_nome
  ) returning * into v_row;

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

grant execute on function public.mov_viatura_criar(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 84.
-- ════════════════════════════════════════════════════════════════════════

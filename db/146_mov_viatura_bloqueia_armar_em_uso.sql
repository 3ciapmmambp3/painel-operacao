-- ════════════════════════════════════════════════════════════════════════
-- 146_mov_viatura_bloqueia_armar_em_uso.sql
--
-- BUG: dois militares distintos conseguiam ARMAR a mesma viatura ao mesmo
-- tempo — o 1º ainda não tinha lançado o "Término (devolver)" (ficha aberta),
-- e o 2º conseguia abrir outra ficha da MESMA viatura. A trava de db/84/86 só
-- pegava MESMA viatura + MESMO motorista + MESMO dia; motorista diferente
-- passava direto. O fluxo público (QR) não tinha trava alguma.
--
-- FIX: antes de gravar, bloqueia quando o PERÍODO da nova ficha SOBREPÕE o de
-- uma ficha ativa da mesma viatura (uma viatura não pode estar em dois serviços
-- ao mesmo tempo). Uma ficha SEM término (aberta) é tratada como "em uso" por
-- até 48h a partir do início — isso evita travar a viatura para sempre por
-- causa de uma ficha antiga que ninguém fechou. A trava anterior (mesma equipe
-- no dia) é mantida e vem primeiro, com
-- a mensagem específica "edite a ficha existente".
--
-- Recria mov_viatura_criar (base = db/86) e mov_viatura_criar_publico (base =
-- db/14), mantendo todo o resto. Idempotente. Rodar depois do 86 e do 14.
-- ════════════════════════════════════════════════════════════════════════

-- ── Ficha com sessão (painel) ────────────────────────────────────────────
create or replace function public.mov_viatura_criar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_row   public.mov_viaturas%rowtype;
  v_ini   timestamptz;
  v_ter   timestamptz;
  v_conf  record;
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
  v_ter := (p_dados->>'termino')::timestamptz;

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

  -- trava de uso simultâneo: o período da nova ficha sobrepõe o de uma ficha
  -- ativa da MESMA viatura (inclusive uma ainda ABERTA, sem término). Ficha
  -- aberta vale como "em uso" por até 48h a partir do início.
  select coalesce(m.inicio, m.criado_em)                                   as ini,
         m.termino                                                         as ter,
         coalesce(nullif(m.motorista_nome,''), m.criado_por_nome, 'outro militar') as quem
    into v_conf
    from public.mov_viaturas m
   where m.ativo = true
     and m.prefixo = v_pref
     and v_ini < coalesce(m.termino, coalesce(m.inicio, m.criado_em) + interval '48 hours')
     and coalesce(m.inicio, m.criado_em) < coalesce(v_ter, v_ini + interval '48 hours')
   order by coalesce(m.inicio, m.criado_em) desc
   limit 1;
  if found then
    raise exception '%', format(
      'A viatura %s já está em uso (armada) por %s desde %s%s. Faça o "Término (devolver)" daquela ficha antes de armar de novo — ou, se a viatura já voltou, edite a ficha dela e lance o término.',
      v_pref, v_conf.quem,
      to_char(v_conf.ini at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),
      case when v_conf.ter is null then ' (ainda sem Término lançado)' else '' end);
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
    v_ini, v_ter,
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

-- ── Ficha pública (QR, condutor externo sem sessão) ──────────────────────
create or replace function public.mov_viatura_criar_publico(
  p_prefixo text, p_qr_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v      public.viaturas%rowtype;
  v_row  public.mov_viaturas%rowtype;
  v_ini  timestamptz;
  v_ter  timestamptz;
  v_conf record;
  v_mat  text := nullif(regexp_replace(coalesce(p_dados->>'condutor_matricula',''),'\D','','g'),'');
begin
  -- 1) token confere com a viatura?
  select * into v from public.viaturas
   where prefixo = p_prefixo and qr_token = p_qr_token and coalesce(ativo,true) = true;
  if v.prefixo is null then
    raise exception 'QR_INVALIDO';
  end if;

  -- 2) viatura disponível?
  if coalesce(v.situacao_operacional,'DISPONIVEL') <> 'DISPONIVEL' then
    raise exception 'Viatura indisponível (baixada/em manutenção). Fale com o setor responsável (Aux P4).';
  end if;

  -- 3) nº PM já cadastrado? -> barra (deve usar o painel com login)
  if v_mat is not null and exists (
       select 1 from public.militares
        where matricula_clean = lpad(v_mat, 7, '0') and coalesce(ativo,true) = true) then
    raise exception 'MILITAR_CADASTRADO';
  end if;

  -- 4) identificação mínima do condutor externo
  if coalesce(p_dados->>'condutor_nome','') = '' then
    raise exception 'Informe o nome completo do condutor.';
  end if;

  v_ini := coalesce((p_dados->>'inicio')::timestamptz, now());
  v_ter := (p_dados->>'termino')::timestamptz;

  -- trava de uso simultâneo (igual ao fluxo com sessão): a viatura não pode
  -- estar em dois serviços ao mesmo tempo; ficha aberta conta como "em uso"
  -- por até 48h a partir do início.
  select coalesce(m.inicio, m.criado_em)                                   as ini,
         m.termino                                                         as ter,
         coalesce(nullif(m.motorista_nome,''), m.criado_por_nome, 'outro militar') as quem
    into v_conf
    from public.mov_viaturas m
   where m.ativo = true
     and m.prefixo = v.prefixo
     and v_ini < coalesce(m.termino, coalesce(m.inicio, m.criado_em) + interval '48 hours')
     and coalesce(m.inicio, m.criado_em) < coalesce(v_ter, v_ini + interval '48 hours')
   order by coalesce(m.inicio, m.criado_em) desc
   limit 1;
  if found then
    raise exception '%', format(
      'A viatura %s já está em uso (armada) por %s desde %s%s. Aguarde o "Término (devolver)" daquela ficha antes de armar de novo.',
      v.prefixo, v_conf.quem,
      to_char(v_conf.ini at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),
      case when v_conf.ter is null then ' (ainda sem Término lançado)' else '' end);
  end if;

  insert into public.mov_viaturas (
    prefixo, placa, motorista_matricula, motorista_nome, lotacao_motorista,
    local_utilizacao, tipo_empenho, km_inicial, km_final, inicio, termino,
    comb_armar, comb_devolver,
    tem_abastecimento, tem_acidente, tem_avaria,
    dados, anexos, observacoes,
    gp_responsavel, grupamento_completo, ano, mes,
    criado_por_matricula, criado_por_nome, condutor_externo
  ) values (
    v.prefixo, coalesce(nullif(p_dados->>'placa',''), v.placa),
    v_mat, nullif(p_dados->>'condutor_nome',''),
    nullif(p_dados->>'condutor_unidade',''),
    nullif(p_dados->>'local_utilizacao',''), nullif(p_dados->>'tipo_empenho',''),
    (p_dados->>'km_inicial')::int, (p_dados->>'km_final')::int,
    v_ini, v_ter,
    nullif(p_dados->>'comb_armar',''), nullif(p_dados->>'comb_devolver',''),
    coalesce((p_dados->>'tem_abastecimento')::boolean,false),
    coalesce((p_dados->>'tem_acidente')::boolean,false),
    coalesce((p_dados->>'tem_avaria')::boolean,false),
    -- guarda a identificação do condutor externo dentro de dados.externo
    coalesce(p_dados->'dados','{}'::jsonb) || jsonb_build_object('externo', jsonb_build_object(
      'nome', p_dados->>'condutor_nome', 'posto_graduacao', p_dados->>'condutor_posto',
      'matricula', p_dados->>'condutor_matricula', 'unidade_origem', p_dados->>'condutor_unidade')),
    coalesce(p_dados->'anexos','[]'::jsonb), nullif(p_dados->>'observacoes',''),
    v.gp, coalesce(v.pel,''), extract(year from v_ini)::int, extract(month from v_ini)::int,
    v_mat,
    trim(coalesce(p_dados->>'condutor_posto','')||' '||coalesce(p_dados->>'condutor_nome','')),
    true
  ) returning * into v_row;

  -- fecha pendências abertas desta viatura no dia
  update public.mov_pendencias
     set atendida = true, mov_id = v_row.id
   where prefixo = v_row.prefixo and dia = current_date and atendida = false;

  return jsonb_build_object('ok', true, 'id', v_row.id, 'prefixo', v_row.prefixo,
                            'km_rodados', v_row.km_rodados);
end;
$$;

grant execute on function public.mov_viatura_criar_publico(text, uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 86 (mov_viatura_criar) e do 14 (público).
-- ════════════════════════════════════════════════════════════════════════

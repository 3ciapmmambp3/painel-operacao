-- ════════════════════════════════════════════════════════════════════════
-- 84_ficha_comandante_e_antiduplicidade.sql
--   Ficha de Movimentação atrelada também ao COMANDANTE da equipe (supervisão)
--   + anti-duplicidade por viatura+motorista no mesmo dia.
--
--   O que muda:
--   • mov_pendencias ganha comandante_matricula/nome — a obrigação da ficha
--     passa a valer para o motorista E o comandante da equipe (o aviso do Meu
--     Dia aparece para os dois; ver db/85 no hub_kpis).
--   • mov_pendencia_criar recebe o comandante (2 params novos, com default) e
--     enriquece a pendência já existente do dia.
--   • mov_viatura_criar bloqueia lançar uma 2ª ficha da MESMA viatura com o
--     MESMO motorista no mesmo dia (= mesma equipe do TTA). Motorista diferente
--     (outro turno/equipe) continua permitido. Quem lançar primeiro registra;
--     o comandante pode lançar (fica "Registrada por" ele, com o motorista do
--     TTA no campo Motorista).
--
--   Depende de: 08 (mov_viaturas/mov_pendencias), 37 (versões atuais dos RPCs).
--   Idempotente. Rodar no SQL Editor depois do 37. Rodar também o 85 (hub_kpis).
-- ════════════════════════════════════════════════════════════════════════

alter table public.mov_pendencias add column if not exists comandante_matricula text;
alter table public.mov_pendencias add column if not exists comandante_nome      text;
create index if not exists idx_pend_com on public.mov_pendencias (comandante_matricula, atendida);

-- ── Criação/enriquecimento da pendência (motorista + comandante) ─────────
drop function if exists public.mov_pendencia_criar(uuid, text, text, text);
create or replace function public.mov_pendencia_criar(
  p_token uuid, p_prefixo text, p_mot_mat text, p_mot_nome text,
  p_com_mat text default null, p_com_nome text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.mov_pendencias%rowtype;
  v_dia  date := (now() at time zone 'America/Sao_Paulo')::date;
  v_mot  text := nullif(regexp_replace(coalesce(p_mot_mat,''),'\D','','g'),'');
  v_com  text := nullif(regexp_replace(coalesce(p_com_mat,''),'\D','','g'),'');
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
  -- pendência aberta desse dia: enriquece (motorista/comandante) e devolve
  select * into v_row from public.mov_pendencias
   where prefixo=p_prefixo and dia=v_dia and atendida=false limit 1;
  if v_row.id is not null then
    update public.mov_pendencias set
      motorista_matricula  = coalesce(motorista_matricula, v_mot),
      motorista_nome       = coalesce(motorista_nome, nullif(p_mot_nome,'')),
      comandante_matricula = coalesce(comandante_matricula, v_com),
      comandante_nome      = coalesce(comandante_nome, nullif(p_com_nome,''))
     where id = v_row.id
    returning * into v_row;
    return to_jsonb(v_row);
  end if;
  insert into public.mov_pendencias
    (prefixo, dia, motorista_matricula, motorista_nome,
     comandante_matricula, comandante_nome, solicitado_por_matricula, solicitado_por_nome)
  values (p_prefixo, v_dia, v_mot, nullif(p_mot_nome,''),
     v_com, nullif(p_com_nome,''), v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo))
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- ── Gravar a ficha: anti-duplicidade + baixa da pendência (como no 37) ───
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
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;

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
    v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo)
  ) returning * into v_row;

  -- fecha pendências abertas desta viatura (data da movimentação e/ou do salvamento)
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

grant execute on function public.mov_pendencia_criar(uuid, text, text, text, text, text) to anon;
grant execute on function public.mov_viatura_criar(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 37. Rodar também o 85 (hub_kpis).
-- ════════════════════════════════════════════════════════════════════════

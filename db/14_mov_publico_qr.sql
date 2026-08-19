-- ════════════════════════════════════════════════════════════════════════
-- 14_mov_publico_qr.sql — Ficha de Movimentação PÚBLICA (condutor externo via QR)
--
-- Objetivo: viatura da 3ª Cia emprestada a quem NÃO tem acesso ao painel.
-- Cada viatura ganha um QR próprio (token secreto). A página pública
-- (movimentacao-publica.html?v=<prefixo>&k=<token>) abre SEM login e permite
-- ao condutor externo registrar a movimentação daquela viatura.
--
-- Regras:
--   • O QR só abre a ficha da viatura cujo token confere (não dá para lançar
--     ficha de outra viatura).
--   • Se quem acessar for MILITAR JÁ CADASTRADO (nº PM bate com militares),
--     é barrado e mandado ao painel para login — validado também no servidor.
--   • Viatura baixada/manutenção continua bloqueada (igual à ficha logada).
--
-- Depende de: 08_mov_viaturas.sql (viaturas, mov_viaturas, mov_pendencias),
--             04_sessoes_e_militares_seguranca.sql (militares).
-- Idempotente. Rodar no SQL Editor DEPOIS do 08.
-- ════════════════════════════════════════════════════════════════════════

-- ── Token de QR por viatura + flag de condutor externo ───────────────────
alter table public.viaturas     add column if not exists qr_token uuid;
alter table public.mov_viaturas add column if not exists condutor_externo boolean not null default false;

-- Gera token para viaturas que ainda não têm (mantém os já existentes).
update public.viaturas set qr_token = gen_random_uuid() where qr_token is null;

-- ── RPC: (re)gerar o token de uma viatura — restrito ao Aux P4/Admin ─────
-- Usada pela Gestão de Viaturas caso o QR precise ser invalidado (rotação).
create or replace function public.viatura_qr_rotacionar(p_token uuid, p_prefixo text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_novo uuid;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: o QR é gerido pelo setor responsável (Aux P4).';
  end if;
  v_novo := gen_random_uuid();
  update public.viaturas set qr_token = v_novo, atualizado_em = now() where prefixo = p_prefixo;
  return jsonb_build_object('ok', true, 'prefixo', p_prefixo, 'qr_token', v_novo);
end;
$$;

-- ── RPC pública: dados da viatura + último odômetro (valida o token) ─────
-- Devolve o necessário para a página pública montar o cabeçalho e a referência
-- de Km. NÃO expõe o token de volta.
create or replace function public.mov_viatura_publica_info(p_prefixo text, p_qr_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v public.viaturas%rowtype; v_km int;
begin
  select * into v from public.viaturas
   where prefixo = p_prefixo and qr_token = p_qr_token and coalesce(ativo,true) = true;
  if v.prefixo is null then
    return jsonb_build_object('ok', false, 'motivo', 'qr_invalido');
  end if;
  select max(km_final) into v_km from public.mov_viaturas
   where prefixo = p_prefixo and ativo = true and km_final is not null;
  return jsonb_build_object(
    'ok', true,
    'disponivel', coalesce(v.situacao_operacional,'DISPONIVEL') = 'DISPONIVEL',
    'ultimo_km', v_km,
    'viatura', jsonb_build_object(
      'prefixo', v.prefixo, 'placa', v.placa, 'marca_modelo', v.marca_modelo,
      'pel', v.pel, 'gp', v.gp, 'municipio', v.municipio,
      'situacao_viatura', v.situacao_viatura,
      'situacao_operacional', coalesce(v.situacao_operacional,'DISPONIVEL')
    )
  );
end;
$$;

-- ── RPC pública: nº PM já é de militar cadastrado? ───────────────────────
-- A página pública consulta ao sair do campo "nº PM": se true, redireciona
-- para o login (o militar cadastrado deve usar o painel, não o QR público).
create or replace function public.mov_militar_e_cadastrado(p_matricula text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.militares
     where matricula_clean = lpad(regexp_replace(coalesce(p_matricula,''),'\D','','g'), 7, '0')
       and coalesce(ativo, true) = true
       and nullif(regexp_replace(coalesce(p_matricula,''),'\D','','g'),'') is not null
  );
$$;

-- ── RPC pública: gravar a ficha (condutor externo, sem sessão) ──────────
create or replace function public.mov_viatura_criar_publico(
  p_prefixo text, p_qr_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v      public.viaturas%rowtype;
  v_row  public.mov_viaturas%rowtype;
  v_ini  timestamptz;
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
    v_ini, (p_dados->>'termino')::timestamptz,
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

-- ── Viatura nova já nasce com QR: redefine viatura_salvar (10) p/ gerar o
--    token no INSERT; na edição mantém o token existente. ─────────────────
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
     situacao_viatura, observacao, ativo, qr_token, atualizado_em)
  values (
    v_prefixo, nullif(p_dados->>'placa',''), nullif(p_dados->>'marca_modelo',''),
    (p_dados->>'ano')::int, nullif(p_dados->>'tracao',''), nullif(p_dados->>'tipo_bem',''),
    nullif(p_dados->>'pel',''), nullif(p_dados->>'gp',''), nullif(p_dados->>'municipio',''),
    nullif(p_dados->>'situacao_viatura',''), nullif(p_dados->>'observacao',''), true,
    gen_random_uuid(), now())
  on conflict (prefixo) do update set
    placa=excluded.placa, marca_modelo=excluded.marca_modelo, ano=excluded.ano,
    tracao=excluded.tracao, tipo_bem=excluded.tipo_bem, pel=excluded.pel, gp=excluded.gp,
    municipio=excluded.municipio, situacao_viatura=excluded.situacao_viatura,
    observacao=excluded.observacao, ativo=true, atualizado_em=now(),
    -- mantém o token existente; só gera se por algum motivo estiver vazio
    qr_token=coalesce(public.viaturas.qr_token, excluded.qr_token)
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

-- ── Permissões p/ o papel anônimo (chave anon do painel) ────────────────
grant execute on function public.mov_viatura_publica_info(text, uuid) to anon;
grant execute on function public.mov_militar_e_cadastrado(text) to anon;
grant execute on function public.mov_viatura_criar_publico(text, uuid, jsonb) to anon;
grant execute on function public.viatura_qr_rotacionar(uuid, text) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 08_mov_viaturas.sql.
-- ════════════════════════════════════════════════════════════════════════

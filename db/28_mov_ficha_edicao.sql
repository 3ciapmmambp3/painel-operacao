-- ════════════════════════════════════════════════════════════════════════
-- 28_mov_ficha_edicao.sql — Lista/Ver/Editar Ficha de Movimentação + Auditoria
--
-- Adiciona: listar as fichas do usuário (gestor vê todas), abrir uma ficha,
-- EDITAR com regra (mesmo dia = quem criou; depois = só gestor de viaturas) e
-- AUDITORIA de cada edição (quem, quando, antes→depois de cada campo alterado).
--
-- "Gestor de viaturas" = _pode_gerenciar_viaturas (admin_geral ou Aux P4) — 08.
-- Depende de 04 (_sessao_militar) e 08 (mov_viaturas, _pode_gerenciar_viaturas).
-- Idempotente. Rodar no SQL Editor (depois do 08).
-- ════════════════════════════════════════════════════════════════════════

-- colunas de atualização (create table if not exists não adiciona sozinho)
alter table public.mov_viaturas add column if not exists atualizado_em            timestamptz;
alter table public.mov_viaturas add column if not exists atualizado_por_matricula text;
alter table public.mov_viaturas add column if not exists atualizado_por_nome      text;

-- ── Log de auditoria das edições ─────────────────────────────────────────
create table if not exists public.mov_viaturas_audit (
  id                uuid primary key default gen_random_uuid(),
  mov_id            uuid not null references public.mov_viaturas(id) on delete cascade,
  editor_matricula  text,
  editor_nome       text,
  editado_em        timestamptz not null default now(),
  alteracoes        jsonb not null default '[]'::jsonb   -- [{campo, antes, depois}]
);
create index if not exists idx_movaudit_mov on public.mov_viaturas_audit (mov_id, editado_em desc);
create index if not exists idx_movaudit_em  on public.mov_viaturas_audit (editado_em desc);

alter table public.mov_viaturas_audit enable row level security;
drop policy if exists movaudit_sel on public.mov_viaturas_audit;
create policy movaudit_sel on public.mov_viaturas_audit for select using (true);

-- ── RPC: listar fichas (as minhas; gestor vê todas) ──────────────────────
-- Retorna campos-chave + flag pode_editar (mesmo dia & criador, OU gestor).
create or replace function public.mov_ficha_listar(p_token uuid, p_todas boolean default false)
returns table (
  id uuid, prefixo text, placa text, motorista_nome text, motorista_matricula text,
  local_utilizacao text, km_inicial int, km_final int, km_rodados int,
  inicio timestamptz, termino timestamptz, criado_em timestamptz,
  criado_por_matricula text, criado_por_nome text,
  atualizado_em timestamptz, atualizado_por_nome text,
  pode_editar boolean, editado boolean
)
language plpgsql stable security definer set search_path = public as $$
declare v_me record; v_gestor boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  v_gestor := public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao);
  return query
    select m.id, m.prefixo, m.placa, m.motorista_nome, m.motorista_matricula,
           m.local_utilizacao, m.km_inicial, m.km_final, m.km_rodados,
           m.inicio, m.termino, m.criado_em, m.criado_por_matricula, m.criado_por_nome,
           m.atualizado_em, m.atualizado_por_nome,
           ( v_gestor OR (m.criado_por_matricula = v_me.matricula
              and (m.criado_em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date) ) as pode_editar,
           (m.atualizado_em is not null) as editado
      from public.mov_viaturas m
     where m.ativo = true
       and ( m.criado_por_matricula = v_me.matricula
             or (v_gestor and coalesce(p_todas,false)) )
     order by m.criado_em desc;
end;
$$;

-- ── RPC: abrir uma ficha (criador ou gestor) ─────────────────────────────
create or replace function public.mov_ficha_completa(p_token uuid, p_id uuid)
returns public.mov_viaturas
language plpgsql stable security definer set search_path = public as $$
declare v_me record; v_row public.mov_viaturas%rowtype;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  select * into v_row from public.mov_viaturas where id = p_id and ativo = true;
  if v_row.id is null then raise exception 'Ficha não encontrada.'; end if;
  if not ( public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao)
           or v_row.criado_por_matricula = v_me.matricula ) then
    raise exception 'Sem permissão para ver esta ficha.';
  end if;
  return v_row;
end;
$$;

-- ── RPC: editar ficha (regra + auditoria) ────────────────────────────────
create or replace function public.mov_ficha_editar(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_old public.mov_viaturas%rowtype; v_row public.mov_viaturas%rowtype;
  v_gestor boolean; v_mesmo_dia boolean; v_alt jsonb := '[]'::jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  select * into v_old from public.mov_viaturas where id = p_id and ativo = true;
  if v_old.id is null then raise exception 'Ficha não encontrada.'; end if;

  v_gestor    := public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao);
  v_mesmo_dia := (v_old.criado_por_matricula = v_me.matricula
    and (v_old.criado_em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date);
  if not (v_gestor or v_mesmo_dia) then
    raise exception 'Edição não permitida: só no mesmo dia (por quem criou) ou pelo gestor de viaturas.';
  end if;

  -- monta o diff (campos-chave) ANTES de atualizar
  declare
    v_new_prefixo text := coalesce(nullif(p_dados->>'prefixo',''), v_old.prefixo);
    v_new_placa   text := nullif(p_dados->>'placa','');
    v_new_motmat  text := nullif(p_dados->>'motorista_matricula','');
    v_new_motnome text := nullif(p_dados->>'motorista_nome','');
    v_new_lot     text := nullif(p_dados->>'lotacao_motorista','');
    v_new_local   text := nullif(p_dados->>'local_utilizacao','');
    v_new_emp     text := nullif(p_dados->>'tipo_empenho','');
    v_new_kmi     int  := (p_dados->>'km_inicial')::int;
    v_new_kmf     int  := (p_dados->>'km_final')::int;
    v_new_ini     timestamptz := (p_dados->>'inicio')::timestamptz;
    v_new_ter     timestamptz := (p_dados->>'termino')::timestamptz;
    v_new_ca      text := nullif(p_dados->>'comb_armar','');
    v_new_cd      text := nullif(p_dados->>'comb_devolver','');
    v_new_obs     text := nullif(p_dados->>'observacoes','');
  begin
    if v_new_prefixo is distinct from v_old.prefixo then v_alt := v_alt || jsonb_build_object('campo','Prefixo','antes',v_old.prefixo,'depois',v_new_prefixo); end if;
    if v_new_placa   is distinct from v_old.placa   then v_alt := v_alt || jsonb_build_object('campo','Placa','antes',v_old.placa,'depois',v_new_placa); end if;
    if v_new_motmat  is distinct from v_old.motorista_matricula then v_alt := v_alt || jsonb_build_object('campo','Matrícula do motorista','antes',v_old.motorista_matricula,'depois',v_new_motmat); end if;
    if v_new_motnome is distinct from v_old.motorista_nome then v_alt := v_alt || jsonb_build_object('campo','Motorista','antes',v_old.motorista_nome,'depois',v_new_motnome); end if;
    if v_new_lot     is distinct from v_old.lotacao_motorista then v_alt := v_alt || jsonb_build_object('campo','Lotação do motorista','antes',v_old.lotacao_motorista,'depois',v_new_lot); end if;
    if v_new_local   is distinct from v_old.local_utilizacao then v_alt := v_alt || jsonb_build_object('campo','Local de utilização','antes',v_old.local_utilizacao,'depois',v_new_local); end if;
    if v_new_emp     is distinct from v_old.tipo_empenho then v_alt := v_alt || jsonb_build_object('campo','Tipo de empenho','antes',v_old.tipo_empenho,'depois',v_new_emp); end if;
    if v_new_kmi     is distinct from v_old.km_inicial then v_alt := v_alt || jsonb_build_object('campo','Km inicial','antes',v_old.km_inicial,'depois',v_new_kmi); end if;
    if v_new_kmf     is distinct from v_old.km_final then v_alt := v_alt || jsonb_build_object('campo','Km final','antes',v_old.km_final,'depois',v_new_kmf); end if;
    if v_new_ini     is distinct from v_old.inicio then v_alt := v_alt || jsonb_build_object('campo','Início','antes',to_char(v_old.inicio,'DD/MM/YYYY HH24:MI'),'depois',to_char(v_new_ini,'DD/MM/YYYY HH24:MI')); end if;
    if v_new_ter     is distinct from v_old.termino then v_alt := v_alt || jsonb_build_object('campo','Término','antes',to_char(v_old.termino,'DD/MM/YYYY HH24:MI'),'depois',to_char(v_new_ter,'DD/MM/YYYY HH24:MI')); end if;
    if v_new_ca      is distinct from v_old.comb_armar then v_alt := v_alt || jsonb_build_object('campo','Combustível ao armar','antes',v_old.comb_armar,'depois',v_new_ca); end if;
    if v_new_cd      is distinct from v_old.comb_devolver then v_alt := v_alt || jsonb_build_object('campo','Combustível ao devolver','antes',v_old.comb_devolver,'depois',v_new_cd); end if;
    if v_new_obs     is distinct from v_old.observacoes then v_alt := v_alt || jsonb_build_object('campo','Observações','antes',v_old.observacoes,'depois',v_new_obs); end if;
    if coalesce(p_dados->'dados','{}'::jsonb)  is distinct from v_old.dados  then v_alt := v_alt || jsonb_build_object('campo','Seções (abastecimento/acidente/etc.)','antes','—','depois','alterado'); end if;
    if coalesce(p_dados->'anexos','[]'::jsonb) is distinct from v_old.anexos then v_alt := v_alt || jsonb_build_object('campo','Anexos','antes','—','depois','alterado'); end if;

    update public.mov_viaturas set
      prefixo=v_new_prefixo, placa=v_new_placa, motorista_matricula=v_new_motmat,
      motorista_nome=v_new_motnome, lotacao_motorista=v_new_lot, local_utilizacao=v_new_local,
      tipo_empenho=v_new_emp, km_inicial=v_new_kmi, km_final=v_new_kmf,
      inicio=coalesce(v_new_ini, inicio), termino=v_new_ter, comb_armar=v_new_ca, comb_devolver=v_new_cd,
      tem_abastecimento=coalesce((p_dados->>'tem_abastecimento')::boolean, tem_abastecimento),
      tem_acidente=coalesce((p_dados->>'tem_acidente')::boolean, tem_acidente),
      tem_manutencao=coalesce((p_dados->>'tem_manutencao')::boolean, tem_manutencao),
      tem_avaria=coalesce((p_dados->>'tem_avaria')::boolean, tem_avaria),
      tem_limpeza=coalesce((p_dados->>'tem_limpeza')::boolean, tem_limpeza),
      tem_taq=coalesce((p_dados->>'tem_taq')::boolean, tem_taq),
      tem_aeronave=coalesce((p_dados->>'tem_aeronave')::boolean, tem_aeronave),
      dados=coalesce(p_dados->'dados', dados), anexos=coalesce(p_dados->'anexos', anexos),
      observacoes=v_new_obs,
      atualizado_em=now(), atualizado_por_matricula=v_me.matricula,
      atualizado_por_nome=coalesce(v_me.nome_guerra, v_me.nome_completo)
    where id = p_id returning * into v_row;
  end;

  -- grava a auditoria (só se houve alteração real)
  if jsonb_array_length(v_alt) > 0 then
    insert into public.mov_viaturas_audit (mov_id, editor_matricula, editor_nome, alteracoes)
    values (p_id, v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo), v_alt);
  end if;

  return jsonb_build_object('ok', true, 'id', p_id, 'alteracoes', jsonb_array_length(v_alt));
end;
$$;

-- ── RPC: consultar auditoria (só gestor de viaturas) ─────────────────────
create or replace function public.mov_ficha_audit_listar(p_token uuid, p_id uuid default null)
returns table (
  id uuid, mov_id uuid, prefixo text, editor_matricula text, editor_nome text,
  editado_em timestamptz, alteracoes jsonb
)
language plpgsql stable security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: consulta de auditoria é do gestor de viaturas.';
  end if;
  return query
    select a.id, a.mov_id, m.prefixo, a.editor_matricula, a.editor_nome, a.editado_em, a.alteracoes
      from public.mov_viaturas_audit a
      join public.mov_viaturas m on m.id = a.mov_id
     where (p_id is null or a.mov_id = p_id)
     order by a.editado_em desc
     limit 500;
end;
$$;

grant execute on function public.mov_ficha_listar(uuid, boolean)       to anon;
grant execute on function public.mov_ficha_completa(uuid, uuid)        to anon;
grant execute on function public.mov_ficha_editar(uuid, uuid, jsonb)   to anon;
grant execute on function public.mov_ficha_audit_listar(uuid, uuid)    to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 08.
-- ════════════════════════════════════════════════════════════════════════

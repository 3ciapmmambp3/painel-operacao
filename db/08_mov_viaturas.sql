-- ════════════════════════════════════════════════════════════════════════
-- 08_mov_viaturas.sql — Módulo "Ficha de Movimentação de Viaturas"
--
-- Depende de:
--   00_grupamentos_view.sql, 04_sessoes_e_militares_seguranca.sql
--   (usa public._sessao_militar(p_token) para resolver quem está logado)
--
-- Duas tabelas:
--   • viaturas      — CADASTRO (espelho da planilha do Google, chave = prefixo).
--                     Escrita feita pelo Apps Script com a service_role key
--                     (bypassa RLS). O painel só LÊ (anon select).
--   • mov_viaturas  — a FICHA em si (núcleo em colunas + seções opcionais em
--                     jsonb `dados` + fotos em jsonb `anexos`).
--
-- RPCs:
--   • mov_viatura_ultimo_km(p_prefixo)     — Km inicial automático (último Km final).
--   • mov_viatura_criar(p_token, p_dados)  — grava a ficha (exige sessão válida).
--
-- Idempotente: pode rodar novamente sem quebrar.
-- ════════════════════════════════════════════════════════════════════════

-- ── CADASTRO DE VIATURAS ────────────────────────────────────────────────
create table if not exists public.viaturas (
  prefixo           text primary key,          -- ex: '36685'
  placa             text,                       -- ex: 'TEI9J19'
  marca_modelo      text,                       -- ex: 'Toyota / Hilux'
  ano               int,
  tracao            text,                       -- '4x4' | '4x2'
  tipo_bem          text,                       -- própria | locada | comodato
  pel               text,                       -- '4º Pel PM MAmb'
  gp                text,                       -- '1º Gp PM MAmb'
  municipio         text,
  situacao_viatura  text,                       -- condição (vem da planilha: BOA/RUIM/...)
  situacao_operacional text not null default 'DISPONIVEL',  -- DISPONIVEL | BAIXADA | EM_MANUTENCAO
  observacao        text,
  ativo             boolean not null default true,
  atualizado_em     timestamptz not null default now()
);
-- para cadastros já existentes (create table if not exists não adiciona colunas novas):
alter table public.viaturas add column if not exists situacao_operacional text not null default 'DISPONIVEL';

create index if not exists idx_viaturas_gp  on public.viaturas (gp);
create index if not exists idx_viaturas_pel on public.viaturas (pel);

-- ── A FICHA ─────────────────────────────────────────────────────────────
create table if not exists public.mov_viaturas (
  id                    uuid primary key default gen_random_uuid(),

  -- viatura / motorista
  prefixo               text,
  placa                 text,
  motorista_matricula   text,
  motorista_nome        text,
  lotacao_motorista     text,
  local_utilizacao      text,
  tipo_empenho          text,

  -- odômetro / turno
  km_inicial            int,
  km_final              int,
  km_rodados            int generated always as (
                          case when km_final is not null and km_inicial is not null
                               then km_final - km_inicial end) stored,
  inicio                timestamptz,
  termino               timestamptz,
  comb_armar            text,
  comb_devolver         text,

  -- flags das seções opcionais (facilita filtro/relatório)
  tem_abastecimento     boolean not null default false,
  tem_acidente          boolean not null default false,
  tem_manutencao        boolean not null default false,
  tem_avaria            boolean not null default false,
  tem_limpeza           boolean not null default false,
  tem_taq               boolean not null default false,
  tem_aeronave          boolean not null default false,

  -- detalhes das seções opcionais e fotos
  dados                 jsonb not null default '{}'::jsonb,   -- {abastecimento:{...}, acidente:{...}, manutencao:{...}, ...}
  anexos                jsonb not null default '[]'::jsonb,   -- [{path,nome,mime,link,origem}]
  observacoes           text,

  -- escopo / auditoria
  gp_responsavel        text,
  grupamento_completo   text,
  ano                   int,
  mes                   int,
  criado_por_matricula  text,
  criado_por_nome       text,
  criado_em             timestamptz not null default now(),
  ativo                 boolean not null default true
);

create index if not exists idx_mov_prefixo on public.mov_viaturas (prefixo);
create index if not exists idx_mov_anomes  on public.mov_viaturas (ano, mes);
create index if not exists idx_mov_gp       on public.mov_viaturas (gp_responsavel);
create index if not exists idx_mov_criado   on public.mov_viaturas (criado_em desc);

-- ── PENDÊNCIAS de ficha ─────────────────────────────────────────────────
-- Quando o Relatório de Serviço informa uma viatura (principal ou de apoio)
-- que ainda não tem ficha no dia, cria-se uma pendência para o MOTORISTA
-- informado — ela aparece na conta dele em Movimentação de Viaturas.
create table if not exists public.mov_pendencias (
  id                        uuid primary key default gen_random_uuid(),
  prefixo                   text not null,
  dia                       date not null default current_date,
  motorista_matricula       text,     -- só dígitos, p/ casar com a sessão
  motorista_nome            text,
  solicitado_por_matricula  text,
  solicitado_por_nome       text,
  origem                    text default 'relatorio_apoio',
  atendida                  boolean not null default false,
  mov_id                    uuid,
  criado_em                 timestamptz not null default now()
);
create index if not exists idx_pend_mot on public.mov_pendencias (motorista_matricula, atendida);
create unique index if not exists uq_pend_prefixo_dia on public.mov_pendencias (prefixo, dia) where atendida = false;

-- ── RPC: Km inicial automático (último Km final da viatura) ──────────────
-- Devolve o maior km_final já registrado para o prefixo (ou null se não houver).
create or replace function public.mov_viatura_ultimo_km(p_prefixo text)
returns int
language sql stable security definer set search_path = public as $$
  select max(km_final)
  from public.mov_viaturas
  where prefixo = p_prefixo and ativo = true and km_final is not null;
$$;

-- ── RPC: gravar a ficha ─────────────────────────────────────────────────
-- Exige sessão válida (p_token). Deriva ano/mês do início (ou agora) e
-- carimba quem criou. Aceita as seções opcionais dentro de p_dados->'dados'.
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

  -- bloqueia movimentação de viatura baixada / em manutenção
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

  -- fecha pendências abertas desta viatura no dia (a viatura ganhou sua ficha)
  update public.mov_pendencias
     set atendida = true, mov_id = v_row.id
   where prefixo = v_row.prefixo and dia = current_date and atendida = false;

  return to_jsonb(v_row);
end;
$$;

-- ── RLS ─────────────────────────────────────────────────────────────────
alter table public.viaturas     enable row level security;
alter table public.mov_viaturas enable row level security;

-- viaturas: qualquer sessão (anon) LÊ o cadastro; escrita só via service_role
drop policy if exists viaturas_sel on public.viaturas;
create policy viaturas_sel on public.viaturas for select using (true);

-- mov_viaturas: anon LÊ (o escopo por perfil é aplicado no painel);
-- INSERT só pela função mov_viatura_criar (security definer) — sem policy de insert.
drop policy if exists mov_sel on public.mov_viaturas;
create policy mov_sel on public.mov_viaturas for select using (true);

-- ── BAIXA / MANUTENÇÃO (gestão do Aux P4) ───────────────────────────────
-- Histórico de baixas da viatura. Registra o odômetro na ida (km_baixa) e no
-- retorno (km_retorno) — a viatura pode rodar em teste durante a manutenção.
create table if not exists public.viaturas_baixas (
  id                 uuid primary key default gen_random_uuid(),
  prefixo            text not null,
  tipo               text not null,            -- 'BAIXADA' (aguardando oficina) | 'EM_MANUTENCAO'
  motivo             text,
  km_baixa           int,
  data_baixa         timestamptz not null default now(),
  baixado_por_matricula text,
  baixado_por_nome   text,
  km_retorno         int,
  data_retorno       timestamptz,
  obs_retorno        text,
  retornado_por_matricula text,
  retornado_por_nome text,
  aberta             boolean not null default true   -- true enquanto não retornou
);
create index if not exists idx_baixas_prefixo on public.viaturas_baixas (prefixo);
create index if not exists idx_baixas_aberta  on public.viaturas_baixas (aberta);

-- Quem gerencia baixa de viatura: Admin Geral OU função 'Aux P4'.
create or replace function public._pode_gerenciar_viaturas(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select p_nivel = 'admin_geral'
      or lower(coalesce(p_funcao,'')) like 'aux p4%';
$$;

-- Baixar (ou colocar em manutenção) uma viatura.
create or replace function public.viatura_baixar(
  p_token uuid, p_prefixo text, p_tipo text, p_motivo text, p_km_baixa int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.viaturas_baixas%rowtype;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: a baixa é gerida pelo setor responsável (Aux P4).';
  end if;
  if upper(coalesce(p_tipo,'')) not in ('BAIXADA','EM_MANUTENCAO') then
    raise exception 'Tipo inválido (use BAIXADA ou EM_MANUTENCAO).';
  end if;
  -- fecha qualquer baixa aberta anterior sem retorno (evita duplicidade)
  update public.viaturas_baixas set aberta=false where prefixo=p_prefixo and aberta=true;
  insert into public.viaturas_baixas (prefixo, tipo, motivo, km_baixa,
     baixado_por_matricula, baixado_por_nome)
  values (p_prefixo, upper(p_tipo), nullif(p_motivo,''), p_km_baixa,
     v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo))
  returning * into v_row;
  update public.viaturas set situacao_operacional = upper(p_tipo), atualizado_em = now()
   where prefixo = p_prefixo;
  return to_jsonb(v_row);
end;
$$;

-- Retornar viatura (fim da baixa/manutenção) — registra km_retorno.
create or replace function public.viatura_retornar(
  p_token uuid, p_prefixo text, p_km_retorno int, p_obs text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.viaturas_baixas%rowtype;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: o retorno é gerido pelo setor responsável (Aux P4).';
  end if;
  update public.viaturas_baixas
     set aberta=false, km_retorno=p_km_retorno, data_retorno=now(),
         obs_retorno=nullif(p_obs,''),
         retornado_por_matricula=v_me.matricula,
         retornado_por_nome=coalesce(v_me.nome_guerra, v_me.nome_completo)
   where prefixo=p_prefixo and aberta=true
  returning * into v_row;
  update public.viaturas set situacao_operacional='DISPONIVEL', atualizado_em=now()
   where prefixo=p_prefixo;
  return to_jsonb(v_row);
end;
$$;

alter table public.viaturas_baixas enable row level security;
drop policy if exists baixas_sel on public.viaturas_baixas;
create policy baixas_sel on public.viaturas_baixas for select using (true);

-- Cria pendência de ficha para o motorista informado (se a viatura ainda não
-- tem ficha hoje). Chamada pelo Relatório de Serviço ao encontrar viatura sem ficha.
create or replace function public.mov_pendencia_criar(
  p_token uuid, p_prefixo text, p_mot_mat text, p_mot_nome text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.mov_pendencias%rowtype;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(p_prefixo,'') = '' then return jsonb_build_object('ok',false); end if;
  -- já existe ficha hoje p/ a viatura? não precisa de pendência
  if exists (select 1 from public.mov_viaturas
             where prefixo=p_prefixo and ativo=true and criado_em::date=current_date) then
    return jsonb_build_object('ok',true,'ja_tem_ficha',true);
  end if;
  -- já há pendência aberta? devolve a existente
  select * into v_row from public.mov_pendencias
   where prefixo=p_prefixo and dia=current_date and atendida=false limit 1;
  if v_row.id is not null then return to_jsonb(v_row); end if;
  insert into public.mov_pendencias
    (prefixo, motorista_matricula, motorista_nome, solicitado_por_matricula, solicitado_por_nome)
  values (p_prefixo,
    nullif(regexp_replace(coalesce(p_mot_mat,''),'\D','','g'),''),
    nullif(p_mot_nome,''), v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo))
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

alter table public.mov_pendencias enable row level security;
drop policy if exists pend_sel on public.mov_pendencias;
create policy pend_sel on public.mov_pendencias for select using (true);

-- Permissões de execução das RPCs para o papel anônimo (chave anon do painel)
grant execute on function public.mov_viatura_ultimo_km(text) to anon;
grant execute on function public.mov_viatura_criar(uuid, jsonb) to anon;
grant execute on function public.viatura_baixar(uuid, text, text, text, int) to anon;
grant execute on function public.viatura_retornar(uuid, text, int, text) to anon;
grant execute on function public.mov_pendencia_criar(uuid, text, text, text) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem de execução no SQL Editor: depois de 00 e 04.
-- ════════════════════════════════════════════════════════════════════════

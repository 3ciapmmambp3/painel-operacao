-- ══════════════════════════════════════════════════════════════════════
--  MÓDULO FÉRIAS — 3ª Cia PM MAmb (P1 / Recursos Humanos)
--  Card "Férias" do hub P1. Substitui o Google Forms de escolha de férias.
--
--  Conceito:
--   • O Aux P1 monta 1 CRONOGRAMA por ano (períodos com janelas de 25 / 15 / 10
--     dias úteis), define o PRAZO de escolha (abertura/limite) e os LIMITES de
--     percentual simultâneo de férias por Cia / Pelotão / Grupamento.
--   • Cada militar tem um PEDIDO (por exercício): férias ANUAIS (25 direto ou
--     15+10 fracionado) ou férias-PRÊMIO (sem prazo; só o Aux P1 lança).
--   • FLUXO da anual: militar escolhe (PENDENTE) → CMT Pelotão ajusta/aprova
--     (APROVADO_PEL) → Aux P1 valida (VALIDADO). REJEITADO encerra.
--   • VISIBILIDADE: Aux P1 / Admin Geral / CMT Cia veem tudo; CMT Pelotão vê o
--     seu pelotão; CMT Grupamento / Admin GP vê o seu GP; Operacional vê o seu.
--
--  Esta é a FASE 1: tabelas + helpers + RPCs de gestão do Aux P1
--  (cronograma, %, lançar/editar/excluir pedido, painel de percentuais, dados
--  p/ Excel). O formulário do militar, a aprovação do CMT Pelotão e o aviso no
--  Meu Dia entram nas fases seguintes reusando estas mesmas tabelas.
--
--  Depende de: 04 (_sessao_militar, _nivel_num), 00 (grupos p/ pelotão/cia).
--  Idempotente. Rodar no SQL Editor (depois do 100).
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) CRONOGRAMA (um por ano) ────────────────────────────────────────
create table if not exists public.ferias_cronograma (
  id            uuid primary key default gen_random_uuid(),
  ano           int  not null unique,
  titulo        text,
  situacao      text not null default 'RASCUNHO'
                  check (situacao in ('RASCUNHO','ABERTO','ENCERRADO')),
  data_abertura date,                       -- início do prazo de escolha (anuais)
  data_limite   date,                       -- fim do prazo de escolha (anuais)

  -- limites de % simultâneo de militares em férias (editáveis pelo Aux P1)
  pct_max_cia        numeric,
  pct_max_pelotao    numeric,
  pct_max_grupamento numeric,

  -- períodos/janelas do cronograma. Array de:
  --   { "ordem": 1,
  --     "25":  {"ini":"2026-02-19","fim":"2026-03-25"},
  --     "15": [{"ini":"2026-01-02","fim":"2026-01-22"}, ...],
  --     "10": [{"ini":"2026-01-23","fim":"2026-02-05"}, ...] }
  periodos      jsonb not null default '[]'::jsonb,

  -- PDF do cronograma no Storage/Drive: [{path,nome,tamanho,mime,link}]
  anexo_pdf     jsonb not null default '[]'::jsonb,

  criado_por_matricula text,
  criado_por_nome      text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ─── 2) PEDIDOS (uma linha por militar/exercício/tipo) ─────────────────
create table if not exists public.ferias_pedidos (
  id            uuid primary key default gen_random_uuid(),
  cronograma_id uuid references public.ferias_cronograma(id) on delete set null,
  ano           int not null,               -- ano do plano/cronograma

  militar_id    uuid references public.militares(id) on delete set null,
  militar       jsonb not null default '{}'::jsonb,  -- {matricula,nome,guerra,pg}
  pelotao       text,                        -- carimbado na criação (p/ escopo e %)
  grupamento_id text,

  tipo          text not null default 'ANUAL' check (tipo in ('ANUAL','PREMIO')),
  exercicio     int,                         -- ano de referência das férias
  modalidade    text,                        -- '25_DIRETO' | '15_10_FRACIONADO' (anuais)

  -- parcelas efetivas: [{parcela:'25'|'15'|'10', ini, fim, periodo}]
  -- (prêmio: [{parcela:'PREMIO', ini, fim}])
  parcelas      jsonb not null default '[]'::jsonb,
  destino       text,                        -- município/fração onde passará as férias
  dias          int,                         -- total de dias (informativo; prêmio)
  observacoes   text,

  situacao      text not null default 'PENDENTE'
                  check (situacao in ('PENDENTE','APROVADO_PEL','VALIDADO','REJEITADO')),
  motivo_rejeicao text,

  criado_por_matricula text, criado_por_nome text,
  aprovado_pel_por_matricula text, aprovado_pel_por_nome text, aprovado_pel_em timestamptz,
  validado_p1_por_matricula  text, validado_p1_por_nome  text, validado_p1_em  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists idx_ferias_ped_ano      on public.ferias_pedidos (ano);
create index if not exists idx_ferias_ped_militar  on public.ferias_pedidos (militar_id);
create index if not exists idx_ferias_ped_pelotao  on public.ferias_pedidos (pelotao);
create index if not exists idx_ferias_ped_situacao on public.ferias_pedidos (situacao);
create index if not exists idx_ferias_ped_gp       on public.ferias_pedidos (grupamento_id);

drop trigger if exists trg_ferias_crono_touch on public.ferias_cronograma;
create trigger trg_ferias_crono_touch before update on public.ferias_cronograma
  for each row execute function public.tg_touch_updated_at();
drop trigger if exists trg_ferias_ped_touch on public.ferias_pedidos;
create trigger trg_ferias_ped_touch before update on public.ferias_pedidos
  for each row execute function public.tg_touch_updated_at();

-- ─── 3) HELPERS ────────────────────────────────────────────────────────
-- 3.1) Quem faz a GESTÃO (Aux P1 / Admin Geral / CMT da Cia).
create or replace function public._ferias_pode_p1(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y');
$$;

-- 3.2a) unaccent tolerante (o unaccent nativo pode não estar instalado):
--       tira só os acentos comuns do português. Definida ANTES de _posto_rank.
create or replace function public.unaccent_safe(p text)
returns text language sql immutable as $$
  select translate(coalesce(p,''),
    'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ',
    'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC');
$$;

-- 3.2b) Antiguidade por POSTO/GRADUAÇÃO. Menor número = mais antigo.
--      Desempate por data de promoção / classificação de curso fica p/ o
--      card Efetivo (campos futuros); aqui é a ordem canônica por posto.
create or replace function public._posto_rank(p_pg text)
returns int language sql immutable as $$
  select case
    when p ~ 'CEL' and p ~ 'TEN'                     then 2   -- Ten Cel
    when p ~ 'CEL'                                    then 1   -- Cel
    when p ~ 'MAJ'                                    then 3
    when p ~ 'CAP'                                    then 4
    when p ~ '1.*TEN'                                 then 5
    when p ~ '2.*TEN'                                 then 6
    when p ~ 'ASP'                                    then 7   -- Aspirante
    when p ~ 'SUB.*TEN' or p ~ 'ST '                  then 8   -- Sub Ten
    when p ~ '1.*SGT'                                 then 9
    when p ~ '2.*SGT'                                 then 10
    when p ~ '3.*SGT'                                 then 11
    when p ~ '\yCB\y' or p ~ 'CABO'                   then 12
    when p ~ '\ySD\y' or p ~ 'SOLDADO'               then 13
    else 99
  end
  from (select upper(public.unaccent_safe(coalesce(p_pg,''))) as p) t;
$$;

-- 3.3) Pelotão do militar (via tabela grupos; fallback regex em grupamento_id).
create or replace function public._ferias_pelotao(p_grupamento_id text)
returns text language sql stable as $$
  select coalesce(
    (select g.pelotao from public.grupos g
      where g.gp_responsavel = p_grupamento_id limit 1),
    nullif((regexp_match(upper(coalesce(p_grupamento_id,'')), '(\d+)\s*PEL'))[1], '')
  );
$$;

-- ─── 4) CRONOGRAMA: obter (qualquer logado) ────────────────────────────
create or replace function public.ferias_cronograma_get(p_token uuid, p_ano int default null)
returns public.ferias_cronograma
language plpgsql security definer set search_path = public as $$
declare
  v_me record;
  v_ano int := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_row public.ferias_cronograma;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_row from public.ferias_cronograma where ano = v_ano;
  return v_row;  -- pode vir vazio (ainda não montado)
end;
$$;

-- ─── 5) CRONOGRAMA: salvar (só gestão P1) ──────────────────────────────
create or replace function public.ferias_cronograma_salvar(p_token uuid, p_dados jsonb)
returns public.ferias_cronograma
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_ano int := coalesce(nullif(p_dados->>'ano','')::int,
                        extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_row public.ferias_cronograma;
  v_nome text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Apenas o Aux P1 / Comando pode montar o cronograma de férias.';
  end if;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  insert into public.ferias_cronograma (
    ano, titulo, situacao, data_abertura, data_limite,
    pct_max_cia, pct_max_pelotao, pct_max_grupamento,
    periodos, anexo_pdf, criado_por_matricula, criado_por_nome
  ) values (
    v_ano, nullif(p_dados->>'titulo',''),
    coalesce(nullif(p_dados->>'situacao',''),'RASCUNHO'),
    nullif(p_dados->>'data_abertura','')::date, nullif(p_dados->>'data_limite','')::date,
    nullif(p_dados->>'pct_max_cia','')::numeric,
    nullif(p_dados->>'pct_max_pelotao','')::numeric,
    nullif(p_dados->>'pct_max_grupamento','')::numeric,
    coalesce(p_dados->'periodos','[]'::jsonb), coalesce(p_dados->'anexo_pdf','[]'::jsonb),
    v_me.matricula, v_nome
  )
  on conflict (ano) do update set
    titulo             = case when p_dados ? 'titulo'        then nullif(p_dados->>'titulo','')             else public.ferias_cronograma.titulo end,
    situacao           = case when p_dados ? 'situacao'      then coalesce(nullif(p_dados->>'situacao',''),'RASCUNHO') else public.ferias_cronograma.situacao end,
    data_abertura      = case when p_dados ? 'data_abertura' then nullif(p_dados->>'data_abertura','')::date else public.ferias_cronograma.data_abertura end,
    data_limite        = case when p_dados ? 'data_limite'   then nullif(p_dados->>'data_limite','')::date   else public.ferias_cronograma.data_limite end,
    pct_max_cia        = case when p_dados ? 'pct_max_cia'        then nullif(p_dados->>'pct_max_cia','')::numeric        else public.ferias_cronograma.pct_max_cia end,
    pct_max_pelotao    = case when p_dados ? 'pct_max_pelotao'    then nullif(p_dados->>'pct_max_pelotao','')::numeric    else public.ferias_cronograma.pct_max_pelotao end,
    pct_max_grupamento = case when p_dados ? 'pct_max_grupamento' then nullif(p_dados->>'pct_max_grupamento','')::numeric else public.ferias_cronograma.pct_max_grupamento end,
    periodos           = case when p_dados ? 'periodos'  then coalesce(p_dados->'periodos','[]'::jsonb)  else public.ferias_cronograma.periodos end,
    anexo_pdf          = case when p_dados ? 'anexo_pdf' then coalesce(p_dados->'anexo_pdf','[]'::jsonb) else public.ferias_cronograma.anexo_pdf end
  returning * into v_row;

  return v_row;
end;
$$;

-- ─── 6) PEDIDOS: listar com ESCOPO ─────────────────────────────────────
create or replace function public.ferias_pedidos_listar(p_token uuid, p_ano int default null)
returns setof public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_ano   int := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_p1    boolean;
  v_pel   text;
  v_cmtpel boolean;
  v_cmtgp  boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  v_p1  := public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao);
  v_pel := public._ferias_pelotao(v_me.grupamento_id);
  v_cmtpel := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* 'pel')
              or coalesce(v_me.nivel_acesso,'') = 'admin_pelotao';
  v_cmtgp  := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* '(gp|grupamento)')
              or coalesce(v_me.nivel_acesso,'') = 'admin_gp';

  return query
    select * from public.ferias_pedidos p
     where p.ano = v_ano
       and (
             v_p1
          or (v_cmtpel and p.pelotao is not distinct from v_pel)
          or (v_cmtgp  and p.grupamento_id is not distinct from v_me.grupamento_id)
          or (p.militar_id = v_me.id)
           )
     order by public._posto_rank((p.militar->>'pg')) asc, (p.militar->>'matricula') asc;
end;
$$;

-- ─── 7) PEDIDO: salvar (criar/editar) ──────────────────────────────────
-- Aux P1 lança/edita qualquer um (inclusive PRÊMIO, sem prazo).
-- Demais papéis: fase 2/3 (formulário do militar e aprovação do CMT Pel).
create or replace function public.ferias_pedido_salvar(p_token uuid, p_id uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.ferias_pedidos;
  v_mid  uuid := nullif(p_dados->>'militar_id','')::uuid;
  v_alvo public.militares;
  v_ano  int := coalesce(nullif(p_dados->>'ano','')::int,
                         extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_crono uuid;
  v_nome text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Nesta fase, apenas o Aux P1 / Comando lança/edita os pedidos.';
  end if;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);
  select id into v_crono from public.ferias_cronograma where ano = v_ano;

  if p_id is not null then
    -- EDIÇÃO
    update public.ferias_pedidos set
      tipo        = case when p_dados ? 'tipo'        then coalesce(nullif(p_dados->>'tipo',''),tipo) else tipo end,
      exercicio   = case when p_dados ? 'exercicio'   then nullif(p_dados->>'exercicio','')::int else exercicio end,
      modalidade  = case when p_dados ? 'modalidade'  then nullif(p_dados->>'modalidade','') else modalidade end,
      parcelas    = case when p_dados ? 'parcelas'    then coalesce(p_dados->'parcelas','[]'::jsonb) else parcelas end,
      destino     = case when p_dados ? 'destino'     then nullif(p_dados->>'destino','') else destino end,
      dias        = case when p_dados ? 'dias'        then nullif(p_dados->>'dias','')::int else dias end,
      observacoes = case when p_dados ? 'observacoes' then nullif(p_dados->>'observacoes','') else observacoes end,
      situacao    = case when p_dados ? 'situacao'    then coalesce(nullif(p_dados->>'situacao',''),situacao) else situacao end
    where id = p_id
    returning * into v_row;
    if v_row.id is null then raise exception 'Pedido não encontrado.'; end if;
    return v_row;
  end if;

  -- CRIAÇÃO — precisa do militar-alvo
  if v_mid is null then raise exception 'Informe o militar.'; end if;
  select * into v_alvo from public.militares where id = v_mid;
  if v_alvo.id is null then raise exception 'Militar não encontrado.'; end if;

  insert into public.ferias_pedidos (
    cronograma_id, ano, militar_id, militar, pelotao, grupamento_id,
    tipo, exercicio, modalidade, parcelas, destino, dias, observacoes,
    situacao, criado_por_matricula, criado_por_nome
  ) values (
    v_crono, v_ano, v_alvo.id,
    jsonb_build_object('matricula', v_alvo.matricula, 'nome', v_alvo.nome_completo,
                       'guerra', v_alvo.nome_guerra, 'pg', v_alvo.posto_graduacao),
    public._ferias_pelotao(v_alvo.grupamento_id), v_alvo.grupamento_id,
    coalesce(nullif(p_dados->>'tipo',''),'ANUAL'),
    nullif(p_dados->>'exercicio','')::int, nullif(p_dados->>'modalidade',''),
    coalesce(p_dados->'parcelas','[]'::jsonb), nullif(p_dados->>'destino',''),
    nullif(p_dados->>'dias','')::int, nullif(p_dados->>'observacoes',''),
    -- Aux P1 lança já VALIDADO por padrão (pode ajustar); o fluxo pendente
    -- será usado pelo formulário do militar na fase 2.
    coalesce(nullif(p_dados->>'situacao',''),'VALIDADO'),
    v_me.matricula, v_nome
  ) returning * into v_row;

  -- carimba validação se já entrou validado
  if v_row.situacao = 'VALIDADO' then
    update public.ferias_pedidos
      set validado_p1_por_matricula = v_me.matricula,
          validado_p1_por_nome = v_nome, validado_p1_em = now()
    where id = v_row.id returning * into v_row;
  end if;

  return v_row;
end;
$$;

-- ─── 8) PEDIDO: excluir (só gestão P1) ─────────────────────────────────
create or replace function public.ferias_pedido_excluir(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Exclusão restrita ao Aux P1 / Comando.';
  end if;
  delete from public.ferias_pedidos where id = p_id;
end;
$$;

-- ─── 9) PAINEL DE PERCENTUAIS (na data; default hoje) ──────────────────
-- Conta militares com pedido VALIDADO em férias na data, por Cia/Pelotão/GP,
-- sobre o efetivo ativo do agrupamento. Só p/ gestão P1.
create or replace function public.ferias_percentuais(p_token uuid, p_ano int default null, p_data date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_ano  int  := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_dia  date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
  v_out  jsonb;
  v_crono public.ferias_cronograma;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Painel de percentuais restrito ao Aux P1 / Comando.';
  end if;
  select * into v_crono from public.ferias_cronograma where ano = v_ano;

  with efetivo as (
    select m.id, m.grupamento_id, public._ferias_pelotao(m.grupamento_id) as pelotao
      from public.militares m
     where m.ativo = true
       and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and coalesce(upper(btrim(m.funcao)),'') <> 'ASPM'
  ),
  em_ferias as (
    select distinct p.militar_id, p.pelotao, p.grupamento_id
      from public.ferias_pedidos p
      cross join lateral jsonb_array_elements(p.parcelas) parc
     where p.ano = v_ano
       and p.situacao = 'VALIDADO'
       and nullif(parc->>'ini','')::date <= v_dia
       and nullif(parc->>'fim','')::date >= v_dia
  ),
  cia as (
    select (select count(*) from efetivo) as total,
           (select count(*) from em_ferias) as ferias
  ),
  por_pel as (
    select e.pelotao,
           count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.pelotao is not distinct from e.pelotao) as ferias
      from efetivo e group by e.pelotao
  ),
  por_gp as (
    select e.grupamento_id,
           count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.grupamento_id is not distinct from e.grupamento_id) as ferias
      from efetivo e group by e.grupamento_id
  )
  select jsonb_build_object(
    'ano', v_ano, 'data', v_dia,
    'limites', jsonb_build_object(
      'cia', v_crono.pct_max_cia, 'pelotao', v_crono.pct_max_pelotao, 'grupamento', v_crono.pct_max_grupamento),
    'cia', (select jsonb_build_object('total', total, 'ferias', ferias,
              'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end) from cia),
    'pelotoes', coalesce((select jsonb_agg(jsonb_build_object(
              'pelotao', coalesce(pelotao,'(sem pelotão)'), 'total', total, 'ferias', ferias,
              'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end)
              order by pelotao) from por_pel), '[]'::jsonb),
    'grupamentos', coalesce((select jsonb_agg(jsonb_build_object(
              'grupamento', coalesce(grupamento_id,'(sem GP)'), 'total', total, 'ferias', ferias,
              'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end)
              order by grupamento_id) from por_gp), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

-- ─── 10) SEGURANÇA (RLS) — tudo passa pelas funções security definer ───
alter table public.ferias_cronograma enable row level security;
alter table public.ferias_pedidos    enable row level security;
revoke all on public.ferias_cronograma from anon, authenticated;
revoke all on public.ferias_pedidos    from anon, authenticated;

grant execute on function public.unaccent_safe(text)                        to anon;
grant execute on function public._posto_rank(text)                          to anon;
grant execute on function public._ferias_pode_p1(text, text)                to anon;
grant execute on function public._ferias_pelotao(text)                      to anon;
grant execute on function public.ferias_cronograma_get(uuid, int)           to anon;
grant execute on function public.ferias_cronograma_salvar(uuid, jsonb)      to anon;
grant execute on function public.ferias_pedidos_listar(uuid, int)           to anon;
grant execute on function public.ferias_pedido_salvar(uuid, uuid, jsonb)    to anon;
grant execute on function public.ferias_pedido_excluir(uuid, uuid)          to anon;
grant execute on function public.ferias_percentuais(uuid, int, date)        to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM (Fase 1). Reusa tg_touch_updated_at (já existe), _sessao_militar (04),
-- grupos (00). Não precisa re-rodar nenhum anterior.
--
-- DESFAZER (se precisar):
--   drop function if exists public.ferias_percentuais(uuid,int,date);
--   drop function if exists public.ferias_pedido_excluir(uuid,uuid);
--   drop function if exists public.ferias_pedido_salvar(uuid,uuid,jsonb);
--   drop function if exists public.ferias_pedidos_listar(uuid,int);
--   drop function if exists public.ferias_cronograma_salvar(uuid,jsonb);
--   drop function if exists public.ferias_cronograma_get(uuid,int);
--   drop function if exists public._ferias_pelotao(text);
--   drop function if exists public._ferias_pode_p1(text,text);
--   drop function if exists public._posto_rank(text);
--   drop table if exists public.ferias_pedidos;
--   drop table if exists public.ferias_cronograma;
-- ══════════════════════════════════════════════════════════════════════

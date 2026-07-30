-- ══════════════════════════════════════════════════════════════════════
--  MÓDULO DENÚNCIAS / REQUISIÇÕES — 3ª Cia PM MAmb
--  Rodar no Supabase (SQL Editor). Idempotente: pode rodar mais de uma vez.
--
--  Depende de: public.municipios_grupos, public.grupos
--  e da view public.vw_municipio_grupamento (rodar 00_grupamentos_view.sql antes).
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) CONTADOR ATÔMICO (numeração sem duplicidade) ───────────────────
-- Uma sequência por ANO e por TIPO (denúncia e requisição contam separado,
-- exatamente como na planilha: existe 001/2024 de cada tipo).
create table if not exists public.contadores (
  ano   int  not null,
  tipo  text not null,
  ultimo int not null default 0,
  primary key (ano, tipo)
);

-- Incremento atômico: o "on conflict do update ... returning" trava a linha,
-- então dois lançamentos simultâneos recebem números diferentes (059 e 060),
-- nunca o mesmo. É isto que elimina as duplicatas que existem hoje.
create or replace function public.proximo_numero(p_ano int, p_tipo text)
returns int
language plpgsql
as $$
declare v int;
begin
  insert into public.contadores (ano, tipo, ultimo)
    values (p_ano, p_tipo, 1)
    on conflict (ano, tipo)
    do update set ultimo = public.contadores.ultimo + 1
    returning ultimo into v;
  return v;
end;
$$;

-- ─── 2) TABELA PRINCIPAL ───────────────────────────────────────────────
-- Denúncias E requisições no mesmo lugar, distinguidas por "tipo".
create table if not exists public.denuncias (
  id            uuid primary key default gen_random_uuid(),
  numero        text not null,                 -- '059/2024'
  numero_seq    int  not null,                 -- 59
  ano           int  not null,                 -- 2024
  tipo          text not null check (tipo in ('denuncia','requisicao')),

  -- origem
  origem        text not null,                 -- órgão (requisição) ou forma de recebimento (denúncia)
  origem_esfera text,                           -- Estadual / Federal / Trabalho (quando MP)
  numero_oficio text,                           -- nº do ofício / processo (requisição)

  -- pessoas (denúncia)
  denunciante   text,
  denunciado    text,

  -- conteúdo / localização
  data_fato     date,
  municipio     text not null,
  gp_responsavel text not null,                 -- chave curta do GP (ex: 'GP GOVERNADOR VALADARES')
  grupamento_completo text not null,            -- rótulo completo (ex: '1 GP / 1 PEL / 3 CIA PM MAMB / GOVERNADOR VALADARES')
  tema          text not null,                  -- tipo de infração
  objeto        text,                           -- ação solicitada
  descricao     text not null,                  -- histórico
  endereco      text,
  referencia    text,                           -- roteiro / ponto de referência
  observacoes   text,
  prazo         date,

  -- anexos no Google Drive: array de objetos
  --   { "file_id","nome","tamanho","mime","web_view_link" }
  anexos        jsonb not null default '[]'::jsonb,

  -- workflow / atendimento
  situacao      text not null default 'PENDENTE'
                  check (situacao in ('PENDENTE','EM ANDAMENTO','CONCLUIDA','RESPONDIDA')),
  -- dados do atendimento (espelham o relatório de serviço)
  data_resposta           date,   -- data da fiscalização / atendimento
  numero_reds             text,   -- Nº REDS (BO/BOS/RAT)
  numero_auto_infracao    text,   -- Nº Auto de Infração
  numero_ato_fiscalizacao text,   -- Nº Ato de Fiscalização
  observacoes_resposta    text,   -- observações do atendimento
  id_sisfis     text,
  atendido_por_matricula text,
  atendido_por_nome      text,

  -- inativação (somente Admin Geral)
  ativo         boolean not null default true,
  inativado_por_matricula text,
  inativado_por_nome      text,
  motivo_inativacao       text,
  inativado_em            timestamptz,

  -- auditoria
  registrado_por_matricula text not null,
  registrado_por_nome      text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Colunas de atendimento (idempotente: caso a tabela já exista de um teste anterior)
alter table public.denuncias add column if not exists grupamento_completo    text;
alter table public.denuncias add column if not exists numero_auto_infracao    text;
alter table public.denuncias add column if not exists numero_ato_fiscalizacao text;
alter table public.denuncias add column if not exists observacoes_resposta    text;
-- Inativação (somente Admin Geral): registro lançado errado, sem apagar (mantém histórico)
alter table public.denuncias add column if not exists ativo boolean not null default true;
alter table public.denuncias add column if not exists inativado_por_matricula text;
alter table public.denuncias add column if not exists inativado_por_nome      text;
alter table public.denuncias add column if not exists motivo_inativacao       text;
alter table public.denuncias add column if not exists inativado_em            timestamptz;

create unique index if not exists uq_denuncias_num_tipo_ano on public.denuncias (ano, tipo, numero_seq);
create index if not exists idx_denuncias_gp        on public.denuncias (gp_responsavel);
create index if not exists idx_denuncias_situacao  on public.denuncias (situacao);
create index if not exists idx_denuncias_municipio on public.denuncias (municipio);
create index if not exists idx_denuncias_created   on public.denuncias (created_at desc);

-- mantém updated_at em dia
create or replace function public.tg_touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists trg_denuncias_touch on public.denuncias;
create trigger trg_denuncias_touch before update on public.denuncias
  for each row execute function public.tg_touch_updated_at();

-- ─── 3) CRIAÇÃO DE REGISTRO (numeração + grupamento, tudo atômico) ──────
-- O frontend chama esta função (nunca insere direto). Ela:
--   1. valida o tipo
--   2. deriva o gp_responsavel a partir do município (municipios_grupos)
--   3. gera o próximo número do ano/tipo (sem duplicidade)
--   4. insere e devolve a linha criada (com o número definitivo)
create or replace function public.criar_denuncia(dados jsonb)
returns public.denuncias
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tipo text := dados->>'tipo';
  v_muni text := upper(trim(dados->>'municipio'));
  v_ano  int  := coalesce(nullif(dados->>'ano','')::int, extract(year from now())::int);
  v_gp   text;
  v_gp_completo text;
  v_seq  int;
  v_row  public.denuncias;
begin
  if v_tipo not in ('denuncia','requisicao') then
    raise exception 'Tipo inválido: %', v_tipo;
  end if;

  -- deriva o grupamento (chave curta + rótulo completo) a partir do município
  select gp_responsavel, grupamento_completo into v_gp, v_gp_completo
    from public.vw_municipio_grupamento
    where municipio_upper = v_muni
    limit 1;
  if v_gp is null then
    raise exception 'Município não encontrado na tabela de grupamentos: %', v_muni;
  end if;

  v_seq := public.proximo_numero(v_ano, v_tipo);

  insert into public.denuncias (
    numero, numero_seq, ano, tipo,
    origem, origem_esfera, numero_oficio,
    denunciante, denunciado,
    data_fato, municipio, gp_responsavel, grupamento_completo, tema, objeto, descricao,
    endereco, referencia, observacoes, prazo, anexos,
    registrado_por_matricula, registrado_por_nome
  ) values (
    lpad(v_seq::text, 3, '0') || '/' || v_ano::text, v_seq, v_ano, v_tipo,
    dados->>'origem', nullif(dados->>'origem_esfera',''), nullif(dados->>'numero_oficio',''),
    nullif(dados->>'denunciante',''), nullif(dados->>'denunciado',''),
    nullif(dados->>'data_fato','')::date, v_muni, v_gp, v_gp_completo,
    dados->>'tema', nullif(dados->>'objeto',''), dados->>'descricao',
    nullif(dados->>'endereco',''), nullif(dados->>'referencia',''), nullif(dados->>'observacoes',''),
    nullif(dados->>'prazo','')::date, coalesce(dados->'anexos','[]'::jsonb),
    dados->>'registrado_por_matricula', dados->>'registrado_por_nome'
  ) returning * into v_row;

  return v_row;
end;
$$;

-- ─── 4) SEGURANÇA (RLS) ────────────────────────────────────────────────
-- O painel usa a chave ANON (mesmo padrão do auth.js). Inserção só via a
-- função acima (security definer), então NÃO criamos policy de INSERT: isso
-- bloqueia gravação direta e força o fluxo correto.
-- OBS de produção: o ideal é migrar para Supabase Auth (JWT) e restringir o
-- SELECT/UPDATE ao grupamento do militar. Por ora, escopo é validado no app.
alter table public.denuncias enable row level security;

drop policy if exists denuncias_select_anon on public.denuncias;
create policy denuncias_select_anon on public.denuncias
  for select to anon using (true);

drop policy if exists denuncias_update_anon on public.denuncias;
create policy denuncias_update_anon on public.denuncias
  for update to anon using (true) with check (true);

grant execute on function public.criar_denuncia(jsonb) to anon;
grant execute on function public.proximo_numero(int, text) to anon;
grant select on public.municipios_grupos to anon;
grant select on public.grupos to anon;
-- (a view vw_municipio_grupamento já recebe grant em 00_grupamentos_view.sql)

-- ─── Pronto. Teste rápido: ─────────────────────────────────────────────
-- select public.criar_denuncia('{
--   "tipo":"denuncia","municipio":"GOVERNADOR VALADARES","tema":"Flora",
--   "origem":"Diretamente ao policial","descricao":"teste",
--   "registrado_por_matricula":"146.322-3","registrado_por_nome":"3º Sgt Edison"
-- }'::jsonb);

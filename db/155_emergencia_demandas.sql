-- ══════════════════════════════════════════════════════════════════════
--  MÓDULO EMERGÊNCIA AMBIENTAL
--  Controle de Demandas — 3ª Cia PM MAmb
--  Rodar no Supabase (SQL Editor). Idempotente: pode rodar mais de uma vez.
--
--  Demandas importadas da planilha "EMERGENCIA AMBIENTAL 3ª CIA MAMB"
--  (aba "EMERGENCIA_3ªCIAMAMB") por um Apps Script agendado → UPSERT por
--  CÓDIGO (Nº PROTOC., ex: '158/2024'). O LANÇAMENTO MANUAL (painel) e a BAIXA
--  (Relatório de Serviço) também passam por aqui. GAIA == Ato de Fiscalização
--  == SISFIS.  Prazo = 4 dias (vence = DATA + 4d; a planilha não tem coluna de
--  vencimento).
--
--  Espelha a tabela irmã public.ri_demandas (db/154), mesma engrenagem.
--  Já inclui numero_auto_infracao / equipe / viatura (db/153) de saída.
--  Segue o padrão de db/01_denuncias.sql: RLS anon (select/update using(true)),
--  escrita só via função security definer, escopo validado no app.
--  Depende de: public.vw_municipio_grupamento (p/ resolver o grupamento do
--  painel a partir do município — usado no filtro de escopo).
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) TABELA ─────────────────────────────────────────────────────────
create table if not exists public.emergencia_demandas (
  id            uuid primary key default gen_random_uuid(),

  -- chave da planilha: CÓDIGO (Nº PROTOC.)
  codigo        text not null,                 -- ex: '158/2024'
  tipo_demanda  text,                           -- rótulo livre (default 'EMERGÊNCIA')

  -- conteúdo / localização (fonte da verdade = planilha/painel)
  data_gerada   date,                           -- DATA
  natureza      text,                           -- MODALIDADE DO ACIDENTE
  municipio     text,
  endereco      text,                           -- (sem endereço na planilha)
  fracao_responsavel  text,                     -- raw: 'GP BARAO DE COCAIS'

  -- grupamento resolvido (p/ o filtro de escopo do painel) — best effort
  gp_responsavel      text,
  grupamento_completo text,

  -- prazos
  data_envio        date,                       -- (sem envio na planilha de Emergência)
  data_vencimento   date,                       -- DATA + 4d
  status_prazo      text,                        -- SITUAÇÃO (rótulo de prazo)

  -- atendimento (espelha o relatório; preenchido pela BAIXA no painel ou robô)
  data_atendimento  date,                        -- DATA DO ATENDIMENTO
  numero_gaia       text,                        -- GAIA == Ato == SISFIS
  numero_reds       text,
  resultado         text,
  status_atendimento text,                        -- STATUS da planilha
  info_complementares text,                       -- PRODUTO / observações
  numero_auto_infracao text,
  equipe            text,
  viatura           text,

  -- anexos no Google Drive (PDF da emergência): [{ tipo, nome, web_view_link, ... }]
  anexos        jsonb not null default '[]'::jsonb,

  -- workflow unificado (pendente = ainda não respondida)
  situacao      text not null default 'PENDENTE'
                  check (situacao in ('PENDENTE','EM ANDAMENTO','RESPONDIDA','DEVOLVIDA','FINALIZADA','INATIVADA')),

  -- baixa feita no painel
  atendido_por_matricula text,
  atendido_por_nome      text,
  observacoes_resposta   text,

  -- proveniência / sync
  fonte_aba     text,                            -- 'manual' (planilha) | 'painel' (lançado no painel)
  raw           jsonb not null default '{}'::jsonb,
  versao        int  not null default 1,
  synced_at     timestamptz,

  -- inativação (só Admin Geral / Aux gestor)
  ativo         boolean not null default true,
  inativado_por_matricula text,
  inativado_por_nome      text,
  motivo_inativacao       text,
  inativado_em            timestamptz,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create unique index if not exists uq_emerg_codigo    on public.emergencia_demandas (codigo);
create index if not exists idx_emerg_gp              on public.emergencia_demandas (gp_responsavel);
create index if not exists idx_emerg_situacao        on public.emergencia_demandas (situacao);
create index if not exists idx_emerg_municipio       on public.emergencia_demandas (municipio);
create index if not exists idx_emerg_venc            on public.emergencia_demandas (data_vencimento);

drop trigger if exists trg_emerg_touch on public.emergencia_demandas;
create trigger trg_emerg_touch before update on public.emergencia_demandas
  for each row execute function public.tg_touch_updated_at();

-- ─── 2) SYNC (UPSERT em lote, vindo do Apps Script / lançamento manual) ─
-- Cada linha: { codigo, tipo_demanda, data_gerada, natureza, municipio,
--   endereco, fracao_responsavel, data_envio, data_vencimento, status_prazo,
--   data_atendimento, numero_gaia, numero_reds, resultado, status_atendimento,
--   info_complementares, numero_auto_infracao, equipe, viatura, anexos,
--   fonte_aba, raw }
-- REGRA de não-destruir baixa: campos de atendimento usam coalesce(existente, novo).
create or replace function public.emergencia_sync(linhas jsonb)
returns table (inseridas int, atualizadas int, total int)
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  v_codigo text;
  v_muni   text;
  v_gp     text;
  v_gpc    text;
  v_exists boolean;
  v_ins int := 0;
  v_upd int := 0;
begin
  if linhas is null or jsonb_typeof(linhas) <> 'array' then
    raise exception 'emergencia_sync: esperado um array JSON';
  end if;

  for r in select * from jsonb_array_elements(linhas)
  loop
    v_codigo := nullif(trim(r->>'codigo'), '');
    if v_codigo is null then continue; end if;

    v_muni := upper(trim(coalesce(r->>'municipio','')));
    v_gp := null; v_gpc := null;
    if v_muni <> '' then
      select gp_responsavel, grupamento_completo into v_gp, v_gpc
        from public.vw_municipio_grupamento
        where translate(municipio_upper,'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','AAAAAEEEEIIIIOOOOOUUUUC')
            = translate(v_muni,       'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','AAAAAEEEEIIIIOOOOOUUUUC')
        limit 1;
    end if;

    select true into v_exists from public.emergencia_demandas where codigo = v_codigo;

    insert into public.emergencia_demandas (
      codigo, tipo_demanda, data_gerada, natureza, municipio, endereco,
      fracao_responsavel, gp_responsavel, grupamento_completo,
      data_envio, data_vencimento, status_prazo,
      data_atendimento, numero_gaia, numero_reds, resultado, status_atendimento,
      info_complementares, numero_auto_infracao, equipe, viatura,
      anexos, fonte_aba, raw, synced_at, situacao
    ) values (
      v_codigo,
      nullif(r->>'tipo_demanda',''),
      nullif(r->>'data_gerada','')::date,
      nullif(r->>'natureza',''),
      nullif(r->>'municipio',''),
      nullif(r->>'endereco',''),
      nullif(r->>'fracao_responsavel',''),
      v_gp, coalesce(v_gpc, nullif(r->>'fracao_responsavel','')),
      nullif(r->>'data_envio','')::date,
      nullif(r->>'data_vencimento','')::date,
      nullif(r->>'status_prazo',''),
      nullif(r->>'data_atendimento','')::date,
      nullif(r->>'numero_gaia',''),
      nullif(r->>'numero_reds',''),
      nullif(r->>'resultado',''),
      nullif(r->>'status_atendimento',''),
      nullif(r->>'info_complementares',''),
      nullif(r->>'numero_auto_infracao',''),
      nullif(r->>'equipe',''),
      nullif(r->>'viatura',''),
      coalesce(r->'anexos','[]'::jsonb),
      nullif(r->>'fonte_aba',''),
      coalesce(r->'raw','{}'::jsonb),
      now(),
      case when nullif(r->>'data_atendimento','') is not null then 'RESPONDIDA' else 'PENDENTE' end
    )
    on conflict (codigo) do update set
      tipo_demanda = coalesce(excluded.tipo_demanda, public.emergencia_demandas.tipo_demanda),
      data_gerada  = coalesce(excluded.data_gerada,  public.emergencia_demandas.data_gerada),
      natureza     = coalesce(excluded.natureza,     public.emergencia_demandas.natureza),
      municipio    = coalesce(excluded.municipio,    public.emergencia_demandas.municipio),
      endereco     = coalesce(excluded.endereco,     public.emergencia_demandas.endereco),
      fracao_responsavel  = coalesce(excluded.fracao_responsavel,  public.emergencia_demandas.fracao_responsavel),
      gp_responsavel      = coalesce(excluded.gp_responsavel,      public.emergencia_demandas.gp_responsavel),
      grupamento_completo = coalesce(excluded.grupamento_completo, public.emergencia_demandas.grupamento_completo),
      data_envio      = coalesce(excluded.data_envio,      public.emergencia_demandas.data_envio),
      data_vencimento = coalesce(excluded.data_vencimento, public.emergencia_demandas.data_vencimento),
      status_prazo    = coalesce(excluded.status_prazo,    public.emergencia_demandas.status_prazo),
      data_atendimento   = coalesce(public.emergencia_demandas.data_atendimento,   excluded.data_atendimento),
      numero_gaia        = coalesce(public.emergencia_demandas.numero_gaia,        excluded.numero_gaia),
      numero_reds        = coalesce(public.emergencia_demandas.numero_reds,        excluded.numero_reds),
      resultado          = coalesce(public.emergencia_demandas.resultado,          excluded.resultado),
      status_atendimento = coalesce(public.emergencia_demandas.status_atendimento, excluded.status_atendimento),
      info_complementares = coalesce(excluded.info_complementares, public.emergencia_demandas.info_complementares),
      numero_auto_infracao = coalesce(public.emergencia_demandas.numero_auto_infracao, excluded.numero_auto_infracao),
      equipe  = coalesce(public.emergencia_demandas.equipe,  excluded.equipe),
      viatura = coalesce(public.emergencia_demandas.viatura, excluded.viatura),
      anexos = case when jsonb_array_length(coalesce(excluded.anexos,'[]'::jsonb)) > 0
                    then excluded.anexos else public.emergencia_demandas.anexos end,
      fonte_aba = coalesce(excluded.fonte_aba, public.emergencia_demandas.fonte_aba),
      raw       = excluded.raw,
      synced_at = now(),
      situacao = case
        when coalesce(public.emergencia_demandas.data_atendimento, excluded.data_atendimento) is not null
             and public.emergencia_demandas.situacao in ('PENDENTE','EM ANDAMENTO')
          then 'RESPONDIDA'
        else public.emergencia_demandas.situacao
      end;

    if coalesce(v_exists,false) then v_upd := v_upd + 1; else v_ins := v_ins + 1; end if;
    v_exists := null;
  end loop;

  return query select v_ins, v_upd, (v_ins + v_upd);
end;
$$;

-- ─── 3) BAIXA (atendimento, chamada pelo Relatório de Serviço) ─────────
-- p_dados: { codigo, data_atendimento, numero_reds, numero_gaia,
--   numero_auto_infracao, resultado, observacoes_resposta, equipe, viatura,
--   atendido_por_matricula, atendido_por_nome }
create or replace function public.emergencia_baixar(p_dados jsonb)
returns public.emergencia_demandas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_row public.emergencia_demandas;
begin
  if v_codigo is null then raise exception 'emergencia_baixar: código ausente'; end if;
  update public.emergencia_demandas set
    data_atendimento = coalesce(nullif(p_dados->>'data_atendimento','')::date, data_atendimento),
    numero_reds      = coalesce(nullif(p_dados->>'numero_reds',''),  numero_reds),
    numero_gaia      = coalesce(nullif(p_dados->>'numero_gaia',''),  numero_gaia),
    numero_auto_infracao = coalesce(nullif(p_dados->>'numero_auto_infracao',''), numero_auto_infracao),
    resultado        = coalesce(nullif(p_dados->>'resultado',''),    resultado),
    observacoes_resposta = coalesce(nullif(p_dados->>'observacoes_resposta',''), observacoes_resposta),
    equipe  = coalesce(nullif(p_dados->>'equipe',''),  equipe),
    viatura = coalesce(nullif(p_dados->>'viatura',''), viatura),
    atendido_por_matricula = coalesce(nullif(p_dados->>'atendido_por_matricula',''), atendido_por_matricula),
    atendido_por_nome      = coalesce(nullif(p_dados->>'atendido_por_nome',''),      atendido_por_nome),
    situacao = 'RESPONDIDA'
  where codigo = v_codigo
  returning * into v_row;
  if v_row.id is null then raise exception 'emergencia_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end;
$$;

-- ─── 4) SEGURANÇA (RLS) — mesmo padrão de db/01 ────────────────────────
alter table public.emergencia_demandas enable row level security;

drop policy if exists emerg_select_anon on public.emergencia_demandas;
create policy emerg_select_anon on public.emergencia_demandas
  for select to anon using (true);

drop policy if exists emerg_update_anon on public.emergencia_demandas;
create policy emerg_update_anon on public.emergencia_demandas
  for update to anon using (true) with check (true);

grant execute on function public.emergencia_sync(jsonb)   to anon;
grant execute on function public.emergencia_baixar(jsonb) to anon;

-- ─── 5) BACKFILL do grupamento (idempotente) ──────────────────────────
update public.emergencia_demandas nd
   set gp_responsavel = v.gp_responsavel
  from public.vw_municipio_grupamento v
 where nd.gp_responsavel is null
   and nd.municipio is not null
   and translate(upper(trim(nd.municipio)),'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','AAAAAEEEEIIIIOOOOOUUUUC')
     = translate(v.municipio_upper,        'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','AAAAAEEEEIIIIOOOOOUUUUC');

-- ─── Teste rápido: ─────────────────────────────────────────────────────
-- select * from public.emergencia_sync('[{"codigo":"999/2026","municipio":"SAO GONCALO DO RIO ABAIXO",
--   "natureza":"TRANSPORTE RODOVIARIO","tipo_demanda":"EMERGÊNCIA","data_gerada":"2026-01-10",
--   "data_vencimento":"2026-01-14","info_complementares":"CARVÃO VEGETAL","fonte_aba":"painel"}]'::jsonb);
-- select codigo, municipio, gp_responsavel, situacao, data_vencimento from public.emergencia_demandas;

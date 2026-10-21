-- ══════════════════════════════════════════════════════════════════════
--  MÓDULO NUDEN (Controle de Demandas) — 3ª Cia PM MAmb
--  Rodar no Supabase (SQL Editor). Idempotente: pode rodar mais de uma vez.
--
--  Demandas da NUDEN/SEMAD importadas da planilha "NUDEN - 3ª CIA MAMB"
--  (2 abas) por um Apps Script agendado → UPSERT por CÓDIGO DEMANDA.
--  A BAIXA (atendimento) acontece no painel, pelo Relatório de Serviço.
--  GAIA == Ato de Fiscalização (mesmo número).  Prazo NUDEN = 85 dias.
--
--  Segue o padrão de db/01_denuncias.sql: RLS anon (select/update using(true)),
--  escrita só via função security definer, escopo validado no app.
--  Depende de: public.vw_municipio_grupamento (db/00) para resolver o
--  grupamento do painel a partir do município (p/ o filtro de escopo).
--  DDU virá em tabela irmã (ddu_demandas), mesma engrenagem.
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) TABELA ─────────────────────────────────────────────────────────
create table if not exists public.nuden_demandas (
  id            uuid primary key default gen_random_uuid(),

  -- chave da planilha (dedupe entre as 2 abas): CÓDIGO DEMANDA == Nº DADOC/SENHA
  codigo        text not null,                 -- ex: 'D148683'
  tipo_demanda  text,                          -- planilha col A: 'DENÚNCIA' / 'REQUISIÇÃO'

  -- conteúdo / localização (fonte da verdade = planilha)
  data_gerada   date,
  natureza      text,                          -- natureza da infração / tipo infração
  municipio     text,
  endereco      text,
  fracao_responsavel  text,                    -- raw da planilha: '4 GP / 2 PEL / 3 CIA PM MAMB'

  -- grupamento resolvido (p/ o filtro de escopo do painel) — best effort pelo município
  gp_responsavel      text,                    -- chave curta: 'GP GOVERNADOR VALADARES'
  grupamento_completo text,

  -- prazos
  data_envio        date,                      -- envio à fração / enviado ao grupamento
  data_vencimento   date,                      -- vencimento (gerada/enviada + ~85d)
  status_prazo      text,                      -- planilha robô col K: 'EM ATRASO', etc. (rótulo de prazo)

  -- atendimento (espelha o relatório; preenchido pela BAIXA no painel ou pelo robô)
  data_atendimento  date,
  numero_gaia       text,                      -- Nº GAIA == Nº Ato de Fiscalização
  numero_reds       text,
  resultado         text,                      -- CONSTATADO / NÃO CONSTATADO / ...
  status_atendimento text,                     -- STATUS DO ATENDIMENTO (planilha)
  info_complementares text,

  -- anexos no Google Drive (PDF da denúncia): [{ file_id, nome, web_view_link, ... }]
  anexos        jsonb not null default '[]'::jsonb,

  -- workflow unificado (pendente = ainda não respondida)
  situacao      text not null default 'PENDENTE'
                  check (situacao in ('PENDENTE','EM ANDAMENTO','RESPONDIDA','DEVOLVIDA','FINALIZADA','INATIVADA')),

  -- baixa feita no painel
  atendido_por_matricula text,
  atendido_por_nome      text,
  observacoes_resposta   text,

  -- proveniência / sync
  fonte_aba     text,                          -- 'robo' (NUDEN_3_CIA) | 'manual' (NUDEN_03CIAMAMB)
  raw           jsonb not null default '{}'::jsonb,   -- linha original da planilha (segurança)
  versao        int  not null default 1,       -- optimistic lock (p/ Fase 2: anotações/devolução)
  synced_at     timestamptz,

  -- inativação (só Admin Geral)
  ativo         boolean not null default true,
  inativado_por_matricula text,
  inativado_por_nome      text,
  motivo_inativacao       text,
  inativado_em            timestamptz,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create unique index if not exists uq_nuden_codigo    on public.nuden_demandas (codigo);
create index if not exists idx_nuden_gp              on public.nuden_demandas (gp_responsavel);
create index if not exists idx_nuden_situacao        on public.nuden_demandas (situacao);
create index if not exists idx_nuden_municipio       on public.nuden_demandas (municipio);
create index if not exists idx_nuden_venc            on public.nuden_demandas (data_vencimento);

-- mantém updated_at em dia (reusa a função de db/01)
drop trigger if exists trg_nuden_touch on public.nuden_demandas;
create trigger trg_nuden_touch before update on public.nuden_demandas
  for each row execute function public.tg_touch_updated_at();

-- ─── 2) SYNC (UPSERT em lote, vindo do Apps Script) ────────────────────
-- Recebe um array JSON de linhas já normalizadas e deduplicadas por código
-- (o Apps Script prefere a aba robô quando o código existe nas duas).
-- Cada linha: { codigo, tipo_demanda, data_gerada, natureza, municipio,
--   endereco, fracao_responsavel, data_envio, data_vencimento, status_prazo,
--   data_atendimento, numero_gaia, numero_reds, resultado, status_atendimento,
--   info_complementares, fonte_aba, raw }
-- REGRA de não-destruir baixa: campos de atendimento usam coalesce(existente, novo)
-- — a baixa feita no painel nunca é apagada por um valor vazio da planilha.
create or replace function public.nuden_sync(linhas jsonb)
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
    raise exception 'nuden_sync: esperado um array JSON';
  end if;

  for r in select * from jsonb_array_elements(linhas)
  loop
    v_codigo := nullif(trim(r->>'codigo'), '');
    if v_codigo is null then continue; end if;   -- ignora linhas sem código

    -- resolve grupamento do painel pelo município (best effort; p/ o filtro de escopo)
    v_muni := upper(trim(coalesce(r->>'municipio','')));
    v_gp := null; v_gpc := null;
    if v_muni <> '' then
      select gp_responsavel, grupamento_completo into v_gp, v_gpc
        from public.vw_municipio_grupamento
        where municipio_upper = v_muni
        limit 1;
    end if;

    select true into v_exists from public.nuden_demandas where codigo = v_codigo;

    insert into public.nuden_demandas (
      codigo, tipo_demanda, data_gerada, natureza, municipio, endereco,
      fracao_responsavel, gp_responsavel, grupamento_completo,
      data_envio, data_vencimento, status_prazo,
      data_atendimento, numero_gaia, numero_reds, resultado, status_atendimento,
      info_complementares, anexos, fonte_aba, raw, synced_at, situacao
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
      coalesce(r->'anexos','[]'::jsonb),
      nullif(r->>'fonte_aba',''),
      coalesce(r->'raw','{}'::jsonb),
      now(),
      case when nullif(r->>'data_atendimento','') is not null then 'RESPONDIDA' else 'PENDENTE' end
    )
    on conflict (codigo) do update set
      tipo_demanda = coalesce(excluded.tipo_demanda, public.nuden_demandas.tipo_demanda),
      data_gerada  = coalesce(excluded.data_gerada,  public.nuden_demandas.data_gerada),
      natureza     = coalesce(excluded.natureza,     public.nuden_demandas.natureza),
      municipio    = coalesce(excluded.municipio,    public.nuden_demandas.municipio),
      endereco     = coalesce(excluded.endereco,     public.nuden_demandas.endereco),
      fracao_responsavel  = coalesce(excluded.fracao_responsavel,  public.nuden_demandas.fracao_responsavel),
      gp_responsavel      = coalesce(excluded.gp_responsavel,      public.nuden_demandas.gp_responsavel),
      grupamento_completo = coalesce(excluded.grupamento_completo, public.nuden_demandas.grupamento_completo),
      data_envio      = coalesce(excluded.data_envio,      public.nuden_demandas.data_envio),
      data_vencimento = coalesce(excluded.data_vencimento, public.nuden_demandas.data_vencimento),
      status_prazo    = coalesce(excluded.status_prazo,    public.nuden_demandas.status_prazo),
      -- atendimento: NÃO apaga baixa do painel com vazio da planilha
      data_atendimento   = coalesce(public.nuden_demandas.data_atendimento,   excluded.data_atendimento),
      numero_gaia        = coalesce(public.nuden_demandas.numero_gaia,        excluded.numero_gaia),
      numero_reds        = coalesce(public.nuden_demandas.numero_reds,        excluded.numero_reds),
      resultado          = coalesce(public.nuden_demandas.resultado,          excluded.resultado),
      status_atendimento = coalesce(public.nuden_demandas.status_atendimento, excluded.status_atendimento),
      info_complementares = coalesce(excluded.info_complementares, public.nuden_demandas.info_complementares),
      -- anexos: só substitui quando o sync trouxe PDF (não apaga o que já havia)
      anexos = case when jsonb_array_length(coalesce(excluded.anexos,'[]'::jsonb)) > 0
                    then excluded.anexos else public.nuden_demandas.anexos end,
      fonte_aba = coalesce(excluded.fonte_aba, public.nuden_demandas.fonte_aba),
      raw       = excluded.raw,
      synced_at = now(),
      -- situação reflete o atendimento, mas nunca rebaixa um estado de workflow
      -- do painel (DEVOLVIDA/FINALIZADA/INATIVADA ficam intactos — Fase 2).
      situacao = case
        when coalesce(public.nuden_demandas.data_atendimento, excluded.data_atendimento) is not null
             and public.nuden_demandas.situacao in ('PENDENTE','EM ANDAMENTO')
          then 'RESPONDIDA'
        else public.nuden_demandas.situacao
      end;

    if coalesce(v_exists,false) then v_upd := v_upd + 1; else v_ins := v_ins + 1; end if;
    v_exists := null;
  end loop;

  return query select v_ins, v_upd, (v_ins + v_upd);
end;
$$;

-- ─── 3) BAIXA (atendimento, chamada pelo Relatório de Serviço) ─────────
-- Fecha o loop com o Relatório, como balcão/requisição. GAIA == Ato de Fisc.
-- p_dados: { codigo, data_atendimento, numero_reds, numero_gaia, resultado,
--            observacoes_resposta, atendido_por_matricula, atendido_por_nome }
create or replace function public.nuden_baixar(p_dados jsonb)
returns public.nuden_demandas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_row public.nuden_demandas;
begin
  if v_codigo is null then raise exception 'nuden_baixar: código ausente'; end if;

  update public.nuden_demandas set
    data_atendimento = coalesce(nullif(p_dados->>'data_atendimento','')::date, data_atendimento),
    numero_reds      = coalesce(nullif(p_dados->>'numero_reds',''),  numero_reds),
    numero_gaia      = coalesce(nullif(p_dados->>'numero_gaia',''),  numero_gaia),
    resultado        = coalesce(nullif(p_dados->>'resultado',''),    resultado),
    observacoes_resposta = coalesce(nullif(p_dados->>'observacoes_resposta',''), observacoes_resposta),
    atendido_por_matricula = coalesce(nullif(p_dados->>'atendido_por_matricula',''), atendido_por_matricula),
    atendido_por_nome      = coalesce(nullif(p_dados->>'atendido_por_nome',''),      atendido_por_nome),
    situacao = 'RESPONDIDA'
  where codigo = v_codigo
  returning * into v_row;

  if v_row.id is null then raise exception 'nuden_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end;
$$;

-- ─── 4) SEGURANÇA (RLS) — mesmo padrão de db/01 ────────────────────────
alter table public.nuden_demandas enable row level security;

drop policy if exists nuden_select_anon on public.nuden_demandas;
create policy nuden_select_anon on public.nuden_demandas
  for select to anon using (true);

drop policy if exists nuden_update_anon on public.nuden_demandas;
create policy nuden_update_anon on public.nuden_demandas
  for update to anon using (true) with check (true);

grant execute on function public.nuden_sync(jsonb)   to anon;
grant execute on function public.nuden_baixar(jsonb) to anon;

-- ─── Teste rápido: ─────────────────────────────────────────────────────
-- select * from public.nuden_sync('[{"codigo":"D000001","municipio":"GOVERNADOR VALADARES",
--   "natureza":"Flora","fracao_responsavel":"1 GP / 1 PEL / 3 CIA PM MAMB",
--   "data_gerada":"2026-10-01","data_envio":"2026-10-02","data_vencimento":"2026-12-26",
--   "status_prazo":"NO PRAZO","fonte_aba":"robo"}]'::jsonb);
-- select codigo, municipio, gp_responsavel, situacao, status_prazo from public.nuden_demandas;

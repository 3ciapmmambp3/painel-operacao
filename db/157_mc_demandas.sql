-- ══════════════════════════════════════════════════════════════════════
--  MÓDULO MONITORAMENTO CONTÍNUO (MC)
--  Controle de Demandas — 3ª Cia PM MAmb
--  Rodar no Supabase (SQL Editor). Idempotente: pode rodar mais de uma vez.
--
--  Fluxo DIFERENTE das demais demandas: a carga de um LOTE NOVO entra pelo
--  próprio painel (botão "Carregar lote"). O painel lê a planilha batch da
--  SEMAD (CIA_PM_X.xlsx) + o KML mestre, gera UM KML por GEOCOD e manda ao
--  Apps Script, que grava os KML no Drive, escreve as linhas na aba MC
--  (planilha 195fFn…) e dispara o sync → esta tabela. O PDF do croqui e o
--  KML são casados por prefixo GEOCOD no Drive.  Chave = GEOCOD_IEF.
--  Prazo = 45 dias (vence = recebimento + 45d).  Gestão = Aux P3 + Admin.
--
--  Espelha a engrenagem de public.ri_demandas (db/154): RLS anon
--  (select/update using(true)), escrita só via função security definer,
--  escopo validado no app.  Campos próprios do MC adicionados ao final do
--  bloco de conteúdo (hectares, datas da cena, coords, regional, bioma,
--  lote, id_semad, id_evolucao, kml_link).
--  Depende de: public.vw_municipio_grupamento (resolve o grupamento a
--  partir do município — usado no filtro de escopo do painel).
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) TABELA ─────────────────────────────────────────────────────────
create table if not exists public.mc_demandas (
  id            uuid primary key default gen_random_uuid(),

  -- chave da planilha/KML/PDF: GEOCOD_IEF
  codigo        text not null,                 -- ex: '13055579'
  tipo_demanda  text,                           -- rótulo livre (default 'MC')

  -- conteúdo / localização (fonte da verdade = planilha batch/aba MC)
  data_gerada   date,                           -- DATA GERADA (cena final) / recebido
  natureza      text,                           -- descrição livre (ex: bioma/área)
  municipio     text,
  endereco      text,                           -- regional / referência
  fracao_responsavel  text,                     -- raw: 'GP ...'

  -- grupamento resolvido (p/ o filtro de escopo do painel) — best effort
  gp_responsavel      text,
  grupamento_completo text,

  -- prazos
  data_envio        date,                       -- DATA ENVIADO PARA O GRUPAMENTO
  data_vencimento   date,                       -- EXPIRAÇÃO (recebimento + 45d)
  status_prazo      text,                        -- SITUAÇÃO (rótulo de prazo)

  -- atendimento (espelha o relatório; preenchido pela BAIXA no painel ou robô)
  data_atendimento  date,                        -- DATA RESPOSTA / FISCALIZAÇÃO
  numero_gaia       text,                        -- ID SISFIS / ato de fiscalização
  numero_reds       text,
  resultado         text,
  status_atendimento text,                        -- STATUS da planilha
  info_complementares text,                       -- observações
  numero_auto_infracao text,
  equipe            text,
  viatura           text,

  -- ─── campos próprios do MC ──────────────────────────────────────────
  hectares      numeric,                         -- área desmatada (ha)
  data_inic     date,                            -- DATA_INIC da cena
  data_final    date,                            -- DATA_FINAL da cena (detecção)
  mes_ref       text,                            -- MES_REF
  ano_ref       text,                            -- ANO_REF
  coord_x       text,                            -- X (longitude)
  coord_y       text,                            -- Y (latitude)
  regional      text,                            -- REGIONAL / NUFIS
  bioma         text,                            -- BIOMA_IBGE
  id_semad      text,                            -- ID (SEMAD) da planilha batch
  id_evolucao   text,                            -- ID_EVOLUCAO
  lote          text,                            -- nome da pasta/lote (ex: '3 CIA 2026-10-20')
  kml_link      text,                            -- link do KML individual (Drive), se houver
  kml_content   text,                            -- KML individual do GEOCOD (baixado no painel)

  -- anexos no Google Drive (PDF do croqui): [{ tipo, nome, web_view_link, ... }]
  anexos        jsonb not null default '[]'::jsonb,

  -- workflow unificado (pendente = ainda não respondida)
  situacao      text not null default 'PENDENTE'
                  check (situacao in ('PENDENTE','EM ANDAMENTO','RESPONDIDA','DEVOLVIDA','FINALIZADA','INATIVADA')),

  -- baixa feita no painel
  atendido_por_matricula text,
  atendido_por_nome      text,
  observacoes_resposta   text,

  -- proveniência / sync
  fonte_aba     text,                            -- 'manual' (planilha) | 'painel' (lote carregado no painel)
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

create unique index if not exists uq_mc_codigo    on public.mc_demandas (codigo);
create index if not exists idx_mc_gp              on public.mc_demandas (gp_responsavel);
create index if not exists idx_mc_situacao        on public.mc_demandas (situacao);
create index if not exists idx_mc_municipio       on public.mc_demandas (municipio);
create index if not exists idx_mc_venc            on public.mc_demandas (data_vencimento);
create index if not exists idx_mc_lote            on public.mc_demandas (lote);

drop trigger if exists trg_mc_touch on public.mc_demandas;
create trigger trg_mc_touch before update on public.mc_demandas
  for each row execute function public.tg_touch_updated_at();

-- ─── 2) SYNC (UPSERT em lote, vindo do Apps Script / carga de lote) ─────
-- Cada linha: { codigo, tipo_demanda, data_gerada, natureza, municipio,
--   endereco, fracao_responsavel, data_envio, data_vencimento, status_prazo,
--   data_atendimento, numero_gaia, numero_reds, resultado, status_atendimento,
--   info_complementares, numero_auto_infracao, equipe, viatura,
--   hectares, data_inic, data_final, mes_ref, ano_ref, coord_x, coord_y,
--   regional, bioma, id_semad, id_evolucao, lote, kml_link, anexos,
--   fonte_aba, raw }
-- REGRA de não-destruir baixa: campos de atendimento usam coalesce(existente, novo).
create or replace function public.mc_sync(linhas jsonb)
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
    raise exception 'mc_sync: esperado um array JSON';
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

    select true into v_exists from public.mc_demandas where codigo = v_codigo;

    insert into public.mc_demandas (
      codigo, tipo_demanda, data_gerada, natureza, municipio, endereco,
      fracao_responsavel, gp_responsavel, grupamento_completo,
      data_envio, data_vencimento, status_prazo,
      data_atendimento, numero_gaia, numero_reds, resultado, status_atendimento,
      info_complementares, numero_auto_infracao, equipe, viatura,
      hectares, data_inic, data_final, mes_ref, ano_ref, coord_x, coord_y,
      regional, bioma, id_semad, id_evolucao, lote, kml_link, kml_content,
      anexos, fonte_aba, raw, synced_at, situacao
    ) values (
      v_codigo,
      coalesce(nullif(r->>'tipo_demanda',''),'MC'),
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
      nullif(r->>'hectares','')::numeric,
      nullif(r->>'data_inic','')::date,
      nullif(r->>'data_final','')::date,
      nullif(r->>'mes_ref',''),
      nullif(r->>'ano_ref',''),
      nullif(r->>'coord_x',''),
      nullif(r->>'coord_y',''),
      nullif(r->>'regional',''),
      nullif(r->>'bioma',''),
      nullif(r->>'id_semad',''),
      nullif(r->>'id_evolucao',''),
      nullif(r->>'lote',''),
      nullif(r->>'kml_link',''),
      nullif(r->>'kml_content',''),
      coalesce(r->'anexos','[]'::jsonb),
      nullif(r->>'fonte_aba',''),
      coalesce(r->'raw','{}'::jsonb),
      now(),
      case when nullif(r->>'data_atendimento','') is not null then 'RESPONDIDA' else 'PENDENTE' end
    )
    on conflict (codigo) do update set
      tipo_demanda = coalesce(excluded.tipo_demanda, public.mc_demandas.tipo_demanda),
      data_gerada  = coalesce(excluded.data_gerada,  public.mc_demandas.data_gerada),
      natureza     = coalesce(excluded.natureza,     public.mc_demandas.natureza),
      municipio    = coalesce(excluded.municipio,    public.mc_demandas.municipio),
      endereco     = coalesce(excluded.endereco,     public.mc_demandas.endereco),
      fracao_responsavel  = coalesce(excluded.fracao_responsavel,  public.mc_demandas.fracao_responsavel),
      gp_responsavel      = coalesce(excluded.gp_responsavel,      public.mc_demandas.gp_responsavel),
      grupamento_completo = coalesce(excluded.grupamento_completo, public.mc_demandas.grupamento_completo),
      data_envio      = coalesce(excluded.data_envio,      public.mc_demandas.data_envio),
      data_vencimento = coalesce(excluded.data_vencimento, public.mc_demandas.data_vencimento),
      status_prazo    = coalesce(excluded.status_prazo,    public.mc_demandas.status_prazo),
      data_atendimento   = coalesce(public.mc_demandas.data_atendimento,   excluded.data_atendimento),
      numero_gaia        = coalesce(public.mc_demandas.numero_gaia,        excluded.numero_gaia),
      numero_reds        = coalesce(public.mc_demandas.numero_reds,        excluded.numero_reds),
      resultado          = coalesce(public.mc_demandas.resultado,          excluded.resultado),
      status_atendimento = coalesce(public.mc_demandas.status_atendimento, excluded.status_atendimento),
      info_complementares = coalesce(excluded.info_complementares, public.mc_demandas.info_complementares),
      numero_auto_infracao = coalesce(public.mc_demandas.numero_auto_infracao, excluded.numero_auto_infracao),
      equipe  = coalesce(public.mc_demandas.equipe,  excluded.equipe),
      viatura = coalesce(public.mc_demandas.viatura, excluded.viatura),
      hectares    = coalesce(excluded.hectares,    public.mc_demandas.hectares),
      data_inic   = coalesce(excluded.data_inic,   public.mc_demandas.data_inic),
      data_final  = coalesce(excluded.data_final,  public.mc_demandas.data_final),
      mes_ref     = coalesce(excluded.mes_ref,     public.mc_demandas.mes_ref),
      ano_ref     = coalesce(excluded.ano_ref,     public.mc_demandas.ano_ref),
      coord_x     = coalesce(excluded.coord_x,     public.mc_demandas.coord_x),
      coord_y     = coalesce(excluded.coord_y,     public.mc_demandas.coord_y),
      regional    = coalesce(excluded.regional,    public.mc_demandas.regional),
      bioma       = coalesce(excluded.bioma,       public.mc_demandas.bioma),
      id_semad    = coalesce(excluded.id_semad,    public.mc_demandas.id_semad),
      id_evolucao = coalesce(excluded.id_evolucao, public.mc_demandas.id_evolucao),
      lote        = coalesce(excluded.lote,        public.mc_demandas.lote),
      kml_link    = coalesce(excluded.kml_link,    public.mc_demandas.kml_link),
      kml_content = coalesce(excluded.kml_content, public.mc_demandas.kml_content),
      anexos = case when jsonb_array_length(coalesce(excluded.anexos,'[]'::jsonb)) > 0
                    then excluded.anexos else public.mc_demandas.anexos end,
      fonte_aba = coalesce(excluded.fonte_aba, public.mc_demandas.fonte_aba),
      raw       = excluded.raw,
      synced_at = now(),
      situacao = case
        when coalesce(public.mc_demandas.data_atendimento, excluded.data_atendimento) is not null
             and public.mc_demandas.situacao in ('PENDENTE','EM ANDAMENTO')
          then 'RESPONDIDA'
        else public.mc_demandas.situacao
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
create or replace function public.mc_baixar(p_dados jsonb)
returns public.mc_demandas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text := nullif(trim(p_dados->>'codigo'), '');
  v_row public.mc_demandas;
begin
  if v_codigo is null then raise exception 'mc_baixar: código ausente'; end if;
  update public.mc_demandas set
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
  if v_row.id is null then raise exception 'mc_baixar: código % não encontrado', v_codigo; end if;
  return v_row;
end;
$$;

-- ─── 4) SEGURANÇA (RLS) — mesmo padrão de db/01 ────────────────────────
alter table public.mc_demandas enable row level security;

drop policy if exists mc_select_anon on public.mc_demandas;
create policy mc_select_anon on public.mc_demandas
  for select to anon using (true);

drop policy if exists mc_update_anon on public.mc_demandas;
create policy mc_update_anon on public.mc_demandas
  for update to anon using (true) with check (true);

grant execute on function public.mc_sync(jsonb)   to anon;
grant execute on function public.mc_baixar(jsonb) to anon;

-- ─── 5) BACKFILL do grupamento (idempotente) ──────────────────────────
update public.mc_demandas nd
   set gp_responsavel = v.gp_responsavel
  from public.vw_municipio_grupamento v
 where nd.gp_responsavel is null
   and nd.municipio is not null
   and translate(upper(trim(nd.municipio)),'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','AAAAAEEEEIIIIOOOOOUUUUC')
     = translate(v.municipio_upper,        'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','AAAAAEEEEIIIIOOOOOUUUUC');

-- ─── Teste rápido: ─────────────────────────────────────────────────────
-- select * from public.mc_sync('[{"codigo":"13055579","municipio":"BARRA LONGA",
--   "tipo_demanda":"MC","data_gerada":"2026-10-20","data_vencimento":"2026-12-04",
--   "hectares":"1.98","bioma":"MATA ATLANTICA","lote":"3 CIA 2026-10-20",
--   "fonte_aba":"painel"}]'::jsonb);
-- select codigo, municipio, gp_responsavel, situacao, data_vencimento, hectares from public.mc_demandas;

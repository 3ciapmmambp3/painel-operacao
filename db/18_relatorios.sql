-- ════════════════════════════════════════════════════════════════════════
-- 18_relatorios.sql — Relatório de Serviço no Supabase (FASE 1: escrita)
--
-- Migração incremental do Relatório de Serviço (hoje no Apps Script/planilha)
-- para o Supabase como FONTE. Nesta fase, o painel GRAVA aqui e CONTINUA
-- mandando para o Apps Script (que espelha na planilha) — "escrita dupla".
-- Nenhuma leitura muda ainda (Meus Relatórios/edição seguem lendo da planilha).
--
-- Modelo:
--   • relatorios       — 1 linha por relatório (Bloco 1 em colunas + bloco1 jsonb cru).
--   • relatorio_itens  — 1 linha por item de categoria: {categoria, nr_item, dados jsonb}.
--                        Genérico: Operação (com quesitos), Produtividade, NUDEN,
--                        DDU, PAF, FAPI, CEMIG, TCO, SEMAD, Recursos, Equipe de Apoio…
--
-- (Auditoria/histórico e itens "consumíveis"/TCO-SEMAD entram em fases seguintes.)
--
-- Depende de: 04_sessoes_e_militares_seguranca.sql (_sessao_militar).
-- Idempotente. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.relatorios (
  id                    uuid primary key default gen_random_uuid(),
  sheet_id              text,                 -- id do relatório na planilha (REL-…), quando conhecido
  -- Bloco 1 (colunas p/ consulta) --------------------------------------
  fracao_atuacao        text,
  data                  date,
  inicio_turno          text,
  fim_turno             text,
  comandante            text,
  motorista             text,
  patrulheiros          text,
  equipe                text,
  tipo_servico          text,
  houve_apoio           text,
  total_militares       int,
  total_viaturas        int,
  observacoes           text,
  enviado_por           text,
  bloco1                jsonb not null default '{}'::jsonb,   -- Bloco 1 cru (todas as chaves)
  -- auditoria ----------------------------------------------------------
  criado_por_matricula  text,
  criado_por_nome       text,
  ano                   int,
  mes                   int,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),
  ativo                 boolean not null default true
);
create index if not exists idx_rel_data      on public.relatorios (data);
create index if not exists idx_rel_fracao    on public.relatorios (fracao_atuacao);
create index if not exists idx_rel_anomes    on public.relatorios (ano, mes);
create index if not exists idx_rel_criadopor on public.relatorios (criado_por_matricula);
create index if not exists idx_rel_sheet     on public.relatorios (sheet_id);

create table if not exists public.relatorio_itens (
  id            uuid primary key default gen_random_uuid(),
  relatorio_id  uuid not null references public.relatorios(id) on delete cascade,
  categoria     text not null,        -- rótulo como no site: 'Operação','Produtividade','NUDEN'…
  nr_item       int not null default 1,
  dados         jsonb not null default '{}'::jsonb,   -- o objeto `campos` (label -> valor)
  criado_em     timestamptz not null default now()
);
create index if not exists idx_relitem_rel  on public.relatorio_itens (relatorio_id);
create index if not exists idx_relitem_cat  on public.relatorio_itens (categoria);

-- ── RPC: gravar/atualizar um relatório (exige sessão) ────────────────────
-- p_dados = { modo:'criar'|'atualizar', id?(uuid), sheet_id?, bloco1:{…},
--             categorias:[ {categoria, itens:[ {campos…} ]} ] }
create or replace function public.relatorio_salvar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_id    uuid;
  v_modo  text := coalesce(p_dados->>'modo','criar');
  v_b     jsonb := coalesce(p_dados->'bloco1','{}'::jsonb);
  v_data  date  := nullif(v_b->>'Data','')::date;
  v_cat   jsonb;
  v_item  jsonb;
  v_n     int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;

  if v_modo = 'atualizar' then
    v_id := nullif(p_dados->>'id','')::uuid;
    if v_id is null then raise exception 'id do relatório não informado para atualização.'; end if;
    update public.relatorios set
      sheet_id = coalesce(nullif(p_dados->>'sheet_id',''), sheet_id),
      fracao_atuacao=v_b->>'Fração de Atuação', data=v_data,
      inicio_turno=v_b->>'Início do Turno', fim_turno=v_b->>'Fim do Turno',
      comandante=v_b->>'Comandante', motorista=v_b->>'Motorista',
      patrulheiros=v_b->>'Patrulheiro(s)', equipe=v_b->>'Equipe',
      tipo_servico=v_b->>'Tipo de Serviço', houve_apoio=v_b->>'Houve Equipe de Apoio?',
      total_militares=nullif(v_b->>'Total de Militares (Geral)','')::int,
      total_viaturas=nullif(v_b->>'Total de Viaturas (Geral)','')::int,
      observacoes=v_b->>'Observações Gerais do Relatório', enviado_por=v_b->>'Enviado por',
      bloco1=v_b,
      ano=extract(year from coalesce(v_data, current_date))::int,
      mes=extract(month from coalesce(v_data, current_date))::int,
      atualizado_em=now()
    where id = v_id and ativo = true;
    if not found then raise exception 'Relatório não encontrado (id %).', v_id; end if;
    delete from public.relatorio_itens where relatorio_id = v_id;   -- apaga e regrava os itens
  else
    insert into public.relatorios (
      sheet_id, fracao_atuacao, data, inicio_turno, fim_turno, comandante, motorista,
      patrulheiros, equipe, tipo_servico, houve_apoio, total_militares, total_viaturas,
      observacoes, enviado_por, bloco1, criado_por_matricula, criado_por_nome, ano, mes
    ) values (
      nullif(p_dados->>'sheet_id',''), v_b->>'Fração de Atuação', v_data,
      v_b->>'Início do Turno', v_b->>'Fim do Turno', v_b->>'Comandante', v_b->>'Motorista',
      v_b->>'Patrulheiro(s)', v_b->>'Equipe', v_b->>'Tipo de Serviço', v_b->>'Houve Equipe de Apoio?',
      nullif(v_b->>'Total de Militares (Geral)','')::int, nullif(v_b->>'Total de Viaturas (Geral)','')::int,
      v_b->>'Observações Gerais do Relatório', v_b->>'Enviado por', v_b,
      v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo),
      extract(year from coalesce(v_data, current_date))::int,
      extract(month from coalesce(v_data, current_date))::int
    ) returning id into v_id;
  end if;

  -- itens de cada categoria
  for v_cat in select * from jsonb_array_elements(coalesce(p_dados->'categorias','[]'::jsonb)) loop
    v_n := 0;
    for v_item in select * from jsonb_array_elements(coalesce(v_cat->'itens','[]'::jsonb)) loop
      v_n := v_n + 1;
      insert into public.relatorio_itens (relatorio_id, categoria, nr_item, dados)
      values (v_id, v_cat->>'categoria', v_n, v_item);
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'id', v_id, 'modo', v_modo);
end;
$$;

-- ── RLS ─────────────────────────────────────────────────────────────────
alter table public.relatorios      enable row level security;
alter table public.relatorio_itens enable row level security;
drop policy if exists relatorios_sel on public.relatorios;
create policy relatorios_sel on public.relatorios for select using (true);
drop policy if exists relitem_sel on public.relatorio_itens;
create policy relitem_sel on public.relatorio_itens for select using (true);

grant execute on function public.relatorio_salvar(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 04. (FASE 1 — só escrita; leituras
-- e lógica com estado entram nas próximas fases.)
-- ════════════════════════════════════════════════════════════════════════

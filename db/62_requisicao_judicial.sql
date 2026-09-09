-- ══════════════════════════════════════════════════════════════════════
--  MÓDULO CONTROLE DE REQUISIÇÃO JUDICIAL — 3ª Cia PM MAmb (P1 / RH)
--  Substitui o Google Forms "Controle de Requisição Judicial".
--
--  Fluxo:
--    • QUALQUER militar logado preenche a requisição (criar_requisicao_judicial).
--    • O RESULTADO/controle só é visível para Aux P1, Admin Geral e CMT da Cia
--      (requisicao_judicial_listar / _controle_salvar validam o papel).
--    • O militar requisitado recebe AVISO no Meu Dia (de 15 dias antes até o
--      dia da audiência) — requisicao_judicial_avisos_get.
--
--  Depende de: 04 (_sessao_militar), 01 (contadores/proximo_numero),
--              44 (tta_listar_militares p/ o seletor de efetivo).
--  Idempotente. Rodar no SQL Editor.
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) TABELA ─────────────────────────────────────────────────────────
create table if not exists public.requisicoes_judiciais (
  id            uuid primary key default gen_random_uuid(),
  numero        text not null,                 -- 'RJ 001/2026'
  numero_seq    int  not null,
  ano           int  not null,

  -- ── preenchido no FORMULÁRIO (qualquer militar) ──
  data_audiencia date not null,
  horario        text,                          -- 'HH:MM'
  processo       text,                          -- Nº do processo
  documento_origem text,                        -- documento de origem
  tipo_envolvimento text,                       -- Testemunha / Autor(es) / Réu(s) / Outro
  tipo_envolvimento_outro text,
  municipio_lotacao   text,                     -- município de lotação do militar
  municipio_requisicao text,                    -- município da audiência
  local_audiencia text,                         -- Fórum / Vara / link, conforme o ofício
  endereco        text,                         -- endereço físico OU link da videoconferência
  metodo          text,                         -- 'Presencial' | 'Videoconferência'
  observacoes     text,

  -- militares requisitados: display (jsonb) + ids p/ casar no Meu Dia + extras livres
  militares       jsonb not null default '[]'::jsonb,  -- [{matricula,nome,pg,guerra,grupamento}]
  militares_ids   uuid[] not null default '{}',
  militares_extra text,                         -- nomes digitados à mão (fora do efetivo)

  -- anexo (requisição digitalizada) no Storage: array de {path,nome,tamanho,mime,link}
  anexos          jsonb not null default '[]'::jsonb,

  -- ── controle (P1). AUTORIDADE é derivada do LOCAL (auto); o PRAZO é
  --    calculado na tela a partir da data da audiência (não é coluna). ──
  situacao        text not null default 'PENDENTE'
                    check (situacao in ('PENDENTE','EM CONTROLE','CONCLUIDA')),
  autoridade_solicitante text,                   -- auto pelo local; Aux P1 pode ajustar
  num_grupamento  text,                          -- Nº do grupamento (Aux P1)
  cadastrada_intranet text,                      -- 'Sim' | 'Não' (Aux P1)
  data_cadastro   date,                          -- data do cadastro na intranet (Aux P1)
  observacoes_controle text,
  controlado_por_matricula text,
  controlado_por_nome      text,

  -- auditoria
  registrado_por_matricula text,
  registrado_por_nome      text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- colunas idempotentes (se a tabela já existir de um teste anterior)
alter table public.requisicoes_judiciais add column if not exists militares_ids uuid[] not null default '{}';
alter table public.requisicoes_judiciais add column if not exists militares_extra text;
alter table public.requisicoes_judiciais add column if not exists autoridade_solicitante text;
alter table public.requisicoes_judiciais add column if not exists num_grupamento text;
alter table public.requisicoes_judiciais add column if not exists cadastrada_intranet text;
alter table public.requisicoes_judiciais add column if not exists data_cadastro date;
alter table public.requisicoes_judiciais add column if not exists observacoes_controle text;
alter table public.requisicoes_judiciais add column if not exists controlado_por_matricula text;
alter table public.requisicoes_judiciais add column if not exists controlado_por_nome text;

create unique index if not exists uq_reqjud_num_ano on public.requisicoes_judiciais (ano, numero_seq);
create index if not exists idx_reqjud_data     on public.requisicoes_judiciais (data_audiencia);
create index if not exists idx_reqjud_situacao on public.requisicoes_judiciais (situacao);
create index if not exists idx_reqjud_created  on public.requisicoes_judiciais (created_at desc);
create index if not exists idx_reqjud_milids   on public.requisicoes_judiciais using gin (militares_ids);

drop trigger if exists trg_reqjud_touch on public.requisicoes_judiciais;
create trigger trg_reqjud_touch before update on public.requisicoes_judiciais
  for each row execute function public.tg_touch_updated_at();

-- ─── 2) HELPER: quem pode CONTROLAR (ver resultado / editar) ───────────
-- Aux P1  OU  Admin Geral  OU  CMT da Cia.
create or replace function public._reqjud_pode_controlar(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') = 'admin_geral'
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y');
$$;

-- HELPER: autoridade solicitante derivada do LOCAL DA AUDIÊNCIA (mesma lógica
-- da planilha). Local fora da tabela padrão → NULL (Aux P1 ajusta na tela).
create or replace function public._reqjud_autoridade(p_local text)
returns text language sql immutable as $$
  select case upper(btrim(coalesce(p_local,'')))
    when 'FÓRUM DA COMARCA'          then 'Juiz de Direito da Comarca'
    when 'FORUM DA COMARCA'          then 'Juiz de Direito da Comarca'
    when 'DELEGACIA DE POLÍCIA CIVIL' then 'Delegado de Polícia Civil'
    when 'DELEGACIA DE POLICIA CIVIL' then 'Delegado de Polícia Civil'
    when 'PROMOTORIA PÚBLICA'        then 'Promotor'
    when 'PROMOTORIA PUBLICA'        then 'Promotor'
    when 'JUSTIÇA FEDERAL'           then 'Juiz Federal'
    when 'JUSTICA FEDERAL'           then 'Juiz Federal'
    else null
  end;
$$;

-- ─── 3) CRIAR (qualquer militar logado) ────────────────────────────────
create or replace function public.criar_requisicao_judicial(p_token uuid, dados jsonb)
returns public.requisicoes_judiciais
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_ano  int := coalesce(nullif(dados->>'ano','')::int, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_seq  int;
  v_ids  uuid[] := coalesce(
            case when jsonb_typeof(dados->'militares_ids') = 'array'
              then array(select (jsonb_array_elements_text(dados->'militares_ids'))::uuid)
              else '{}'::uuid[] end, '{}'::uuid[]);
  v_row  public.requisicoes_judiciais;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if coalesce(nullif(dados->>'data_audiencia',''),'') = '' then
    raise exception 'Informe a data da audiência.';
  end if;

  v_seq := public.proximo_numero(v_ano, 'req_judicial');

  insert into public.requisicoes_judiciais (
    numero, numero_seq, ano,
    data_audiencia, horario, processo, documento_origem,
    tipo_envolvimento, tipo_envolvimento_outro,
    municipio_lotacao, municipio_requisicao, local_audiencia, endereco, metodo, observacoes,
    autoridade_solicitante,
    militares, militares_ids, militares_extra, anexos,
    registrado_por_matricula, registrado_por_nome
  ) values (
    'RJ ' || lpad(v_seq::text, 3, '0') || '/' || v_ano::text, v_seq, v_ano,
    (dados->>'data_audiencia')::date, nullif(dados->>'horario',''),
    nullif(dados->>'processo',''), nullif(dados->>'documento_origem',''),
    nullif(dados->>'tipo_envolvimento',''), nullif(dados->>'tipo_envolvimento_outro',''),
    nullif(dados->>'municipio_lotacao',''), nullif(dados->>'municipio_requisicao',''),
    nullif(dados->>'local_audiencia',''), nullif(dados->>'endereco',''),
    nullif(dados->>'metodo',''), nullif(dados->>'observacoes',''),
    public._reqjud_autoridade(dados->>'local_audiencia'),
    coalesce(dados->'militares','[]'::jsonb), v_ids, nullif(dados->>'militares_extra',''),
    coalesce(dados->'anexos','[]'::jsonb),
    v_me.matricula, coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo)
  ) returning * into v_row;

  return v_row;
end;
$$;

-- ─── 4) LISTAR (só Aux P1 / Admin Geral / CMT Cia) ─────────────────────
create or replace function public.requisicao_judicial_listar(p_token uuid)
returns setof public.requisicoes_judiciais
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._reqjud_pode_controlar(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Acesso restrito ao controle da P1.';
  end if;
  return query
    select * from public.requisicoes_judiciais
     order by data_audiencia desc, created_at desc;
end;
$$;

-- ─── 5) CONTROLE: Aux P1 grava as ações pós-envio ──────────────────────
create or replace function public.requisicao_judicial_controle_salvar(p_token uuid, p_id uuid, p_dados jsonb)
returns public.requisicoes_judiciais
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.requisicoes_judiciais;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._reqjud_pode_controlar(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Acesso restrito ao controle da P1.';
  end if;

  update public.requisicoes_judiciais set
    situacao               = coalesce(nullif(p_dados->>'situacao',''), situacao),
    autoridade_solicitante = case when p_dados ? 'autoridade_solicitante' then nullif(p_dados->>'autoridade_solicitante','') else autoridade_solicitante end,
    num_grupamento         = case when p_dados ? 'num_grupamento' then nullif(p_dados->>'num_grupamento','')       else num_grupamento end,
    cadastrada_intranet    = case when p_dados ? 'cadastrada_intranet' then nullif(p_dados->>'cadastrada_intranet','') else cadastrada_intranet end,
    data_cadastro          = case when p_dados ? 'data_cadastro'  then nullif(p_dados->>'data_cadastro','')::date  else data_cadastro  end,
    observacoes_controle   = case when p_dados ? 'observacoes_controle' then nullif(p_dados->>'observacoes_controle','') else observacoes_controle end,
    controlado_por_matricula = v_me.matricula,
    controlado_por_nome      = coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo)
  where id = p_id
  returning * into v_row;
  if v_row.id is null then raise exception 'Requisição não encontrada.'; end if;
  return v_row;
end;
$$;

-- ─── 6) EXCLUIR (só Admin Geral) ───────────────────────────────────────
create or replace function public.requisicao_judicial_excluir(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Exclusão restrita ao Admin Geral.';
  end if;
  delete from public.requisicoes_judiciais where id = p_id;
end;
$$;

-- ─── 7) AVISOS: audiências do militar logado (Meu Dia) ─────────────────
-- Janela: de 15 dias antes até o PRÓPRIO DIA da audiência. Some no dia seguinte.
-- Só para os militares que constam em militares_ids (selecionados do efetivo).
create or replace function public.requisicao_judicial_avisos_get(p_token uuid)
returns table (id uuid, numero text, data_audiencia date, horario text, metodo text,
               local_audiencia text, endereco text, processo text,
               tipo_envolvimento text, municipio_requisicao text)
language plpgsql security definer set search_path = public as $$
declare v_me record; v_hoje date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  v_hoje := (now() at time zone 'America/Sao_Paulo')::date;
  return query
    select r.id, r.numero, r.data_audiencia, r.horario, r.metodo,
           r.local_audiencia, r.endereco, r.processo,
           r.tipo_envolvimento, r.municipio_requisicao
    from public.requisicoes_judiciais r
    where v_me.id = any (r.militares_ids)
      and r.data_audiencia >= v_hoje
      and r.data_audiencia <= v_hoje + 15
    order by r.data_audiencia asc, r.horario asc;
end;
$$;

-- ─── 8) SEGURANÇA (RLS) ────────────────────────────────────────────────
-- Sem policy de SELECT/INSERT/UPDATE p/ anon: o acesso direto à tabela fica
-- BLOQUEADO. Tudo passa pelas funções security definer acima — assim o
-- RESULTADO só chega a quem pode controlar (Aux P1 / Admin Geral / CMT Cia),
-- e o aviso do Meu Dia só devolve as audiências do próprio militar.
alter table public.requisicoes_judiciais enable row level security;

grant execute on function public.criar_requisicao_judicial(uuid, jsonb)               to anon;
grant execute on function public.requisicao_judicial_listar(uuid)                     to anon;
grant execute on function public.requisicao_judicial_controle_salvar(uuid, uuid, jsonb) to anon;
grant execute on function public.requisicao_judicial_excluir(uuid, uuid)              to anon;
grant execute on function public.requisicao_judicial_avisos_get(uuid)                 to anon;
grant execute on function public._reqjud_pode_controlar(text, text)                   to anon;
grant execute on function public._reqjud_autoridade(text)                             to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 44. Reusa proximo_numero (db/01) e
-- tta_listar_militares (db/44). Não precisa re-rodar nenhum anterior.
-- ══════════════════════════════════════════════════════════════════════

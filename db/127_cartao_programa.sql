-- ════════════════════════════════════════════════════════════════════════
--  MÓDULO CARTÃO PROGRAMA — 3ª Cia PM MAmb   (db/127)
--
--  Traz o "Cartão Programa" (hoje em 2 Google Forms + planilha) para dentro
--  do painel, em Emprego Operacional (P3). Um cartão = uma EQUIPE em um TURNO
--  de uma DATA, com as demandas a atender. A equipe responde cada demanda
--  (REDS / Auto de Infração / Ato de Fiscalização / data / obs) — pelo próprio
--  cartão, pelo link público ou embutido no Relatório de Serviço.
--
--  Decisões de modelagem:
--   • demandas (emissão) e respostas (atendimento) ficam em COLUNAS jsonb
--     SEPARADAS, amarradas pela "ordem" da demanda. Assim o comandante pode
--     editar/!reordenar as demandas sem apagar o que a equipe já respondeu.
--   • anexos das demandas ficam no Google DRIVE (conta 3ciapmmamb.cartao),
--     não no Supabase — guardamos só o link (igual Ofícios/Requisição).
--   • numeração atômica por ANO via public.contadores (tipo 'cartao'),
--     mesmo mecanismo de criar_denuncia (db/01).
--   • escopo por nível reaproveita a lógica de militares_roster_escopo (db/45):
--     admin_geral/admin ou CMT+CIA = tudo; admin_pelotao = seu pelotão;
--     demais = o próprio grupamento.
--
--  Depende de: 01 (contadores/proximo_numero), 04 (_sessao_militar,_nivel_num).
--  Idempotente — pode rodar mais de uma vez. Rodar no SQL Editor do Supabase.
-- ════════════════════════════════════════════════════════════════════════

-- ─── 1) TABELA ──────────────────────────────────────────────────────────
create table if not exists public.cartoes_programa (
  id            uuid primary key default gen_random_uuid(),
  numero        text not null,            -- '045/2026'
  numero_seq    int  not null,            -- 45
  ano           int  not null,            -- 2026

  -- unidade / escala
  grupamento_id       text not null,      -- lotação "N GP / M PEL / … / MUNICÍPIO"
  grupamento_completo text,               -- rótulo amigável (pode ser = grupamento_id)
  data_empenho  date not null,
  turno         text,                     -- '07:00 ÀS 17:00'
  equipe        text,                     -- 'A' / 'B' / …
  mes_servico   text,

  -- serviço / operação
  tipo_servico  text,                     -- 'PATRULHA RURAL' etc.
  operacao      text,
  operacao_descr text,

  -- efetivo (opcional, informativo)
  efetivo_total      int,
  efetivo_ferias     int,
  efetivo_licenciado int,

  -- equipe empregada
  comandante    text,
  motorista     text,
  patrulheiros  jsonb not null default '[]'::jsonb,   -- ["mat - posto - nome", …]
  total_militares int,
  viatura       text,

  -- demandas (EMISSÃO) — array de objetos:
  --   { ordem, texto, municipio, endereco, sisfis(bool),
  --     anexos:[{nome,mime,tamanho,link,id}] }
  demandas      jsonb not null default '[]'::jsonb,

  -- respostas (ATENDIMENTO) — objeto keyed pela ordem (texto):
  --   { "1": { atendida:'TOTAL'|'PARCIAL'|'NAO', reds, auto_infracao,
  --            ato_fiscalizacao, data_atendimento, obs,
  --            por_matricula, por_nome, em }, … }
  respostas     jsonb not null default '{}'::jsonb,

  -- alteração de escala / observações
  alterou_escala    boolean default false,
  motivo_alteracao  text,
  observacoes_equipe text,

  -- status derivado: EMITIDO | EM_ATENDIMENTO | CONCLUIDO
  status        text not null default 'EMITIDO',

  -- inativação (soft delete, só quem criou ou admin)
  ativo         boolean not null default true,

  -- auditoria
  criado_por_matricula text not null,
  criado_por_nome      text not null,
  criado_por_posto     text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Colunas idempotentes (caso a tabela já exista de um teste anterior)
alter table public.cartoes_programa add column if not exists respostas jsonb not null default '{}'::jsonb;
alter table public.cartoes_programa add column if not exists status text not null default 'EMITIDO';
alter table public.cartoes_programa add column if not exists ativo boolean not null default true;

create unique index if not exists uq_cartao_num_ano on public.cartoes_programa (ano, numero_seq);
create index if not exists idx_cartao_grupamento on public.cartoes_programa (grupamento_id);
create index if not exists idx_cartao_data       on public.cartoes_programa (data_empenho desc);
create index if not exists idx_cartao_status     on public.cartoes_programa (status);
create index if not exists idx_cartao_created    on public.cartoes_programa (created_at desc);

drop trigger if exists trg_cartao_touch on public.cartoes_programa;
create trigger trg_cartao_touch before update on public.cartoes_programa
  for each row execute function public.tg_touch_updated_at();   -- definido em db/01

-- ─── 2) STATUS DERIVADO ─────────────────────────────────────────────────
-- EMITIDO (nada respondido) → EM_ATENDIMENTO (parte) → CONCLUIDO (todas).
create or replace function public._cartao_status(p_demandas jsonb, p_respostas jsonb)
returns text language plpgsql immutable as $$
declare v_total int; v_resp int := 0; d jsonb; v_ord text;
begin
  v_total := coalesce(jsonb_array_length(p_demandas), 0);
  if v_total = 0 then return 'EMITIDO'; end if;
  for d in select * from jsonb_array_elements(p_demandas) loop
    v_ord := coalesce(d->>'ordem', '');
    if p_respostas ? v_ord and coalesce(p_respostas->v_ord->>'atendida','') <> '' then
      v_resp := v_resp + 1;
    end if;
  end loop;
  if v_resp = 0 then return 'EMITIDO';
  elsif v_resp >= v_total then return 'CONCLUIDO';
  else return 'EM_ATENDIMENTO'; end if;
end;
$$;

-- ─── 3) ESCOPO (reaproveita a regra do db/45) ───────────────────────────
-- Retorna true se o militar v_me pode ver/gerir um cartão do grupamento dado.
create or replace function public._cartao_pode_ver(v_nivel text, v_funcao text, v_grup_me text, p_grupamento text)
returns boolean language plpgsql immutable as $$
declare v_ge boolean; v_adm boolean; v_pel text; v_pel_alvo text;
begin
  v_ge  := coalesce(v_nivel,'') in ('admin_geral','admin')
        or (upper(coalesce(v_funcao,'')) like '%CMT%' and upper(coalesce(v_funcao,'')) like '%CIA%');
  if v_ge then return true; end if;
  v_adm := upper(btrim(coalesce(v_grup_me,''))) like 'ADM%';
  if v_adm then return upper(btrim(coalesce(p_grupamento,''))) like 'ADM%'; end if;
  if coalesce(v_nivel,'') = 'admin_pelotao' then
    v_pel      := (regexp_match(upper(coalesce(v_grup_me,'')),   '(\d+)\s*PEL'))[1];
    v_pel_alvo := (regexp_match(upper(coalesce(p_grupamento,'')), '(\d+)\s*PEL'))[1];
    return v_pel is not null and v_pel = v_pel_alvo;
  end if;
  return p_grupamento = v_grup_me;
end;
$$;

-- ─── 4) CRIAR (emissão) ─────────────────────────────────────────────────
-- Só admin_gp+ emitem. Numeração atômica. Grava demandas (com anexos do Drive).
create or replace function public.cartao_criar(p_token uuid, dados jsonb)
returns public.cartoes_programa
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_ano int; v_seq int; v_grup text; v_row public.cartoes_programa;
  v_demandas jsonb := coalesce(dados->'demandas', '[]'::jsonb);
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if public._nivel_num(v_me.nivel_acesso) < public._nivel_num('admin_gp') then
    raise exception 'Permissão insuficiente para emitir Cartão Programa.';
  end if;

  v_grup := nullif(btrim(dados->>'grupamento_id'), '');
  if v_grup is null then raise exception 'Grupamento é obrigatório.'; end if;
  if not public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, v_grup) then
    raise exception 'Você não pode emitir cartão para este grupamento.';
  end if;
  if coalesce(dados->>'data_empenho','') = '' then raise exception 'Data de empenho é obrigatória.'; end if;

  v_ano := coalesce(nullif(dados->>'ano','')::int, extract(year from (dados->>'data_empenho')::date)::int);
  v_seq := public.proximo_numero(v_ano, 'cartao');

  insert into public.cartoes_programa (
    numero, numero_seq, ano,
    grupamento_id, grupamento_completo, data_empenho, turno, equipe, mes_servico,
    tipo_servico, operacao, operacao_descr,
    efetivo_total, efetivo_ferias, efetivo_licenciado,
    comandante, motorista, patrulheiros, total_militares, viatura,
    demandas, respostas, status,
    alterou_escala, motivo_alteracao, observacoes_equipe,
    criado_por_matricula, criado_por_nome, criado_por_posto
  ) values (
    lpad(v_seq::text, 3, '0') || '/' || v_ano::text, v_seq, v_ano,
    v_grup, nullif(dados->>'grupamento_completo',''), (dados->>'data_empenho')::date,
    nullif(dados->>'turno',''), nullif(dados->>'equipe',''), nullif(dados->>'mes_servico',''),
    nullif(dados->>'tipo_servico',''), nullif(dados->>'operacao',''), nullif(dados->>'operacao_descr',''),
    nullif(dados->>'efetivo_total','')::int, nullif(dados->>'efetivo_ferias','')::int, nullif(dados->>'efetivo_licenciado','')::int,
    nullif(dados->>'comandante',''), nullif(dados->>'motorista',''),
    coalesce(dados->'patrulheiros','[]'::jsonb), nullif(dados->>'total_militares','')::int, nullif(dados->>'viatura',''),
    v_demandas, '{}'::jsonb, public._cartao_status(v_demandas, '{}'::jsonb),
    coalesce((dados->>'alterou_escala')::boolean, false), nullif(dados->>'motivo_alteracao',''), nullif(dados->>'observacoes_equipe',''),
    v_me.matricula, coalesce(v_me.nome_completo, v_me.matricula), v_me.posto_graduacao
  ) returning * into v_row;

  return v_row;
end;
$$;

-- ─── 5) EDITAR (só emissão; preserva respostas) ─────────────────────────
create or replace function public.cartao_editar(p_token uuid, p_id uuid, dados jsonb)
returns public.cartoes_programa
language plpgsql security definer set search_path = public as $$
declare v_me record; v_cur public.cartoes_programa; v_row public.cartoes_programa;
        v_demandas jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_cur from public.cartoes_programa where id = p_id and ativo = true;
  if v_cur.id is null then raise exception 'Cartão não encontrado.'; end if;
  if not public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, v_cur.grupamento_id) then
    raise exception 'Você não pode editar este cartão.';
  end if;

  v_demandas := coalesce(dados->'demandas', v_cur.demandas);

  update public.cartoes_programa set
    grupamento_id       = coalesce(nullif(dados->>'grupamento_id',''), grupamento_id),
    grupamento_completo = coalesce(nullif(dados->>'grupamento_completo',''), grupamento_completo),
    data_empenho        = coalesce(nullif(dados->>'data_empenho','')::date, data_empenho),
    turno               = coalesce(nullif(dados->>'turno',''), turno),
    equipe              = coalesce(nullif(dados->>'equipe',''), equipe),
    mes_servico         = coalesce(nullif(dados->>'mes_servico',''), mes_servico),
    tipo_servico        = coalesce(nullif(dados->>'tipo_servico',''), tipo_servico),
    operacao            = coalesce(nullif(dados->>'operacao',''), operacao),
    operacao_descr      = case when dados ? 'operacao_descr' then nullif(dados->>'operacao_descr','') else operacao_descr end,
    efetivo_total       = case when dados ? 'efetivo_total' then nullif(dados->>'efetivo_total','')::int else efetivo_total end,
    efetivo_ferias      = case when dados ? 'efetivo_ferias' then nullif(dados->>'efetivo_ferias','')::int else efetivo_ferias end,
    efetivo_licenciado  = case when dados ? 'efetivo_licenciado' then nullif(dados->>'efetivo_licenciado','')::int else efetivo_licenciado end,
    comandante          = coalesce(nullif(dados->>'comandante',''), comandante),
    motorista           = coalesce(nullif(dados->>'motorista',''), motorista),
    patrulheiros        = case when dados ? 'patrulheiros' then dados->'patrulheiros' else patrulheiros end,
    total_militares     = case when dados ? 'total_militares' then nullif(dados->>'total_militares','')::int else total_militares end,
    viatura             = coalesce(nullif(dados->>'viatura',''), viatura),
    demandas            = v_demandas,
    status              = public._cartao_status(v_demandas, respostas),
    alterou_escala      = case when dados ? 'alterou_escala' then (dados->>'alterou_escala')::boolean else alterou_escala end,
    motivo_alteracao    = case when dados ? 'motivo_alteracao' then nullif(dados->>'motivo_alteracao','') else motivo_alteracao end,
    observacoes_equipe  = case when dados ? 'observacoes_equipe' then nullif(dados->>'observacoes_equipe','') else observacoes_equipe end
  where id = p_id returning * into v_row;

  return v_row;
end;
$$;

-- ─── 6) ATENDER (merge de respostas por ordem) ──────────────────────────
-- p_respostas = { "1": {atendida, reds, auto_infracao, ato_fiscalizacao,
--                        data_atendimento, obs}, "2": {…} }  (só as que mudaram)
-- Usada tanto pelo botão "Atender" do cartão quanto pelo Relatório de Serviço.
create or replace function public.cartao_atender(p_token uuid, p_id uuid, p_respostas jsonb)
returns public.cartoes_programa
language plpgsql security definer set search_path = public as $$
declare v_me record; v_cur public.cartoes_programa; v_row public.cartoes_programa;
        v_merged jsonb; k text; v_ent jsonb; v_carimbo jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_cur from public.cartoes_programa where id = p_id and ativo = true;
  if v_cur.id is null then raise exception 'Cartão não encontrado.'; end if;
  -- qualquer militar logado (a equipe é operacional) pode responder o cartão
  -- do PRÓPRIO grupamento; admins pelo escopo normal.
  if not public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, v_cur.grupamento_id)
     and v_cur.grupamento_id <> coalesce(v_me.grupamento_id,'') then
    raise exception 'Você não pode responder este cartão.';
  end if;

  v_merged := coalesce(v_cur.respostas, '{}'::jsonb);
  v_carimbo := jsonb_build_object(
    'por_matricula', v_me.matricula,
    'por_nome', trim(both ' ' from concat(coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo))),
    'em', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF')
  );
  for k in select jsonb_object_keys(coalesce(p_respostas,'{}'::jsonb)) loop
    v_ent := p_respostas->k;
    -- ignora entradas vazias (sem "atendida")
    if coalesce(v_ent->>'atendida','') <> '' then
      v_merged := jsonb_set(v_merged, array[k], v_ent || v_carimbo, true);
    end if;
  end loop;

  update public.cartoes_programa set
    respostas = v_merged,
    status    = public._cartao_status(demandas, v_merged)
  where id = p_id returning * into v_row;

  return v_row;
end;
$$;

-- ─── 7) EXCLUIR (soft delete) ───────────────────────────────────────────
create or replace function public.cartao_excluir(p_token uuid, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record; v_cur public.cartoes_programa;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then return jsonb_build_object('ok', false, 'erro', 'Sessão expirada.'); end if;
  select * into v_cur from public.cartoes_programa where id = p_id;
  if v_cur.id is null then return jsonb_build_object('ok', false, 'erro', 'Cartão não encontrado.'); end if;
  if not public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, v_cur.grupamento_id) then
    return jsonb_build_object('ok', false, 'erro', 'Permissão insuficiente.');
  end if;
  update public.cartoes_programa set ativo = false where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- ─── 8) LISTAR (escopo por nível) ───────────────────────────────────────
-- Filtros opcionais: ano, status, data (= data_empenho), grupamento.
create or replace function public.cartao_listar(
  p_token uuid, p_ano int default null, p_status text default null,
  p_data date default null, p_grupamento text default null
) returns setof public.cartoes_programa
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  return query
    select c.* from public.cartoes_programa c
    where c.ativo = true
      and public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, c.grupamento_id)
      and (p_ano is null or c.ano = p_ano)
      and (p_status is null or c.status = p_status)
      and (p_data is null or c.data_empenho = p_data)
      and (p_grupamento is null or c.grupamento_id = p_grupamento)
    order by c.data_empenho desc, c.numero_seq desc;
end;
$$;

-- Cartões abertos/parciais de uma DATA, no escopo do militar — usado pelo
-- bloco "Cartão Programa" dentro do Relatório de Serviço (a equipe escolhe o seu).
create or replace function public.cartao_abertos_por_data(p_token uuid, p_data date)
returns setof public.cartoes_programa
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  return query
    select c.* from public.cartoes_programa c
    where c.ativo = true
      and c.data_empenho = p_data
      and c.status <> 'CONCLUIDO'
      and ( public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, c.grupamento_id)
            or c.grupamento_id = coalesce(v_me.grupamento_id,'') )
    order by c.equipe, c.numero_seq;
end;
$$;

-- ─── 9) PÚBLICO (leitura read-only, SEM token — link do WhatsApp) ───────
-- Devolve só o necessário p/ a view pública. O cartão é um documento feito
-- para ser enviado à equipe, então o conteúdo é compartilhável por natureza.
create or replace function public.cartao_publico(p_id uuid)
returns jsonb language sql security definer set search_path = public as $$
  select case when c.id is null then null else jsonb_build_object(
    'id', c.id, 'numero', c.numero, 'status', c.status,
    'grupamento_completo', coalesce(c.grupamento_completo, c.grupamento_id),
    'data_empenho', c.data_empenho, 'turno', c.turno, 'equipe', c.equipe, 'mes_servico', c.mes_servico,
    'tipo_servico', c.tipo_servico, 'operacao', c.operacao, 'operacao_descr', c.operacao_descr,
    'comandante', c.comandante, 'motorista', c.motorista, 'patrulheiros', c.patrulheiros,
    'total_militares', c.total_militares, 'viatura', c.viatura,
    'demandas', c.demandas, 'respostas', c.respostas,
    'alterou_escala', c.alterou_escala, 'motivo_alteracao', c.motivo_alteracao,
    'observacoes_equipe', c.observacoes_equipe,
    'criado_por_nome', c.criado_por_nome, 'criado_por_posto', c.criado_por_posto, 'criado_em', c.created_at
  ) end
  from (select * from public.cartoes_programa where id = p_id and ativo = true) c;
$$;

-- ─── 10) SEGURANÇA (RLS) — mesmo modelo de denúncias ────────────────────
-- Escrita só pelas funções acima (security definer). SELECT direto liberado
-- p/ anon (o escopo real é aplicado nas funções/JS, como no resto do painel).
alter table public.cartoes_programa enable row level security;

drop policy if exists cartao_select_anon on public.cartoes_programa;
create policy cartao_select_anon on public.cartoes_programa
  for select to anon using (true);

grant select on public.cartoes_programa to anon;
grant execute on function public.cartao_criar(uuid, jsonb)              to anon;
grant execute on function public.cartao_editar(uuid, uuid, jsonb)       to anon;
grant execute on function public.cartao_atender(uuid, uuid, jsonb)      to anon;
grant execute on function public.cartao_excluir(uuid, uuid)             to anon;
grant execute on function public.cartao_listar(uuid, int, text, date, text) to anon;
grant execute on function public.cartao_abertos_por_data(uuid, date)    to anon;
grant execute on function public.cartao_publico(uuid)                   to anon;

-- ─── Teste rápido (troque o token por um real de public.auth_login): ────
-- select public.cartao_criar('<token>'::uuid, '{
--   "grupamento_id":"1 GP / 1 PEL / 3 CIA PM MAMB/GOVERNADOR VALADARES",
--   "data_empenho":"2026-10-06","turno":"07:00 ÀS 17:00","equipe":"A",
--   "tipo_servico":"PATRULHA RURAL","comandante":"146.322-3 - 3º SGT PM - EDISON",
--   "demandas":[{"ordem":"1","texto":"Atender ponto de monitoramento…","municipio":"Governador Valadares","endereco":"zona rural","anexos":[]}]
-- }'::jsonb);
-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 01 e do 04).
-- ════════════════════════════════════════════════════════════════════════

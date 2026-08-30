-- ══════════════════════════════════════════════════════════════════════
--  TREINAMENTO TÁTICO (TTA) — Pré-turno — 3ª Cia PM MAmb
--  Substitui o Google Forms/Sheets/Drive de TTA. Rodar DEPOIS de
--  04_sessoes_e_militares_seguranca.sql (usa _sessao_militar/_nivel_num)
--  e 01_denuncias.sql (usa tg_touch_updated_at). Idempotente.
--
--  3 peças:
--  1. tta_temas — cronograma mensal (dias do mês → Assunto + Referência),
--     gerido por Aux P1 lotado em ADM (ou Admin Geral, acesso irrestrito).
--     "dias" é um array de inteiros (não um intervalo min/max) porque o
--     cronograma real da PM às vezes tem faixas que se cruzam (ex.: "7,9"
--     e "8,10" nas duas linhas do mesmo mês) — replicar isso como range
--     quebraria. Cada linha pode ter 1+ dias soltos.
--  2. tta_materiais — arquivos do mês (memorando, cronograma, aditivos —
--     quantos forem). Lista aberta: nada é substituído, cada envio novo
--     é uma linha a mais, meses fechados continuam pra consulta.
--     Guardados no bucket privado tta-materiais (mesmo padrão de "anexos").
--  3. tta_chamadas — a chamada em si. QUALQUER militar logado registra;
--     "responsável" é sempre quem está logado (nunca um campo escolhido),
--     data/hora é sempre a do servidor, e o tema do dia é resolvido aqui
--     dentro a partir da data — nada disso é confiável vindo do navegador.
--
--  Reaproveita o que já existe — grupos, militares, municipios_grupos —
--  em vez de duplicar essas listas como o Forms fazia (198 militares e
--  216 municípios mantidos manualmente num dropdown).
-- ══════════════════════════════════════════════════════════════════════

/* ─── Quem pode gerenciar o conteúdo mensal do TTA ───────────────────
   Admin Geral: irrestrito. Além disso, o militar lotado em ADM com
   função "Aux P1" (mesma convenção de texto já usada em admin.html:
   funcao ilike 'aux p1', grupamento_id = 'ADM'). */
create or replace function public._pode_gerenciar_tta(p_nivel text, p_funcao text, p_grupamento text)
returns boolean language sql immutable as $$
  select p_nivel = 'admin_geral'
    or (lower(coalesce(p_funcao,'')) = 'aux p1' and upper(coalesce(p_grupamento,'')) = 'ADM');
$$;

/* ─── Roster para preencher a chamada — qualquer militar logado ──────
   (militares NÃO tem mais SELECT direto pra anon desde 04_*.sql; esta
   função devolve só os campos necessários, nunca senha_hash. Não filtra
   por grupamento — a equipe de hoje pode incluir gente de outro GP.) */
create or replace function public.tta_listar_militares(p_token uuid)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text)
language plpgsql security definer set search_path = public as $$
begin
  if (select sm.id from public._sessao_militar(p_token) sm) is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  return query
    select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra, m.grupamento_id
    from public.militares m
    where m.ativo = true
      -- contas de teste (0000001-0000004): continuam existindo/logando
      -- normalmente, só não aparecem pra marcar presença no TTA. Tirar
      -- essa linha quando não precisar mais escondê-las daqui.
      and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
    order by m.matricula_clean;   -- ordem por número PM (não por nome)
end;
$$;

/* ─── 1) TEMAS DO MÊS ─────────────────────────────────────────────── */
create table if not exists public.tta_temas (
  id          uuid primary key default gen_random_uuid(),
  ano         int not null,
  mes         int not null check (mes between 1 and 12),
  dias        int[] not null,             -- ex.: {11,12}
  assunto     text not null,              -- ex.: "Memorando nº 30.130.2/22 – EMPM ..."
  referencia  text not null,              -- ex.: "M 31.444 a M 31.506"
  criado_por_matricula text,
  criado_por_nome       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_tta_temas_ano_mes on public.tta_temas(ano, mes);

drop trigger if exists trg_tta_temas_touch on public.tta_temas;
create trigger trg_tta_temas_touch before update on public.tta_temas
  for each row execute function public.tg_touch_updated_at();

/* ─── 2) MATERIAIS DO MÊS (metadados; os bytes vão pro Storage) ─────────
   Lista aberta de propósito: sem unique/on-conflict, cada envio é uma
   linha nova — os arquivos servem de consulta, não devem sumir. */
create table if not exists public.tta_materiais (
  id          uuid primary key default gen_random_uuid(),
  ano         int not null,
  mes         int not null check (mes between 1 and 12),
  nome        text not null,
  path        text not null,
  tamanho     int,
  link        text not null,               -- signed URL durável (mesmo padrão de anexos)
  enviado_por_matricula text,
  enviado_por_nome       text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_tta_materiais_ano_mes on public.tta_materiais(ano, mes);

/* ─── 3) CHAMADA (pré-turno) ─────────────────────────────────────────
   Sem numeração/contador — é um registro por chamada, não algo protocolado. */
create table if not exists public.tta_chamadas (
  id          uuid primary key default gen_random_uuid(),
  gp_responsavel          text not null,
  grupamento_completo      text not null,   -- "Grupamento de Atuação" — pode ser diferente da lotação
  militar_resp_matricula   text not null,   -- sempre quem estava logado, nunca um campo escolhido
  militar_resp_nome        text not null,
  militares_presentes      jsonb not null default '[]'::jsonb,  -- [{matricula,pg,nome}]
  data_hora_chamada        timestamptz not null,                -- sempre now() no servidor
  tema_id                  uuid references public.tta_temas(id),
  tema_assunto              text,          -- snapshot (sobrevive a edição/exclusão do tema)
  tema_referencia           text,
  inicio_turno              time,
  final_turno                time,
  prefixo_viatura            text,                                 -- 1ª viatura (compat.)
  viaturas                   jsonb not null default '[]'::jsonb,   -- [{prefixo, motorista_matricula, motorista_nome}]
  equipes                    jsonb not null default '[]'::jsonb,   -- [{ordem,comandante,motorista,prefixo_viatura,vinculo,tipo_patrulha,patrulheiros[],municipios[]}]
  tipo_patrulha               text,
  municipios_atuacao         jsonb not null default '[]'::jsonb,  -- ["MUNICIPIO A", ...]
  observacoes                 text,
  registrado_por_matricula   text not null,
  registrado_por_nome         text not null,
  created_at   timestamptz not null default now()
);
alter table public.tta_chamadas add column if not exists viaturas jsonb not null default '[]'::jsonb;
alter table public.tta_chamadas add column if not exists equipes  jsonb not null default '[]'::jsonb;
create index if not exists idx_tta_chamadas_gp   on public.tta_chamadas(gp_responsavel);
create index if not exists idx_tta_chamadas_resp on public.tta_chamadas(militar_resp_matricula, data_hora_chamada desc);
create index if not exists idx_tta_chamadas_data on public.tta_chamadas(data_hora_chamada desc);

/* ─── 4) INSERIR CHAMADA (qualquer militar logado) ────────────────────
   security definer: resolve quem está chamando pelo token (nunca confia
   no navegador), sempre usa now() como data/hora, e resolve o tema do
   dia sozinho a partir da data — o front não escolhe/manda o tema. */
create or replace function public.tta_criar_chamada(p_token uuid, p_dados jsonb)
returns public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare
  v_me record;
  v_row public.tta_chamadas;
  v_tema public.tta_temas;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- NOTA: a checagem anti-duplicidade de tta_criar_chamada foi movida para
  -- db/42 (create-or-replace), para não obrigar a re-rodar TODO o 07 (cuja
  -- tta_listar_militares diverge da versão em produção). Ver db/42.

  select * into v_tema from public.tta_temas
    where ano = extract(year from v_hoje)::int
      and mes = extract(month from v_hoje)::int
      and extract(day from v_hoje)::int = any(dias)
    order by created_at
    limit 1;

  insert into public.tta_chamadas (
    gp_responsavel, grupamento_completo,
    militar_resp_matricula, militar_resp_nome,
    militares_presentes, data_hora_chamada,
    tema_id, tema_assunto, tema_referencia,
    inicio_turno, final_turno, prefixo_viatura, viaturas, equipes, tipo_patrulha,
    municipios_atuacao, observacoes,
    registrado_por_matricula, registrado_por_nome
  ) values (
    p_dados->>'gp_responsavel', p_dados->>'grupamento_completo',
    v_me.matricula, v_me.nome_completo,
    coalesce(p_dados->'militares_presentes', '[]'::jsonb), now(),
    v_tema.id, v_tema.assunto, v_tema.referencia,
    nullif(p_dados->>'inicio_turno','')::time, nullif(p_dados->>'final_turno','')::time,
    nullif(p_dados->>'prefixo_viatura',''), coalesce(p_dados->'viaturas','[]'::jsonb), coalesce(p_dados->'equipes','[]'::jsonb), nullif(p_dados->>'tipo_patrulha',''),
    coalesce(p_dados->'municipios_atuacao', '[]'::jsonb), nullif(p_dados->>'observacoes',''),
    v_me.matricula, v_me.nome_completo
  ) returning * into v_row;

  return v_row;
end;
$$;

/* Devolve a chamada de HOJE feita pelo militar logado (ou nenhuma linha) —
   usada por relatorio-servico.html pra pré-preencher Comandante/
   Motorista/Patrulheiro(s) sem mexer no layout do formulário. */
create or replace function public.tta_chamada_hoje(p_token uuid)
returns public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.tta_chamadas; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_row from public.tta_chamadas
    where militar_resp_matricula = v_me.matricula
      and (data_hora_chamada at time zone 'America/Sao_Paulo')::date = v_hoje
    order by created_at desc
    limit 1;
  return v_row;
end;
$$;

/* Relatório mensal de chamadas — restrito a Aux P1 (ADM) ou Admin Geral,
   mesmo controle que já existe pra gerir temas/materiais. Base pro
   "extração/consulta" que substitui a planilha do Google. */
create or replace function public.tta_listar_chamadas(p_token uuid, p_ano int, p_mes int)
returns setof public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._pode_gerenciar_tta(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id) then
    raise exception 'Consulta de lançamentos restrita ao Aux P1 (ADM) ou Admin Geral.';
  end if;
  return query
    select * from public.tta_chamadas
    where extract(year  from data_hora_chamada at time zone 'America/Sao_Paulo')::int = p_ano
      and extract(month from data_hora_chamada at time zone 'America/Sao_Paulo')::int = p_mes
    order by data_hora_chamada desc;
end;
$$;

/* ─── 5) TEMAS: listar (todo mundo logado) e gerenciar (Aux P1/ADM ou AG) */
create or replace function public.tta_listar_temas(p_token uuid, p_ano int, p_mes int)
returns setof public.tta_temas
language plpgsql security definer set search_path = public as $$
begin
  if (select id from public._sessao_militar(p_token)) is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  return query select * from public.tta_temas where ano = p_ano and mes = p_mes order by created_at;
end;
$$;

create or replace function public.tta_salvar_tema(p_token uuid, p_id uuid, p_dados jsonb)
returns public.tta_temas
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.tta_temas; v_dias int[];
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._pode_gerenciar_tta(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id) then
    raise exception 'Gestão do TTA restrita ao Aux P1 (ADM) ou Admin Geral.';
  end if;

  if p_dados ? 'dias' then
    select array_agg((x)::int) into v_dias from jsonb_array_elements_text(p_dados->'dias') x;
  end if;

  if p_id is null then
    insert into public.tta_temas (ano, mes, dias, assunto, referencia, criado_por_matricula, criado_por_nome)
    values (
      (p_dados->>'ano')::int, (p_dados->>'mes')::int, v_dias,
      p_dados->>'assunto', p_dados->>'referencia', v_me.matricula, v_me.nome_completo
    ) returning * into v_row;
  else
    update public.tta_temas set
      dias       = coalesce(v_dias, dias),
      assunto    = coalesce(p_dados->>'assunto', assunto),
      referencia = coalesce(p_dados->>'referencia', referencia)
    where id = p_id
    returning * into v_row;
  end if;
  return v_row;
end;
$$;

create or replace function public.tta_excluir_tema(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._pode_gerenciar_tta(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id) then
    raise exception 'Gestão do TTA restrita ao Aux P1 (ADM) ou Admin Geral.';
  end if;
  delete from public.tta_temas where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

/* ─── 6) MATERIAIS: listar (todo mundo) e registrar/remover (Aux P1/ADM ou AG)
   O upload dos bytes acontece direto no Storage (como em anexos); esta
   função só registra/confirma o metadado — o painel só EXIBE materiais
   que passaram por aqui, mesmo que o bucket em si aceite a chave anon.
   Sempre INSERT puro — nunca substitui um arquivo já registrado. */
create or replace function public.tta_listar_materiais(p_token uuid, p_ano int, p_mes int)
returns setof public.tta_materiais
language plpgsql security definer set search_path = public as $$
begin
  if (select id from public._sessao_militar(p_token)) is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  return query select * from public.tta_materiais where ano = p_ano and mes = p_mes order by created_at;
end;
$$;

create or replace function public.tta_registrar_material(p_token uuid, p_dados jsonb)
returns public.tta_materiais
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.tta_materiais;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._pode_gerenciar_tta(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id) then
    raise exception 'Gestão do TTA restrita ao Aux P1 (ADM) ou Admin Geral.';
  end if;

  insert into public.tta_materiais (ano, mes, nome, path, tamanho, link, enviado_por_matricula, enviado_por_nome)
  values (
    (p_dados->>'ano')::int, (p_dados->>'mes')::int,
    p_dados->>'nome', p_dados->>'path', nullif(p_dados->>'tamanho','')::int, p_dados->>'link',
    v_me.matricula, v_me.nome_completo
  ) returning * into v_row;

  return v_row;
end;
$$;

create or replace function public.tta_excluir_material(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._pode_gerenciar_tta(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id) then
    raise exception 'Gestão do TTA restrita ao Aux P1 (ADM) ou Admin Geral.';
  end if;
  delete from public.tta_materiais where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

/* ─── 7) SEGURANÇA: RLS + bucket ──────────────────────────────────────
   Leitura liberada (igual denuncias) — escrita só pelas funções acima. */
alter table public.tta_temas     enable row level security;
alter table public.tta_materiais enable row level security;
alter table public.tta_chamadas  enable row level security;

drop policy if exists tta_temas_select_anon on public.tta_temas;
create policy tta_temas_select_anon on public.tta_temas for select to anon using (true);
drop policy if exists tta_materiais_select_anon on public.tta_materiais;
create policy tta_materiais_select_anon on public.tta_materiais for select to anon using (true);
drop policy if exists tta_chamadas_select_anon on public.tta_chamadas;
create policy tta_chamadas_select_anon on public.tta_chamadas for select to anon using (true);
-- sem policy de insert/update/delete nas 3 tabelas: só passa pelas funções acima.

insert into storage.buckets (id, name, public, file_size_limit)
values ('tta-materiais', 'tta-materiais', false, 15728640)
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit;

drop policy if exists "tta_materiais_anon_select" on storage.objects;
create policy "tta_materiais_anon_select" on storage.objects
  for select to anon using (bucket_id = 'tta-materiais');
drop policy if exists "tta_materiais_anon_insert" on storage.objects;
create policy "tta_materiais_anon_insert" on storage.objects
  for insert to anon with check (bucket_id = 'tta-materiais');
drop policy if exists "tta_materiais_anon_delete" on storage.objects;
create policy "tta_materiais_anon_delete" on storage.objects
  for delete to anon using (bucket_id = 'tta-materiais');

grant execute on function public.tta_listar_militares(uuid) to anon;
grant execute on function public.tta_criar_chamada(uuid, jsonb) to anon;
grant execute on function public.tta_chamada_hoje(uuid) to anon;
grant execute on function public.tta_listar_chamadas(uuid, int, int) to anon;
grant execute on function public.tta_listar_temas(uuid, int, int) to anon;
grant execute on function public.tta_salvar_tema(uuid, uuid, jsonb) to anon;
grant execute on function public.tta_excluir_tema(uuid, uuid) to anon;
grant execute on function public.tta_listar_materiais(uuid, int, int) to anon;
grant execute on function public.tta_registrar_material(uuid, jsonb) to anon;
grant execute on function public.tta_excluir_material(uuid, uuid) to anon;

-- ─── Teste rápido (no SQL Editor) ───────────────────────────────────────
-- select public.tta_salvar_tema(
--   (select token from public.sessoes limit 1), -- ou um token de sessão real
--   null,
--   '{"ano":2026,"mes":8,"dias":[11,12],"assunto":"Memorando nº 30.130.2/22 – EMPM","referencia":"M 31.444 a M 31.506"}'::jsonb
-- );

-- ─── DESFAZER ───────────────────────────────────────────────────────────
-- drop function if exists public.tta_criar_chamada(uuid,jsonb);
-- drop function if exists public.tta_chamada_hoje(uuid);
-- drop function if exists public.tta_listar_chamadas(uuid,int,int);
-- drop function if exists public.tta_listar_temas(uuid,int,int);
-- drop function if exists public.tta_salvar_tema(uuid,uuid,jsonb);
-- drop function if exists public.tta_excluir_tema(uuid,uuid);
-- drop function if exists public.tta_listar_materiais(uuid,int,int);
-- drop function if exists public.tta_registrar_material(uuid,jsonb);
-- drop function if exists public.tta_excluir_material(uuid,uuid);
-- drop function if exists public.tta_listar_militares(uuid);
-- drop function if exists public._pode_gerenciar_tta(text,text,text);
-- drop table if exists public.tta_chamadas;
-- drop table if exists public.tta_materiais;
-- drop table if exists public.tta_temas;
-- delete from storage.buckets where id = 'tta-materiais';

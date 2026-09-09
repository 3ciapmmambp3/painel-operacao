-- ══════════════════════════════════════════════════════════════════════
--  MÓDULO CONTROLE DE OFÍCIOS (ENTRADA e SAÍDA) — 3ª Cia PM MAmb (P1)
--  Substitui o Google Forms "CONTROLE DE OFÍCIOS".
--
--  Fluxo:
--    • QUALQUER militar logado registra o ofício (criar_oficio).
--        - SAÍDA: recebe numeração automática 'Ofício nº NNN/AAAA - 3ª Cia
--          PM MAmb' (proximo_numero(ano,'oficio')); pode trazer o CORPO do
--          ofício (vocativo/corpo/assinante/destinatário) p/ gerar o PDF.
--        - ENTRADA: registra nº externo, emitente externo e o destino interno.
--    • A TELA DE CONTROLE tem VISIBILIDADE ESCOPADA:
--        - Aux P1 / Admin / Admin Geral / CMT Cia  → veem TUDO.
--        - CMT/Aux de Pelotão (admin_pelotao)       → veem do seu pelotão.
--        - Admin de GP (admin_gp) e demais militares → veem do seu grupamento.
--      O ofício guarda `grupamento_id` = grupamento do Emitente (saída) /
--      Destino (entrada); o recorte casa por NÚMERO de GP + Pelotão (regex,
--      igual aos db/25/db/49) — tolerante a diferenças de grafia.
--
--  Depende de: 04 (_sessao_militar), 01 (proximo_numero).
--  (No frontend, os selects de Emitente/Destino usam grupamentos_listar, db/27.)
--  Idempotente. Rodar no SQL Editor (ordem: depois do 04 e 01).
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) TABELA ─────────────────────────────────────────────────────────
create table if not exists public.oficios (
  id            uuid primary key default gen_random_uuid(),
  tipo          text not null check (tipo in ('Saída','Entrada')),

  -- numeração (só SAÍDA): 'Ofício nº 001/2026 - 3ª Cia PM MAmb'
  numero        text,
  numero_seq    int,
  ano           int  not null,

  -- ── comuns ──
  data_doc      date not null,                 -- data da emissão / recebimento
  assunto       text,
  em_resposta   text,                          -- "Em resposta a ofício anterior?"
  responsavel   text,                          -- nº/posto/nome do responsável
  observacoes   text,

  -- grupamento p/ VISIBILIDADE (emitente na saída / destino na entrada)
  grupamento_id text,

  -- ── SAÍDA ──
  emitente      text,                          -- GP/Pel/Setor emissor (= grupamento_id)
  destino_ext   text,                          -- destino externo (órgão)

  -- ── ENTRADA ──
  num_externo   text,                          -- nº do ofício externo
  emitente_ext  text,                          -- órgão que enviou
  destino_int   text,                          -- GP/Pel/Setor que recebeu (= grupamento_id)

  -- ── CORPO do ofício (SAÍDA, para gerar o PDF) ──
  of_vocativo   text,                           -- "Senhor Promotor,"
  of_corpo      text,                           -- parágrafos (linha em branco separa)
  of_fecho      text,                           -- "Atenciosamente,"
  of_cidade     text,                           -- cidade da assinatura
  of_assinante  text,                           -- "TÚLIO FERREIRA DA CUNHA, CAP PM"
  of_cargo      text,                           -- "COMANDANTE DA 3ª COMPANHIA…"
  dest_tratamento text,                         -- "Ao Senhor Promotor da 15ª PJGV…"
  dest_nome     text,
  dest_orgao    text,
  dest_endereco text,

  -- anexo (ofício digitalizado): array de {path,nome,tamanho,mime,link}
  anexos        jsonb not null default '[]'::jsonb,

  -- controle (P1)
  situacao      text not null default 'REGISTRADO'
                  check (situacao in ('REGISTRADO','ARQUIVADO')),
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
alter table public.oficios add column if not exists grupamento_id text;
alter table public.oficios add column if not exists of_vocativo text;
alter table public.oficios add column if not exists of_corpo text;
alter table public.oficios add column if not exists of_fecho text;
alter table public.oficios add column if not exists of_cidade text;
alter table public.oficios add column if not exists of_assinante text;
alter table public.oficios add column if not exists of_cargo text;
alter table public.oficios add column if not exists dest_tratamento text;
alter table public.oficios add column if not exists dest_nome text;
alter table public.oficios add column if not exists dest_orgao text;
alter table public.oficios add column if not exists dest_endereco text;
alter table public.oficios add column if not exists observacoes_controle text;
alter table public.oficios add column if not exists controlado_por_matricula text;
alter table public.oficios add column if not exists controlado_por_nome text;

-- numeração única por ano só entre as SAÍDAS (numero_seq preenchido)
create unique index if not exists uq_oficio_saida_num on public.oficios (ano, numero_seq)
  where numero_seq is not null;
create index if not exists idx_oficio_data    on public.oficios (data_doc desc);
create index if not exists idx_oficio_tipo    on public.oficios (tipo);
create index if not exists idx_oficio_grp     on public.oficios (grupamento_id);
create index if not exists idx_oficio_created on public.oficios (created_at desc);

drop trigger if exists trg_oficio_touch on public.oficios;
create trigger trg_oficio_touch before update on public.oficios
  for each row execute function public.tg_touch_updated_at();

-- ─── 2) HELPER: escopo TOTAL (vê tudo) ─────────────────────────────────
-- Aux P1  OU  Admin  OU  Admin Geral  OU  CMT da Cia.
create or replace function public._oficio_escopo_total(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select coalesce(p_nivel,'') in ('admin_geral','admin')
      or (coalesce(p_funcao,'') ~* 'aux' and coalesce(p_funcao,'') ~* 'p\s*1')
      or (coalesce(p_funcao,'') ~* '(cmt|comandante)' and coalesce(p_funcao,'') ~* '\ycia\y');
$$;

-- ─── 3) CRIAR (qualquer militar logado) ────────────────────────────────
create or replace function public.criar_oficio(p_token uuid, dados jsonb)
returns public.oficios
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_ano  int := coalesce(nullif(dados->>'ano','')::int, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_tipo text := nullif(dados->>'tipo','');
  v_seq  int;
  v_num  text;
  v_grp  text;
  v_row  public.oficios;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if v_tipo not in ('Saída','Entrada') then raise exception 'Selecione o tipo (Saída ou Entrada).'; end if;
  if coalesce(nullif(dados->>'data_doc',''),'') = '' then
    raise exception 'Informe a data de emissão / recebimento.';
  end if;

  if v_tipo = 'Saída' then
    -- numeração sequencial única da Companhia por ano
    v_seq := public.proximo_numero(v_ano, 'oficio');
    v_num := 'Ofício nº ' || lpad(v_seq::text, 3, '0') || '/' || v_ano::text || ' - 3ª Cia PM MAmb';
    v_grp := nullif(dados->>'emitente','');
  else
    v_seq := null; v_num := null;
    v_grp := nullif(dados->>'destino_int','');
  end if;

  insert into public.oficios (
    tipo, numero, numero_seq, ano,
    data_doc, assunto, em_resposta, responsavel, observacoes, grupamento_id,
    emitente, destino_ext,
    num_externo, emitente_ext, destino_int,
    of_vocativo, of_corpo, of_fecho, of_cidade, of_assinante, of_cargo,
    dest_tratamento, dest_nome, dest_orgao, dest_endereco,
    anexos,
    registrado_por_matricula, registrado_por_nome
  ) values (
    v_tipo, v_num, v_seq, v_ano,
    (dados->>'data_doc')::date, nullif(dados->>'assunto',''), nullif(dados->>'em_resposta',''),
    nullif(dados->>'responsavel',''), nullif(dados->>'observacoes',''), v_grp,
    nullif(dados->>'emitente',''), nullif(dados->>'destino_ext',''),
    nullif(dados->>'num_externo',''), nullif(dados->>'emitente_ext',''), nullif(dados->>'destino_int',''),
    nullif(dados->>'of_vocativo',''), nullif(dados->>'of_corpo',''), nullif(dados->>'of_fecho',''),
    nullif(dados->>'of_cidade',''), nullif(dados->>'of_assinante',''), nullif(dados->>'of_cargo',''),
    nullif(dados->>'dest_tratamento',''), nullif(dados->>'dest_nome',''),
    nullif(dados->>'dest_orgao',''), nullif(dados->>'dest_endereco',''),
    coalesce(dados->'anexos','[]'::jsonb),
    v_me.matricula, coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo)
  ) returning * into v_row;

  return v_row;
end;
$$;

-- ─── 4) LISTAR (VISIBILIDADE ESCOPADA) ─────────────────────────────────
-- Recorte tolerante a formato: casa por NÚMERO de GP e Pelotão extraídos da
-- string do grupamento (mesma técnica dos db/25 e db/49), pois grupos e
-- militares podem ter grafias ligeiramente diferentes. GP se identifica por
-- (nº GP + nº Pelotão), porque o mesmo "nº GP" se repete em pelotões distintos.
create or replace function public.oficio_listar(p_token uuid)
returns setof public.oficios
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_gp  text;
  v_pel text;
  v_adm boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- Aux P1 / Admin / Admin Geral / CMT Cia → veem tudo
  if public._oficio_escopo_total(v_me.nivel_acesso, v_me.funcao) then
    return query select * from public.oficios order by data_doc desc, created_at desc;
    return;
  end if;

  v_adm := upper(btrim(coalesce(v_me.grupamento_id,''))) like 'ADM%';
  v_gp  := (regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\s*GP',  'i'))[1];
  v_pel := (regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1];

  return query
    select * from public.oficios o
     where case
       -- staff/ADM (sem GP/Pel): vê os ofícios de origem ADM
       when v_adm then upper(btrim(coalesce(o.grupamento_id,''))) like 'ADM%'
       -- CMT/Aux de Pelotão: todo o pelotão (casa o nº do Pelotão)
       when coalesce(v_me.nivel_acesso,'') = 'admin_pelotao' and v_pel is not null then
         (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1] = v_pel
       -- Admin de GP e demais militares: o próprio GP (nº GP + nº Pelotão)
       when v_gp is not null and v_pel is not null then
             (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*GP',  'i'))[1] = v_gp
         and (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1] = v_pel
       else false
     end
     order by o.data_doc desc, o.created_at desc;
end;
$$;

-- ─── 5) CONTROLE: gravar situação / observações ────────────────────────
-- Quem pode controlar = quem tem o ofício no seu escopo de visão. Reusa a
-- mesma regra do listar (chamando-o) para localizar o registro permitido.
create or replace function public.oficio_controle_salvar(p_token uuid, p_id uuid, p_dados jsonb)
returns public.oficios
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.oficios; v_ok boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- o registro tem de estar dentro da visão do militar
  select exists(select 1 from public.oficio_listar(p_token) o where o.id = p_id) into v_ok;
  if not v_ok then raise exception 'Ofício não encontrado no seu escopo.'; end if;

  update public.oficios set
    situacao             = coalesce(nullif(p_dados->>'situacao',''), situacao),
    observacoes_controle = case when p_dados ? 'observacoes_controle' then nullif(p_dados->>'observacoes_controle','') else observacoes_controle end,
    -- anexos: quando enviado, substitui pelo array completo (existentes + novos)
    -- que o cliente monta. Serve p/ anexar a via assinada de um ofício de saída.
    anexos               = case when p_dados ? 'anexos' then coalesce(p_dados->'anexos','[]'::jsonb) else anexos end,
    controlado_por_matricula = v_me.matricula,
    controlado_por_nome      = coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo)
  where id = p_id
  returning * into v_row;
  if v_row.id is null then raise exception 'Ofício não encontrado.'; end if;
  return v_row;
end;
$$;

-- ─── 6) EXCLUIR (só Admin Geral) ───────────────────────────────────────
create or replace function public.oficio_excluir(p_token uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Exclusão restrita ao Admin Geral.';
  end if;
  delete from public.oficios where id = p_id;
end;
$$;

-- ─── 7) SEGURANÇA (RLS) ────────────────────────────────────────────────
-- Sem policy p/ anon: acesso direto à tabela BLOQUEADO. Tudo passa pelas
-- funções security definer acima — o recorte de visibilidade é garantido no
-- banco a partir do token.
alter table public.oficios enable row level security;

grant execute on function public.criar_oficio(uuid, jsonb)              to anon;
grant execute on function public.oficio_listar(uuid)                    to anon;
grant execute on function public.oficio_controle_salvar(uuid, uuid, jsonb) to anon;
grant execute on function public.oficio_excluir(uuid, uuid)             to anon;
grant execute on function public._oficio_escopo_total(text, text)       to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Reusa proximo_numero (db/01) e _sessao_militar (db/04). Não precisa
-- re-rodar nenhum anterior. grupamentos_listar (db/27) é usado só no frontend.
-- ══════════════════════════════════════════════════════════════════════

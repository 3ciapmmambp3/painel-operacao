-- ══════════════════════════════════════════════════════════════════════
--  FIX — NUMERAÇÃO A PARTIR DE 1000 (bug do lpad que truncava)
--
--  Sintoma: depois de 999/2026, as DENÚNCIAS de balcão saíram 100/2026 em
--  vez de 1000/2026 (e seguiriam 101, 102...).
--
--  Causa: o número é montado com  lpad(seq::text, 3, '0').  No PostgreSQL o
--  lpad TRUNCA pela direita quando o texto é MAIOR que o tamanho pedido, então
--    lpad('1000', 3, '0')  →  '100'
--  O numero_seq (inteiro) foi gravado certo (1000); só a STRING "numero" saiu
--  errada. O mesmo padrão existe em Requisição Judicial e Ofício — que ainda
--  não passaram de 999, mas passariam com o mesmo defeito. Corrigido aqui p/ os
--  três de uma vez.
--
--  O que este script faz:
--    1) Cria helper fmt_seq(int): pad de 3 dígitos NO MÍNIMO, sem nunca truncar
--       (001, 059, 927, 1000, 10000...).
--    2) Recria criar_denuncia / criar_requisicao_judicial / criar_oficio usando
--       fmt_seq no lugar do lpad(...,3,...).
--    3) Conserta as linhas JÁ gravadas com número truncado (numero_seq >= 1000),
--       recompondo o "numero" a partir do numero_seq (que está correto).
--
--  Idempotente. Depende de: 01, 62, 63, 96. Rodar no Supabase → SQL Editor.
-- ══════════════════════════════════════════════════════════════════════

-- ─── 0) HELPER: formata a sequência sem truncar ────────────────────────
create or replace function public.fmt_seq(p_seq int)
returns text
language sql
immutable
as $$
  select lpad(p_seq::text, greatest(3, length(p_seq::text)), '0');
$$;

-- ─── 1) DENÚNCIA / REQUISIÇÃO (balcão) — recria criar_denuncia (base: db/96)
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
  v_receb date := coalesce(nullif(dados->>'data_recebimento','')::date,
                           (now() at time zone 'America/Sao_Paulo')::date);
  v_prazo date := coalesce(nullif(dados->>'prazo','')::date, v_receb + 45);
  v_row  public.denuncias;
begin
  if v_tipo not in ('denuncia','requisicao') then
    raise exception 'Tipo inválido: %', v_tipo;
  end if;

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
    data_fato, data_recebimento, municipio, gp_responsavel, grupamento_completo, tema, objeto, descricao,
    endereco, referencia, observacoes, prazo, anexos,
    registrado_por_matricula, registrado_por_nome
  ) values (
    public.fmt_seq(v_seq) || '/' || v_ano::text, v_seq, v_ano, v_tipo,
    dados->>'origem', nullif(dados->>'origem_esfera',''), nullif(dados->>'numero_oficio',''),
    nullif(dados->>'denunciante',''), nullif(dados->>'denunciado',''),
    nullif(dados->>'data_fato','')::date, v_receb, v_muni, v_gp, v_gp_completo,
    dados->>'tema', nullif(dados->>'objeto',''), dados->>'descricao',
    nullif(dados->>'endereco',''), nullif(dados->>'referencia',''), nullif(dados->>'observacoes',''),
    v_prazo, coalesce(dados->'anexos','[]'::jsonb),
    dados->>'registrado_por_matricula', dados->>'registrado_por_nome'
  ) returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.criar_denuncia(jsonb) to anon;

-- ─── 2) REQUISIÇÃO JUDICIAL — recria criar_requisicao_judicial (base: db/62)
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
    'RJ ' || public.fmt_seq(v_seq) || '/' || v_ano::text, v_seq, v_ano,
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

-- ─── 3) OFÍCIO (saída) — recria criar_oficio (base: db/63) ──────────────
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
    v_num := 'Ofício nº ' || public.fmt_seq(v_seq) || '/' || v_ano::text || ' - 3ª Cia PM MAmb';
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
    v_me.matricula, coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_completo, v_me.nome_guerra)
  ) returning * into v_row;

  return v_row;
end;
$$;

-- ══════════════════════════════════════════════════════════════════════
--  4) BACKFILL — corrige as linhas JÁ gravadas com número truncado.
--     Só toca linhas com numero_seq >= 1000 (única faixa em que o lpad
--     truncava). numero_seq está correto; recompomos apenas a string.
--     Ex.: denúncia seq 1000 que estava "100/2026" volta a ser "1000/2026".
-- ══════════════════════════════════════════════════════════════════════

-- Denúncias e requisições (mesma tabela)
update public.denuncias
   set numero = public.fmt_seq(numero_seq) || '/' || ano::text
 where numero_seq >= 1000
   and numero is distinct from public.fmt_seq(numero_seq) || '/' || ano::text;

-- Requisições judiciais (prefixo "RJ ")
update public.requisicoes_judiciais
   set numero = 'RJ ' || public.fmt_seq(numero_seq) || '/' || ano::text
 where numero_seq >= 1000
   and numero is distinct from 'RJ ' || public.fmt_seq(numero_seq) || '/' || ano::text;

-- Ofícios de saída (entrada tem numero_seq nulo e fica de fora)
update public.oficios
   set numero = 'Ofício nº ' || public.fmt_seq(numero_seq) || '/' || ano::text || ' - 3ª Cia PM MAmb'
 where numero_seq >= 1000
   and tipo = 'Saída'
   and numero is distinct from 'Ofício nº ' || public.fmt_seq(numero_seq) || '/' || ano::text || ' - 3ª Cia PM MAmb';

-- Conferência (rode à parte se quiser ver o que mudou):
--   select numero, numero_seq, ano, tipo from public.denuncias where numero_seq >= 1000 order by numero_seq;
-- ══════════════════════════════════════════════════════════════════════

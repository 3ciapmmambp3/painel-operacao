-- ══════════════════════════════════════════════════════════════════════
--  DENÚNCIAS / REQUISIÇÕES — DATA DE RECEBIMENTO (base da contagem do prazo)
--
--  Pedido: ter uma "Data de Recebimento" própria (fato do balcão), usada para
--  contar o prazo. Padrão = hoje (data do lançamento), mas EDITÁVEL para
--  corrigir lançamentos atrasados (recebeu num dia, lançou depois).
--
--  Regras:
--    • Nova coluna data_recebimento (date). Default no app = hoje; no servidor,
--      cai em current_date se não vier.
--    • O PRAZO passa a ser derivado da data_recebimento: se o app não mandar
--      prazo, usa data_recebimento + 45 dias.
--    • Backfill: registros antigos recebem data_recebimento = created_at::date.
--
--  Depende de: 01_denuncias.sql. Idempotente.
-- ══════════════════════════════════════════════════════════════════════

-- 1) coluna nova
alter table public.denuncias add column if not exists data_recebimento date;

-- 2) backfill dos registros existentes (recebimento = dia do lançamento)
update public.denuncias
   set data_recebimento = (created_at at time zone 'America/Sao_Paulo')::date
 where data_recebimento is null;

-- 3) criar_denuncia: grava data_recebimento (default hoje) e deriva o prazo dela
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
    lpad(v_seq::text, 3, '0') || '/' || v_ano::text, v_seq, v_ano, v_tipo,
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

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Reusa proximo_numero (db/01) e vw_municipio_grupamento.
-- ══════════════════════════════════════════════════════════════════════

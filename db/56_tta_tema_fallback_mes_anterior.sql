-- 56_tta_tema_fallback_mes_anterior.sql
-- Fallback do tema do TTA para o mês anterior enquanto o cronograma do mês
-- atual não é lançado. Motivo: o cronograma do mês novo costuma chegar com 5–10
-- dias de atraso, e nesse intervalo o pré-turno ficava sem instrução.
--
-- Regra:
--   1) usa o tema do PRÓPRIO mês/dia, se existir;
--   2) se o mês pedido já tem ALGUM tema (cronograma já lançado), respeita o vão
--      — não faz fallback (o dia sem tema é intencional);
--   3) se o mês pedido não tem NENHUM tema, usa o mês anterior, mesmo dia.

-- ── Fonte única de verdade: tema efetivo do dia ─────────────────────────
create or replace function public._tta_tema_efetivo(p_ano int, p_mes int, p_dia int)
returns public.tta_temas
language plpgsql stable set search_path = public as $$
declare
  v_tema public.tta_temas;
  v_tem_mes boolean;
  v_ano int;
  v_mes int;
begin
  -- 1) tema do próprio mês, no dia pedido
  select * into v_tema from public.tta_temas
    where ano = p_ano and mes = p_mes and p_dia = any(dias)
    order by created_at limit 1;
  if v_tema.id is not null then return v_tema; end if;

  -- 2) mês já lançado (tem algum tema) → não faz fallback
  select exists(select 1 from public.tta_temas where ano = p_ano and mes = p_mes)
    into v_tem_mes;
  if v_tem_mes then return v_tema; end if; -- v_tema nulo

  -- 3) mês sem nenhum tema → mês anterior, mesmo dia
  v_ano := p_ano; v_mes := p_mes - 1;
  if v_mes < 1 then v_mes := 12; v_ano := p_ano - 1; end if;
  select * into v_tema from public.tta_temas
    where ano = v_ano and mes = v_mes and p_dia = any(dias)
    order by created_at limit 1;
  return v_tema;
end;
$$;

-- ── RPC de leitura para a tela de pré-turno ─────────────────────────────
-- Devolve o tema efetivo do dia + flag "fallback" (veio de mês/ano anterior).
create or replace function public.tta_tema_do_dia(p_token uuid, p_ano int, p_mes int, p_dia int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_tema public.tta_temas;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  v_tema := public._tta_tema_efetivo(p_ano, p_mes, p_dia);
  if v_tema.id is null then return null; end if;
  return jsonb_build_object(
    'id',         v_tema.id,
    'assunto',    v_tema.assunto,
    'referencia', v_tema.referencia,
    'dias',       to_jsonb(v_tema.dias),
    'ano',        v_tema.ano,
    'mes',        v_tema.mes,
    'fallback',   (v_tema.ano <> p_ano or v_tema.mes <> p_mes)
  );
end;
$$;
grant execute on function public.tta_tema_do_dia(uuid, int, int, int) to anon;

-- ── tta_criar_chamada: usa o tema efetivo (mesmo fallback da tela) ───────
--    Redefinição idêntica à do db/42, trocando só a busca do tema pela
--    função _tta_tema_efetivo, para o TTA lançado nos primeiros dias do mês
--    já sair com o assunto/referência do mês anterior.
create or replace function public.tta_criar_chamada(p_token uuid, p_dados jsonb)
returns public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.tta_chamadas;
  v_tema public.tta_temas;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_conf text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- Impede duplicidade: militar/viatura já lançado(s) em outro TTA de hoje.
  v_conf := public._tta_conflitos(p_dados, v_hoje, null);
  if v_conf <> '' then
    raise exception 'Lançamento duplicado — %', v_conf;
  end if;

  -- Tema do dia com fallback pro mês anterior (mesma regra da tela de pré-turno).
  v_tema := public._tta_tema_efetivo(
    extract(year  from v_hoje)::int,
    extract(month from v_hoje)::int,
    extract(day   from v_hoje)::int
  );

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
grant execute on function public.tta_criar_chamada(uuid, jsonb) to anon;

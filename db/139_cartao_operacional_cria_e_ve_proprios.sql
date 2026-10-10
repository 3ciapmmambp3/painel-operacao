-- ════════════════════════════════════════════════════════════════════════
--  CARTÃO PROGRAMA — operacional pode EMITIR + vê os que ELE criou
--
--  Caso de uso: comandante de férias → o operacional precisa conseguir lançar
--  o Cartão Programa. Agora:
--   • cartao_criar: qualquer militar logado pode emitir, mas SÓ para o próprio
--     grupamento (a gestão segue com o escopo amplo do _cartao_pode_ver).
--   • cartao_listar: o operacional, além dos cartões em que está na equipe
--     (_cartao_tem_militar), passa a ver também os que ELE criou
--     (criado_por_matricula = a dele). A gestão não muda (vê o grupamento).
--
--  Depende de: 127 (cartao_criar/listar, _cartao_pode_ver), 130
--  (_cartao_tem_militar), 138 (cartao_listar atual). Idempotente. Rodar por último.
-- ════════════════════════════════════════════════════════════════════════

-- ─── CRIAR: qualquer militar emite, operacional só p/ o próprio grupamento ──
create or replace function public.cartao_criar(p_token uuid, dados jsonb)
returns public.cartoes_programa
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_ano int; v_seq int; v_grup text; v_row public.cartoes_programa;
  v_demandas jsonb := coalesce(dados->'demandas', '[]'::jsonb);
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  v_grup := nullif(btrim(dados->>'grupamento_id'), '');
  if v_grup is null then raise exception 'Grupamento é obrigatório.'; end if;
  -- Gestão: escopo amplo (_cartao_pode_ver). Demais (operacional): só o PRÓPRIO
  -- grupamento — assim o operacional lança quando o comandante está de férias.
  if not ( public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, v_grup)
           or v_grup = coalesce(v_me.grupamento_id,'') ) then
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

-- ─── LISTAR: gestão vê escopo; operacional vê os da sua equipe + os que criou ──
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
      and ( public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, c.grupamento_id)
            or public._cartao_tem_militar(c, v_me.matricula_clean)
            or lpad(regexp_replace(coalesce(c.criado_por_matricula,''),'\D','','g'),7,'0') = v_me.matricula_clean )
      and (p_ano is null or c.ano = p_ano)
      and (p_status is null or c.status = p_status)
      and (p_data is null or c.data_empenho = p_data)
      and (p_grupamento is null or c.grupamento_id = p_grupamento)
    order by c.data_empenho desc, c.numero_seq desc;
end;
$$;

grant execute on function public.cartao_criar(uuid, jsonb)                  to anon;
grant execute on function public.cartao_listar(uuid, int, text, date, text) to anon;
-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 127, 130 e 138).
-- ════════════════════════════════════════════════════════════════════════

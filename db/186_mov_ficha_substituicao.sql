-- ════════════════════════════════════════════════════════════════════════
-- 186_mov_ficha_substituicao.sql
--   Baixa da viatura SUBSTITUÍDA no TTA, com KM inicial/final + observação.
--
--   CENÁRIO (pedido do user 2026-11-12): durante o serviço a viatura de uma
--   equipe quebra/é trocada. Na maioria das vezes ela JÁ RODOU boa parte do dia.
--   Hoje o TTA, ao trocar a viatura, apenas CANCELA a pendência de Ficha da
--   antiga (db/91, db/92) — a quilometragem que ela rodou se perde. Agora, ao
--   corrigir a chamada e substituir a viatura, o militar informa se ela rodou e,
--   se sim, dá a BAIXA dela: KM inicial, KM final e uma observação/motivo da
--   troca. Isso vira uma Ficha de Movimentação real (mov_viaturas) da viatura
--   antiga — entra em Minhas Movimentações, no controle de frota e nos KM.
--
--   Esta RPC é dedicada à baixa por substituição:
--   • Grava a ficha da viatura ANTIGA com km_inicial/km_final/observacoes e
--     marca dados->>'origem' = 'substituicao' (+ 'substituida_por' = nova VTR).
--   • NÃO aplica o bloqueio de disponibilidade do mov_viatura_criar: a viatura
--     antiga pode estar prestes a ser baixada pelo Aux P4; isto é um registro
--     histórico do que ela rodou, não um novo empenho.
--   • Idempotente: re-salvar a correção do TTA ATUALIZA a baixa existente
--     (mesma viatura, mesmo dia, origem='substituicao') em vez de duplicar.
--   • Fecha a pendência aberta da viatura antiga no dia (se ainda houver).
--
--   Depende de: 08 (mov_viaturas/mov_pendencias), 84 (versão atual do RPC),
--               04 (_sessao_militar). Idempotente. Rodar depois do 185.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.mov_ficha_substituicao(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_row   public.mov_viaturas%rowtype;
  v_exist public.mov_viaturas%rowtype;
  v_pref  text := nullif(trim(p_dados->>'prefixo'),'');
  v_ini   timestamptz := coalesce((p_dados->>'inicio')::timestamptz, now());
  v_ter   timestamptz := coalesce((p_dados->>'termino')::timestamptz, now());
  v_dia   date := (v_ini at time zone 'America/Sao_Paulo')::date;
  v_kmi   int;
  v_kmf   int;
  v_json  jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if v_pref is null then raise exception 'Informe a viatura substituída.'; end if;

  -- KM obrigatórios e coerentes
  if nullif(p_dados->>'km_inicial','') is null or nullif(p_dados->>'km_final','') is null then
    raise exception 'Informe o KM inicial e o KM final da viatura substituída.';
  end if;
  v_kmi := (p_dados->>'km_inicial')::int;
  v_kmf := (p_dados->>'km_final')::int;
  if v_kmf < v_kmi then
    raise exception 'O KM final (%) não pode ser menor que o KM inicial (%).', v_kmf, v_kmi;
  end if;

  v_json := jsonb_build_object(
    'origem', 'substituicao',
    'substituida_por', nullif(p_dados->>'substituida_por',''),
    'por_matricula', v_me.matricula,
    'por_nome', coalesce(v_me.nome_guerra, v_me.nome_completo)
  );

  -- idempotência: já há baixa por substituição desta viatura, neste dia? atualiza.
  select * into v_exist from public.mov_viaturas m
   where m.ativo = true
     and m.prefixo = v_pref
     and coalesce(m.dados->>'origem','') = 'substituicao'
     and (coalesce(m.inicio, m.criado_em) at time zone 'America/Sao_Paulo')::date = v_dia
   order by m.criado_em desc
   limit 1;

  if v_exist.id is not null then
    update public.mov_viaturas set
      motorista_matricula = nullif(p_dados->>'motorista_matricula',''),
      motorista_nome      = nullif(p_dados->>'motorista_nome',''),
      km_inicial          = v_kmi,
      km_final            = v_kmf,
      termino             = v_ter,
      observacoes         = nullif(p_dados->>'observacoes',''),
      gp_responsavel      = coalesce(nullif(p_dados->>'gp_responsavel',''), gp_responsavel),
      grupamento_completo = coalesce(nullif(p_dados->>'grupamento_completo',''), grupamento_completo),
      dados               = v_json
    where id = v_exist.id
    returning * into v_row;
    return to_jsonb(v_row);
  end if;

  insert into public.mov_viaturas (
    prefixo, placa, motorista_matricula, motorista_nome, tipo_empenho,
    km_inicial, km_final, inicio, termino, observacoes,
    dados, gp_responsavel, grupamento_completo, ano, mes,
    criado_por_matricula, criado_por_nome
  ) values (
    v_pref,
    (select placa from public.viaturas where prefixo = v_pref),
    nullif(p_dados->>'motorista_matricula',''), nullif(p_dados->>'motorista_nome',''),
    'TTA — viatura substituída',
    v_kmi, v_kmf, v_ini, v_ter,
    nullif(p_dados->>'observacoes',''),
    v_json,
    nullif(p_dados->>'gp_responsavel',''), nullif(p_dados->>'grupamento_completo',''),
    extract(year from v_ini)::int, extract(month from v_ini)::int,
    v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo)
  ) returning * into v_row;

  -- fecha pendência aberta da viatura antiga nesse dia (se ainda houver)
  update public.mov_pendencias
     set atendida = true, mov_id = v_row.id
   where prefixo = v_row.prefixo
     and atendida = false
     and dia in (v_dia, (now() at time zone 'America/Sao_Paulo')::date);

  return to_jsonb(v_row);
end;
$$;

grant execute on function public.mov_ficha_substituicao(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 185.
-- ════════════════════════════════════════════════════════════════════════

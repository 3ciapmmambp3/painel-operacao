-- ════════════════════════════════════════════════════════════════════════
-- 33_frota_acidentes.sql — Controle de ACIDENTES de viatura (extração das fichas)
--
-- Cada ficha (mov_viaturas) pode ter UMA seção de acidente em
-- dados->'acidente' (objeto), marcada por tem_acidente=true. Campos:
--   { reds, odometro, data_hora, mesmo_motorista, pericia, cpu, vitimas,
--     responsavel, bafometro, guincho }
--
-- Depende de: 04 (_sessao_militar), 08 (mov_viaturas).
-- Idempotente. Rodar no SQL Editor depois do 08.
-- ════════════════════════════════════════════════════════════════════════

-- ── RPC: listar acidentes de um mês (p_mes null = todos os meses do ano) ─
create or replace function public.frota_acidentes_listar(p_token uuid, p_ano int, p_mes int)
returns table (
  mov_id uuid, prefixo text, placa text, data_ficha timestamptz,
  reds text, odometro text, data_hora text, vitimas text, pericia text,
  cpu text, bafometro text, guincho text, mesmo_motorista text, responsavel text,
  km_rodados int, motorista_nome text, motorista_matricula text, gp_responsavel text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if (select sm.id from public._sessao_militar(p_token) sm) is null then
    raise exception 'Sessão inválida ou expirada.';
  end if;
  return query
  select
    m.id::uuid, m.prefixo::text, m.placa::text,
    coalesce(m.inicio, m.criado_em)::timestamptz as data_ficha,
    nullif(m.dados->'acidente'->>'reds','')::text,
    nullif(m.dados->'acidente'->>'odometro','')::text,
    nullif(m.dados->'acidente'->>'data_hora','')::text,
    nullif(m.dados->'acidente'->>'vitimas','')::text,
    nullif(m.dados->'acidente'->>'pericia','')::text,
    nullif(m.dados->'acidente'->>'cpu','')::text,
    nullif(m.dados->'acidente'->>'bafometro','')::text,
    nullif(m.dados->'acidente'->>'guincho','')::text,
    nullif(m.dados->'acidente'->>'mesmo_motorista','')::text,
    nullif(m.dados->'acidente'->>'responsavel','')::text,
    m.km_rodados::int,
    m.motorista_nome::text, m.motorista_matricula::text, m.gp_responsavel::text
  from public.mov_viaturas m
  where m.ativo = true
    and coalesce(m.tem_acidente,false) = true
    and m.ano = p_ano
    and (p_mes is null or m.mes = p_mes)
  order by coalesce(m.inicio, m.criado_em) desc, m.prefixo;
end;
$$;

grant execute on function public.frota_acidentes_listar(uuid, int, int) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 08.
-- ════════════════════════════════════════════════════════════════════════

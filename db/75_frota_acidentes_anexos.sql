-- ════════════════════════════════════════════════════════════════════════
-- 75_frota_acidentes_anexos.sql — Fotos do acidente no listar/exportar
--
-- O painel de Acidentes de Viatura (acidentes.html) e o Exportar Excel
-- precisam dos LINKS das fotos anexadas na seção "Acidente" da ficha.
-- As fotos ficam na coluna jsonb mov_viaturas.anexos, marcadas com
-- categoria = 'acidente-fotos' (ver movimentacao-viaturas.html / coletarAnexos).
--
-- Aqui recriamos frota_acidentes_listar (33_frota_acidentes.sql) adicionando
-- a coluna `fotos jsonb` = [{nome, link}] só das fotos de acidente. Como a
-- assinatura de RETURNS TABLE muda, precisamos DROP antes do CREATE.
--
-- Depende de: 04 (_sessao_militar), 08 (mov_viaturas), 33 (versão anterior).
-- Idempotente. Rodar no SQL Editor depois do 33.
-- ════════════════════════════════════════════════════════════════════════

drop function if exists public.frota_acidentes_listar(uuid, int, int);

create or replace function public.frota_acidentes_listar(p_token uuid, p_ano int, p_mes int)
returns table (
  mov_id uuid, prefixo text, placa text, data_ficha timestamptz,
  reds text, odometro text, data_hora text, vitimas text, pericia text,
  cpu text, bafometro text, guincho text, mesmo_motorista text, responsavel text,
  km_rodados int, motorista_nome text, motorista_matricula text, gp_responsavel text,
  fotos jsonb
)
language plpgsql stable security definer set search_path = public as $$
begin
  if (select sm.id from public._sessao_militar(p_token) sm) is null then
    raise exception 'Sessão inválida ou expirada.';
  end if;
  if not exists (
    select 1 from public._sessao_militar(p_token) sm
     where public._pode_gerenciar_viaturas(sm.nivel_acesso, sm.funcao)
  ) then
    raise exception 'Sem permissão: dados de acidentes restritos ao Aux P4 / Admin Geral.';
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
    m.motorista_nome::text, m.motorista_matricula::text, m.gp_responsavel::text,
    coalesce((
      select jsonb_agg(jsonb_build_object('nome', a->>'nome', 'link', a->>'link'))
      from jsonb_array_elements(coalesce(m.anexos, '[]'::jsonb)) a
      where a->>'categoria' = 'acidente-fotos'
        and coalesce(a->>'link','') <> ''
    ), '[]'::jsonb) as fotos
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
-- FIM. Ordem no SQL Editor: depois do 33.
-- ════════════════════════════════════════════════════════════════════════

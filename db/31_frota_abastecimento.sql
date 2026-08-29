-- ════════════════════════════════════════════════════════════════════════
-- 31_frota_abastecimento.sql — Painel de ABASTECIMENTO + controle SIAD
--
-- Extrai os abastecimentos lançados nas fichas (mov_viaturas.dados->'abastecimento'
-- ->'itens'[]) para o gestor acompanhar por mês: litros, km rodados por viatura,
-- e marcar o que já foi LANÇADO NO SIAD (só Convênio/Doação vão pro SIAD).
--
-- Estrutura de cada item (montado em movimentacao-viaturas.html salvar()):
--   { fonte:'POC'|'Cartão PRIME'|'Convênio ou Doação', combustivel, litros,
--     valor_unit, valor_total, odometro, data_hora, cidade, obs,
--     tipo:'Convênio'|'Doação esporádica', convenio, doador, ... }
--
-- Depende de: 04 (_sessao_militar), 08 (mov_viaturas), 10 (_pode_gerenciar_viaturas).
-- Idempotente. Rodar no SQL Editor depois do 10.
-- ════════════════════════════════════════════════════════════════════════

-- ── Controle do que já foi lançado no SIAD ──────────────────────────────
-- Chave = (mov_id, idx do item dentro do array). Presença da linha = lançado.
create table if not exists public.siad_lancado (
  mov_id       uuid not null,
  idx          int  not null,
  lancado_por  text,
  lancado_em   timestamptz not null default now(),
  primary key (mov_id, idx)
);

-- ── RPC: listar abastecimentos de um mês (ano+mes), 1 linha por item ─────
-- p_ano/p_mes filtram pela data da ficha (coluna ano/mes de mov_viaturas).
create or replace function public.frota_abast_listar(p_token uuid, p_ano int, p_mes int)
returns table (
  mov_id uuid, idx int, prefixo text, placa text,
  data_ficha timestamptz, fonte text, tipo text, combustivel text,
  litros numeric, valor_total numeric, convenio text, doador text,
  km_rodados int, vai_siad boolean, siad_lancado boolean,
  motorista_nome text, gp_responsavel text
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
    raise exception 'Sem permissão: dados de abastecimento restritos ao Aux P4 / Admin Geral.';
  end if;
  return query
  select
    m.id as mov_id,
    (it.ord - 1)::int as idx,
    m.prefixo::text, m.placa::text,
    coalesce(m.inicio, m.criado_em)::timestamptz as data_ficha,
    nullif(it.item->>'fonte','')::text        as fonte,
    nullif(it.item->>'tipo','')::text         as tipo,
    nullif(it.item->>'combustivel','')::text  as combustivel,
    nullif(it.item->>'litros','')::numeric      as litros,
    nullif(it.item->>'valor_total','')::numeric as valor_total,
    nullif(it.item->>'convenio','')::text     as convenio,
    nullif(it.item->>'doador','')::text       as doador,
    m.km_rodados::int,
    -- vai pro SIAD? só a fonte "Convênio ou Doação"
    (coalesce(it.item->>'fonte','') = 'Convênio ou Doação') as vai_siad,
    (s.mov_id is not null) as siad_lancado,
    m.motorista_nome::text, m.gp_responsavel::text
  from public.mov_viaturas m
  cross join lateral jsonb_array_elements(
      coalesce(m.dados->'abastecimento'->'itens', '[]'::jsonb)
  ) with ordinality as it(item, ord)
  left join public.siad_lancado s on s.mov_id = m.id and s.idx = (it.ord - 1)
  where m.ativo = true
    and m.ano = p_ano
    and (p_mes is null or m.mes = p_mes)   -- p_mes null = todos os meses do ano
  order by coalesce(m.inicio, m.criado_em) desc, m.prefixo, idx;
end;
$$;

-- ── RPC: totais do mês (litros por fonte, km rodados) ───────────────────
create or replace function public.frota_abast_totais(p_token uuid, p_ano int, p_mes int)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb;
begin
  if (select sm.id from public._sessao_militar(p_token) sm) is null then
    raise exception 'Sessão inválida ou expirada.';
  end if;
  if not exists (
    select 1 from public._sessao_militar(p_token) sm
     where public._pode_gerenciar_viaturas(sm.nivel_acesso, sm.funcao)
  ) then
    raise exception 'Sem permissão: dados de abastecimento restritos ao Aux P4 / Admin Geral.';
  end if;
  with itens as (
    select
      nullif(it.item->>'fonte','') as fonte,
      nullif(it.item->>'litros','')::numeric as litros
    from public.mov_viaturas m
    cross join lateral jsonb_array_elements(
        coalesce(m.dados->'abastecimento'->'itens', '[]'::jsonb)
    ) as it(item)
    where m.ativo = true and m.ano = p_ano and (p_mes is null or m.mes = p_mes)
  ),
  km as (
    select m.prefixo, sum(coalesce(m.km_rodados,0)) as km
    from public.mov_viaturas m
    where m.ativo = true and m.ano = p_ano and (p_mes is null or m.mes = p_mes)
    group by m.prefixo
  )
  select jsonb_build_object(
    'litros_total', coalesce((select sum(litros) from itens), 0),
    'litros_por_fonte', coalesce((
      select jsonb_object_agg(fonte, s) from (
        select coalesce(fonte,'—') as fonte, sum(coalesce(litros,0)) as s
        from itens group by 1
      ) t
    ), '{}'::jsonb),
    'km_por_viatura', coalesce((
      select jsonb_object_agg(prefixo, km) from km
    ), '{}'::jsonb),
    'km_total', coalesce((select sum(km) from km), 0)
  ) into v_out;
  return v_out;
end;
$$;

-- ── RPC: marcar / desmarcar "lançado no SIAD" (restrito gestor) ─────────
create or replace function public.frota_siad_marcar(p_token uuid, p_mov_id uuid, p_idx int, p_lancado boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: controle do SIAD é do Aux P4 / Admin Geral.';
  end if;
  if coalesce(p_lancado, false) then
    insert into public.siad_lancado (mov_id, idx, lancado_por, lancado_em)
    values (p_mov_id, p_idx, v_me.matricula, now())
    on conflict (mov_id, idx) do update set lancado_por = excluded.lancado_por, lancado_em = now();
  else
    delete from public.siad_lancado where mov_id = p_mov_id and idx = p_idx;
  end if;
  return jsonb_build_object('ok', true, 'lancado', coalesce(p_lancado,false));
end;
$$;

alter table public.siad_lancado enable row level security;
-- acesso só via RPC (security definer)

grant execute on function public.frota_abast_listar(uuid, int, int) to anon;
grant execute on function public.frota_abast_totais(uuid, int, int) to anon;
grant execute on function public.frota_siad_marcar(uuid, uuid, int, boolean) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 10.
-- ════════════════════════════════════════════════════════════════════════

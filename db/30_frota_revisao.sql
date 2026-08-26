-- ════════════════════════════════════════════════════════════════════════
-- 30_frota_revisao.sql — Controle de REVISÃO da frota (por km da próxima revisão)
--
-- O gestor informa, por viatura, o "km da próxima revisão". O sistema compara
-- com o hodômetro atual (max km_final de mov_viaturas) e alerta quando faltar
-- ≤ 1.000 km (ou já vencida). O cadastro `viaturas` é escrito pelo Apps Script
-- (painel só lê), por isso a revisão vai numa tabela própria.
--
-- Depende de: 04 (_sessao_militar), 08 (viaturas / mov_viaturas),
--             10 (_pode_gerenciar_viaturas).
-- Idempotente. Rodar no SQL Editor depois do 10.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.viatura_revisao (
  prefixo               text primary key,
  km_proxima_revisao    int,
  obs                   text,
  atualizado_por        text,
  atualizado_em         timestamptz not null default now()
);

-- ── RPC: listar frota com hodômetro atual + km até a próxima revisão ─────
-- Devolve TODAS as viaturas ativas com: km atual (última devolução), km da
-- próxima revisão (se cadastrado), km faltando e um "status" já calculado.
-- Alerta: faltando <= 1000 km => 'proxima'; <= 0 => 'vencida'.
create or replace function public.frota_revisao_listar(p_token uuid)
returns table (
  prefixo text, placa text, marca_modelo text, gp text, municipio text,
  km_atual int, km_proxima_revisao int, km_faltando int, status text, obs text,
  atualizado_por text, atualizado_em timestamptz
)
language plpgsql stable security definer set search_path = public as $$
begin
  if (select sm.id from public._sessao_militar(p_token) sm) is null then
    raise exception 'Sessão inválida ou expirada.';
  end if;
  return query
  with km as (
    select m.prefixo, max(m.km_final) as km_atual
    from public.mov_viaturas m
    where m.ativo = true and m.km_final is not null
    group by m.prefixo
  )
  select
    v.prefixo, v.placa, v.marca_modelo, v.gp, v.municipio,
    km.km_atual,
    r.km_proxima_revisao,
    case when r.km_proxima_revisao is not null and km.km_atual is not null
         then r.km_proxima_revisao - km.km_atual end as km_faltando,
    case
      when r.km_proxima_revisao is null then 'sem_cadastro'
      when km.km_atual is null then 'sem_km'
      when (r.km_proxima_revisao - km.km_atual) <= 0 then 'vencida'
      when (r.km_proxima_revisao - km.km_atual) <= 1000 then 'proxima'
      else 'ok'
    end as status,
    r.obs, r.atualizado_por, r.atualizado_em
  from public.viaturas v
  left join km on km.prefixo = v.prefixo
  left join public.viatura_revisao r on r.prefixo = v.prefixo
  where coalesce(v.ativo, true) = true
  order by
    case
      when r.km_proxima_revisao is not null and km.km_atual is not null
        then (r.km_proxima_revisao - km.km_atual)
      else 2147483647
    end asc,
    v.prefixo;
end;
$$;

-- ── RPC: salvar o km da próxima revisão de uma viatura (restrito gestor) ──
create or replace function public.frota_revisao_salvar(p_token uuid, p_prefixo text, p_km int, p_obs text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: controle de revisão é do Aux P4 / Admin Geral.';
  end if;
  if nullif(btrim(p_prefixo),'') is null then raise exception 'Informe a viatura.'; end if;

  insert into public.viatura_revisao (prefixo, km_proxima_revisao, obs, atualizado_por, atualizado_em)
  values (btrim(p_prefixo), p_km, nullif(btrim(p_obs),''), v_me.matricula, now())
  on conflict (prefixo) do update
    set km_proxima_revisao = excluded.km_proxima_revisao,
        obs = excluded.obs,
        atualizado_por = excluded.atualizado_por,
        atualizado_em = now();
  return jsonb_build_object('ok', true);
end;
$$;

-- ── RPC leve: só os alertas (viaturas próximas/vencidas) — p/ Meu Dia e ficha ──
-- Traz gp/município da viatura p/ o Meu Dia mostrar o aviso também aos integrantes
-- do grupamento onde a viatura está lotada (não só ao gestor de frota).
-- (drop antes: o retorno mudou — ganhou gp/municipio; create or replace não altera tipo de retorno.)
drop function if exists public.frota_revisao_alertas(uuid);
create or replace function public.frota_revisao_alertas(p_token uuid)
returns table (prefixo text, km_atual int, km_proxima_revisao int, km_faltando int, status text, gp text, municipio text)
language sql stable security definer set search_path = public as $$
  select prefixo, km_atual, km_proxima_revisao, km_faltando, status, gp, municipio
  from public.frota_revisao_listar(p_token)
  where status in ('proxima','vencida')
  order by km_faltando asc;
$$;

alter table public.viatura_revisao enable row level security;
-- acesso só via RPC (security definer); sem policy de select p/ anon.

grant execute on function public.frota_revisao_listar(uuid) to anon;
grant execute on function public.frota_revisao_salvar(uuid, text, int, text) to anon;
grant execute on function public.frota_revisao_alertas(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 10.
-- ════════════════════════════════════════════════════════════════════════

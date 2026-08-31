-- ════════════════════════════════════════════════════════════════════════
-- 47_defeitos_manut_campos.sql — situação / endereço / serviços no defeito AVULSO
--
-- O botão 🔧 "Manutenção / defeito reportado" (Revisão da frota) passou a ter os
-- mesmos campos novos da ficha: Situação da viatura, Endereço (imobilizada) e
-- Serviços solicitados. Este SQL:
--   • adiciona as colunas em defeitos_reportados;
--   • grava-as no defeito_reportar;
--   • devolve-as no defeitos_listar (ramo avulso) e também traz os serviços do
--     ramo FICHA (dados->'manutencao'->'servicos_solicitados').
--
-- Depende de: 08 (viaturas / _pode_gerenciar_viaturas), 34 (defeitos_reportados /
--             defeito_ficha_resolvido), 46 (defeitos_listar c/ situacao/endereco/lotação).
-- Idempotente. Rodar no SQL Editor depois do 46.
-- ════════════════════════════════════════════════════════════════════════

-- 1) Colunas novas no defeito AVULSO
alter table public.defeitos_reportados add column if not exists situacao             text;
alter table public.defeitos_reportados add column if not exists endereco             text;
alter table public.defeitos_reportados add column if not exists servicos_solicitados jsonb not null default '[]'::jsonb;

-- 2) Reportar defeito AVULSO — grava os campos novos
create or replace function public.defeito_reportar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_v record; v_row public.defeitos_reportados%rowtype;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if nullif(btrim(p_dados->>'prefixo'),'') is null then raise exception 'Informe a viatura.'; end if;
  if nullif(btrim(p_dados->>'defeito'),'') is null then raise exception 'Descreva o defeito.'; end if;
  select prefixo, placa, gp, municipio into v_v from public.viaturas where prefixo = btrim(p_dados->>'prefixo');
  insert into public.defeitos_reportados (
    prefixo, placa, gp, municipio, tipo, urgencia, odometro, defeito, impede_uso, observacoes,
    situacao, endereco, servicos_solicitados,
    reportado_por_matricula, reportado_por_nome
  ) values (
    btrim(p_dados->>'prefixo'), v_v.placa, v_v.gp, v_v.municipio,
    nullif(p_dados->>'tipo',''), nullif(p_dados->>'urgencia',''), nullif(p_dados->>'odometro',''),
    btrim(p_dados->>'defeito'), nullif(p_dados->>'impede_uso',''), nullif(p_dados->>'observacoes',''),
    nullif(p_dados->>'situacao',''), nullif(p_dados->>'endereco',''),
    coalesce(p_dados->'servicos_solicitados','[]'::jsonb),
    v_me.matricula, coalesce(v_me.nome_completo, v_me.nome_guerra, v_me.matricula)
  ) returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- 3) Listar defeitos — devolve serviços; avulso traz situacao/endereco/serviços; ficha traz serviços
drop function if exists public.defeitos_listar(uuid, text);

create or replace function public.defeitos_listar(p_token uuid, p_status text default null)
returns table (
  origem text, ref_id uuid, prefixo text, placa text, gp text, municipio text,
  tipo text, urgencia text, odometro text, defeito text, impede_uso text, observacoes text,
  situacao text, endereco text, servicos_solicitados jsonb,
  vtr_gp text, vtr_pel text, vtr_municipio text,
  status text, reportado_por_nome text, criado_em timestamptz
)
language plpgsql stable security definer set search_path = public as $$
declare v_me record; v_gestor boolean; v_muni text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  v_gestor := public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao);
  v_muni   := upper(btrim(split_part(coalesce(v_me.grupamento_id,''), '/', -1)));

  return query
  with avulsos as (
    select 'avulso'::text as origem, d.id as ref_id, d.prefixo, d.placa, d.gp, d.municipio,
           d.tipo, d.urgencia, d.odometro, d.defeito, d.impede_uso, d.observacoes,
           d.situacao, d.endereco, coalesce(d.servicos_solicitados,'[]'::jsonb) as servicos_solicitados,
           va.gp::text as vtr_gp, va.pel::text as vtr_pel, va.municipio::text as vtr_municipio,
           d.status, d.reportado_por_nome, d.criado_em
    from public.defeitos_reportados d
    left join public.viaturas va on va.prefixo = d.prefixo
  ),
  fichas as (
    select 'ficha'::text as origem, m.id as ref_id, m.prefixo::text, m.placa::text,
           m.gp_responsavel::text as gp, v.municipio::text as municipio,
           nullif(m.dados->'manutencao'->>'tipo','')::text,
           nullif(m.dados->'manutencao'->>'urgencia','')::text,
           nullif(m.dados->'manutencao'->>'odometro','')::text,
           coalesce(nullif(m.dados->'manutencao'->>'defeito',''),'(defeito informado na ficha)')::text,
           nullif(m.dados->'manutencao'->>'impede_uso','')::text,
           nullif(m.dados->'manutencao'->>'obs','')::text,
           nullif(m.dados->'manutencao'->>'situacao','')::text as situacao,
           nullif(m.dados->'manutencao'->>'endereco_imobilizada','')::text as endereco,
           coalesce(m.dados->'manutencao'->'servicos_solicitados','[]'::jsonb) as servicos_solicitados,
           v.gp::text as vtr_gp, v.pel::text as vtr_pel, v.municipio::text as vtr_municipio,
           case when r.mov_id is not null then 'resolvido' else 'aberto' end::text as status,
           m.motorista_nome::text as reportado_por_nome,
           coalesce(m.inicio, m.criado_em)::timestamptz as criado_em
    from public.mov_viaturas m
    left join public.viaturas v on v.prefixo = m.prefixo
    left join public.defeito_ficha_resolvido r on r.mov_id = m.id
    where m.ativo = true and coalesce(m.tem_manutencao,false) = true
  ),
  todos as ( select * from avulsos union all select * from fichas )
  select * from todos t
  where (p_status is null or t.status = p_status)
    and (v_gestor or (v_muni <> '' and upper(coalesce(t.municipio,'')) = v_muni))
  order by (t.status='aberto') desc, t.criado_em desc;
end;
$$;

grant execute on function public.defeito_reportar(uuid, jsonb) to anon;
grant execute on function public.defeitos_listar(uuid, text) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 46.
-- ════════════════════════════════════════════════════════════════════════

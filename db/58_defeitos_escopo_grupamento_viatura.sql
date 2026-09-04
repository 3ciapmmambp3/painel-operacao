-- ════════════════════════════════════════════════════════════════════════
-- 58_defeitos_escopo_grupamento_viatura.sql
--
-- Escopo de quem vê cada defeito reportado. Substitui a defeitos_listar por
-- completo (engloba o db/57) — rodar SÓ este 58 já basta, mesmo que o 57 não
-- tenha sido rodado.
--
-- Quem NÃO é gestor (Aux P4 / Admin Geral) passa a ver um defeito quando:
--   (a) a viatura está no MESMO MUNICÍPIO do seu grupamento  (regra antiga); OU
--   (b) a viatura pertence ao MESMO GRUPAMENTO (GP) do usuário — controle do GP,
--       mesmo que a viatura esteja em outro município;                 (NOVO) OU
--   (c) foi o PRÓPRIO usuário quem reportou (ex.: em operação com viatura de
--       outro GP) — para acompanhar o que reportou.                    (db/57)
-- Gestor continua vendo tudo.
--
-- O número do GP é extraído por regex tolerante a "º"/espaços ('(\d+)\D*GP'),
-- mesma lógica de escopo por GP do hub_kpis (db/25).
--
-- Depende de: 47 (defeitos_listar base). Idempotente. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

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
declare v_me record; v_gestor boolean; v_muni text; v_mat text; v_meu_gp int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  v_gestor := public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao);
  v_muni   := upper(btrim(split_part(coalesce(v_me.grupamento_id,''), '/', -1)));
  v_mat    := regexp_replace(coalesce(v_me.matricula,''), '\D', '', 'g'); -- só dígitos
  v_meu_gp := (regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\D*GP', 'i'))[1]::int;

  return query
  with avulsos as (
    select 'avulso'::text as origem, d.id as ref_id, d.prefixo, d.placa, d.gp, d.municipio,
           d.tipo, d.urgencia, d.odometro, d.defeito, d.impede_uso, d.observacoes,
           d.situacao, d.endereco, coalesce(d.servicos_solicitados,'[]'::jsonb) as servicos_solicitados,
           va.gp::text as vtr_gp, va.pel::text as vtr_pel, va.municipio::text as vtr_municipio,
           d.status, d.reportado_por_nome, d.criado_em,
           regexp_replace(coalesce(d.reportado_por_matricula,''),'\D','','g') as rep_mat,
           (regexp_match(coalesce(nullif(va.gp,''), d.gp, ''), '(\d+)\D*GP', 'i'))[1]::int as gp_num
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
           coalesce(m.inicio, m.criado_em)::timestamptz as criado_em,
           regexp_replace(coalesce(nullif(m.motorista_matricula,''), m.criado_por_matricula, ''),'\D','','g') as rep_mat,
           (regexp_match(coalesce(nullif(v.gp,''), m.gp_responsavel, ''), '(\d+)\D*GP', 'i'))[1]::int as gp_num
    from public.mov_viaturas m
    left join public.viaturas v on v.prefixo = m.prefixo
    left join public.defeito_ficha_resolvido r on r.mov_id = m.id
    where m.ativo = true and coalesce(m.tem_manutencao,false) = true
  ),
  todos as ( select * from avulsos union all select * from fichas )
  select t.origem, t.ref_id, t.prefixo, t.placa, t.gp, t.municipio,
         t.tipo, t.urgencia, t.odometro, t.defeito, t.impede_uso, t.observacoes,
         t.situacao, t.endereco, t.servicos_solicitados,
         t.vtr_gp, t.vtr_pel, t.vtr_municipio,
         t.status, t.reportado_por_nome, t.criado_em
  from todos t
  where (p_status is null or t.status = p_status)
    and (
          v_gestor
       or (v_muni <> '' and upper(coalesce(t.municipio,'')) = v_muni)          -- mesmo município
       or (v_meu_gp is not null and t.gp_num = v_meu_gp)                        -- mesmo grupamento da viatura
       or (v_mat  <> '' and t.rep_mat = v_mat)                                  -- o que ele mesmo reportou
    )
  order by (t.status='aberto') desc, t.criado_em desc;
end;
$$;

grant execute on function public.defeitos_listar(uuid, text) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar este 58 no SQL Editor (substitui/engloba o 57).
-- ════════════════════════════════════════════════════════════════════════

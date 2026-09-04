-- ════════════════════════════════════════════════════════════════════════
-- 57_defeitos_ver_o_que_reportei.sql
--
-- Antes: quem NÃO é gestor (Aux P4 / Admin Geral) só via os defeitos cujo
-- MUNICÍPIO da viatura batia com o município do seu grupamento. Se a viatura
-- era de outro município (ou o grupamento não resolvia pro mesmo município),
-- o defeito que o próprio usuário reportou não aparecia pra ele — só pro admin.
--
-- Agora: além do escopo por município, o usuário SEMPRE vê os defeitos que
-- ELE MESMO reportou (avulso: reportado_por_matricula; ficha: motorista/criador),
-- para poder acompanhar/controlar.
--
-- Depende de: 47 (defeitos_listar atual). Idempotente. Rodar depois do 47.
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
declare v_me record; v_gestor boolean; v_muni text; v_mat text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  v_gestor := public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao);
  v_muni   := upper(btrim(split_part(coalesce(v_me.grupamento_id,''), '/', -1)));
  v_mat    := regexp_replace(coalesce(v_me.matricula,''), '\D', '', 'g'); -- só dígitos

  return query
  with avulsos as (
    select 'avulso'::text as origem, d.id as ref_id, d.prefixo, d.placa, d.gp, d.municipio,
           d.tipo, d.urgencia, d.odometro, d.defeito, d.impede_uso, d.observacoes,
           d.situacao, d.endereco, coalesce(d.servicos_solicitados,'[]'::jsonb) as servicos_solicitados,
           va.gp::text as vtr_gp, va.pel::text as vtr_pel, va.municipio::text as vtr_municipio,
           d.status, d.reportado_por_nome, d.criado_em,
           regexp_replace(coalesce(d.reportado_por_matricula,''),'\D','','g') as rep_mat
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
           regexp_replace(coalesce(nullif(m.motorista_matricula,''), m.criado_por_matricula, ''),'\D','','g') as rep_mat
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
       or (v_muni <> '' and upper(coalesce(t.municipio,'')) = v_muni)
       or (v_mat  <> '' and t.rep_mat = v_mat)   -- o que ELE MESMO reportou
    )
  order by (t.status='aberto') desc, t.criado_em desc;
end;
$$;

grant execute on function public.defeitos_listar(uuid, text) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 47.
-- ════════════════════════════════════════════════════════════════════════

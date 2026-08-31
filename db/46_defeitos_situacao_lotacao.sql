-- ════════════════════════════════════════════════════════════════════════
-- 46_defeitos_situacao_lotacao.sql — mais campos na lista de defeitos (Aux P4)
--
-- Acrescenta à listagem de defeitos (Revisão da frota → "Defeitos reportados"):
--   • situacao / endereco  — vindos da seção Manutenção da ficha
--                            (dados->'manutencao'->>'situacao' / 'endereco_imobilizada').
--   • lotação da VIATURA    — gp / pel / município do CADASTRO (tabela viaturas),
--                            para o Aux P4 preencher o agendamento externo sem
--                            precisar pesquisar de qual grupamento é a viatura.
--
-- Recria public.defeitos_listar (novas colunas no retorno → precisa DROP antes).
-- Depende de: 08 (viaturas / mov_viaturas / _pode_gerenciar_viaturas),
--             34 (defeitos_reportados / defeito_ficha_resolvido).
-- Idempotente. Rodar no SQL Editor depois do 34.
-- ════════════════════════════════════════════════════════════════════════

drop function if exists public.defeitos_listar(uuid, text);

create or replace function public.defeitos_listar(p_token uuid, p_status text default null)
returns table (
  origem text, ref_id uuid, prefixo text, placa text, gp text, municipio text,
  tipo text, urgencia text, odometro text, defeito text, impede_uso text, observacoes text,
  situacao text, endereco text,
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
           null::text as situacao, null::text as endereco,
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

grant execute on function public.defeitos_listar(uuid, text) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 34.
-- ════════════════════════════════════════════════════════════════════════

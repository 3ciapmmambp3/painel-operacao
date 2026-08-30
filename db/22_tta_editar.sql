-- ════════════════════════════════════════════════════════════════════════
-- 22_tta_editar.sql — Correção da chamada do TTA no MESMO dia
--
-- Permite ao AUTOR da chamada corrigi-la, desde que seja do MESMO dia. Não
-- altera data/hora, tema nem quem registrou. Base para o botão "Corrigir
-- chamada de hoje" em tta.html.
--
-- Depende de: 04_sessoes_e_militares_seguranca.sql, 07_tta.sql.
-- Idempotente. Rodar no SQL Editor, depois do 07.
-- ════════════════════════════════════════════════════════════════════════

-- Regras (db/42): quem pode editar = o AUTOR no mesmo dia, OU o Aux P1 (ADM) /
-- Admin Geral (qualquer dia, p/ correção). Substituir viatura/militar exige
-- JUSTIFICATIVA (p_dados->>'justificativa'). Toda edição é auditada. Continua
-- impedindo duplicidade (militar/viatura já em outro TTA do mesmo dia).
create or replace function public.tta_editar_chamada(p_token uuid, p_id uuid, p_dados jsonb)
returns public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_old   public.tta_chamadas;
  v_new   public.tta_chamadas;
  v_hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  v_data  date;
  v_gestor boolean;
  v_conf  text;
  v_just  text := nullif(btrim(p_dados->>'justificativa'),'');
  v_old_mats text[]; v_new_mats text[];
  v_old_vtr  text[]; v_new_vtr  text[];
  v_subst boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;

  select * into v_old from public.tta_chamadas where id = p_id;
  if v_old.id is null then
    raise exception 'Chamada não encontrada.';
  end if;

  v_gestor := public._pode_gerenciar_tta(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id);
  v_data   := (v_old.data_hora_chamada at time zone 'America/Sao_Paulo')::date;
  if not v_gestor then
    if v_old.militar_resp_matricula <> v_me.matricula then
      raise exception 'Só o autor da chamada (ou o Aux P1/Admin) pode corrigi-la.';
    end if;
    if v_data <> v_hoje then
      raise exception 'A correção do TTA só é permitida no mesmo dia da chamada (fale com o Aux P1).';
    end if;
  end if;

  -- Duplicidade (mesmo dia da PRÓPRIA chamada, ignorando ela mesma)
  v_conf := public._tta_conflitos(p_dados, v_data, p_id);
  if v_conf <> '' then
    raise exception 'Lançamento duplicado — %', v_conf;
  end if;

  -- Substituição? (mudou o conjunto de militares OU de viaturas)
  select coalesce(array_agg(distinct m order by m) filter (where m <> ''), '{}') into v_old_mats
    from (select regexp_replace(coalesce(e->>'matricula',''),'\D','','g') m
            from jsonb_array_elements(v_old.militares_presentes) e) s;
  select coalesce(array_agg(distinct m order by m) filter (where m <> ''), '{}') into v_new_mats
    from (select regexp_replace(coalesce(e->>'matricula',''),'\D','','g') m
            from jsonb_array_elements(coalesce(p_dados->'militares_presentes','[]'::jsonb)) e) s;
  select coalesce(array_agg(distinct p order by p) filter (where p <> ''), '{}') into v_old_vtr
    from (select trim(coalesce(v->>'prefixo','')) p
            from jsonb_array_elements(v_old.viaturas) v) s;
  select coalesce(array_agg(distinct p order by p) filter (where p <> ''), '{}') into v_new_vtr
    from (select trim(coalesce(v->>'prefixo','')) p
            from jsonb_array_elements(coalesce(p_dados->'viaturas','[]'::jsonb)) v) s;
  v_subst := (v_old_mats is distinct from v_new_mats) or (v_old_vtr is distinct from v_new_vtr);

  if v_subst and v_just is null then
    raise exception 'Justificativa obrigatória para substituir viatura ou militar da equipe.';
  end if;

  update public.tta_chamadas set
    gp_responsavel      = coalesce(nullif(p_dados->>'gp_responsavel',''),      gp_responsavel),
    grupamento_completo = coalesce(nullif(p_dados->>'grupamento_completo',''), grupamento_completo),
    militares_presentes = coalesce(p_dados->'militares_presentes',             militares_presentes),
    inicio_turno        = nullif(p_dados->>'inicio_turno','')::time,
    final_turno         = nullif(p_dados->>'final_turno','')::time,
    prefixo_viatura     = nullif(p_dados->>'prefixo_viatura',''),
    viaturas            = coalesce(p_dados->'viaturas',            viaturas),
    equipes             = coalesce(p_dados->'equipes',            equipes),
    tipo_patrulha       = nullif(p_dados->>'tipo_patrulha',''),
    municipios_atuacao  = coalesce(p_dados->'municipios_atuacao', municipios_atuacao),
    observacoes         = nullif(p_dados->>'observacoes','')
  where id = p_id
  returning * into v_new;

  insert into public.tta_auditoria
    (chamada_id, acao, usuario_matricula, usuario_nome, registro_anterior, registro_novo, justificativa)
  values
    (p_id, case when v_subst then 'SUBSTITUICAO' else 'EDICAO' end,
     v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo),
     to_jsonb(v_old), to_jsonb(v_new), v_just);

  return v_new;
end;
$$;

grant execute on function public.tta_editar_chamada(uuid, uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 07_tta.sql.
-- ════════════════════════════════════════════════════════════════════════

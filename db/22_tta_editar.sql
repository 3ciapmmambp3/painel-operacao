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

create or replace function public.tta_editar_chamada(p_token uuid, p_id uuid, p_dados jsonb)
returns public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.tta_chamadas;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;

  select * into v_row from public.tta_chamadas where id = p_id;
  if v_row.id is null then
    raise exception 'Chamada não encontrada.';
  end if;
  if v_row.militar_resp_matricula <> v_me.matricula then
    raise exception 'Só o autor da chamada pode corrigi-la.';
  end if;
  if (v_row.data_hora_chamada at time zone 'America/Sao_Paulo')::date <> v_hoje then
    raise exception 'A correção do TTA só é permitida no mesmo dia da chamada.';
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
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.tta_editar_chamada(uuid, uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 07_tta.sql.
-- ════════════════════════════════════════════════════════════════════════

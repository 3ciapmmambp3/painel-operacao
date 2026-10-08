-- ════════════════════════════════════════════════════════════════════════
--  CARTÃO PROGRAMA — baixa da demanda de origem SÓ quando FINALIZADO (TOTAL)
--
--  Regra de negócio: só a situação "✅ Finalizado" (TOTAL) dá baixa na
--  denúncia/requisição de origem (situacao='RESPONDIDA'). "🟡 Em andamento"
--  (PARCIAL) e "⛔ Não atendido" (NAO) NÃO dão baixa — a demanda continua
--  pendente de atendimento (volta a ser listada para novo despacho).
--
--  Antes (db/129/131) a baixa disparava para TOTAL *ou* PARCIAL. Esta migration
--  recria cartao_atender(4 args) mudando a condição para SOMENTE 'TOTAL'.
--  Depende de: 127, 129, 131. Idempotente. Rodar depois do 131/132.
-- ════════════════════════════════════════════════════════════════════════
create or replace function public.cartao_atender(p_token uuid, p_id uuid, p_respostas jsonb, p_relatorio text default null)
returns public.cartoes_programa
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_cur public.cartoes_programa; v_row public.cartoes_programa;
  v_merged jsonb; k text; v_ent jsonb; v_carimbo jsonb;
  d jsonb; o jsonb; v_ord text; r jsonb; v_equipe text; v_assin text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_cur from public.cartoes_programa where id = p_id and ativo = true;
  if v_cur.id is null then raise exception 'Cartão não encontrado.'; end if;
  if not public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, v_cur.grupamento_id)
     and v_cur.grupamento_id <> coalesce(v_me.grupamento_id,'') then
    raise exception 'Você não pode responder este cartão.';
  end if;

  v_merged := coalesce(v_cur.respostas, '{}'::jsonb);
  v_carimbo := jsonb_build_object(
    'por_matricula', v_me.matricula,
    'por_nome', trim(both ' ' from concat(coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo))),
    'em', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF')
  );
  for k in select jsonb_object_keys(coalesce(p_respostas,'{}'::jsonb)) loop
    v_ent := p_respostas->k;
    if coalesce(v_ent->>'atendida','') <> '' then
      v_merged := jsonb_set(v_merged, array[k], v_ent || v_carimbo, true);
    end if;
  end loop;

  update public.cartoes_programa set
    respostas = v_merged,
    status    = public._cartao_status(demandas, v_merged),
    relatorio_id = coalesce(nullif(p_relatorio,''), relatorio_id),
    relatorio_em = case when nullif(p_relatorio,'') is not null then now() else relatorio_em end
  where id = p_id returning * into v_row;

  -- baixa das demandas puxadas do painel (d.origem) — SOMENTE as FINALIZADAS (TOTAL).
  -- PARCIAL (em andamento) e NAO (não atendido) permanecem PENDENTE/EM ANDAMENTO.
  v_equipe := nullif(btrim(concat_ws('; ', nullif(v_cur.comandante,''), nullif(v_cur.motorista,''))), '');
  v_assin  := trim(both ' ' from concat(v_me.matricula, ' — ', coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo)));
  for d in select * from jsonb_array_elements(coalesce(v_cur.demandas,'[]'::jsonb)) loop
    o := d->'origem'; v_ord := coalesce(d->>'ordem','');
    r := v_merged->v_ord;
    if o is not null and (o ? 'numero') and (o ? 'tipo')
       and r is not null and coalesce(r->>'atendida','') = 'TOTAL' then
      update public.denuncias set
        situacao = 'RESPONDIDA',
        data_resposta = coalesce(nullif(r->>'data_atendimento','')::date, data_resposta),
        numero_reds = coalesce(nullif(r->>'reds',''), numero_reds),
        numero_auto_infracao = coalesce(nullif(r->>'auto_infracao',''), numero_auto_infracao),
        numero_ato_fiscalizacao = coalesce(nullif(r->>'ato_fiscalizacao',''), numero_ato_fiscalizacao),
        observacoes_resposta = coalesce(nullif(r->>'obs',''), observacoes_resposta),
        resp_equipe = coalesce(resp_equipe, v_equipe),
        resp_viatura = coalesce(resp_viatura, nullif(v_cur.viatura,'')),
        atendido_por_matricula = v_me.matricula,
        atendido_por_nome = v_assin
      where numero = (o->>'numero') and tipo = (o->>'tipo') and ativo = true;
    end if;
  end loop;

  return v_row;
end;
$$;

grant execute on function public.cartao_atender(uuid, uuid, jsonb, text) to anon;
-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 131/132).
-- ════════════════════════════════════════════════════════════════════════

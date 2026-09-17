-- ════════════════════════════════════════════════════════════════════════
-- 87_mov_ficha_editar_equipe.sql — motorista também pode editar a ficha no dia
--
-- Como a ficha pode ser lançada pelo COMANDANTE (fica "Registrada por" ele) ou
-- pelo motorista, ambos precisam poder ALTERAR no mesmo dia. Antes, o
-- mov_ficha_editar (db/28) só liberava a edição para quem CRIOU (ou gestor).
--
-- FIX: v_mesmo_dia passa a valer quando o militar é o CRIADOR OU o MOTORISTA da
-- ficha, no mesmo dia (Brasília). Gestor (Aux P4/Admin Geral) segue editando
-- qualquer dia. Resto idêntico ao db/28. Idempotente. Rodar depois do 28.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.mov_ficha_editar(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_old public.mov_viaturas%rowtype; v_row public.mov_viaturas%rowtype;
  v_gestor boolean; v_mesmo_dia boolean; v_alt jsonb := '[]'::jsonb; v_mat text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  select * into v_old from public.mov_viaturas where id = p_id and ativo = true;
  if v_old.id is null then raise exception 'Ficha não encontrada.'; end if;

  v_mat    := regexp_replace(coalesce(v_me.matricula,''),'\D','','g');
  v_gestor := public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao);
  -- mesmo dia + (criador OU motorista da ficha)
  v_mesmo_dia := (
       ( regexp_replace(coalesce(v_old.criado_por_matricula,''),'\D','','g') = v_mat
      or regexp_replace(coalesce(v_old.motorista_matricula,''),'\D','','g') = v_mat )
   and (v_old.criado_em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date );
  if not (v_gestor or v_mesmo_dia) then
    raise exception 'Edição não permitida: só no mesmo dia (por quem criou ou o motorista) ou pelo gestor de viaturas.';
  end if;

  -- monta o diff (campos-chave) ANTES de atualizar
  declare
    v_new_prefixo text := coalesce(nullif(p_dados->>'prefixo',''), v_old.prefixo);
    v_new_placa   text := nullif(p_dados->>'placa','');
    v_new_motmat  text := nullif(p_dados->>'motorista_matricula','');
    v_new_motnome text := nullif(p_dados->>'motorista_nome','');
    v_new_lot     text := nullif(p_dados->>'lotacao_motorista','');
    v_new_local   text := nullif(p_dados->>'local_utilizacao','');
    v_new_emp     text := nullif(p_dados->>'tipo_empenho','');
    v_new_kmi     int  := (p_dados->>'km_inicial')::int;
    v_new_kmf     int  := (p_dados->>'km_final')::int;
    v_new_ini     timestamptz := (p_dados->>'inicio')::timestamptz;
    v_new_ter     timestamptz := (p_dados->>'termino')::timestamptz;
    v_new_ca      text := nullif(p_dados->>'comb_armar','');
    v_new_cd      text := nullif(p_dados->>'comb_devolver','');
    v_new_obs     text := nullif(p_dados->>'observacoes','');
  begin
    if v_new_prefixo is distinct from v_old.prefixo then v_alt := v_alt || jsonb_build_object('campo','Prefixo','antes',v_old.prefixo,'depois',v_new_prefixo); end if;
    if v_new_placa   is distinct from v_old.placa   then v_alt := v_alt || jsonb_build_object('campo','Placa','antes',v_old.placa,'depois',v_new_placa); end if;
    if v_new_motmat  is distinct from v_old.motorista_matricula then v_alt := v_alt || jsonb_build_object('campo','Matrícula do motorista','antes',v_old.motorista_matricula,'depois',v_new_motmat); end if;
    if v_new_motnome is distinct from v_old.motorista_nome then v_alt := v_alt || jsonb_build_object('campo','Motorista','antes',v_old.motorista_nome,'depois',v_new_motnome); end if;
    if v_new_lot     is distinct from v_old.lotacao_motorista then v_alt := v_alt || jsonb_build_object('campo','Lotação do motorista','antes',v_old.lotacao_motorista,'depois',v_new_lot); end if;
    if v_new_local   is distinct from v_old.local_utilizacao then v_alt := v_alt || jsonb_build_object('campo','Local de utilização','antes',v_old.local_utilizacao,'depois',v_new_local); end if;
    if v_new_emp     is distinct from v_old.tipo_empenho then v_alt := v_alt || jsonb_build_object('campo','Tipo de empenho','antes',v_old.tipo_empenho,'depois',v_new_emp); end if;
    if v_new_kmi     is distinct from v_old.km_inicial then v_alt := v_alt || jsonb_build_object('campo','Km inicial','antes',v_old.km_inicial,'depois',v_new_kmi); end if;
    if v_new_kmf     is distinct from v_old.km_final then v_alt := v_alt || jsonb_build_object('campo','Km final','antes',v_old.km_final,'depois',v_new_kmf); end if;
    if v_new_ini     is distinct from v_old.inicio then v_alt := v_alt || jsonb_build_object('campo','Início','antes',to_char(v_old.inicio,'DD/MM/YYYY HH24:MI'),'depois',to_char(v_new_ini,'DD/MM/YYYY HH24:MI')); end if;
    if v_new_ter     is distinct from v_old.termino then v_alt := v_alt || jsonb_build_object('campo','Término','antes',to_char(v_old.termino,'DD/MM/YYYY HH24:MI'),'depois',to_char(v_new_ter,'DD/MM/YYYY HH24:MI')); end if;
    if v_new_ca      is distinct from v_old.comb_armar then v_alt := v_alt || jsonb_build_object('campo','Combustível ao armar','antes',v_old.comb_armar,'depois',v_new_ca); end if;
    if v_new_cd      is distinct from v_old.comb_devolver then v_alt := v_alt || jsonb_build_object('campo','Combustível ao devolver','antes',v_old.comb_devolver,'depois',v_new_cd); end if;
    if v_new_obs     is distinct from v_old.observacoes then v_alt := v_alt || jsonb_build_object('campo','Observações','antes',v_old.observacoes,'depois',v_new_obs); end if;
    if coalesce(p_dados->'dados','{}'::jsonb)  is distinct from v_old.dados  then v_alt := v_alt || jsonb_build_object('campo','Seções (abastecimento/acidente/etc.)','antes','—','depois','alterado'); end if;
    if coalesce(p_dados->'anexos','[]'::jsonb) is distinct from v_old.anexos then v_alt := v_alt || jsonb_build_object('campo','Anexos','antes','—','depois','alterado'); end if;

    update public.mov_viaturas set
      prefixo=v_new_prefixo, placa=v_new_placa, motorista_matricula=v_new_motmat,
      motorista_nome=v_new_motnome, lotacao_motorista=v_new_lot, local_utilizacao=v_new_local,
      tipo_empenho=v_new_emp, km_inicial=v_new_kmi, km_final=v_new_kmf,
      inicio=coalesce(v_new_ini, inicio), termino=v_new_ter, comb_armar=v_new_ca, comb_devolver=v_new_cd,
      tem_abastecimento=coalesce((p_dados->>'tem_abastecimento')::boolean, tem_abastecimento),
      tem_acidente=coalesce((p_dados->>'tem_acidente')::boolean, tem_acidente),
      tem_manutencao=coalesce((p_dados->>'tem_manutencao')::boolean, tem_manutencao),
      tem_avaria=coalesce((p_dados->>'tem_avaria')::boolean, tem_avaria),
      tem_limpeza=coalesce((p_dados->>'tem_limpeza')::boolean, tem_limpeza),
      tem_taq=coalesce((p_dados->>'tem_taq')::boolean, tem_taq),
      tem_aeronave=coalesce((p_dados->>'tem_aeronave')::boolean, tem_aeronave),
      dados=coalesce(p_dados->'dados', dados), anexos=coalesce(p_dados->'anexos', anexos),
      observacoes=v_new_obs,
      atualizado_em=now(), atualizado_por_matricula=v_me.matricula,
      atualizado_por_nome=coalesce(v_me.nome_guerra, v_me.nome_completo)
    where id = p_id returning * into v_row;
  end;

  if jsonb_array_length(v_alt) > 0 then
    insert into public.mov_viaturas_audit (mov_id, editor_matricula, editor_nome, alteracoes)
    values (p_id, v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo), v_alt);
  end if;

  return jsonb_build_object('ok', true, 'id', p_id, 'alteracoes', jsonb_array_length(v_alt));
end;
$$;

grant execute on function public.mov_ficha_editar(uuid, uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 28.
-- ════════════════════════════════════════════════════════════════════════

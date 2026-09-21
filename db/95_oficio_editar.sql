-- ══════════════════════════════════════════════════════════════════════
--  OFÍCIOS — EDIÇÃO DOS DADOS PRINCIPAIS (janela de 24h, só quem registrou)
--
--  Pedido do usuário: permitir corrigir um ofício logo após lançá-lo, caso
--  tenha esquecido algo ou lançado errado — SEM mexer na numeração já gerada.
--
--  Regras:
--    • QUEM REGISTROU pode editar até 24h após o registro (created_at).
--    • A GESTÃO da P1 (Aux P1 / Admin / Admin Geral / CMT Cia — o mesmo grupo
--      de _oficio_escopo_total) edita QUALQUER ofício, SEM restrição de prazo
--      nem de autoria.
--    • A NUMERAÇÃO NÃO MUDA: numero, numero_seq, ano e tipo são preservados.
--    • Ofício EXCLUÍDO não pode ser editado.
--    • grupamento_id (visibilidade) é recalculado do emitente (saída) /
--      destino_int (entrada), como no criar_oficio.
--    • Registra auditoria: editado_por_* e editado_em.
--
--  Depende de: 63_oficios.sql (tabela + _sessao_militar). Idempotente.
-- ══════════════════════════════════════════════════════════════════════

-- colunas de auditoria da edição (idempotentes)
alter table public.oficios add column if not exists editado_por_matricula text;
alter table public.oficios add column if not exists editado_por_nome      text;
alter table public.oficios add column if not exists editado_em            timestamptz;

create or replace function public.oficio_editar(p_token uuid, p_id uuid, p_dados jsonb)
returns public.oficios
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_row   public.oficios;
  v_grp   text;
  v_horas numeric;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_row from public.oficios where id = p_id;
  if v_row.id is null then raise exception 'Ofício não encontrado.'; end if;
  if v_row.situacao = 'EXCLUIDO' then
    raise exception 'Ofício excluído não pode ser editado.';
  end if;

  -- A GESTÃO da P1 (Aux P1 / Admin / Admin Geral / CMT Cia) edita qualquer
  -- ofício, sem restrição. Os DEMAIS: só quem registrou e só até 24h.
  if not public._oficio_escopo_total(v_me.nivel_acesso, v_me.funcao) then
    -- só quem registrou (compara só os dígitos da matrícula, tolerante ao formato)
    if regexp_replace(coalesce(v_row.registrado_por_matricula,''),'\D','','g')
         <> regexp_replace(coalesce(v_me.matricula,''),'\D','','g')
       or coalesce(v_me.matricula,'') = '' then
      raise exception 'Sem permissão: só quem registrou o ofício (ou a gestão da P1) pode editá-lo.';
    end if;
    -- janela de 24h a partir do registro
    v_horas := extract(epoch from (now() - v_row.created_at)) / 3600.0;
    if v_horas > 24 then
      raise exception 'Prazo de edição encerrado: alterações só são permitidas em até 24h após o registro.';
    end if;
  end if;

  -- grupamento p/ visibilidade: emitente (saída) / destino_int (entrada)
  if v_row.tipo = 'Saída' then
    v_grp := coalesce(nullif(p_dados->>'emitente',''), v_row.emitente);
  else
    v_grp := coalesce(nullif(p_dados->>'destino_int',''), v_row.destino_int);
  end if;

  update public.oficios set
    -- ⚠ NUMERAÇÃO PRESERVADA: numero, numero_seq, ano, tipo NÃO são alterados.
    data_doc      = coalesce(nullif(p_dados->>'data_doc','')::date, data_doc),
    assunto       = case when p_dados ? 'assunto'      then nullif(p_dados->>'assunto','')      else assunto      end,
    em_resposta   = case when p_dados ? 'em_resposta'  then nullif(p_dados->>'em_resposta','')  else em_resposta  end,
    responsavel   = case when p_dados ? 'responsavel'  then nullif(p_dados->>'responsavel','')  else responsavel  end,
    observacoes   = case when p_dados ? 'observacoes'  then nullif(p_dados->>'observacoes','')  else observacoes  end,
    grupamento_id = v_grp,
    -- SAÍDA
    emitente      = case when v_row.tipo='Saída'   and p_dados ? 'emitente'    then nullif(p_dados->>'emitente','')    else emitente    end,
    destino_ext   = case when v_row.tipo='Saída'   and p_dados ? 'destino_ext' then nullif(p_dados->>'destino_ext','') else destino_ext end,
    -- ENTRADA
    num_externo   = case when v_row.tipo='Entrada' and p_dados ? 'num_externo'  then nullif(p_dados->>'num_externo','')  else num_externo  end,
    emitente_ext  = case when v_row.tipo='Entrada' and p_dados ? 'emitente_ext' then nullif(p_dados->>'emitente_ext','') else emitente_ext end,
    destino_int   = case when v_row.tipo='Entrada' and p_dados ? 'destino_int'  then nullif(p_dados->>'destino_int','')  else destino_int  end,
    -- CORPO do ofício (saída, p/ o PDF)
    of_vocativo   = case when p_dados ? 'of_vocativo'   then nullif(p_dados->>'of_vocativo','')   else of_vocativo   end,
    of_corpo      = case when p_dados ? 'of_corpo'      then nullif(p_dados->>'of_corpo','')      else of_corpo      end,
    of_fecho      = case when p_dados ? 'of_fecho'      then nullif(p_dados->>'of_fecho','')      else of_fecho      end,
    of_cidade     = case when p_dados ? 'of_cidade'     then nullif(p_dados->>'of_cidade','')     else of_cidade     end,
    of_assinante  = case when p_dados ? 'of_assinante'  then nullif(p_dados->>'of_assinante','')  else of_assinante  end,
    of_cargo      = case when p_dados ? 'of_cargo'      then nullif(p_dados->>'of_cargo','')      else of_cargo      end,
    dest_tratamento = case when p_dados ? 'dest_tratamento' then nullif(p_dados->>'dest_tratamento','') else dest_tratamento end,
    dest_nome     = case when p_dados ? 'dest_nome'     then nullif(p_dados->>'dest_nome','')     else dest_nome     end,
    dest_orgao    = case when p_dados ? 'dest_orgao'    then nullif(p_dados->>'dest_orgao','')    else dest_orgao    end,
    dest_endereco = case when p_dados ? 'dest_endereco' then nullif(p_dados->>'dest_endereco','') else dest_endereco end,
    -- auditoria (anexos NÃO são tocados aqui — ficam a cargo do Controle)
    editado_por_matricula = v_me.matricula,
    editado_por_nome      = coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_completo, v_me.nome_guerra),
    editado_em            = now()
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.oficio_editar(uuid, uuid, jsonb) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Reusa a tabela public.oficios e _sessao_militar (db/04/63).
-- ══════════════════════════════════════════════════════════════════════

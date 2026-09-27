-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — aprovação com ESCOPO (CMT do Pelotão / Grupamento) + Aux P1
--  Fluxo: militar escolhe (PENDENTE) → CMT do Pelotão organiza e aprova
--  (APROVADO_PEL) → Aux P1 valida (VALIDADO).
--
--  ferias_pedido_aprovar deixa:
--   • Aux P1 / Admin Geral / CMT Cia: definir o período final e QUALQUER
--     situação (PENDENTE/APROVADO_PEL/VALIDADO/REJEITADO), qualquer pedido.
--   • CMT do Pelotão (função CMT+PEL ou admin_pelotao): só pedidos do SEU
--     pelotão; situação até APROVADO_PEL (não pode VALIDAR — isso é do Aux P1).
--   • CMT do Grupamento (CMT+GP ou admin_gp): idem, só do seu grupamento.
--  Carimba aprovado_pel_*/validado_p1_* e grava motivo_rejeicao.
--  Depende de: 101, 110 (opcoes). Idempotente. Rodar depois do 112.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_pedido_aprovar(p_token uuid, p_id uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me   record; v_row public.ferias_pedidos; v_nome text;
  v_p1   boolean; v_cmtpel boolean; v_cmtgp boolean;
  v_meu_pel text;
  v_sit  text := nullif(p_dados->>'situacao','');
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_row from public.ferias_pedidos where id = p_id;
  if v_row.id is null then raise exception 'Pedido não encontrado.'; end if;

  v_p1     := public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao);
  v_cmtpel := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* 'pel')
              or coalesce(v_me.nivel_acesso,'') = 'admin_pelotao';
  v_cmtgp  := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* '(gp|grupamento)')
              or coalesce(v_me.nivel_acesso,'') = 'admin_gp';
  v_meu_pel := public._ferias_pelotao(v_me.grupamento_id);

  if not (v_p1 or v_cmtpel or v_cmtgp) then
    raise exception 'Você não tem permissão para aprovar férias.';
  end if;
  -- escopo p/ comandantes (Aux P1/Comando não têm restrição)
  if not v_p1 then
    if v_cmtpel then
      if v_row.pelotao is distinct from v_meu_pel then
        raise exception 'Você só aprova férias do seu pelotão.';
      end if;
    elsif v_cmtgp then
      if v_row.grupamento_id is distinct from v_me.grupamento_id then
        raise exception 'Você só aprova férias do seu grupamento.';
      end if;
    end if;
    if v_sit = 'VALIDADO' then
      raise exception 'A validação final é do Aux P1. Você pode aprovar (Aprovado pelo Pelotão).';
    end if;
  end if;

  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  update public.ferias_pedidos set
    modalidade  = case when p_dados ? 'modalidade' then nullif(p_dados->>'modalidade','') else modalidade end,
    parcelas    = case when p_dados ? 'parcelas'   then coalesce(p_dados->'parcelas','[]'::jsonb) else parcelas end,
    observacoes = case when p_dados ? 'observacoes' then nullif(p_dados->>'observacoes','') else observacoes end,
    situacao    = case when v_sit is not null then v_sit else situacao end,
    motivo_rejeicao = case when v_sit = 'REJEITADO' then nullif(p_dados->>'motivo_rejeicao','')
                           when v_sit is not null then null else motivo_rejeicao end,
    aprovado_pel_por_matricula = case when v_sit='APROVADO_PEL' then v_me.matricula else aprovado_pel_por_matricula end,
    aprovado_pel_por_nome      = case when v_sit='APROVADO_PEL' then v_nome        else aprovado_pel_por_nome end,
    aprovado_pel_em            = case when v_sit='APROVADO_PEL' then now()          else aprovado_pel_em end,
    validado_p1_por_matricula  = case when v_sit='VALIDADO' then v_me.matricula else validado_p1_por_matricula end,
    validado_p1_por_nome       = case when v_sit='VALIDADO' then v_nome        else validado_p1_por_nome end,
    validado_p1_em             = case when v_sit='VALIDADO' then now()          else validado_p1_em end
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

-- Info do pelotão do próprio usuário (nome + total de militares ativos que
-- contam), para o CMT do Pelotão montar o painel de % (ele não pode chamar
-- ferias_percentuais, que é do Aux P1).
create or replace function public.ferias_meu_pelotao_info(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_pel text; v_total int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  v_pel := public._ferias_pelotao(v_me.grupamento_id);
  select count(*) into v_total from public.militares m
   where m.ativo = true and coalesce(m.situacao_efetivo,'ATIVO')='ATIVO'
     and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and public._ferias_pelotao(m.grupamento_id) is not distinct from v_pel;
  return jsonb_build_object('pelotao', v_pel, 'total', v_total);
end;
$$;

grant execute on function public.ferias_pedido_aprovar(uuid, uuid, jsonb) to anon;
grant execute on function public.ferias_meu_pelotao_info(uuid) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do 112. ferias_pedidos_listar (db/101) já entrega ao
-- CMT do Pelotão os pedidos do seu pelotão.
-- ══════════════════════════════════════════════════════════════════════

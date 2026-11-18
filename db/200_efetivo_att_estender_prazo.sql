-- ══════════════════════════════════════════════════════════════════════
--  db/200 — ATUALIZAÇÃO CADASTRAL: estender/alterar o prazo da MESMA
--           solicitação (sem zerar quem já preencheu)
--  Data: 2026-11-18
--
--  CONTEXTO: a Aux P1 abre uma solicitação de atualização de dados com um
--  prazo que ela mesma define. Nem todos preenchem até o prazo. Hoje só havia
--  "abrir nova" (que cria outra campanha e, portanto, re-cobra TODO MUNDO) e
--  "encerrar". Faltava ESTENDER o prazo da mesma solicitação: continuar
--  cobrando só os pendentes e manter como feito quem já preencheu.
--
--  Como a confirmação é amarrada ao ID da campanha (militares.dados_
--  confirmados_campanha = campanha.id), estender = manter o MESMO id. Assim:
--    • quem já confirmou nesta solicitação → continua confirmado (sem aviso);
--    • quem não confirmou → volta a ver o aviso até o novo prazo.
--  Uma NOVA solicitação (efetivo_att_abrir) cria um id novo e re-cobra todos.
--
--  Também: efetivo_att_atual passa a devolver a solicitação MAIS RECENTE
--  mesmo encerrada (com 'aberta' e 'encerrada_em'), p/ a tela oferecer
--  "reabrir p/ os pendentes" × "abrir nova (todos de novo)".
--
--  Depende de: 04 (_sessao_militar), 175 (efetivo_att_campanha + _efetivo_pode).
--  Idempotente. Rodar no SQL Editor (depois do 176).
-- ══════════════════════════════════════════════════════════════════════

-- ─── Estender / alterar o prazo (reabre a MESMA solicitação) ───────────
create or replace function public.efetivo_att_prazo(p_token uuid, p_prazo date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; c record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Alterar o prazo restrito ao Aux P1 / Comando.';
  end if;

  -- solicitação mais recente (aberta ou encerrada)
  select * into c from public.efetivo_att_campanha order by criada_em desc limit 1;
  if c.id is null then
    raise exception 'Não há solicitação para estender. Abra uma nova.';
  end if;

  -- garante que só esta fique aberta; mantém o MESMO id (preserva confirmações)
  update public.efetivo_att_campanha set aberta = false, fechada_em = now()
   where aberta = true and id <> c.id;

  update public.efetivo_att_campanha
     set prazo = p_prazo, aberta = true, fechada_em = null
   where id = c.id;

  return jsonb_build_object('ok', true, 'id', c.id, 'prazo', p_prazo);
end;
$$;
grant execute on function public.efetivo_att_prazo(uuid, date) to anon;

-- ─── efetivo_att_atual — solicitação mais recente (aberta OU encerrada) ─
create or replace function public.efetivo_att_atual(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; c record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._efetivo_pode(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Restrito ao Aux P1 / Comando.';
  end if;
  -- preferência pela aberta; se não houver, a última encerrada (p/ reabrir)
  select * into c from public.efetivo_att_campanha
    order by aberta desc, criada_em desc limit 1;
  if c.id is null then return null; end if;
  return jsonb_build_object('id', c.id, 'prazo', c.prazo, 'escopo_pel', c.escopo_pel,
    'mensagem', c.mensagem, 'criada_em', c.criada_em,
    'aberta', c.aberta, 'encerrada_em', c.fechada_em);
end;
$$;
grant execute on function public.efetivo_att_atual(uuid) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 176). Idempotente.
-- ══════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- 74_instrucao_chamada_preserva_autoria.sql
--
--   BUG: em chamada_instrucao_lancar (db/65), o `on conflict do update`
--   SEMPRE regravava registrado_por = quem salvou — mesmo em registro que não
--   mudou. Como o Admin Geral não tem a trava de autoria, ao salvar UMA
--   presença nova o cliente reenviava todos os editáveis e TODOS passavam a
--   constar como lançados por ele.
--
--   Correção (defesa no banco; o frontend também passou a só enviar o que
--   mudou): no update, só troca a AUTORIA quando o status OU a justificativa
--   realmente mudaram. Registro reenviado sem mudança mantém quem lançou.
--
--   Depende de: 65_instrucao_chamada_alteracao.sql. Idempotente. Rodar no
--   SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.chamada_instrucao_lancar(
  p_token uuid, p_instrucao_id uuid, p_registros jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me       record;
  v_inst     public.instrucoes;
  v_reg      jsonb;
  v_n        int := 0;
  v_hoje     date;
  v_geral    boolean;
  v_me_dig   text;
  v_owner    record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;

  select * into v_inst from public.instrucoes where id = p_instrucao_id;
  if v_inst.id is null then
    raise exception 'Instrução não encontrada. Peça ao administrador para configurar a instrução atual.';
  end if;
  if jsonb_typeof(p_registros) <> 'array' then
    raise exception 'Registros inválidos.';
  end if;

  v_hoje   := (now() at time zone 'America/Sao_Paulo')::date;
  v_geral  := coalesce(v_me.nivel_acesso,'') = 'admin_geral';
  v_me_dig := regexp_replace(coalesce(v_me.matricula,''), '\D', '', 'g');

  /* (1) janela por data — só o Admin Geral altera após o dia da instrução */
  if not v_geral and v_inst.data < v_hoje then
    raise exception 'Após o dia da instrução (%), apenas o Admin Geral pode alterar a chamada.',
      to_char(v_inst.data, 'DD/MM/YYYY');
  end if;

  for v_reg in select * from jsonb_array_elements(p_registros) loop
    if coalesce(v_reg->>'matricula','') = '' then continue; end if;
    if coalesce(v_reg->>'status','') not in ('presente','ausente') then continue; end if;

    /* (2) dono do registro — só quem lançou (ou Admin Geral) altera */
    if not v_geral then
      select registrado_por_matricula, registrado_por_nome
        into v_owner
        from public.chamada_instrucao
       where instrucao_id = p_instrucao_id
         and matricula = v_reg->>'matricula';
      if found
         and coalesce(v_owner.registrado_por_matricula,'') <> ''
         and regexp_replace(v_owner.registrado_por_matricula, '\D', '', 'g') <> v_me_dig then
        raise exception 'O registro de % foi lançado por % — somente essa pessoa (ou o Admin Geral) pode alterar.',
          coalesce(nullif(v_reg->>'nome_guerra',''), nullif(v_reg->>'nome_completo',''), v_reg->>'matricula'),
          coalesce(v_owner.registrado_por_nome, 'outro usuário');
      end if;
    end if;

    insert into public.chamada_instrucao (
      instrucao_id, militar_id, matricula, matricula_clean, posto_graduacao,
      nome_completo, nome_guerra, grupamento_id, status, justificativa, observacao,
      registrado_por_matricula, registrado_por_nome)
    values (
      p_instrucao_id,
      nullif(v_reg->>'militar_id','')::uuid,
      v_reg->>'matricula',
      regexp_replace(coalesce(v_reg->>'matricula',''), '\D', '', 'g'),
      nullif(v_reg->>'posto_graduacao',''),
      nullif(v_reg->>'nome_completo',''),
      nullif(v_reg->>'nome_guerra',''),
      nullif(v_reg->>'grupamento_id',''),
      v_reg->>'status',
      nullif(v_reg->>'justificativa',''),
      nullif(v_reg->>'observacao',''),
      v_me.matricula, v_me.nome_completo)
    on conflict (instrucao_id, matricula) do update set
      status        = excluded.status,
      justificativa = excluded.justificativa,
      observacao    = excluded.observacao,
      posto_graduacao = coalesce(excluded.posto_graduacao, public.chamada_instrucao.posto_graduacao),
      nome_completo = coalesce(excluded.nome_completo, public.chamada_instrucao.nome_completo),
      nome_guerra   = coalesce(excluded.nome_guerra, public.chamada_instrucao.nome_guerra),
      grupamento_id = coalesce(excluded.grupamento_id, public.chamada_instrucao.grupamento_id),
      -- AUTORIA: só muda para quem salvou se o status OU a justificativa mudaram.
      -- Reenvio sem mudança preserva quem lançou originalmente.
      registrado_por_matricula = case
        when public.chamada_instrucao.status is distinct from excluded.status
          or coalesce(public.chamada_instrucao.justificativa,'') is distinct from coalesce(excluded.justificativa,'')
        then v_me.matricula
        else public.chamada_instrucao.registrado_por_matricula end,
      registrado_por_nome = case
        when public.chamada_instrucao.status is distinct from excluded.status
          or coalesce(public.chamada_instrucao.justificativa,'') is distinct from coalesce(excluded.justificativa,'')
        then v_me.nome_completo
        else public.chamada_instrucao.registrado_por_nome end;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'gravados', v_n);
end;
$$;

grant execute on function public.chamada_instrucao_lancar(uuid, uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Preserva a autoria de registros reenviados sem mudança.
-- ════════════════════════════════════════════════════════════════════════

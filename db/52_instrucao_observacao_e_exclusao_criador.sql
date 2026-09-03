-- ════════════════════════════════════════════════════════════════════════
-- 52_instrucao_observacao_e_exclusao_criador.sql
--
-- Chamada de Instrução — dois acréscimos:
--   1) Campo OBSERVAÇÃO na instrução (instrucoes.observacao): detalhes tratados,
--      dúvidas, sugestões etc. Persistido no instrucao_salvar.
--   2) EXCLUSÃO pelo CRIADOR até a data da instrução:
--        • quem criou a instrução (criado_por_matricula) pode EXCLUIR enquanto
--          hoje <= data da instrução (o dia da instrução, inclusive) — para o
--          caso de mudança de planos ou de a instrução não ocorrer;
--        • DEPOIS da data, apenas o Admin Geral pode excluir.
--      Regra geral (vale p/ qualquer criador: Admin, CMT Cia, Pelotão, GP…).
--      O Admin Geral pode excluir a qualquer momento.
--
-- Depende de: 24, 44, 51. Idempotente. Rodar no SQL Editor depois do 51.
-- ════════════════════════════════════════════════════════════════════════

/* ─── 1) coluna observação ─────────────────────────────────────────────── */
alter table public.instrucoes
  add column if not exists observacao text;

/* ─── 2) instrucao_salvar: grava observação (mantém escopo do db/51) ─────── */
create or replace function public.instrucao_salvar(p_token uuid, p_dados jsonb)
returns public.instrucoes
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.instrucoes;
  v_cur  public.instrucoes;
  v_id   uuid := nullif(p_dados->>'id','')::uuid;
  v_ativa boolean := coalesce((p_dados->>'ativa')::boolean, true);
  v_tem_grp boolean := (p_dados ? 'grupamentos');
  v_tem_obs boolean := (p_dados ? 'observacao');
  v_obs  text := nullif(p_dados->>'observacao','');
  v_grupamentos text[] := case
    when jsonb_typeof(p_dados->'grupamentos') = 'array'
      then array(select jsonb_array_elements_text(p_dados->'grupamentos'))
    else null
  end;
  v_total boolean;
  v_perm  text[];
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if not public._instrucao_pode_gerir2(p_token) then
    raise exception 'Acesso restrito (Admin Geral, Admin, CMT Cia, Admin de Pelotão ou Admin de GP).';
  end if;
  if coalesce(p_dados->>'assunto','') = '' then
    raise exception 'Informe o assunto da instrução.';
  end if;

  if v_grupamentos is not null and array_length(v_grupamentos, 1) is null then
    v_grupamentos := null;
  end if;

  v_total := public._instrucao_escopo_total(p_token);

  if not v_total then
    v_perm := public._instrucao_grupamentos_permitidos(p_token);
    if v_grupamentos is null then
      raise exception 'Apenas o Comando pode criar instrução para toda a Companhia. Selecione o(s) grupamento(s) do seu escopo.';
    end if;
    if not (v_grupamentos <@ coalesce(v_perm, '{}')) then
      raise exception 'Você só pode criar instrução para grupamento(s) do seu escopo.';
    end if;
    if v_id is not null then
      select * into v_cur from public.instrucoes where id = v_id;
      if v_cur.id is null then raise exception 'Instrução não encontrada.'; end if;
      if v_cur.grupamentos is null or not (v_cur.grupamentos <@ coalesce(v_perm, '{}')) then
        raise exception 'Você não pode editar esta instrução (fora do seu escopo).';
      end if;
    end if;
  end if;

  if v_ativa then
    if v_grupamentos is null then
      update public.instrucoes set ativa = false
        where ativa = true and (v_id is null or id <> v_id);
    else
      update public.instrucoes set ativa = false
        where ativa = true and (v_id is null or id <> v_id)
          and grupamentos is not null
          and grupamentos && v_grupamentos;
    end if;
  end if;

  if v_id is null then
    insert into public.instrucoes (data, assunto, responsavel_instrucao, ativa,
                                   grupamentos, observacao,
                                   criado_por_matricula, criado_por_nome)
    values (coalesce(nullif(p_dados->>'data','')::date, (now() at time zone 'America/Sao_Paulo')::date),
            p_dados->>'assunto',
            nullif(p_dados->>'responsavel_instrucao',''),
            v_ativa, v_grupamentos, v_obs, v_me.matricula, v_me.nome_completo)
    returning * into v_row;
  else
    update public.instrucoes set
      data = coalesce(nullif(p_dados->>'data','')::date, data),
      assunto = p_dados->>'assunto',
      responsavel_instrucao = nullif(p_dados->>'responsavel_instrucao',''),
      ativa = v_ativa,
      grupamentos = case when v_tem_grp then v_grupamentos else grupamentos end,
      -- só mexe na observação se o cliente mandou a chave (senão preserva)
      observacao  = case when v_tem_obs then v_obs else observacao end
    where id = v_id
    returning * into v_row;
    if v_row.id is null then raise exception 'Instrução não encontrada.'; end if;
  end if;
  return v_row;
end;
$$;

/* ─── 3) instrucao_excluir: criador até a data + Admin Geral sempre ──────── */
create or replace function public.instrucao_excluir(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.instrucoes;
  v_hoje date;
  v_n    int;
  v_geral   boolean;
  v_criador boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if p_id is null then
    raise exception 'Instrução não informada.';
  end if;

  select * into v_row from public.instrucoes where id = p_id;
  if v_row.id is null then
    raise exception 'Instrução não encontrada.';
  end if;

  v_hoje    := (now() at time zone 'America/Sao_Paulo')::date;
  v_geral   := coalesce(v_me.nivel_acesso,'') = 'admin_geral';
  v_criador := regexp_replace(coalesce(v_me.matricula,''), '\D', '', 'g') <> ''
    and regexp_replace(coalesce(v_me.matricula,''), '\D', '', 'g')
      = regexp_replace(coalesce(v_row.criado_por_matricula,''), '\D', '', 'g');

  if not v_geral then
    if not v_criador then
      raise exception 'Só quem criou a instrução (até a data dela) ou o Admin Geral pode excluir.';
    end if;
    if v_row.data < v_hoje then
      raise exception 'Depois da data da instrução, apenas o Admin Geral pode excluir.';
    end if;
  end if;

  select count(*) into v_n from public.chamada_instrucao where instrucao_id = p_id;

  delete from public.instrucoes where id = p_id;
  if not found then
    raise exception 'Instrução não encontrada.';
  end if;

  return jsonb_build_object('ok', true, 'lancamentos_removidos', coalesce(v_n, 0));
end;
$$;

/* ─── grants ───────────────────────────────────────────────────────────── */
grant execute on function public.instrucao_salvar(uuid, jsonb)   to anon;
grant execute on function public.instrucao_excluir(uuid, uuid)   to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 51_instrucao_escopo_pel_gp.sql.
-- ════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- 64_instrucao_link_reuniao.sql
--
-- Chamada de Instrução — LINK DE ACESSO para instrução ONLINE.
--   1) coluna instrucoes.link_reuniao text — cole o convite inteiro
--      (link do Teams/Meet/Zoom + ID + senha). NULL/vazio = presencial.
--   2) instrucao_salvar passa a persistir link_reuniao (padrão "só mexe se
--      o cliente mandou a chave", igual ao observacao do db/52).
--
-- A instrucao_avisos_get / instrucao_lancaveis_listar / instrucao_listar já
-- fazem `select *`, então o novo campo flui automático para o Meu Dia e para
-- a aba de Chamada de Instrução — nada a alterar nelas.
--
-- Depende de: 24, 43, 51, 52. Idempotente. Rodar no SQL Editor depois do 52.
-- ════════════════════════════════════════════════════════════════════════

/* ─── 1) coluna link de acesso (reunião online) ───────────────────────── */
alter table public.instrucoes
  add column if not exists link_reuniao text;

/* ─── 2) instrucao_salvar: grava link_reuniao (mantém escopo do db/52) ─── */
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
  v_tem_link boolean := (p_dados ? 'link_reuniao');
  v_obs  text := nullif(p_dados->>'observacao','');
  v_link text := nullif(btrim(p_dados->>'link_reuniao'),'');
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
                                   grupamentos, observacao, link_reuniao,
                                   criado_por_matricula, criado_por_nome)
    values (coalesce(nullif(p_dados->>'data','')::date, (now() at time zone 'America/Sao_Paulo')::date),
            p_dados->>'assunto',
            nullif(p_dados->>'responsavel_instrucao',''),
            v_ativa, v_grupamentos, v_obs, v_link, v_me.matricula, v_me.nome_completo)
    returning * into v_row;
  else
    update public.instrucoes set
      data = coalesce(nullif(p_dados->>'data','')::date, data),
      assunto = p_dados->>'assunto',
      responsavel_instrucao = nullif(p_dados->>'responsavel_instrucao',''),
      ativa = v_ativa,
      grupamentos = case when v_tem_grp then v_grupamentos else grupamentos end,
      -- só mexe na observação/link se o cliente mandou a chave (senão preserva)
      observacao   = case when v_tem_obs  then v_obs  else observacao   end,
      link_reuniao = case when v_tem_link then v_link else link_reuniao end
    where id = v_id
    returning * into v_row;
    if v_row.id is null then raise exception 'Instrução não encontrada.'; end if;
  end if;
  return v_row;
end;
$$;

/* ─── grants ───────────────────────────────────────────────────────────── */
grant execute on function public.instrucao_salvar(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 52_instrucao_observacao_e_exclusao_criador.sql.
-- ════════════════════════════════════════════════════════════════════════

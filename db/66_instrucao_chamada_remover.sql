-- ════════════════════════════════════════════════════════════════════════
-- 66_instrucao_chamada_remover.sql — DESMARCAR presença (apagar registro)
--
-- Complementa o db/65: se quem lançou marcou errado (presente/ausente) e quer
-- deixar o militar SEM marcação, a UI desmarca (toggle) e, no salvar, chama
-- esta RPC para APAGAR o registro daquele militar naquela instrução.
--
-- Mesmas travas do lançamento (db/65):
--   • Só até o DIA da instrução (inclusive); depois, só o Admin Geral.
--   • Só o DONO do registro (quem lançou) ou o Admin Geral pode apagar.
--
-- Depende de: 24_chamada_instrucao.sql, 04_sessoes_e_militares_seguranca.sql.
-- Idempotente. Rodar no SQL Editor depois do 65.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.chamada_instrucao_remover(
  p_token uuid, p_instrucao_id uuid, p_matriculas jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me       record;
  v_inst     public.instrucoes;
  v_mat      text;
  v_owner    record;
  v_hoje     date;
  v_geral    boolean;
  v_me_dig   text;
  v_n        int := 0;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;

  select * into v_inst from public.instrucoes where id = p_instrucao_id;
  if v_inst.id is null then
    raise exception 'Instrução não encontrada.';
  end if;
  if jsonb_typeof(p_matriculas) <> 'array' then
    raise exception 'Lista de matrículas inválida.';
  end if;

  v_hoje   := (now() at time zone 'America/Sao_Paulo')::date;
  v_geral  := coalesce(v_me.nivel_acesso,'') = 'admin_geral';
  v_me_dig := regexp_replace(coalesce(v_me.matricula,''), '\D', '', 'g');

  /* janela por data — só o Admin Geral altera após o dia da instrução */
  if not v_geral and v_inst.data < v_hoje then
    raise exception 'Após o dia da instrução (%), apenas o Admin Geral pode alterar a chamada.',
      to_char(v_inst.data, 'DD/MM/YYYY');
  end if;

  for v_mat in select value from jsonb_array_elements_text(p_matriculas) loop
    if coalesce(v_mat,'') = '' then continue; end if;

    select registrado_por_matricula, registrado_por_nome
      into v_owner
      from public.chamada_instrucao
     where instrucao_id = p_instrucao_id and matricula = v_mat;
    if not found then continue; end if;   -- já não existe, nada a apagar

    /* dono do registro — só quem lançou (ou Admin Geral) pode apagar */
    if not v_geral
       and coalesce(v_owner.registrado_por_matricula,'') <> ''
       and regexp_replace(v_owner.registrado_por_matricula, '\D', '', 'g') <> v_me_dig then
      raise exception 'O registro de % foi lançado por % — somente essa pessoa (ou o Admin Geral) pode desmarcar.',
        v_mat, coalesce(v_owner.registrado_por_nome, 'outro usuário');
    end if;

    delete from public.chamada_instrucao
     where instrucao_id = p_instrucao_id and matricula = v_mat;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'removidos', v_n);
end;
$$;

grant execute on function public.chamada_instrucao_remover(uuid, uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 65_instrucao_chamada_alteracao.sql.
-- ════════════════════════════════════════════════════════════════════════

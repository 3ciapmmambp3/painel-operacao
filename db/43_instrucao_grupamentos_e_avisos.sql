-- ════════════════════════════════════════════════════════════════════════
-- 43_instrucao_grupamentos_e_avisos.sql
--
-- Chamada de Instrução — dois acréscimos:
--   1) A instrução passa a ter GRUPAMENTOS PARTICIPANTES (às vezes só um
--      grupamento específico faz a instrução, não a Cia inteira).
--        • instrucoes.grupamentos text[]  → NULL/vazio = toda a Companhia;
--          senão, a lista de grupamento_id (mesmos rótulos que a chamada
--          já usa pra agrupar o efetivo).
--   2) AVISO ao militar na home (Meu Dia → 🔔 Avisos para você): a instrução
--      aparece a partir de 8 dias antes e some quando o dia dela termina —
--      só pros militares dos grupamentos participantes (ou todos, se toda a Cia).
--
-- Depende de: 24_chamada_instrucao.sql, 04_sessoes_e_militares_seguranca.sql.
-- Idempotente. Rodar no SQL Editor depois do 24.
-- ════════════════════════════════════════════════════════════════════════

/* ─── 1) coluna: grupamentos participantes (NULL/vazio = toda a Cia) ────── */
alter table public.instrucoes
  add column if not exists grupamentos text[];

/* ─── 2) instrucao_salvar: agora grava também os grupamentos ───────────── */
create or replace function public.instrucao_salvar(p_token uuid, p_dados jsonb)
returns public.instrucoes
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_row  public.instrucoes;
  v_id   uuid := nullif(p_dados->>'id','')::uuid;
  v_ativa boolean := coalesce((p_dados->>'ativa')::boolean, true);
  v_tem_grp boolean := (p_dados ? 'grupamentos');
  v_grupamentos text[] := case
    when jsonb_typeof(p_dados->'grupamentos') = 'array'
      then array(select jsonb_array_elements_text(p_dados->'grupamentos'))
    else null
  end;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if not public._pode_gerir_instrucao(v_me.nivel_acesso) then
    raise exception 'Acesso restrito (Admin Geral, Admin ou Admin de Pelotão).';
  end if;
  if coalesce(p_dados->>'assunto','') = '' then
    raise exception 'Informe o assunto da instrução.';
  end if;

  -- lista vazia = toda a Companhia → normaliza pra NULL
  if v_grupamentos is not null and array_length(v_grupamentos, 1) is null then
    v_grupamentos := null;
  end if;

  if v_ativa then
    update public.instrucoes set ativa = false where ativa = true
       and (v_id is null or id <> v_id);
  end if;

  if v_id is null then
    insert into public.instrucoes (data, assunto, responsavel_instrucao, ativa,
                                   grupamentos, criado_por_matricula, criado_por_nome)
    values (coalesce(nullif(p_dados->>'data','')::date, (now() at time zone 'America/Sao_Paulo')::date),
            p_dados->>'assunto',
            nullif(p_dados->>'responsavel_instrucao',''),
            v_ativa, v_grupamentos, v_me.matricula, v_me.nome_completo)
    returning * into v_row;
  else
    update public.instrucoes set
      data = coalesce(nullif(p_dados->>'data','')::date, data),
      assunto = p_dados->>'assunto',
      responsavel_instrucao = nullif(p_dados->>'responsavel_instrucao',''),
      ativa = v_ativa,
      -- só mexe nos grupamentos se o cliente mandou a chave (senão preserva)
      grupamentos = case when v_tem_grp then v_grupamentos else grupamentos end
    where id = v_id
    returning * into v_row;
    if v_row.id is null then raise exception 'Instrução não encontrada.'; end if;
  end if;
  return v_row;
end;
$$;

/* ─── 3) AVISOS: instruções próximas para o militar logado ─────────────────
   Janela: de 8 dias antes até o PRÓPRIO DIA da instrução (a data marcada).
   Ancorada só na data da instrução — independe de quando foi cadastrada.
   No dia da instrução ainda aparece; no dia seguinte some.
   Filtro: toda a Cia (grupamentos NULL/vazio) OU o grupamento do militar
   está na lista. Todos os logados. */
create or replace function public.instrucao_avisos_get(p_token uuid)
returns setof public.instrucoes
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_hoje date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  v_hoje := (now() at time zone 'America/Sao_Paulo')::date;
  return query
    select * from public.instrucoes i
     where i.data >= v_hoje          -- some no dia seguinte à instrução
       and i.data <= v_hoje + 8      -- começa a avisar 8 dias antes
       and (
         i.grupamentos is null
         or array_length(i.grupamentos, 1) is null
         or coalesce(v_me.grupamento_id, '') = any (i.grupamentos)
       )
     order by i.data asc, i.created_at desc;
end;
$$;

/* ─── grants ───────────────────────────────────────────────────────────── */
grant execute on function public.instrucao_salvar(uuid, jsonb)     to anon;
grant execute on function public.instrucao_avisos_get(uuid)        to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 24_chamada_instrucao.sql.
-- ════════════════════════════════════════════════════════════════════════

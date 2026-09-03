-- ════════════════════════════════════════════════════════════════════════
-- 51_instrucao_escopo_pel_gp.sql
--
-- Chamada de Instrução — CRIAÇÃO ESCOPADA por Pelotão / Grupamento.
--
--   • Admin Geral / Admin / função CMT CIA  → cria para qualquer grupamento
--     ou "Toda a Companhia" (como já era).
--   • Admin de Pelotão (admin_pelotao)       → cria SÓ para os grupamentos do
--     seu escopo (os mesmos que ele já lança no efetivo).
--   • Admin de GP (admin_gp)                 → cria SÓ para o seu grupamento.
--
--   O conjunto de grupamentos que cada um pode escolher é exatamente o que
--   `militares_roster_escopo` (db/45) já devolve para o usuário — assim
--   "criar" == "lançar chamada" == "avisar" ficam sempre coerentes.
--
--   "Ativa" passa a ser POR ESCOPO: uma instrução de PEL/GP só desliga a
--   ativa de instruções que compartilham grupamento com ela — nunca a ativa
--   de "Toda a Companhia" nem a de outros grupamentos.
--
--   A validação é feita SEMPRE no banco a partir do token (o RPC é o único
--   portão; a RLS bloqueia acesso direto às tabelas).
--
-- Depende de: 24_chamada_instrucao.sql, 43_instrucao_grupamentos_e_avisos.sql,
--             45_roster_escopo.sql. Idempotente. Rodar no SQL Editor depois do 45.
-- ════════════════════════════════════════════════════════════════════════

/* ─── helpers de escopo ─────────────────────────────────────────────────── */

-- Escopo TOTAL (vê/cria para toda a Companhia): Admin Geral, Admin ou CMT Cia.
-- Mesma regra do v_ge do db/45.
create or replace function public._instrucao_escopo_total(p_token uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then return false; end if;
  return coalesce(v_me.nivel_acesso,'') in ('admin_geral','admin')
    or (upper(coalesce(v_me.funcao,'')) like '%CMT%'
        and upper(coalesce(v_me.funcao,'')) like '%CIA%');
end;
$$;

-- Pode gerir a Chamada (ver a aba Configurar e criar/editar instrução)?
-- Escopo total OU Admin de Pelotão OU Admin de GP.
create or replace function public._instrucao_pode_gerir2(p_token uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then return false; end if;
  return public._instrucao_escopo_total(p_token)
    or coalesce(v_me.nivel_acesso,'') in ('admin_pelotao','admin_gp');
end;
$$;

-- Grupamentos que o usuário pode escolher = os grupamentos distintos que o
-- roster escopado (db/45) devolve para ele. Garante que o picker (frontend) e a
-- validação (backend) nunca divirjam.
create or replace function public._instrucao_grupamentos_permitidos(p_token uuid)
returns text[] language sql security definer set search_path = public as $$
  select coalesce(array_agg(distinct g), '{}')
  from (
    select nullif(btrim(grupamento_id),'') as g
    from public.militares_roster_escopo(p_token)
  ) s
  where g is not null;
$$;

/* ─── instrucao_salvar: gate + validação de escopo + ativa por escopo ─────── */
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

  -- lista vazia = toda a Companhia → normaliza pra NULL
  if v_grupamentos is not null and array_length(v_grupamentos, 1) is null then
    v_grupamentos := null;
  end if;

  v_total := public._instrucao_escopo_total(p_token);

  -- ── validação de escopo para quem NÃO é total (Pelotão / GP) ──────────────
  if not v_total then
    v_perm := public._instrucao_grupamentos_permitidos(p_token);
    -- não pode "Toda a Companhia"
    if v_grupamentos is null then
      raise exception 'Apenas o Comando pode criar instrução para toda a Companhia. Selecione o(s) grupamento(s) do seu escopo.';
    end if;
    -- todo grupamento escolhido tem de estar no escopo permitido
    if not (v_grupamentos <@ coalesce(v_perm, '{}')) then
      raise exception 'Você só pode criar instrução para grupamento(s) do seu escopo.';
    end if;
    -- ao editar: a instrução existente também tem de ser inteiramente do escopo
    if v_id is not null then
      select * into v_cur from public.instrucoes where id = v_id;
      if v_cur.id is null then raise exception 'Instrução não encontrada.'; end if;
      if v_cur.grupamentos is null or not (v_cur.grupamentos <@ coalesce(v_perm, '{}')) then
        raise exception 'Você não pode editar esta instrução (fora do seu escopo).';
      end if;
    end if;
  end if;

  -- ── "ativa" POR ESCOPO ────────────────────────────────────────────────────
  if v_ativa then
    if v_grupamentos is null then
      -- Toda a Companhia (só escopo total chega aqui): vira a ativa geral.
      update public.instrucoes set ativa = false
        where ativa = true and (v_id is null or id <> v_id);
    else
      -- Escopo específico: desliga só as ativas que compartilham grupamento.
      -- Não toca na ativa de "Toda a Cia" (grupamentos NULL) nem em outros grupamentos.
      update public.instrucoes set ativa = false
        where ativa = true and (v_id is null or id <> v_id)
          and grupamentos is not null
          and grupamentos && v_grupamentos;
    end if;
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
      grupamentos = case when v_tem_grp then v_grupamentos else grupamentos end
    where id = v_id
    returning * into v_row;
    if v_row.id is null then raise exception 'Instrução não encontrada.'; end if;
  end if;
  return v_row;
end;
$$;

/* ─── instrucao_listar (histórico/Configurar): escopado ────────────────────
   Escopo total → todas. Pelotão/GP → só instruções inteiramente do seu escopo
   (as que ele pode, de fato, editar). */
create or replace function public.instrucao_listar(p_token uuid)
returns setof public.instrucoes
language plpgsql security definer set search_path = public as $$
declare v_me record; v_perm text[];
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if not public._instrucao_pode_gerir2(p_token) then
    raise exception 'Acesso restrito (Admin Geral, Admin, CMT Cia, Admin de Pelotão ou Admin de GP).';
  end if;
  if public._instrucao_escopo_total(p_token) then
    return query select * from public.instrucoes order by data desc, created_at desc;
  else
    v_perm := public._instrucao_grupamentos_permitidos(p_token);
    return query
      select * from public.instrucoes i
       where i.grupamentos is not null
         and i.grupamentos <@ coalesce(v_perm, '{}')
       order by i.data desc, i.created_at desc;
  end if;
end;
$$;

/* ─── instrucao_lancaveis_listar: escopo total → todas; Pelotão/GP →
   toda a Cia + as que tocam o escopo dele; demais → toda a Cia + as do seu
   grupamento. Janela: ativa OU últimos 30 / próximos 8 dias. ──────────────── */
create or replace function public.instrucao_lancaveis_listar(p_token uuid)
returns setof public.instrucoes
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_hoje   date;
  v_total  boolean;
  v_gestor boolean;
  v_perm   text[];
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  v_hoje   := (now() at time zone 'America/Sao_Paulo')::date;
  v_total  := public._instrucao_escopo_total(p_token);
  v_gestor := coalesce(v_me.nivel_acesso,'') in ('admin_pelotao','admin_gp');

  if v_total then
    return query
      select * from public.instrucoes i
       where (i.ativa = true or (i.data >= v_hoje - 30 and i.data <= v_hoje + 8))
       order by i.data desc, i.created_at desc;
  elsif v_gestor then
    v_perm := public._instrucao_grupamentos_permitidos(p_token);
    return query
      select * from public.instrucoes i
       where (i.ativa = true or (i.data >= v_hoje - 30 and i.data <= v_hoje + 8))
         and (
           i.grupamentos is null
           or array_length(i.grupamentos, 1) is null
           or i.grupamentos && coalesce(v_perm, '{}')
         )
       order by i.data desc, i.created_at desc;
  else
    return query
      select * from public.instrucoes i
       where (i.ativa = true or (i.data >= v_hoje - 30 and i.data <= v_hoje + 8))
         and (
           i.grupamentos is null
           or array_length(i.grupamentos, 1) is null
           or coalesce(v_me.grupamento_id, '') = any (i.grupamentos)
         )
       order by i.data desc, i.created_at desc;
  end if;
end;
$$;

/* ─── grants ───────────────────────────────────────────────────────────── */
grant execute on function public.instrucao_salvar(uuid, jsonb)          to anon;
grant execute on function public.instrucao_listar(uuid)                 to anon;
grant execute on function public.instrucao_lancaveis_listar(uuid)       to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 45_roster_escopo.sql.
-- ════════════════════════════════════════════════════════════════════════

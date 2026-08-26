-- ════════════════════════════════════════════════════════════════════════
-- 36_relatorios_pendentes.sql — Relatórios de serviço PENDENTES por dia de TTA.
--
-- Regra (decisão do usuário): a pendência é POR EQUIPE. Todos os integrantes de
-- uma equipe do TTA veem "Relatório pendente do dia DD/MM" até que QUALQUER um
-- deles lance o relatório daquele dia. Some quando existe um relatório com
-- data = data da chamada criado por algum membro da equipe.
--
-- + tta_chamada_por_id: usada pelo relatório (?chamada=<id>) p/ pré-preencher a
--   equipe de um DIA específico (não só hoje).
--
-- Depende de: 04 (_sessao_militar), 07 (tta_chamadas), 18 (relatorios).
-- Idempotente. Rodar no SQL Editor depois do 18.
-- ════════════════════════════════════════════════════════════════════════

-- ── Chamada específica por id (pré-preenchimento de um dia) ──────────────
create or replace function public.tta_chamada_por_id(p_token uuid, p_id uuid)
returns public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.tta_chamadas;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_row from public.tta_chamadas where id = p_id limit 1;
  return v_row;   -- linha vazia (id null) se não existir
end;
$$;

-- ── Relatórios pendentes do militar (por equipe, janela de 45 dias) ───────
create or replace function public.relatorios_pendentes_do_militar(p_token uuid)
returns table(
  dia              date,
  chamada_id       uuid,
  operacao         text,
  comandante_nome  text,
  prefixo_viatura  text
)
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini   date := v_hoje - 45;
  c       record;
  eq      jsonb;
  membros text[];
  atendido boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  for c in
    select id,
           (data_hora_chamada at time zone 'America/Sao_Paulo')::date as d,
           equipes, militares_presentes
      from public.tta_chamadas
     where (data_hora_chamada at time zone 'America/Sao_Paulo')::date between v_ini and v_hoje
     order by (data_hora_chamada at time zone 'America/Sao_Paulo')::date desc
  loop
    if jsonb_array_length(coalesce(c.equipes, '[]'::jsonb)) > 0 then
      -- TTA novo: uma pendência por EQUIPE de que o militar participa
      for eq in select value from jsonb_array_elements(c.equipes) as t(value)
      loop
        membros := array_remove(array[
                     nullif(eq->'comandante'->>'matricula',''),
                     nullif(eq->'motorista'->>'matricula','')
                   ], null);
        membros := membros || coalesce((
                     select array_agg(p->>'matricula')
                       from jsonb_array_elements(coalesce(eq->'patrulheiros','[]'::jsonb)) p
                      where nullif(p->>'matricula','') is not null), array[]::text[]);
        if not (v_me.matricula = any(membros)) then continue; end if;

        select exists(
          select 1 from public.relatorios r
           where r.data = c.d
             and r.criado_por_matricula = any(membros)
        ) into atendido;

        if not atendido then
          dia := c.d;
          chamada_id := c.id;
          operacao := nullif(eq->>'operacao','');
          comandante_nome := nullif(eq->'comandante'->>'nome','');
          prefixo_viatura := nullif(eq->>'prefixo_viatura','');
          return next;
        end if;
      end loop;
    else
      -- TTA antigo (sem equipes): trata os presentes como uma equipe única
      if c.militares_presentes @> jsonb_build_array(jsonb_build_object('matricula', v_me.matricula)) then
        membros := coalesce((
                     select array_agg(m->>'matricula')
                       from jsonb_array_elements(c.militares_presentes) m
                      where nullif(m->>'matricula','') is not null), array[]::text[]);
        select exists(
          select 1 from public.relatorios r
           where r.data = c.d
             and r.criado_por_matricula = any(membros)
        ) into atendido;
        if not atendido then
          dia := c.d; chamada_id := c.id;
          operacao := null; comandante_nome := null; prefixo_viatura := null;
          return next;
        end if;
      end if;
    end if;
  end loop;
end;
$$;

grant execute on function public.tta_chamada_por_id(uuid, uuid) to anon;
grant execute on function public.relatorios_pendentes_do_militar(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 18.
-- ════════════════════════════════════════════════════════════════════════

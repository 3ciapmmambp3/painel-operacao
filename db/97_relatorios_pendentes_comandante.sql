-- ════════════════════════════════════════════════════════════════════════
-- 97_relatorios_pendentes_comandante.sql
-- Relatórios de serviço PENDENTES no "Meu Dia" — casamento mais robusto.
--
-- PROBLEMA (caso Nanuque, 19/09/2026):
--   A pendência por equipe só sumia quando o relatório do dia era lançado por
--   ALGUÉM ESCALADO NAQUELA EQUIPE do TTA (comandante/motorista/patrulheiro),
--   via `criado_por_matricula`. Quando um integrante lança o relatório do dia
--   MAS não estava escalado naquela chamada específica (ex.: patrulheiro que só
--   consta no TTA de outro dia, ou lançamento feito por outro militar em nome
--   da equipe), o relatório existe e aponta o comandante certo, porém a
--   pendência continua para todos — porque quem lançou não está na lista de
--   membros daquele dia.
--
-- CORREÇÃO:
--   Considerar a equipe ATENDIDA quando existir relatório do dia em que:
--     • `criado_por_matricula` ∈ membros da equipe (regra atual), OU
--     • a MATRÍCULA DO COMANDANTE indicada no próprio relatório (extraída do
--       texto `relatorios.comandante`, que vem "149.960-7 - PG - NOME") ∈ membros.
--   Assim, um relatório que aponta o comandante correto quita a pendência mesmo
--   que quem lançou não estivesse escalado naquele TTA. Retroage sozinho.
--
-- Substitui a definição de public.relatorios_pendentes_do_militar do db/36.
-- (tta_chamada_por_id do db/36 permanece inalterada.)
-- Idempotente. Rodar no SQL Editor depois do 36.
-- ════════════════════════════════════════════════════════════════════════

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
             and (
                   r.criado_por_matricula = any(membros)
                   -- também quita se o COMANDANTE apontado no relatório é membro da equipe
                   or substring(coalesce(r.comandante,'') from '\d{3}\.\d{3}-\d') = any(membros)
                 )
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
             and (
                   r.criado_por_matricula = any(membros)
                   or substring(coalesce(r.comandante,'') from '\d{3}\.\d{3}-\d') = any(membros)
                 )
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

grant execute on function public.relatorios_pendentes_do_militar(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 36.
-- ════════════════════════════════════════════════════════════════════════

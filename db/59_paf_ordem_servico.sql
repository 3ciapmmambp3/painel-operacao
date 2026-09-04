-- ════════════════════════════════════════════════════════════════════════
-- 59_paf_ordem_servico.sql — Ordem de Serviço (OS) por operação PAF + alerta P3
--
-- Acrescenta ao cadastro PAF (operacoes_paf_fapi):
--   • número da Ordem de Serviço confeccionada (controle da P3 / Emprego Op.);
--   • marca de "confeccionada e enviada para execução" (data + quem).
-- Editável pelo Aux P3 e pelo Admin Geral (o cadastro da operação em si segue
-- só com o Admin Geral, via paf_fapi_salvar).
--
-- E cria a consulta das OS pendentes (paf_os_pendentes) para o alerta no Meu
-- Dia do Aux P3: a partir de 10 dias antes do início da operação, até a OS ser
-- marcada como enviada (ou a operação terminar).
--
-- Depende de: 04 (_sessao_militar), 26 (operacoes_paf_fapi). Idempotente.
-- ════════════════════════════════════════════════════════════════════════

-- 1) Colunas novas
alter table public.operacoes_paf_fapi add column if not exists os_numero      text;
alter table public.operacoes_paf_fapi add column if not exists os_enviada     boolean not null default false;
alter table public.operacoes_paf_fapi add column if not exists os_enviada_em  timestamptz;
alter table public.operacoes_paf_fapi add column if not exists os_enviada_por text;

-- 2) Quem pode gerenciar a OS: Aux P3 ou Admin Geral
create or replace function public._pode_gerenciar_os_paf(p_nivel text, p_funcao text)
returns boolean language sql immutable as $$
  select p_nivel = 'admin_geral'
      or lower(coalesce(p_funcao,'')) like 'aux p3%';
$$;

-- 3) Salvar a OS de uma operação
create or replace function public.paf_os_salvar(p_token uuid, p_id uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.operacoes_paf_fapi%rowtype; v_num text; v_env boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: a OS é controle do Aux P3 (ou Admin Geral).';
  end if;

  v_num := nullif(btrim(p_dados->>'os_numero'),'');
  v_env := coalesce((p_dados->>'os_enviada')::boolean, false);
  if v_env and v_num is null then
    raise exception 'Informe o número da OS antes de marcar como enviada para execução.';
  end if;

  update public.operacoes_paf_fapi set
    os_numero      = v_num,
    os_enviada     = v_env,
    os_enviada_em  = case when v_env then coalesce(os_enviada_em, now()) else null end,
    os_enviada_por = case when v_env then coalesce(os_enviada_por, v_me.matricula) else null end,
    atualizado_por = v_me.matricula, atualizado_em = now()
  where id = p_id
  returning * into v_row;
  if v_row.id is null then raise exception 'Operação PAF não encontrada.'; end if;
  return to_jsonb(v_row);
end;
$$;

-- 4) OS pendentes para o alerta do Aux P3 (Meu Dia)
--    A partir de 10 dias antes do início até o final (ou início, se sem final),
--    enquanto a OS não estiver marcada como enviada. Só devolve para Aux P3 /
--    Admin Geral; para os demais, vem vazio.
create or replace function public.paf_os_pendentes(p_token uuid)
returns table (
  id uuid, id_operacao text, nome text, inicio date, final date,
  os_numero text, dias_para_inicio int
)
language plpgsql stable security definer set search_path = public as $$
declare v_me record; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_os_paf(v_me.nivel_acesso, v_me.funcao) then
    return; -- vazio para quem não é P3/Admin
  end if;
  return query
    select o.id, o.id_operacao, o.nome, o.inicio, o.final, o.os_numero,
           (o.inicio - v_hoje)::int as dias_para_inicio
      from public.operacoes_paf_fapi o
     where o.tipo = 'PAF'
       and o.ativo = true
       and coalesce(o.os_enviada, false) = false
       and o.inicio is not null
       and v_hoje >= (o.inicio - interval '10 days')::date
       and v_hoje <= coalesce(o.final, o.inicio)
     order by o.inicio;
end;
$$;

grant execute on function public.paf_os_salvar(uuid, uuid, jsonb) to anon;
grant execute on function public.paf_os_pendentes(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 26.
-- ════════════════════════════════════════════════════════════════════════

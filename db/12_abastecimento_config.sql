-- ════════════════════════════════════════════════════════════════════════
-- 12_abastecimento_config.sql — Controle de LIMITE de abastecimento (POC/PRIME)
-- Configurável por Admin Geral e Aux P4 (na Gestão de Viaturas).
-- Quando ATIVO, a ficha passa a pedir os litros daquela fonte; se acima do
-- limite, exige quem autorizou e por quê.
-- Depende de: 04 (_sessao_militar) e 08 (_pode_gerenciar_viaturas). Idempotente.
-- ════════════════════════════════════════════════════════════════════════
create table if not exists public.abastecimento_config (
  id             int primary key default 1,
  poc_ativo      boolean not null default false,
  poc_limite     numeric,
  prime_ativo    boolean not null default false,
  prime_limite   numeric,
  atualizado_por text,
  atualizado_em  timestamptz not null default now(),
  constraint abast_config_singleton check (id = 1)
);
insert into public.abastecimento_config (id) values (1) on conflict (id) do nothing;

create or replace function public.abastecimento_config_get()
returns public.abastecimento_config
language sql stable security definer set search_path = public as $$
  select * from public.abastecimento_config where id = 1;
$$;

create or replace function public.abastecimento_config_salvar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.abastecimento_config;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: apenas Aux P4 e Admin Geral configuram o limite.';
  end if;
  update public.abastecimento_config set
    poc_ativo    = coalesce((p_dados->>'poc_ativo')::boolean, false),
    poc_limite   = nullif(p_dados->>'poc_limite','')::numeric,
    prime_ativo  = coalesce((p_dados->>'prime_ativo')::boolean, false),
    prime_limite = nullif(p_dados->>'prime_limite','')::numeric,
    atualizado_por = coalesce(v_me.nome_guerra, v_me.nome_completo),
    atualizado_em = now()
   where id = 1
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

grant execute on function public.abastecimento_config_get() to anon;
grant execute on function public.abastecimento_config_salvar(uuid, jsonb) to anon;

alter table public.abastecimento_config enable row level security;
drop policy if exists abast_cfg_sel on public.abastecimento_config;
create policy abast_cfg_sel on public.abastecimento_config for select using (true);

-- ════════════════════════════════════════════════════════════════════════
-- Excluir uma BAIXA registrada por engano (Aux P4 / Admin Geral).
-- Após excluir, recompõe a situação operacional da viatura a partir de uma
-- baixa aberta remanescente (se houver); caso contrário volta a DISPONIVEL.
-- ════════════════════════════════════════════════════════════════════════
create or replace function public.viatura_baixa_excluir(p_token uuid, p_baixa_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
        v_bx   public.viaturas_baixas%rowtype;
        v_open public.viaturas_baixas%rowtype;
        v_sit  text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: apenas Aux P4 e Admin Geral podem excluir uma baixa.';
  end if;
  select * into v_bx from public.viaturas_baixas where id = p_baixa_id;
  if v_bx.id is null then raise exception 'Baixa não encontrada.'; end if;

  delete from public.viaturas_baixas where id = p_baixa_id;

  select * into v_open from public.viaturas_baixas
    where prefixo = v_bx.prefixo and aberta = true
    order by data_baixa desc limit 1;
  v_sit := coalesce(v_open.tipo, 'DISPONIVEL');

  update public.viaturas set situacao_operacional = v_sit, atualizado_em = now()
   where prefixo = v_bx.prefixo;

  return jsonb_build_object('prefixo', v_bx.prefixo, 'situacao_operacional', v_sit);
end;
$$;
grant execute on function public.viatura_baixa_excluir(uuid, uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rode no SQL Editor depois do 08.
-- ════════════════════════════════════════════════════════════════════════

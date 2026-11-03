-- ══════════════════════════════════════════════════════════════════════
--  SISDEN responder — contas dos militares (self-service pelo painel)
--  Rodar no Supabase (SQL Editor). Idempotente.
--
--  Cada militar (Aux P3 / Admin Geral) cadastra NO PAINEL seu CPF + senha do
--  SISDEN + um PIN. Ao responder em lote, a Edge Function sisden-responder
--  acha pelo PIN, loga no SISDEN com a conta DELE e assina com o nome dele.
--
--  SEGURANÇA: a tabela guarda a SENHA do SISDEN → fica com RLS SEM políticas
--  para anon (ninguém lê pelo painel). A escrita é só via estas RPCs (security
--  definer, validadas pelo token de sessão). A Edge Function lê com a
--  service_role (que ignora RLS). A senha NUNCA volta pro painel.
-- ══════════════════════════════════════════════════════════════════════

create table if not exists public.sisden_responder_contas (
  id         uuid primary key default gen_random_uuid(),
  matricula  text not null unique,          -- dono (1 cadastro por militar)
  nome       text not null,                 -- nome que assina no SISDEN
  cpf        text not null,                 -- CPF do SISDEN (só dígitos)
  senha      text not null,                 -- senha do SISDEN (protegida por RLS)
  pin        text not null,                 -- identifica/autoriza o envio
  ativo      boolean not null default true,
  updated_at timestamptz not null default now()
);
create unique index if not exists uq_srcontas_pin on public.sisden_responder_contas (pin) where ativo;

-- RLS LIGADA e SEM políticas p/ anon → anon não lê nem escreve direto.
alter table public.sisden_responder_contas enable row level security;

-- ─── Salvar/atualizar o próprio cadastro ───────────────────────────────
create or replace function public.sisden_resp_salvar(p_token uuid, p_cpf text, p_senha text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_cpf text; v_pin text; v_outro text;
begin
  select * into r from public._sessao_militar(p_token);
  if r.id is null then raise exception 'sessão inválida'; end if;
  if not (coalesce(r.funcao,'') ~* 'AUX\s*P?\s*3' or r.nivel_acesso = 'admin_geral') then
    raise exception 'apenas Aux P3 / Admin Geral podem cadastrar';
  end if;
  v_cpf := regexp_replace(coalesce(p_cpf,''), '\D', '', 'g');
  v_pin := trim(coalesce(p_pin,''));
  if length(v_cpf) < 11 then raise exception 'CPF inválido'; end if;
  if coalesce(p_senha,'') = '' then raise exception 'senha vazia'; end if;
  if length(v_pin) < 4 then raise exception 'PIN precisa de ao menos 4 caracteres'; end if;
  select matricula into v_outro from public.sisden_responder_contas
    where pin = v_pin and ativo and matricula <> r.matricula limit 1;
  if v_outro is not null then raise exception 'PIN já usado por outro militar — escolha outro'; end if;

  insert into public.sisden_responder_contas (matricula, nome, cpf, senha, pin, ativo, updated_at)
  values (r.matricula, coalesce(r.nome_completo, r.nome_guerra), v_cpf, p_senha, v_pin, true, now())
  on conflict (matricula) do update
    set nome = excluded.nome, cpf = excluded.cpf, senha = excluded.senha,
        pin = excluded.pin, ativo = true, updated_at = now();
  return jsonb_build_object('ok', true, 'nome', coalesce(r.nome_completo, r.nome_guerra));
end; $$;

-- ─── Ver o próprio cadastro (SEM a senha) ──────────────────────────────
create or replace function public.sisden_resp_meu(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; c record;
begin
  select * into r from public._sessao_militar(p_token);
  if r.id is null then raise exception 'sessão inválida'; end if;
  select nome, cpf, pin, ativo, updated_at into c
    from public.sisden_responder_contas where matricula = r.matricula;
  if c.nome is null then return jsonb_build_object('cadastrado', false); end if;
  return jsonb_build_object('cadastrado', true, 'nome', c.nome,
    'cpf_mascarado', '***' || right(c.cpf, 3), 'tem_senha', true,
    'tem_pin', (coalesce(c.pin,'') <> ''), 'ativo', c.ativo, 'atualizado_em', c.updated_at);
end; $$;

-- ─── Remover o próprio cadastro ────────────────────────────────────────
create or replace function public.sisden_resp_remover(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record;
begin
  select * into r from public._sessao_militar(p_token);
  if r.id is null then raise exception 'sessão inválida'; end if;
  delete from public.sisden_responder_contas where matricula = r.matricula;
  return jsonb_build_object('ok', true);
end; $$;

grant execute on function public.sisden_resp_salvar(uuid,text,text,text) to anon;
grant execute on function public.sisden_resp_meu(uuid)     to anon;
grant execute on function public.sisden_resp_remover(uuid) to anon;

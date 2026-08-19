-- ════════════════════════════════════════════════════════════════════════
-- 15_operacao_quesitos.sql — Quesitos específicos por Operação
--
-- Cada operação (do card "Operação" do Relatório de Serviço) pode ter perguntas
-- próprias. Cada QUESITO tem um ESCOPO:
--   • 'todas'       — vale para todas as operações (comum);
--   • 'especificas' — vale só para as operações listadas em `operacoes` (uma ou várias).
-- No Relatório, a operação recebe os quesitos "de todas" SOMADOS aos específicos dela.
--
-- Armazenado como um único array jsonb (catálogo pequeno, edição "salvar tudo"),
-- no mesmo espírito de listas_config/abastecimento_config. Cada item:
--   { id, label, tipo, opcoes[], obrigatorio, escopo, operacoes[] }
--   tipo ∈ texto_curto | texto_longo | numero | sim_nao | opcoes | data
--
-- Depende de: 04_sessoes_e_militares_seguranca.sql (_sessao_militar).
-- Idempotente. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.operacao_quesitos (
  id             text primary key default 'default',
  quesitos       jsonb not null default '[]'::jsonb,
  atualizado_por text,
  atualizado_em  timestamptz not null default now()
);
insert into public.operacao_quesitos (id, quesitos) values ('default','[]'::jsonb)
  on conflict (id) do nothing;

-- ── RPC: ler o catálogo (anon — usado pelo Admin e pelo Relatório) ───────
create or replace function public.operacao_quesitos_get()
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select quesitos from public.operacao_quesitos where id='default'), '[]'::jsonb);
$$;

-- ── RPC: salvar o catálogo inteiro (restrito Admin Geral) ────────────────
create or replace function public.operacao_quesitos_salvar(p_token uuid, p_quesitos jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: os quesitos de operação são geridos pelo Admin Geral.';
  end if;
  if jsonb_typeof(p_quesitos) <> 'array' then
    raise exception 'Formato inválido (esperado um array de quesitos).';
  end if;
  update public.operacao_quesitos
     set quesitos = p_quesitos, atualizado_por = v_me.matricula, atualizado_em = now()
   where id = 'default';
  return jsonb_build_object('ok', true, 'total', jsonb_array_length(p_quesitos));
end;
$$;

-- ── RLS ─────────────────────────────────────────────────────────────────
alter table public.operacao_quesitos enable row level security;
drop policy if exists opq_sel on public.operacao_quesitos;
create policy opq_sel on public.operacao_quesitos for select using (true);

grant execute on function public.operacao_quesitos_get() to anon;
grant execute on function public.operacao_quesitos_salvar(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 04.
-- ════════════════════════════════════════════════════════════════════════

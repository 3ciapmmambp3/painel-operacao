-- ════════════════════════════════════════════════════════════════════════
-- 16_operacoes.sql — Cadastro de OPERAÇÕES no painel (migração da aba da planilha)
--
-- Passa a ser a FONTE das operações (antes vinham da aba "OPERAÇÕES" da planilha
-- via Apps Script). O Relatório de Serviço lê daqui; o card "Operação" mostra as
-- operações ATIVAS na data do serviço (inicio <= data <= final).
--
-- Só as abas OPERAÇÕES e CAMPOS_PRODUTIVIDADE migram para o painel; as demais
-- referências (MILITARES, PAF, FAPI, GRUPOS...) continuam na planilha por ora.
--
-- Depende de: 04_sessoes_e_militares_seguranca.sql (_sessao_militar).
-- Idempotente. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.operacoes (
  id             uuid primary key default gen_random_uuid(),
  nome           text not null,
  inicio         date,
  final          date,
  observacao     text,
  ativo          boolean not null default true,
  atualizado_por text,
  atualizado_em  timestamptz not null default now(),
  criado_em      timestamptz not null default now()
);
-- chave lógica p/ o seed ser idempotente (mesma operação = mesmo nome + mesmo início)
create unique index if not exists uq_operacoes_nome_inicio on public.operacoes (nome, inicio);
create index if not exists idx_operacoes_ativo on public.operacoes (ativo);

-- ── Seed das operações de 2026 (as que estavam na planilha) ──────────────
-- "OUTRA OPERAÇÃO NÃO DESCRITA ACIMA" é sentinela da UI — NÃO entra aqui.
insert into public.operacoes (nome, inicio, final) values
  ('ANO NOVO',                                    '2026-01-01','2026-01-04'),
  ('CARNAVAL',                                    '2026-02-14','2026-02-17'),
  ('CAMPO SEGURO (fictícia)',                     '2026-03-16','2026-03-19'),
  ('SEMANA SANTA',                                '2026-03-29','2026-04-01'),
  ('DIA DO TRABALHADOR',                          '2026-05-01','2026-05-04'),
  ('DIVISA SEGURA (fictícia)',                    '2026-05-11','2026-05-14'),
  ('SEMANA NACIONAL DO MEIO AMBIENTE',            '2026-06-01','2026-06-04'),
  ('CORPUS CHRISTI',                              '2026-06-04','2026-06-07'),
  ('PROTETOR DOS BIOMAS DIVERSOS - POAI',         '2026-07-01','2026-08-20'),
  ('INDEPENDÊNCIA DO BRASIL (7 DE SETEMBRO)',     '2026-09-07','2026-09-10'),
  ('DIA DA ÁRVORE',                               '2026-09-21','2026-09-24'),
  ('APARECIDA',                                   '2026-10-12','2026-10-15'),
  ('PIRACEMA',                                    '2026-11-01','2026-11-04'),
  ('FINADOS',                                     '2026-11-02','2026-11-05'),
  ('PROCLAMAÇÃO DA REPÚBLICA',                    '2026-11-15','2026-11-18'),
  ('NATALINA (fictícia)',                         '2026-12-20','2026-12-23')
on conflict (nome, inicio) do nothing;

-- ── RPC: listar (anon) — o painel filtra por data no cliente ─────────────
create or replace function public.operacoes_listar()
returns setof public.operacoes
language sql stable security definer set search_path = public as $$
  select * from public.operacoes where ativo = true order by inicio nulls last, nome;
$$;

-- ── RPC: salvar (incluir/editar) — restrito Admin Geral ──────────────────
create or replace function public.operacao_salvar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.operacoes%rowtype; v_id uuid; v_nome text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: o cadastro de operações é do Admin Geral.';
  end if;
  v_nome := nullif(trim(p_dados->>'nome'),'');
  if v_nome is null then raise exception 'Informe o nome da operação.'; end if;
  v_id := nullif(p_dados->>'id','')::uuid;

  if v_id is null then
    insert into public.operacoes (nome, inicio, final, observacao, ativo, atualizado_por)
    values (v_nome, nullif(p_dados->>'inicio','')::date, nullif(p_dados->>'final','')::date,
            nullif(p_dados->>'observacao',''), coalesce((p_dados->>'ativo')::boolean,true), v_me.matricula)
    returning * into v_row;
  else
    update public.operacoes set
      nome = v_nome,
      inicio = nullif(p_dados->>'inicio','')::date,
      final  = nullif(p_dados->>'final','')::date,
      observacao = nullif(p_dados->>'observacao',''),
      ativo = coalesce((p_dados->>'ativo')::boolean, ativo),
      atualizado_por = v_me.matricula, atualizado_em = now()
    where id = v_id
    returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- ── RPC: remover (soft por padrão: ativo=false; hard apaga) ──────────────
create or replace function public.operacao_remover(p_token uuid, p_id uuid, p_hard boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: o cadastro de operações é do Admin Geral.';
  end if;
  if coalesce(p_hard,false) then
    delete from public.operacoes where id = p_id;
    return jsonb_build_object('ok', true, 'hard', true);
  end if;
  update public.operacoes set ativo=false, atualizado_por=v_me.matricula, atualizado_em=now() where id = p_id;
  return jsonb_build_object('ok', true, 'hard', false);
end;
$$;

-- ── RLS ─────────────────────────────────────────────────────────────────
alter table public.operacoes enable row level security;
drop policy if exists operacoes_sel on public.operacoes;
create policy operacoes_sel on public.operacoes for select using (true);

grant execute on function public.operacoes_listar() to anon;
grant execute on function public.operacao_salvar(uuid, jsonb) to anon;
grant execute on function public.operacao_remover(uuid, uuid, boolean) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 04.
-- ════════════════════════════════════════════════════════════════════════

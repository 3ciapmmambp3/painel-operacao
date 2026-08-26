-- ════════════════════════════════════════════════════════════════════════
-- 32_links_uteis.sql — Links úteis gerenciáveis (aparecem no Meu Dia)
--
-- O Admin Geral cadastra (nome + URL) na aba Administração; os cards aparecem
-- na seção "Links úteis" do Meu Dia para todos. Substitui a lista fixa que
-- estava hard-coded em inicio.html (semeada abaixo).
--
-- Depende de: 04_sessoes_e_militares_seguranca.sql (_sessao_militar).
-- Idempotente. Rodar no SQL Editor depois do 04.
-- ════════════════════════════════════════════════════════════════════════

create table if not exists public.links_uteis (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  url           text not null,
  ordem         int not null default 0,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);

-- Seed dos links que estavam fixos no Meu Dia (só na 1ª vez; não duplica).
insert into public.links_uteis (nome, url, ordem)
select v.nome, v.url, v.ordem from (values
  ('REDS',                        'https://web.sids.mg.gov.br/reds/',                     1),
  ('Intranet PMMG',               'https://intranet.policiamilitar.mg.gov.br',            2),
  ('Mandado de Prisão (CNJ/BNMP)','https://portalbnmp.cnj.jus.br/#/pesquisa-peca',        3),
  ('SISPASS / IBAMA',             'https://servicos.ibama.gov.br/ctf/sistema.php',        4),
  ('SIAM Legislação',             'https://www.siam.mg.gov.br/sla/action/Consulta.do',    5),
  ('IDE Sisema (webgis)',         'https://idesisema.meioambiente.mg.gov.br/webgis',      6)
) as v(nome,url,ordem)
where not exists (select 1 from public.links_uteis);

-- ── RPC: listar (anon) — só ativos, na ordem ───────────────────────────
create or replace function public.links_uteis_listar()
returns setof public.links_uteis
language sql stable security definer set search_path = public as $$
  select * from public.links_uteis where ativo = true order by ordem, criado_em;
$$;

-- ── RPC: salvar (incluir/editar) — restrito Admin Geral ─────────────────
create or replace function public.links_uteis_salvar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.links_uteis%rowtype; v_id uuid;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: apenas o Admin Geral gerencia os links úteis.';
  end if;
  if nullif(btrim(p_dados->>'nome'),'') is null then raise exception 'Informe o nome do link.'; end if;
  if nullif(btrim(p_dados->>'url'),'')  is null then raise exception 'Informe a URL do link.'; end if;
  v_id := nullif(p_dados->>'id','')::uuid;
  if v_id is null then
    insert into public.links_uteis (nome, url, ordem, ativo)
    values (btrim(p_dados->>'nome'), btrim(p_dados->>'url'),
            coalesce((p_dados->>'ordem')::int, 999), coalesce((p_dados->>'ativo')::boolean, true))
    returning * into v_row;
  else
    update public.links_uteis set
      nome  = btrim(p_dados->>'nome'),
      url   = btrim(p_dados->>'url'),
      ordem = coalesce((p_dados->>'ordem')::int, ordem),
      ativo = coalesce((p_dados->>'ativo')::boolean, ativo)
    where id = v_id
    returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- ── RPC: remover (hard delete) — restrito Admin Geral ───────────────────
create or replace function public.links_uteis_remover(p_token uuid, p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: apenas o Admin Geral gerencia os links úteis.';
  end if;
  delete from public.links_uteis where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

alter table public.links_uteis enable row level security;
drop policy if exists links_uteis_sel on public.links_uteis;
create policy links_uteis_sel on public.links_uteis for select using (true);

grant execute on function public.links_uteis_listar() to anon;
grant execute on function public.links_uteis_salvar(uuid, jsonb) to anon;
grant execute on function public.links_uteis_remover(uuid, uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 04.
-- ════════════════════════════════════════════════════════════════════════

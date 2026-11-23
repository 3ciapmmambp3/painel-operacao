-- ══════════════════════════════════════════════════════════════════════
--  db/212 — Minha Agenda: sincronização com a Google Agenda pessoal
--  Data: 2026-11-23
--
--  Caminho B (Apps Script na conta Google do próprio militar):
--   (1) Cada militar tem um TOKEN pessoal de sincronização (uuid secreto).
--   (2) Um FEED somente-leitura, identificado SÓ por esse token (sem sessão),
--       devolve os LEMBRETES pessoais do militar (agenda_pessoal com data).
--   O Apps Script na conta dele lê o feed e cria os eventos na agenda dele.
--  Sem senha no script; o token pode ser rotacionado a qualquer momento.
--  Idempotente.
-- ══════════════════════════════════════════════════════════════════════

alter table public.militares add column if not exists agenda_sync_token uuid;
create unique index if not exists idx_militares_agenda_sync_token
  on public.militares(agenda_sync_token) where agenda_sync_token is not null;

-- Gera/retorna o token de sync do PRÓPRIO militar (resolvido pela sessão).
-- p_novo = true → rotaciona (revoga o anterior).
create or replace function public.agenda_sync_token(p_token uuid, p_novo boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me record; v_tok uuid;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  select agenda_sync_token into v_tok from public.militares where id = v_me.id;
  if v_tok is null or p_novo then
    v_tok := gen_random_uuid();
    update public.militares set agenda_sync_token = v_tok where id = v_me.id;
  end if;
  return jsonb_build_object('ok', true, 'sync_token', v_tok);
end $$;

-- Feed somente-leitura (sem sessão): identificado SÓ pelo sync token.
-- Devolve os lembretes pessoais pendentes/em andamento, com data, dos
-- últimos 7 dias em diante. Nada é exposto sem o token correto.
create or replace function public.agenda_sync_feed(p_sync uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_mid uuid; v_out jsonb;
begin
  if p_sync is null then return '[]'::jsonb; end if;
  select id into v_mid from public.militares
    where agenda_sync_token = p_sync and ativo = true;
  if v_mid is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',         a.id,
           'titulo',     a.titulo,
           'inicio',     a.prazo,                 -- timestamptz → ISO com offset
           'observacao', coalesce(a.observacao,''),
           'prioridade', a.prioridade,
           'status',     a.status
         ) order by a.prazo), '[]'::jsonb)
    into v_out
  from public.agenda_pessoal a
  where a.militar_id = v_mid
    and a.prazo is not null
    and a.status in ('pendente','em_andamento')
    and a.prazo >= now() - interval '7 days';
  return v_out;
end $$;

grant execute on function public.agenda_sync_token(uuid, boolean) to anon, authenticated;
grant execute on function public.agenda_sync_feed(uuid)            to anon, authenticated;

-- ══════════════════════════════════════════════════════════════════════
--  SSO — validação de token de sessão para o painel-3cia (Painel de Demandas)
--  Rodar no Supabase (SQL Editor). Idempotente.
--
--  O painel-3cia é um app separado (Next.js) que, quando aberto pelo card
--  da aba Gestão Operacional, recebe o token de sessão opaco do militar
--  (o mesmo emitido por auth_login → tabela public.sessoes). Ele valida o
--  token AQUI, no servidor, e só então cria a sessão dele — assim não há
--  segundo login nem exposição pública do painel de demandas.
--
--  Retorna a identidade mínima do militar se o token for válido e não
--  expirado; NULL caso contrário. Reaproveita _sessao_militar (04_*.sql),
--  que já resolve o token com todas as verificações (expira_em, ativo).
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.auth_sso_validar(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record;
begin
  select * into r from public._sessao_militar(p_token);
  if r.id is null then
    return null;
  end if;
  return jsonb_build_object(
    'id',            r.id,
    'matricula',     r.matricula,
    'nome',          coalesce(r.nome_guerra, r.nome_completo),
    'nivel_acesso',  r.nivel_acesso,
    'grupamento_id', r.grupamento_id
  );
end;
$$;

-- PostgREST: permite que a chave anon (pública) chame esta RPC. A função é
-- security definer e só devolve dados para um token válido — a chave anon
-- sozinha, sem um token de sessão real, não obtém nada.
grant execute on function public.auth_sso_validar(uuid) to anon;

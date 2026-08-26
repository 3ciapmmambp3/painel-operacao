-- ════════════════════════════════════════════════════════════════════════
-- 35_links_icone.sql — Ícone (emoji) por link útil
--
-- Dá a cada card de "Links úteis" (Meu Dia) um ícone próprio, escolhido pelo
-- Admin Geral no gestor de links. Antes todos caíam no 🔗 genérico; agora cada
-- link guarda seu emoji. Semeia os 6 links originais com os ícones antigos.
--
-- Depende de: 32_links_uteis.sql. Idempotente. Rodar no SQL Editor depois do 32.
-- ════════════════════════════════════════════════════════════════════════

-- 1) Coluna nova (aditiva; nula = usa o 🔗 padrão no front)
alter table public.links_uteis add column if not exists icone text;

-- 2) Semeia os ícones antigos nos links originais (só onde ainda não há ícone,
--    para não sobrescrever escolhas futuras do Admin).
update public.links_uteis set icone = '🚔' where icone is null and nome = 'REDS';
update public.links_uteis set icone = '🌐' where icone is null and nome = 'Intranet PMMG';
update public.links_uteis set icone = '⚖️' where icone is null and nome = 'Mandado de Prisão (CNJ/BNMP)';
update public.links_uteis set icone = '🦜' where icone is null and nome = 'SISPASS / IBAMA';
update public.links_uteis set icone = '📜' where icone is null and nome = 'SIAM Legislação';
update public.links_uteis set icone = '🗺️' where icone is null and nome = 'IDE Sisema (webgis)';

-- 3) RPC salvar atualizada para persistir o ícone (mantém as demais regras).
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
    insert into public.links_uteis (nome, url, icone, ordem, ativo)
    values (btrim(p_dados->>'nome'), btrim(p_dados->>'url'),
            nullif(btrim(p_dados->>'icone'),''),
            coalesce((p_dados->>'ordem')::int, 999), coalesce((p_dados->>'ativo')::boolean, true))
    returning * into v_row;
  else
    update public.links_uteis set
      nome  = btrim(p_dados->>'nome'),
      url   = btrim(p_dados->>'url'),
      icone = nullif(btrim(p_dados->>'icone'),''),
      ordem = coalesce((p_dados->>'ordem')::int, ordem),
      ativo = coalesce((p_dados->>'ativo')::boolean, ativo)
    where id = v_id
    returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

grant execute on function public.links_uteis_salvar(uuid, jsonb) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 32.
-- ════════════════════════════════════════════════════════════════════════

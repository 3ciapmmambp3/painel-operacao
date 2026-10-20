-- 150_ferias_efetivo_escopo.sql
--   RPC que lista o EFETIVO (nomes) com recorte de escopo para a visão de
--   "quem já escolheu / quem falta escolher" as férias.
--
--   Problema que resolve: militares_roster_escopo (db/45/67/73) recorta o
--   pelotão por um REGEX em grupamento_id ('(\d+)\s*PEL'). Quando o grupamento
--   é um nome de GP (sem "PEL" no texto), o militar é descartado — então o
--   Admin Pelotão não via vários grupamentos do seu pelotão (nem a si mesmo).
--
--   Aqui o pelotão vem do MAPA AUTORITATIVO public._ferias_pelotao(grupamento_id)
--   (tabela grupos), o MESMO usado por ferias_percentuais. E o efetivo-base usa
--   o MESMO filtro de ferias_percentuais, para que os totais batam.
--
--   Escopo por quem chama:
--     • _ferias_pode_p1 (Admin Geral / Aux P1 / CMT Cia / CMT Pel) → TODA a Cia.
--     • admin_pelotao  → todo o SEU pelotão (via _ferias_pelotao).
--     • admin_gp       → o seu grupamento.
--     • demais (CMT/Cmt de GP etc.) → o seu grupamento.

drop function if exists public.ferias_efetivo_escopo(uuid, int);

create or replace function public.ferias_efetivo_escopo(p_token uuid, p_ano int default null)
returns table (id uuid, matricula text, posto_graduacao text, nome_completo text,
               nome_guerra text, grupamento_id text, pelotao text, funcao text)
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_ano    int := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_full   boolean;
  v_mypel  text;
  v_reconv boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  v_full := public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao);
  -- só gestor (Cia) ou comandante de pelotão/grupamento pode consultar o efetivo
  if not v_full
     and coalesce(v_me.nivel_acesso,'') not in ('admin_pelotao','admin_gp')
     and coalesce(v_me.funcao,'') !~* '(cmt|comandante)' then
    raise exception 'Consulta restrita ao Aux P1 / Comando.';
  end if;

  v_mypel := public._ferias_pelotao(v_me.grupamento_id);
  select coalesce(contar_reconvocados, false) into v_reconv
    from public.ferias_cronograma where ano = v_ano;
  v_reconv := coalesce(v_reconv, false);

  return query
    select m.id, m.matricula, m.posto_graduacao, m.nome_completo, m.nome_guerra,
           m.grupamento_id, public._ferias_pelotao(m.grupamento_id) as pelotao, m.funcao
      from public.militares m
     where m.ativo = true
       and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and upper(coalesce(m.funcao,'')) not like '%ASPM%'
       and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
       and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                         and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
       and (
            v_full
         or (coalesce(v_me.nivel_acesso,'') = 'admin_pelotao'
             and public._ferias_pelotao(m.grupamento_id) is not distinct from v_mypel)
         or (coalesce(v_me.nivel_acesso,'') = 'admin_gp'
             and m.grupamento_id = v_me.grupamento_id)
         or (coalesce(v_me.nivel_acesso,'') not in ('admin_pelotao','admin_gp')
             and m.grupamento_id = v_me.grupamento_id)
       )
     order by pelotao nulls last, m.grupamento_id, m.posto_graduacao, m.nome_completo;
end;
$$;

grant execute on function public.ferias_efetivo_escopo(uuid, int) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- 77_oficio_visibilidade_pelotao_cia.sql — Ofício em nível de PELOTÃO e CIA
--
-- Os selects de Emitente (saída) / Destino (entrada) passaram a oferecer, além
-- dos GP, o nível PELOTÃO ("N PEL / 3 CIA PM MAMB / CIDADE-SEDE") e o nível
-- COMPANHIA ("3 CIA PM MAMB"). Isso muda o grupamento_id gravado, então o
-- recorte de visibilidade (oficio_listar, db/63) precisa entender esses casos:
--
--   • Ofício de PELOTÃO (tem PEL, não tem GP): visível a todo o pelotão —
--     o CMT/Aux de Pelotão já via (casa o nº do PEL); agora os militares de GP
--     daquele pelotão também veem.
--   • Ofício de COMPANHIA ("3 CIA PM MAMB": sem GP e sem PEL, cita CIA):
--     visível aos militares da ADM (e ao CMT Cia, que já vê por escopo total).
--
-- Escopo total (Aux P1 / Admin / Admin Geral / CMT Cia) continua vendo tudo.
-- Só recria oficio_listar. Idempotente. Rodar depois do 63.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.oficio_listar(p_token uuid)
returns setof public.oficios
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_gp  text;
  v_pel text;
  v_adm boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- Aux P1 / Admin / Admin Geral / CMT Cia → veem tudo
  if public._oficio_escopo_total(v_me.nivel_acesso, v_me.funcao) then
    return query select * from public.oficios order by data_doc desc, created_at desc;
    return;
  end if;

  v_adm := upper(btrim(coalesce(v_me.grupamento_id,''))) like 'ADM%';
  v_gp  := (regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\s*GP',  'i'))[1];
  v_pel := (regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1];

  return query
    select * from public.oficios o
     where case
       -- staff/ADM (sem GP/Pel): ofícios de origem ADM + ofícios de COMPANHIA
       when v_adm then
             upper(btrim(coalesce(o.grupamento_id,''))) like 'ADM%'
          or ( (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*GP',  'i'))[1] is null
           and (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1] is null
           and coalesce(o.grupamento_id,'') ~* 'cia' )
       -- CMT/Aux de Pelotão: todo o pelotão (casa o nº do Pelotão — inclui os de nível Pelotão)
       when coalesce(v_me.nivel_acesso,'') = 'admin_pelotao' and v_pel is not null then
         (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1] = v_pel
       -- Admin de GP e demais militares: o próprio GP (nº GP + nº Pelotão)
       -- OU um ofício de nível PELOTÃO do seu pelotão (tem PEL, sem GP)
       when v_gp is not null and v_pel is not null then
         (     (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*GP',  'i'))[1] = v_gp
           and (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1] = v_pel )
         or (  (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*GP',  'i'))[1] is null
           and (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1] = v_pel )
       else false
     end
     order by o.data_doc desc, o.created_at desc;
end;
$$;

grant execute on function public.oficio_listar(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 63.
-- ════════════════════════════════════════════════════════════════════════

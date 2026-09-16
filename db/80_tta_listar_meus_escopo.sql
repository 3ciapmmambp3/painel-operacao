-- ══════════════════════════════════════════════════════════════════════
--  80_tta_listar_meus_escopo.sql — TTA: Admin GP vê o GP, Admin Pel vê o Pel
--
--  Unifica a visibilidade do TTA ("Meus TTA") com a do Relatório de Serviço
--  (db/49). Antes, tta_listar_meus só mostrava as chamadas em que o militar era
--  RESPONSÁVEL ou PRESENTE. Agora, além disso:
--    • Admin Geral / Admin / função "CMT CIA" → TODAS as chamadas
--    • Admin de Pelotão (admin_pelotao)         → todo o seu PELOTÃO
--    • Admin de GP (admin_gp)                   → todo o seu GRUPAMENTO (GP+PEL)
--    • Qualquer militar                          → onde é responsável ou presente
--
--  O escopo do GP/Pel é casado pelo grupamento_completo da chamada (nº GP + nº
--  PEL via regex), igual ao relatorio_meus. Usado só em meus-tta.html.
--  Idempotente. Rodar depois do 42 (que criou tta_listar_meus).
-- ══════════════════════════════════════════════════════════════════════

create or replace function public.tta_listar_meus(p_token uuid, p_ano int, p_mes int)
returns setof public.tta_chamadas
language plpgsql stable security definer set search_path = public as $$
declare
  v_me      record;
  v_mat     text;
  v_nivel   text;
  v_func    text;
  v_all     boolean;
  v_meu_pel text;
  v_meu_gp  text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  v_mat   := regexp_replace(coalesce(v_me.matricula,''),'\D','','g');
  v_nivel := coalesce(v_me.nivel_acesso, '');
  v_func  := upper(btrim(coalesce(v_me.funcao, '')));
  v_all   := v_nivel in ('admin_geral', 'admin') or v_func = 'CMT CIA';
  v_meu_pel := (regexp_match(coalesce(v_me.grupamento_id, ''), '(\d+)\s*PEL', 'i'))[1];
  v_meu_gp  := (regexp_match(coalesce(v_me.grupamento_id, ''), '(\d+)\s*GP',  'i'))[1];

  return query
    select * from public.tta_chamadas c
     where extract(year from c.data_hora_chamada at time zone 'America/Sao_Paulo')::int = p_ano
       and (p_mes is null or extract(month from c.data_hora_chamada at time zone 'America/Sao_Paulo')::int = p_mes)
       and (
         v_all
         -- Admin de Pelotão: todo o pelotão.
         or (v_nivel = 'admin_pelotao' and v_meu_pel is not null
             and (regexp_match(coalesce(c.grupamento_completo, ''), '(\d+)\s*PEL', 'i'))[1] = v_meu_pel)
         -- Admin de GP: o seu grupamento (GP + Pelotão).
         or (v_nivel = 'admin_gp' and v_meu_gp is not null and v_meu_pel is not null
             and (regexp_match(coalesce(c.grupamento_completo, ''), '(\d+)\s*GP',  'i'))[1] = v_meu_gp
             and (regexp_match(coalesce(c.grupamento_completo, ''), '(\d+)\s*PEL', 'i'))[1] = v_meu_pel)
         -- Qualquer militar: onde é responsável ou presente na equipe.
         or regexp_replace(coalesce(c.militar_resp_matricula,''),'\D','','g') = v_mat
         or exists (
              select 1 from jsonb_array_elements(coalesce(c.militares_presentes,'[]'::jsonb)) e
               where regexp_replace(coalesce(e->>'matricula',''),'\D','','g') = v_mat
            )
       )
     order by c.data_hora_chamada desc;
end;
$$;

grant execute on function public.tta_listar_meus(uuid, int, int) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 42.
-- ══════════════════════════════════════════════════════════════════════

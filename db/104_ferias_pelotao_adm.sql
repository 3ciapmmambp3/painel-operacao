-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — ADM como grupo próprio no percentual
--  Militares da ADM (grupamento_id começando com 'ADM') não têm número de
--  pelotão, então caíam em "(sem pelotão)". Agora _ferias_pelotao devolve
--  'ADM' para eles → aparece como um grupo próprio nos limites de % e no
--  painel de Percentuais (junto com Pelotão 1..N).
--
--  Afeta ferias_percentuais e o carimbo de pelotão em ferias_pedido_salvar
--  (ambos usam _ferias_pelotao). Depende de: 101. Idempotente. Rodar depois do 103.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public._ferias_pelotao(p_grupamento_id text)
returns text language sql stable as $$
  select case
    when upper(btrim(coalesce(p_grupamento_id,''))) like 'ADM%' then 'ADM'
    else coalesce(
      (select g.pelotao from public.grupos g
        where g.gp_responsavel = p_grupamento_id limit 1),
      nullif((regexp_match(upper(coalesce(p_grupamento_id,'')), '(\d+)\s*PEL'))[1], '')
    )
  end;
$$;
grant execute on function public._ferias_pelotao(text) to anon;
-- ══════════════════════════════════════════════════════════════════════
-- FIM. Não precisa re-rodar anteriores. Os pedidos já gravados mantêm o
-- pelotao antigo até serem re-salvos (não afeta o painel, que recalcula).
-- ══════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
-- db/99 — relatorio_completo devolve também o NOME COMPLETO de quem registrou
-- ════════════════════════════════════════════════════════════════════════
-- Motivo: o rodapé "Registrado por … em …" do Ver/Imprimir vinha com o NOME DE
-- GUERRA (é o que fica gravado em relatorios.criado_por_nome). Como a RPC já
-- cruza com o efetivo (militares) p/ resolver o posto, aqui também trazemos o
-- nome_completo e devolvemos em `criado_por_nome_completo` — o front usa esse
-- e cai no nome gravado só se o militar não for encontrado.
--
-- SUBSTITUI a definição do db/98 (create or replace). Ordem: depois do 18/19.
-- Idempotente.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.relatorio_completo(p_token uuid, p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_me record; v_r public.relatorios%rowtype; v_cats jsonb;
  v_posto text; v_nome_completo text; v_matclean text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  select * into v_r from public.relatorios where id = p_id and ativo = true;
  if v_r.id is null then return jsonb_build_object('ok', false); end if;

  select coalesce(jsonb_agg(jsonb_build_object('categoria', categoria, 'itens', itens) order by categoria), '[]'::jsonb)
    into v_cats
  from (
    select categoria, jsonb_agg(dados order by nr_item) as itens
    from public.relatorio_itens where relatorio_id = p_id
    group by categoria
  ) g;

  -- Posto/graduação e NOME COMPLETO de quem registrou não são gravados no
  -- relatório (criado_por_nome guarda o nome de guerra); resolve pelo efetivo
  -- (militares) via matrícula normalizada (7 dígitos com zero à esquerda).
  v_matclean := lpad(regexp_replace(coalesce(v_r.criado_por_matricula,''), '\D', '', 'g'), 7, '0');
  if v_matclean <> '0000000' then
    select m.posto_graduacao, m.nome_completo
      into v_posto, v_nome_completo
      from public.militares m
     where m.matricula_clean = v_matclean
     limit 1;
  end if;

  return jsonb_build_object('ok', true, 'sheet_id', v_r.sheet_id,
                            'bloco1', v_r.bloco1, 'categorias', v_cats,
                            'criado_por_matricula', v_r.criado_por_matricula,
                            'criado_por_nome', v_r.criado_por_nome,
                            'criado_por_nome_completo', v_nome_completo,
                            'criado_por_posto', v_posto,
                            'criado_em', v_r.criado_em);
end;
$$;

grant execute on function public.relatorio_completo(uuid, uuid) to anon;

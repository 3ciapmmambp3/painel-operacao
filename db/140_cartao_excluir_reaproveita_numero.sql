-- ════════════════════════════════════════════════════════════════════════
--  db/140 — EXCLUSÃO DO CARTÃO PROGRAMA REAPROVEITA O NÚMERO
--  (mesmo comportamento dos Ofícios, db/69)
--
--   • Se o cartão excluído é o de MAIOR número do ano (não existe nenhum
--     outro registro — ativo ou inativo — com numero_seq maior), ou seja,
--     o PRÓXIMO ainda não foi gerado → REMOVE o registro de fato e DEVOLVE
--     o contador (ultimo = numero_seq - 1), para que o próximo cartão criado
--     receba exatamente esse número, mantendo a sequência sem buraco.
--   • Se já existe um número MAIOR (o próximo já foi gerado) → mantém a
--     exclusão LÓGICA (ativo = false): o número vira uma lacuna e NÃO é
--     reaproveitado (não renumera os demais).
--
--  Observações:
--   - demandas/respostas são colunas jsonb na própria tabela e não há
--     tabelas filhas com FK para cartoes_programa, então o delete físico é
--     seguro. O delete físico é necessário porque o índice único
--     uq_cartao_num_ano (ano, numero_seq) impediria reusar o número com o
--     registro antigo ainda presente.
--   - Os números atuais NÃO são tocados — a regra vale só para exclusões
--     daqui em diante.
--
--  Depende de: 127 (cartoes_programa, cartao_excluir, _cartao_pode_ver),
--              01 (public.contadores).
--  Idempotente — pode rodar mais de uma vez. Rodar no SQL Editor do Supabase.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.cartao_excluir(p_token uuid, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me       record;
  v_cur      public.cartoes_programa;
  v_eh_ultimo boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then return jsonb_build_object('ok', false, 'erro', 'Sessão expirada.'); end if;

  select * into v_cur from public.cartoes_programa where id = p_id;
  if v_cur.id is null then return jsonb_build_object('ok', false, 'erro', 'Cartão não encontrado.'); end if;

  if not public._cartao_pode_ver(v_me.nivel_acesso, v_me.funcao, v_me.grupamento_id, v_cur.grupamento_id) then
    return jsonb_build_object('ok', false, 'erro', 'Permissão insuficiente.');
  end if;

  -- É o cartão de MAIOR número do ano? (nenhum outro registro acima dele)
  v_eh_ultimo := not exists (
    select 1 from public.cartoes_programa
    where ano = v_cur.ano and numero_seq > v_cur.numero_seq
  );

  if v_eh_ultimo then
    -- último número gerado → remove de fato e devolve o contador
    delete from public.cartoes_programa where id = p_id;
    update public.contadores
       set ultimo = greatest(v_cur.numero_seq - 1, 0)
     where ano = v_cur.ano and tipo = 'cartao';
    return jsonb_build_object('ok', true, 'reaproveitado', true,
                              'numero', v_cur.numero, 'seq', v_cur.numero_seq);
  end if;

  -- já existe número maior → exclusão lógica (número vira lacuna)
  update public.cartoes_programa set ativo = false where id = p_id;
  return jsonb_build_object('ok', true, 'reaproveitado', false,
                            'numero', v_cur.numero, 'seq', v_cur.numero_seq);
end;
$$;

grant execute on function public.cartao_excluir(uuid, uuid) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. proximo_numero (db/01) segue igual; aqui só devolvemos o contador
-- quando o número excluído era o último do ano.
-- ══════════════════════════════════════════════════════════════════════

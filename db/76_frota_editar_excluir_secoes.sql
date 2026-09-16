-- ════════════════════════════════════════════════════════════════════════
-- 76_frota_editar_excluir_secoes.sql — Aux P4 edita/exclui ACIDENTE e
-- ABASTECIMENTO direto nos painéis, e o painel de Abastecimento passa a
-- mostrar o comprovante anexado.
--
-- Acidente:      1 por ficha em mov_viaturas.dados->'acidente' (tem_acidente).
-- Abastecimento: N por ficha em mov_viaturas.dados->'abastecimento'->'itens'[].
-- Comprovante do abastecimento: anexo com categoria 'abastecimento-comprovante'
--   e contexto = a fonte do lançamento (POC / Cartão PRIME / Convênio ou Doação).
--
-- Tudo restrito ao gestor de viaturas (_pode_gerenciar_viaturas = Aux P4 /
-- Admin Geral) e registrado em mov_viaturas_audit (db/28). Exclusão é só da
-- SEÇÃO — a ficha de movimentação continua existindo. As fotos do acidente
-- (categoria 'acidente-fotos') são removidas junto ao excluir o acidente.
--
-- Depende de: 04 (_sessao_militar), 08 (mov_viaturas, _pode_gerenciar_viaturas),
-- 28 (mov_viaturas_audit), 31 (frota_abast_listar), 33 (frota_acidentes_listar).
-- Idempotente. Rodar no SQL Editor depois do 33.
-- ════════════════════════════════════════════════════════════════════════

-- ── Helper interno: exige gestor e devolve a sessão ──────────────────────
create or replace function public._frota_gestor(p_token uuid)
returns public.militares
language plpgsql stable security definer set search_path = public as $$
declare v_me public.militares%rowtype;
begin
  select m.* into v_me
    from public._sessao_militar(p_token) sm
    join public.militares m on m.id = sm.id;
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not public._pode_gerenciar_viaturas(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Sem permissão: ação restrita ao Aux P4 / Admin Geral.';
  end if;
  return v_me;
end;
$$;

-- ════════════════════════════════════════════════════════════════════════
-- ACIDENTE
-- ════════════════════════════════════════════════════════════════════════

-- ── Editar a seção de acidente (substitui dados->'acidente' pelo enviado) ─
create or replace function public.frota_acidente_editar(p_token uuid, p_mov_id uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me public.militares%rowtype; v_old public.mov_viaturas%rowtype;
  v_old_ac jsonb; v_new_ac jsonb; v_alt jsonb := '[]'::jsonb;
  v_campos text[] := array['reds','odometro','data_hora','vitimas','pericia','cpu','bafometro','guincho','mesmo_motorista','responsavel','obs'];
  v_c text; v_nome text;
begin
  v_me := public._frota_gestor(p_token);
  select * into v_old from public.mov_viaturas where id = p_mov_id and ativo = true;
  if v_old.id is null then raise exception 'Ficha não encontrada.'; end if;
  v_old_ac := coalesce(v_old.dados->'acidente', '{}'::jsonb);
  v_new_ac := v_old_ac || p_dados;   -- mescla: preserva chaves não enviadas

  foreach v_c in array v_campos loop
    if (v_old_ac->>v_c) is distinct from (v_new_ac->>v_c) then
      v_alt := v_alt || jsonb_build_object('campo','Acidente · '||v_c,
        'antes', coalesce(v_old_ac->>v_c,'—'), 'depois', coalesce(v_new_ac->>v_c,'—'));
    end if;
  end loop;

  v_nome := coalesce(v_me.nome_guerra, v_me.nome_completo);
  update public.mov_viaturas set
    dados = jsonb_set(coalesce(dados,'{}'::jsonb), '{acidente}', v_new_ac, true),
    tem_acidente = true,
    atualizado_em = now(), atualizado_por_matricula = v_me.matricula, atualizado_por_nome = v_nome
  where id = p_mov_id;

  if jsonb_array_length(v_alt) > 0 then
    insert into public.mov_viaturas_audit (mov_id, editor_matricula, editor_nome, alteracoes)
    values (p_mov_id, v_me.matricula, v_nome, v_alt);
  end if;
  return jsonb_build_object('ok', true, 'alteracoes', jsonb_array_length(v_alt));
end;
$$;

-- ── Excluir a seção de acidente (some acidente + suas fotos; ficha fica) ──
create or replace function public.frota_acidente_excluir(p_token uuid, p_mov_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me public.militares%rowtype; v_old public.mov_viaturas%rowtype;
  v_reds text; v_novos_anexos jsonb; v_nome text;
begin
  v_me := public._frota_gestor(p_token);
  select * into v_old from public.mov_viaturas where id = p_mov_id and ativo = true;
  if v_old.id is null then raise exception 'Ficha não encontrada.'; end if;
  if coalesce(v_old.tem_acidente,false) = false and (v_old.dados->'acidente') is null then
    raise exception 'Esta ficha não tem acidente registrado.';
  end if;
  v_reds := v_old.dados->'acidente'->>'reds';

  -- remove as fotos do acidente (categoria acidente-fotos) do array de anexos
  select coalesce(jsonb_agg(a), '[]'::jsonb) into v_novos_anexos
    from jsonb_array_elements(coalesce(v_old.anexos,'[]'::jsonb)) a
   where coalesce(a->>'categoria','') <> 'acidente-fotos';

  v_nome := coalesce(v_me.nome_guerra, v_me.nome_completo);
  update public.mov_viaturas set
    dados = (coalesce(dados,'{}'::jsonb) - 'acidente'),
    tem_acidente = false,
    anexos = v_novos_anexos,
    atualizado_em = now(), atualizado_por_matricula = v_me.matricula, atualizado_por_nome = v_nome
  where id = p_mov_id;

  insert into public.mov_viaturas_audit (mov_id, editor_matricula, editor_nome, alteracoes)
  values (p_mov_id, v_me.matricula, v_nome,
    jsonb_build_array(jsonb_build_object('campo','Acidente',
      'antes', coalesce('REDS '||v_reds, 'registrado'), 'depois', 'EXCLUÍDO (com fotos)')));
  return jsonb_build_object('ok', true);
end;
$$;

-- ════════════════════════════════════════════════════════════════════════
-- ABASTECIMENTO (por item, indexado por idx = posição no array)
-- ════════════════════════════════════════════════════════════════════════

-- ── Editar um lançamento de abastecimento (mescla os campos enviados) ────
create or replace function public.frota_abast_editar(p_token uuid, p_mov_id uuid, p_idx int, p_item jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me public.militares%rowtype; v_old public.mov_viaturas%rowtype;
  v_itens jsonb; v_old_item jsonb; v_new_item jsonb; v_alt jsonb := '[]'::jsonb;
  v_campos text[] := array['fonte','tipo','combustivel','litros','valor_unit','valor_total','odometro','data_hora','cidade','obs','convenio','doador','autorizado_por','motivo'];
  v_c text; v_nome text;
begin
  v_me := public._frota_gestor(p_token);
  select * into v_old from public.mov_viaturas where id = p_mov_id and ativo = true;
  if v_old.id is null then raise exception 'Ficha não encontrada.'; end if;
  v_itens := coalesce(v_old.dados->'abastecimento'->'itens', '[]'::jsonb);
  if p_idx < 0 or p_idx >= jsonb_array_length(v_itens) then
    raise exception 'Lançamento de abastecimento não encontrado (idx %).', p_idx;
  end if;
  v_old_item := v_itens->p_idx;
  v_new_item := v_old_item || p_item;   -- mescla: mantém chaves não enviadas

  foreach v_c in array v_campos loop
    if (v_old_item->>v_c) is distinct from (v_new_item->>v_c) then
      v_alt := v_alt || jsonb_build_object('campo','Abastecimento · '||v_c,
        'antes', coalesce(v_old_item->>v_c,'—'), 'depois', coalesce(v_new_item->>v_c,'—'));
    end if;
  end loop;

  v_nome := coalesce(v_me.nome_guerra, v_me.nome_completo);
  update public.mov_viaturas set
    dados = jsonb_set(dados, array['abastecimento','itens', p_idx::text], v_new_item, true),
    atualizado_em = now(), atualizado_por_matricula = v_me.matricula, atualizado_por_nome = v_nome
  where id = p_mov_id;

  if jsonb_array_length(v_alt) > 0 then
    insert into public.mov_viaturas_audit (mov_id, editor_matricula, editor_nome, alteracoes)
    values (p_mov_id, v_me.matricula, v_nome, v_alt);
  end if;
  return jsonb_build_object('ok', true, 'alteracoes', jsonb_array_length(v_alt));
end;
$$;

-- ── Excluir um lançamento de abastecimento (remove o item do array) ──────
-- Os índices seguintes "descem" 1; realinhamos a tabela siad_lancado.
create or replace function public.frota_abast_excluir(p_token uuid, p_mov_id uuid, p_idx int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me public.militares%rowtype; v_old public.mov_viaturas%rowtype;
  v_itens jsonb; v_item jsonb; v_novos jsonb; v_nome text; v_resumo text;
begin
  v_me := public._frota_gestor(p_token);
  select * into v_old from public.mov_viaturas where id = p_mov_id and ativo = true;
  if v_old.id is null then raise exception 'Ficha não encontrada.'; end if;
  v_itens := coalesce(v_old.dados->'abastecimento'->'itens', '[]'::jsonb);
  if p_idx < 0 or p_idx >= jsonb_array_length(v_itens) then
    raise exception 'Lançamento de abastecimento não encontrado (idx %).', p_idx;
  end if;
  v_item := v_itens->p_idx;
  v_resumo := trim(both ' ' from concat_ws(' ', v_item->>'fonte', nullif(v_item->>'litros','')||'L', v_item->>'combustivel'));

  v_novos := v_itens - p_idx;   -- remove o elemento na posição p_idx

  v_nome := coalesce(v_me.nome_guerra, v_me.nome_completo);
  update public.mov_viaturas set
    dados = jsonb_set(dados, '{abastecimento,itens}', v_novos, true),
    tem_abastecimento = (jsonb_array_length(v_novos) > 0),
    atualizado_em = now(), atualizado_por_matricula = v_me.matricula, atualizado_por_nome = v_nome
  where id = p_mov_id;

  -- Realinha o controle de SIAD: remove o idx excluído e desloca os maiores.
  delete from public.siad_lancado where mov_id = p_mov_id and idx = p_idx;
  update public.siad_lancado set idx = idx - 1 where mov_id = p_mov_id and idx > p_idx;

  insert into public.mov_viaturas_audit (mov_id, editor_matricula, editor_nome, alteracoes)
  values (p_mov_id, v_me.matricula, v_nome,
    jsonb_build_array(jsonb_build_object('campo','Abastecimento',
      'antes', coalesce(nullif(v_resumo,''),'lançamento'), 'depois', 'EXCLUÍDO')));
  return jsonb_build_object('ok', true);
end;
$$;

-- ════════════════════════════════════════════════════════════════════════
-- frota_abast_listar: agora também devolve os COMPROVANTES do lançamento
-- (anexo categoria 'abastecimento-comprovante' com contexto = a fonte).
-- Muda o RETURNS TABLE → DROP antes do CREATE.
-- ════════════════════════════════════════════════════════════════════════
drop function if exists public.frota_abast_listar(uuid, int, int);

create or replace function public.frota_abast_listar(p_token uuid, p_ano int, p_mes int)
returns table (
  mov_id uuid, idx int, prefixo text, placa text,
  data_ficha timestamptz, fonte text, tipo text, combustivel text,
  litros numeric, valor_total numeric, valor_unit numeric, odometro text,
  cidade text, obs text, convenio text, doador text,
  km_rodados int, vai_siad boolean, siad_lancado boolean,
  motorista_nome text, gp_responsavel text, comprovantes jsonb
)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._frota_gestor(p_token);
  return query
  select
    m.id as mov_id,
    (it.ord - 1)::int as idx,
    m.prefixo::text, m.placa::text,
    coalesce(m.inicio, m.criado_em)::timestamptz as data_ficha,
    nullif(it.item->>'fonte','')::text        as fonte,
    nullif(it.item->>'tipo','')::text         as tipo,
    nullif(it.item->>'combustivel','')::text  as combustivel,
    nullif(it.item->>'litros','')::numeric      as litros,
    nullif(it.item->>'valor_total','')::numeric as valor_total,
    nullif(it.item->>'valor_unit','')::numeric  as valor_unit,
    nullif(it.item->>'odometro','')::text     as odometro,
    nullif(it.item->>'cidade','')::text       as cidade,
    nullif(it.item->>'obs','')::text          as obs,
    nullif(it.item->>'convenio','')::text     as convenio,
    nullif(it.item->>'doador','')::text       as doador,
    m.km_rodados::int,
    (coalesce(it.item->>'fonte','') = 'Convênio ou Doação') as vai_siad,
    (s.mov_id is not null) as siad_lancado,
    m.motorista_nome::text, m.gp_responsavel::text,
    coalesce((
      select jsonb_agg(jsonb_build_object('nome', a->>'nome', 'link', a->>'link'))
      from jsonb_array_elements(coalesce(m.anexos, '[]'::jsonb)) a
      where a->>'categoria' = 'abastecimento-comprovante'
        and coalesce(a->>'link','') <> ''
        and coalesce(a->>'contexto','') = coalesce(it.item->>'fonte','')
    ), '[]'::jsonb) as comprovantes
  from public.mov_viaturas m
  cross join lateral jsonb_array_elements(
      coalesce(m.dados->'abastecimento'->'itens', '[]'::jsonb)
  ) with ordinality as it(item, ord)
  left join public.siad_lancado s on s.mov_id = m.id and s.idx = (it.ord - 1)
  where m.ativo = true
    and m.ano = p_ano
    and (p_mes is null or m.mes = p_mes)
  order by coalesce(m.inicio, m.criado_em) desc, m.prefixo, idx;
end;
$$;

-- _frota_gestor NÃO recebe grant a anon de propósito: retorna a linha de
-- militares (com hash) e só é usada internamente pelas funções abaixo, que
-- rodam como dono (security definer) e por isso a enxergam sem grant.
grant execute on function public.frota_acidente_editar(uuid, uuid, jsonb)     to anon;
grant execute on function public.frota_acidente_excluir(uuid, uuid)           to anon;
grant execute on function public.frota_abast_editar(uuid, uuid, int, jsonb)   to anon;
grant execute on function public.frota_abast_excluir(uuid, uuid, int)         to anon;
grant execute on function public.frota_abast_listar(uuid, int, int)           to anon;

-- ════════════════════════════════════════════════════════════════════════
-- frota_acidentes_listar: agora também devolve `obs` (para o modal de edição
-- vir completo). Supersede a versão do db/75 (mantém `fotos`). DROP antes.
-- ════════════════════════════════════════════════════════════════════════
drop function if exists public.frota_acidentes_listar(uuid, int, int);

create or replace function public.frota_acidentes_listar(p_token uuid, p_ano int, p_mes int)
returns table (
  mov_id uuid, prefixo text, placa text, data_ficha timestamptz,
  reds text, odometro text, data_hora text, vitimas text, pericia text,
  cpu text, bafometro text, guincho text, mesmo_motorista text, responsavel text,
  obs text, km_rodados int, motorista_nome text, motorista_matricula text,
  gp_responsavel text, fotos jsonb
)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._frota_gestor(p_token);
  return query
  select
    m.id::uuid, m.prefixo::text, m.placa::text,
    coalesce(m.inicio, m.criado_em)::timestamptz as data_ficha,
    nullif(m.dados->'acidente'->>'reds','')::text,
    nullif(m.dados->'acidente'->>'odometro','')::text,
    nullif(m.dados->'acidente'->>'data_hora','')::text,
    nullif(m.dados->'acidente'->>'vitimas','')::text,
    nullif(m.dados->'acidente'->>'pericia','')::text,
    nullif(m.dados->'acidente'->>'cpu','')::text,
    nullif(m.dados->'acidente'->>'bafometro','')::text,
    nullif(m.dados->'acidente'->>'guincho','')::text,
    nullif(m.dados->'acidente'->>'mesmo_motorista','')::text,
    nullif(m.dados->'acidente'->>'responsavel','')::text,
    nullif(m.dados->'acidente'->>'obs','')::text,
    m.km_rodados::int,
    m.motorista_nome::text, m.motorista_matricula::text, m.gp_responsavel::text,
    coalesce((
      select jsonb_agg(jsonb_build_object('nome', a->>'nome', 'link', a->>'link'))
      from jsonb_array_elements(coalesce(m.anexos, '[]'::jsonb)) a
      where a->>'categoria' = 'acidente-fotos'
        and coalesce(a->>'link','') <> ''
    ), '[]'::jsonb) as fotos
  from public.mov_viaturas m
  where m.ativo = true
    and coalesce(m.tem_acidente,false) = true
    and m.ano = p_ano
    and (p_mes is null or m.mes = p_mes)
  order by coalesce(m.inicio, m.criado_em) desc, m.prefixo;
end;
$$;

grant execute on function public.frota_acidentes_listar(uuid, int, int)       to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 33 (e do 75, indiferente).
-- ════════════════════════════════════════════════════════════════════════

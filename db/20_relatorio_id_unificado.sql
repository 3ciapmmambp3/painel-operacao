-- ════════════════════════════════════════════════════════════════════════
-- 20_relatorio_id_unificado.sql — FASE 3: id único planilha↔Supabase no CREATE
--
-- Ajusta relatorio_salvar: ao CRIAR, o Supabase gera o id e já grava
-- `sheet_id = esse id` (quando o cliente não manda um sheet_id). O painel passa
-- esse id ao Apps Script como "ID Relatório", então a planilha e o Supabase
-- compartilham o MESMO id. Resultado: relatórios novos já nascem vinculados e
-- suas edições espelham na planilha (mesma linha, sem duplicar).
--
-- (Requer também: mudança no painel + pequeno ajuste no Apps Script —
--  processarCriacaoRelatorio_ usar payload.idRelatorio quando vier.)
--
-- Depende de: 18_relatorios.sql. Idempotente (create or replace). Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.relatorio_salvar(p_token uuid, p_dados jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_id    uuid;
  v_modo  text := coalesce(p_dados->>'modo','criar');
  v_b     jsonb := coalesce(p_dados->'bloco1','{}'::jsonb);
  v_data  date  := nullif(v_b->>'Data','')::date;
  v_cat   jsonb;
  v_item  jsonb;
  v_n     int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;

  if v_modo = 'atualizar' then
    v_id := nullif(p_dados->>'id','')::uuid;
    if v_id is null then raise exception 'id do relatório não informado para atualização.'; end if;
    update public.relatorios set
      sheet_id = coalesce(nullif(p_dados->>'sheet_id',''), sheet_id),
      fracao_atuacao=v_b->>'Fração de Atuação', data=v_data,
      inicio_turno=v_b->>'Início do Turno', fim_turno=v_b->>'Fim do Turno',
      comandante=v_b->>'Comandante', motorista=v_b->>'Motorista',
      patrulheiros=v_b->>'Patrulheiro(s)', equipe=v_b->>'Equipe',
      tipo_servico=v_b->>'Tipo de Serviço', houve_apoio=v_b->>'Houve Equipe de Apoio?',
      total_militares=nullif(v_b->>'Total de Militares (Geral)','')::int,
      total_viaturas=nullif(v_b->>'Total de Viaturas (Geral)','')::int,
      observacoes=v_b->>'Observações Gerais do Relatório', enviado_por=v_b->>'Enviado por',
      bloco1=v_b,
      ano=extract(year from coalesce(v_data, current_date))::int,
      mes=extract(month from coalesce(v_data, current_date))::int,
      atualizado_em=now()
    where id = v_id and ativo = true;
    if not found then raise exception 'Relatório não encontrado (id %).', v_id; end if;
    delete from public.relatorio_itens where relatorio_id = v_id;
  else
    -- CREATE: gera o id e usa-o também como sheet_id padrão (id único p/ ambos).
    v_id := gen_random_uuid();
    insert into public.relatorios (
      id, sheet_id, fracao_atuacao, data, inicio_turno, fim_turno, comandante, motorista,
      patrulheiros, equipe, tipo_servico, houve_apoio, total_militares, total_viaturas,
      observacoes, enviado_por, bloco1, criado_por_matricula, criado_por_nome, ano, mes
    ) values (
      v_id, coalesce(nullif(p_dados->>'sheet_id',''), v_id::text),
      v_b->>'Fração de Atuação', v_data,
      v_b->>'Início do Turno', v_b->>'Fim do Turno', v_b->>'Comandante', v_b->>'Motorista',
      v_b->>'Patrulheiro(s)', v_b->>'Equipe', v_b->>'Tipo de Serviço', v_b->>'Houve Equipe de Apoio?',
      nullif(v_b->>'Total de Militares (Geral)','')::int, nullif(v_b->>'Total de Viaturas (Geral)','')::int,
      v_b->>'Observações Gerais do Relatório', v_b->>'Enviado por', v_b,
      v_me.matricula, coalesce(v_me.nome_guerra, v_me.nome_completo),
      extract(year from coalesce(v_data, current_date))::int,
      extract(month from coalesce(v_data, current_date))::int
    );
  end if;

  for v_cat in select * from jsonb_array_elements(coalesce(p_dados->'categorias','[]'::jsonb)) loop
    v_n := 0;
    for v_item in select * from jsonb_array_elements(coalesce(v_cat->'itens','[]'::jsonb)) loop
      v_n := v_n + 1;
      insert into public.relatorio_itens (relatorio_id, categoria, nr_item, dados)
      values (v_id, v_cat->>'categoria', v_n, v_item);
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'id', v_id, 'sheet_id', v_id::text, 'modo', v_modo);
end;
$$;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 18/19.
-- ════════════════════════════════════════════════════════════════════════

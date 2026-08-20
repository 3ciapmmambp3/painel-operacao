-- ════════════════════════════════════════════════════════════════════════
-- 19_relatorios_fase2.sql — Relatório de Serviço no Supabase (FASE 2: leituras)
--
-- Pré-requisito da Fase 2: BACKFILL. Traz todos os relatórios que já existem na
-- planilha para o Supabase, guardando o `sheet_id` (o "ID Relatório" da planilha)
-- em cada um — isso deixa o Supabase completo E cria o vínculo planilha↔Supabase
-- (permite espelhar edições de volta na planilha, sem duplicar).
--
-- Este arquivo cria:
--   • índice único em relatorios.sheet_id (backfill idempotente);
--   • limpeza das linhas órfãs da Fase 1 (dual-write sem sheet_id);
--   • RPC relatorio_backfill  — insere/atualiza um relatório por sheet_id (Admin);
--   • RPC relatorio_meus      — lista os relatórios do militar logado (ou todos, Admin);
--   • RPC relatorio_completo  — reconstrói {bloco1, categorias} de um relatório.
--
-- Depende de: 18_relatorios.sql. Idempotente. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

-- Vínculo único por relatório da planilha (permite upsert idempotente no backfill).
create unique index if not exists uq_relatorios_sheet on public.relatorios (sheet_id) where sheet_id is not null;

-- Limpa as linhas que a Fase 1 criou sem vínculo (serão recriadas pelo backfill,
-- agora com sheet_id, a partir da planilha — a fonte completa/autoritativa).
delete from public.relatorios where sheet_id is null;

-- ── RPC: BACKFILL de um relatório (por sheet_id) — restrito Admin Geral ──
create or replace function public.relatorio_backfill(
  p_token uuid, p_sheet_id text, p_bloco1 jsonb, p_categorias jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_id    uuid;
  v_b     jsonb := coalesce(p_bloco1,'{}'::jsonb);
  v_data  date  := nullif(v_b->>'Data','')::date;
  v_env   text  := v_b->>'Enviado por';
  v_mat   text  := nullif(regexp_replace(coalesce(split_part(coalesce(v_env,''),' - ',1),''),'\D','','g'),'');
  v_cat   jsonb; v_item jsonb; v_n int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Sem permissão: o backfill é do Admin Geral.';
  end if;
  if coalesce(p_sheet_id,'') = '' then raise exception 'sheet_id obrigatório no backfill.'; end if;

  select id into v_id from public.relatorios where sheet_id = p_sheet_id;

  if v_id is null then
    insert into public.relatorios (
      sheet_id, fracao_atuacao, data, inicio_turno, fim_turno, comandante, motorista,
      patrulheiros, equipe, tipo_servico, houve_apoio, total_militares, total_viaturas,
      observacoes, enviado_por, bloco1, criado_por_matricula, criado_por_nome, ano, mes
    ) values (
      p_sheet_id, v_b->>'Fração de Atuação', v_data, v_b->>'Início do Turno', v_b->>'Fim do Turno',
      v_b->>'Comandante', v_b->>'Motorista', v_b->>'Patrulheiro(s)', v_b->>'Equipe',
      v_b->>'Tipo de Serviço', v_b->>'Houve Equipe de Apoio?',
      nullif(v_b->>'Total de Militares (Geral)','')::int, nullif(v_b->>'Total de Viaturas (Geral)','')::int,
      v_b->>'Observações Gerais do Relatório', v_env, v_b, v_mat, v_env,
      extract(year from coalesce(v_data,current_date))::int, extract(month from coalesce(v_data,current_date))::int
    ) returning id into v_id;
  else
    update public.relatorios set
      fracao_atuacao=v_b->>'Fração de Atuação', data=v_data,
      inicio_turno=v_b->>'Início do Turno', fim_turno=v_b->>'Fim do Turno',
      comandante=v_b->>'Comandante', motorista=v_b->>'Motorista',
      patrulheiros=v_b->>'Patrulheiro(s)', equipe=v_b->>'Equipe',
      tipo_servico=v_b->>'Tipo de Serviço', houve_apoio=v_b->>'Houve Equipe de Apoio?',
      total_militares=nullif(v_b->>'Total de Militares (Geral)','')::int,
      total_viaturas=nullif(v_b->>'Total de Viaturas (Geral)','')::int,
      observacoes=v_b->>'Observações Gerais do Relatório', enviado_por=v_env, bloco1=v_b,
      ano=extract(year from coalesce(v_data,current_date))::int,
      mes=extract(month from coalesce(v_data,current_date))::int, atualizado_em=now()
    where id = v_id;
    delete from public.relatorio_itens where relatorio_id = v_id;
  end if;

  for v_cat in select * from jsonb_array_elements(coalesce(p_categorias,'[]'::jsonb)) loop
    v_n := 0;
    for v_item in select * from jsonb_array_elements(coalesce(v_cat->'itens','[]'::jsonb)) loop
      v_n := v_n + 1;
      insert into public.relatorio_itens (relatorio_id, categoria, nr_item, dados)
      values (v_id, v_cat->>'categoria', v_n, v_item);
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'id', v_id, 'sheet_id', p_sheet_id);
end;
$$;

-- ── RPC: lista de relatórios do militar logado (ou todos, se Admin+p_todos) ──
create or replace function public.relatorio_meus(p_token uuid, p_todos boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_me record; v_todos boolean; v_hoje date := current_date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  v_todos := coalesce(p_todos,false) and coalesce(v_me.nivel_acesso,'') = 'admin_geral';

  return coalesce((
    select jsonb_agg(x order by x->>'Data' desc) from (
      select jsonb_build_object(
        'ID Relatório', r.id,
        'sheet_id', r.sheet_id,
        'Fração de Atuação', r.fracao_atuacao,
        'Data', to_char(r.data,'YYYY-MM-DD'),
        'Início do Turno', r.inicio_turno,
        'Fim do Turno', r.fim_turno,
        'Equipe', r.equipe,
        'Tipo de Serviço', r.tipo_servico,
        'podeEditar', (v_todos or (r.data is not null and (v_hoje - r.data) <= 2))
      ) as x
      from public.relatorios r
      where r.ativo = true
        and (
          v_todos
          or position(v_me.matricula in coalesce(r.comandante,'')) > 0
          or position(v_me.matricula in coalesce(r.motorista,''))  > 0
          or position(v_me.matricula in coalesce(r.patrulheiros,'')) > 0
        )
    ) t
  ), '[]'::jsonb);
end;
$$;

-- ── RPC: reconstrói {bloco1, categorias} de um relatório (por id) ────────
create or replace function public.relatorio_completo(p_token uuid, p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_me record; v_r public.relatorios%rowtype; v_cats jsonb;
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

  return jsonb_build_object('ok', true, 'sheet_id', v_r.sheet_id,
                            'bloco1', v_r.bloco1, 'categorias', v_cats);
end;
$$;

grant execute on function public.relatorio_backfill(uuid, text, jsonb, jsonb) to anon;
grant execute on function public.relatorio_meus(uuid, boolean) to anon;
grant execute on function public.relatorio_completo(uuid, uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 18. (Executar o backfill em seguida
-- pela tela/rotina de importação — Admin.)
-- ════════════════════════════════════════════════════════════════════════

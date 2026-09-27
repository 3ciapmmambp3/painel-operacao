-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — IMPORTAÇÃO EM LOTE (planilha da P1: FERIAS-ANUAIS / FERIAS-PREMIO)
--  Rodar depois do 115.
--
--  Recebe as linhas já parseadas pelo front (ferias.html → importarFerias):
--    p_tipo = 'ANUAL' | 'PREMIO'
--    p_rows = [ { matricula, tipo, modalidade?, parcelas:[{parcela,ini,fim}] }, ... ]
--
--  SUBSTITUI (delete + insert) os lançamentos daquele ANO e TIPO — assim a
--  importação zera os registros de teste e recompõe do zero. Casa o militar
--  pela MATRÍCULA (matricula_clean = lpad(dígitos,7,'0')). Lançados já como
--  VALIDADO (a planilha é o consolidado da P1). Só Aux P1 / Comando.
--  Retorna { inseridos, ignorados, nao_encontrados:[matriculas] }.
-- ══════════════════════════════════════════════════════════════════════

drop function if exists public.ferias_importar_lote(uuid, int, text, jsonb);
create or replace function public.ferias_importar_lote(p_token uuid, p_ano int, p_tipo text, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_nome   text;
  v_tipo   text := upper(coalesce(nullif(p_tipo,''),'ANUAL'));
  v_crono  uuid;
  v_row    jsonb;
  v_mat    text;
  v_clean  text;
  v_alvo   public.militares;
  v_ins    int := 0;
  v_ign    int := 0;
  v_nf     text[] := '{}';
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Importação restrita ao Aux P1 / Comando.';
  end if;
  if v_tipo not in ('ANUAL','PREMIO') then raise exception 'Tipo inválido: %', v_tipo; end if;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);
  select id into v_crono from public.ferias_cronograma where ano = p_ano;

  -- substitui tudo do ano+tipo (limpa inclusive os testes)
  delete from public.ferias_pedidos where ano = p_ano and tipo = v_tipo;

  for v_row in select * from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb))
  loop
    v_mat := coalesce(v_row->>'matricula','');
    v_clean := lpad(regexp_replace(v_mat, '\D', '', 'g'), 7, '0');
    if v_clean is null or v_clean = '0000000' then v_ign := v_ign + 1; continue; end if;

    select * into v_alvo from public.militares
      where matricula_clean = v_clean
      order by ativo desc nulls last limit 1;

    if v_alvo.id is null then
      v_nf := array_append(v_nf, v_mat);
      continue;
    end if;

    insert into public.ferias_pedidos (
      cronograma_id, ano, militar_id, militar, pelotao, grupamento_id,
      tipo, exercicio, modalidade, parcelas, dias, situacao,
      criado_por_matricula, criado_por_nome,
      validado_p1_por_matricula, validado_p1_por_nome, validado_p1_em
    ) values (
      v_crono, p_ano, v_alvo.id,
      jsonb_build_object('matricula', v_alvo.matricula, 'nome', v_alvo.nome_completo,
                         'guerra', v_alvo.nome_guerra, 'pg', v_alvo.posto_graduacao),
      public._ferias_pelotao(v_alvo.grupamento_id), v_alvo.grupamento_id,
      v_tipo, p_ano,
      case when v_tipo='PREMIO' then null else nullif(v_row->>'modalidade','') end,
      coalesce(v_row->'parcelas','[]'::jsonb),
      nullif(v_row->>'dias','')::int,
      'VALIDADO',
      v_me.matricula, v_nome,
      v_me.matricula, v_nome, now()
    );
    v_ins := v_ins + 1;
  end loop;

  return jsonb_build_object('inseridos', v_ins, 'ignorados', v_ign, 'nao_encontrados', to_jsonb(v_nf));
end;
$$;

grant execute on function public.ferias_importar_lote(uuid, int, text, jsonb) to anon;

-- Reverter:
--   drop function if exists public.ferias_importar_lote(uuid,int,text,jsonb);

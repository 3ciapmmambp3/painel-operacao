-- ════════════════════════════════════════════════════════════════════════
--  db/178 — Relatório grava a VIATURA e a pendência do relatório casa por
--           DIA + VIATURA da equipe (correção durável do "lançou por fora")
--  Data: 2026-11-06
--
--  Problema: se a equipe lança o relatório SEM apontar os militares da equipe
--  do TTA (comandante/motorista diferentes, ou lançado por outra pessoa), não
--  havia como ligar aquele relatório à equipe — a pendência do "Relatório de
--  serviço pendente" no Meu Dia ficava aberta para sempre. A tabela relatorios
--  não guardava a viatura, então não dava para casar por VTR.
--
--  Correção:
--   (1) relatorios.viatura_prefixos text[] — guarda os prefixos das viaturas
--       (principal + apoios) do relatório. O relatorio-servico.html passa os
--       prefixos no payload (p_dados.viatura_prefixos).
--   (2) relatorio_salvar passa a gravar viatura_prefixos (no criar e no
--       atualizar — no update só sobrescreve quando o payload trouxer o campo).
--   (3) relatorios_pendentes_do_militar quita a pendência também quando existe
--       um relatório do DIA cuja VIATURA bate com a prefixo_viatura da equipe
--       do TTA — além das regras do db/97/177 (quem lançou / comandante /
--       motorista). Retroage sozinho conforme os relatórios novos entram.
--
--  Idempotente. Rodar DEPOIS do db/20 e do db/97 (substitui ambas as funções).
-- ════════════════════════════════════════════════════════════════════════

-- ─── (1) Coluna + índice ───────────────────────────────────────────────
alter table public.relatorios add column if not exists viatura_prefixos text[];
create index if not exists idx_relatorios_vtr on public.relatorios using gin (viatura_prefixos);

-- ─── (2) relatorio_salvar (db/20 + viatura_prefixos) ───────────────────
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
  v_prefs text[];
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;

  select coalesce(array_agg(distinct p), '{}'::text[]) into v_prefs
    from (select nullif(btrim(x),'') as p
            from jsonb_array_elements_text(coalesce(p_dados->'viatura_prefixos','[]'::jsonb)) t(x)) s
   where p is not null;

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
      viatura_prefixos = case when p_dados ? 'viatura_prefixos' then v_prefs else viatura_prefixos end,
      ano=extract(year from coalesce(v_data, current_date))::int,
      mes=extract(month from coalesce(v_data, current_date))::int,
      atualizado_em=now()
    where id = v_id and ativo = true;
    if not found then raise exception 'Relatório não encontrado (id %).', v_id; end if;
    delete from public.relatorio_itens where relatorio_id = v_id;
  else
    v_id := gen_random_uuid();
    insert into public.relatorios (
      id, sheet_id, fracao_atuacao, data, inicio_turno, fim_turno, comandante, motorista,
      patrulheiros, equipe, tipo_servico, houve_apoio, total_militares, total_viaturas,
      observacoes, enviado_por, bloco1, viatura_prefixos, criado_por_matricula, criado_por_nome, ano, mes
    ) values (
      v_id, coalesce(nullif(p_dados->>'sheet_id',''), v_id::text),
      v_b->>'Fração de Atuação', v_data,
      v_b->>'Início do Turno', v_b->>'Fim do Turno', v_b->>'Comandante', v_b->>'Motorista',
      v_b->>'Patrulheiro(s)', v_b->>'Equipe', v_b->>'Tipo de Serviço', v_b->>'Houve Equipe de Apoio?',
      nullif(v_b->>'Total de Militares (Geral)','')::int, nullif(v_b->>'Total de Viaturas (Geral)','')::int,
      v_b->>'Observações Gerais do Relatório', v_b->>'Enviado por', v_b, v_prefs,
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

grant execute on function public.relatorio_salvar(uuid, jsonb) to anon;

-- ─── (3) relatório pendente: casa por quem lançou / comandante / motorista
--          / E pela VIATURA (prefixo da equipe do TTA) ─────────────────────
create or replace function public.relatorios_pendentes_do_militar(p_token uuid)
returns table(
  dia              date,
  chamada_id       uuid,
  operacao         text,
  comandante_nome  text,
  prefixo_viatura  text
)
language plpgsql security definer set search_path = public as $$
declare
  v_me    record;
  v_hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini   date := v_hoje - 45;
  c       record;
  eq      jsonb;
  membros text[];
  v_pref  text;
  atendido boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  for c in
    select id,
           (data_hora_chamada at time zone 'America/Sao_Paulo')::date as d,
           equipes, militares_presentes
      from public.tta_chamadas
     where (data_hora_chamada at time zone 'America/Sao_Paulo')::date between v_ini and v_hoje
     order by (data_hora_chamada at time zone 'America/Sao_Paulo')::date desc
  loop
    if jsonb_array_length(coalesce(c.equipes, '[]'::jsonb)) > 0 then
      for eq in select value from jsonb_array_elements(c.equipes) as t(value)
      loop
        membros := array_remove(array[
                     nullif(eq->'comandante'->>'matricula',''),
                     nullif(eq->'motorista'->>'matricula','')
                   ], null);
        membros := membros || coalesce((
                     select array_agg(p->>'matricula')
                       from jsonb_array_elements(coalesce(eq->'patrulheiros','[]'::jsonb)) p
                      where nullif(p->>'matricula','') is not null), array[]::text[]);
        if not (v_me.matricula = any(membros)) then continue; end if;
        v_pref := nullif(eq->>'prefixo_viatura','');

        select exists(
          select 1 from public.relatorios r
           where r.data = c.d
             and (
                   r.criado_por_matricula = any(membros)
                   or substring(coalesce(r.comandante,'') from '\d{3}\.\d{3}-\d') = any(membros)
                   or substring(coalesce(r.motorista,'')  from '\d{3}\.\d{3}-\d') = any(membros)
                   or (v_pref is not null and v_pref = any(coalesce(r.viatura_prefixos,'{}'::text[])))
                 )
        ) into atendido;

        if not atendido then
          dia := c.d;
          chamada_id := c.id;
          operacao := nullif(eq->>'operacao','');
          comandante_nome := nullif(eq->'comandante'->>'nome','');
          prefixo_viatura := v_pref;
          return next;
        end if;
      end loop;
    else
      if c.militares_presentes @> jsonb_build_array(jsonb_build_object('matricula', v_me.matricula)) then
        membros := coalesce((
                     select array_agg(m->>'matricula')
                       from jsonb_array_elements(c.militares_presentes) m
                      where nullif(m->>'matricula','') is not null), array[]::text[]);
        select exists(
          select 1 from public.relatorios r
           where r.data = c.d
             and (
                   r.criado_por_matricula = any(membros)
                   or substring(coalesce(r.comandante,'') from '\d{3}\.\d{3}-\d') = any(membros)
                   or substring(coalesce(r.motorista,'')  from '\d{3}\.\d{3}-\d') = any(membros)
                 )
        ) into atendido;
        if not atendido then
          dia := c.d; chamada_id := c.id;
          operacao := null; comandante_nome := null; prefixo_viatura := null;
          return next;
        end if;
      end if;
    end if;
  end loop;
end;
$$;

grant execute on function public.relatorios_pendentes_do_militar(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois do db/20 e do db/97 (idempotente). Substitui o db/177.
-- ════════════════════════════════════════════════════════════════════════

-- ════════════════════════════════════════════════════════════════════════
--  db/181 — Vínculo automático de CRIME (REDS) a OPERAÇÃO/VISITA a partir do
--           Relatório de Serviço — FASE 1 (backend: tabela + RPCs)
--  Data: 2026-11-08
--
--  CONTEXTO: hoje o vínculo crime↔operação/visita é MANUAL em analise-criminal
--  ("Vincular RAT" → bd_operacoes.rat_referencia[]; "Vincular BOS" →
--  bd_visitas.bo_referencia[]). Esta é uma ALTERNATIVA COMPLEMENTAR: o militar,
--  no lançamento do Relatório de Serviço, indica o CRIME (REDS/BO) relacionado
--  à operação ou à visita tranquilizadora. A indicação NÃO vincula na hora:
--  fica PENDENTE e é efetivada quando o RAT/BOS e o crime já estiverem
--  importados (pelo Aux P3), gravando nos MESMOS arrays do fluxo manual.
--
--  MATCH: exato pelo número próprio (RAT da operação / BOS da visita), que o
--  militar já digita ("Nº do REDS / Registro"). Comparação por dígitos (imune a
--  separadores). O crime deve existir em bd_crimes; senão, continua pendente.
--  Formato REDS: AAAA-NNNNNNNNN-NNN (ex.: 2026-030135292-001).
--
--  SEGURANÇA / CONVIVÊNCIA COM O MANUAL:
--   - A reconciliação só processa linhas status='pendente' e as marca 'auto'
--     UMA vez. Depois nunca mais toca → se o usuário corrigir/remover o vínculo
--     manualmente em analise-criminal, a reconciliação NÃO o recria. Manual
--     sempre vence.
--   - Append idempotente com dedup; grava a forma CANÔNICA de bd_crimes.
--
--  Idempotente. Rodar no Supabase (SQL Editor). FASE 1 não altera relatorio_salvar
--  nem o frontend — isso vem nas fases seguintes.
-- ════════════════════════════════════════════════════════════════════════

-- ─── (1) Tabela de indicações/pendências ───────────────────────────────
create table if not exists public.vinculo_crime_pendente (
  id              uuid primary key default gen_random_uuid(),
  tipo            text not null check (tipo in ('op','visita')),
  numero_proprio  text not null,                 -- RAT (op) ou BOS (visita), formato REDS
  crime_reds      text not null,                 -- BO do crime (bd_crimes.numero_reds)
  observacao      text,
  relatorio_id    uuid,
  matricula       text,
  nome            text,
  data_servico    date,
  status          text not null default 'pendente'
                    check (status in ('pendente','auto','cancelada')),
  motivo_pendente text,                          -- diagnóstico enquanto continua pendente
  vinculado_em    timestamptz,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);

-- 1 indicação por (tipo, nº próprio, crime) — reindicar = atualiza, não duplica
create unique index if not exists uq_vcp_chave
  on public.vinculo_crime_pendente (tipo, numero_proprio, crime_reds);
create index if not exists idx_vcp_status   on public.vinculo_crime_pendente (status);
create index if not exists idx_vcp_proprio  on public.vinculo_crime_pendente (numero_proprio);
create index if not exists idx_vcp_crime    on public.vinculo_crime_pendente (crime_reds);

-- RLS: anon LÊ (badges no analise-criminal); escrita só pelas RPCs abaixo.
alter table public.vinculo_crime_pendente enable row level security;
drop policy if exists vcp_sel_anon on public.vinculo_crime_pendente;
create policy vcp_sel_anon on public.vinculo_crime_pendente
  for select to anon using (true);

-- ─── (2) Reconciliação — efetiva as pendentes cujo RAT/BOS e crime existem ──
create or replace function public.vincular_reds_pendentes()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p            record;
  v_tem_doc    boolean;
  v_crime_canon text;            -- numero_reds canônico de bd_crimes (NULL = não existe)
  v_proc int := 0; v_vinc int := 0; v_pend int := 0;
begin
  for p in
    select * from public.vinculo_crime_pendente
     where status = 'pendente'
     for update
  loop
    v_proc := v_proc + 1;

    -- documento próprio (RAT ou BOS) existe?
    if p.tipo = 'op' then
      select exists(
        select 1 from public.bd_operacoes o
         where regexp_replace(o.numero_rat,'\D','','g')
             = regexp_replace(p.numero_proprio,'\D','','g')
      ) into v_tem_doc;
    else
      select exists(
        select 1 from public.bd_visitas b
         where regexp_replace(b.numero_bos,'\D','','g')
             = regexp_replace(p.numero_proprio,'\D','','g')
      ) into v_tem_doc;
    end if;

    -- crime existe? guarda a forma canônica p/ gravar igual ao manual
    select c.numero_reds into v_crime_canon
      from public.bd_crimes c
     where regexp_replace(c.numero_reds,'\D','','g')
         = regexp_replace(p.crime_reds,'\D','','g')
     limit 1;

    if not v_tem_doc or v_crime_canon is null then
      update public.vinculo_crime_pendente set
        motivo_pendente = case
          when not v_tem_doc and v_crime_canon is null
            then (case when p.tipo='op' then 'RAT e crime não importados'
                       else 'BOS e crime não importados' end)
          when not v_tem_doc
            then (case when p.tipo='op' then 'RAT não importado'
                       else 'BOS não importado' end)
          else 'crime (REDS) não importado' end,
        atualizado_em = now()
      where id = p.id;
      v_pend := v_pend + 1;
      continue;
    end if;

    -- efetiva o vínculo nos MESMOS arrays do fluxo manual (append + dedup)
    if p.tipo = 'op' then
      update public.bd_operacoes o set
        rat_referencia = (
          select array_agg(distinct x)
            from unnest(coalesce(o.rat_referencia,'{}'::text[]) || array[v_crime_canon]) x
        )
      where regexp_replace(o.numero_rat,'\D','','g')
          = regexp_replace(p.numero_proprio,'\D','','g');
    else
      update public.bd_visitas b set
        bo_referencia = (
          select array_agg(distinct x)
            from unnest(coalesce(b.bo_referencia,'{}'::text[]) || array[v_crime_canon]) x
        )
      where regexp_replace(b.numero_bos,'\D','','g')
          = regexp_replace(p.numero_proprio,'\D','','g');
    end if;

    update public.vinculo_crime_pendente set
      status='auto', motivo_pendente=null, vinculado_em=now(), atualizado_em=now()
    where id = p.id;
    v_vinc := v_vinc + 1;
  end loop;

  return jsonb_build_object('ok',true,'processadas',v_proc,'vinculadas',v_vinc,'ainda_pendentes',v_pend);
end; $$;

grant execute on function public.vincular_reds_pendentes() to anon;

-- ─── (3) Indicar (chamada pelo relatório/FE) — grava a indicação e tenta já ──
create or replace function public.vinculo_crime_indicar(
  p_token          uuid,
  p_tipo           text,     -- 'op' | 'visita'
  p_numero_proprio text,     -- RAT (op) ou BOS (visita)
  p_crime_reds     text,     -- BO do crime
  p_observacao     text default null,
  p_relatorio_id   uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r      record;
  v_id   uuid;
  v_tipo text := lower(btrim(coalesce(p_tipo,'')));
begin
  select * into r from public._sessao_militar(p_token);
  if r.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if v_tipo not in ('op','visita') then raise exception 'tipo inválido (use op|visita).'; end if;
  if coalesce(btrim(p_numero_proprio),'') = '' or coalesce(btrim(p_crime_reds),'') = '' then
    raise exception 'Número próprio (RAT/BOS) e crime (REDS) são obrigatórios.';
  end if;

  insert into public.vinculo_crime_pendente
    (tipo, numero_proprio, crime_reds, observacao, relatorio_id, matricula, nome, data_servico, status)
  values
    (v_tipo, btrim(p_numero_proprio), btrim(p_crime_reds),
     nullif(btrim(coalesce(p_observacao,'')),''), p_relatorio_id,
     r.matricula, coalesce(r.nome_completo, r.nome_guerra),
     (now() at time zone 'America/Sao_Paulo')::date, 'pendente')
  on conflict (tipo, numero_proprio, crime_reds) do update
    set observacao   = coalesce(excluded.observacao, public.vinculo_crime_pendente.observacao),
        relatorio_id = coalesce(excluded.relatorio_id, public.vinculo_crime_pendente.relatorio_id),
        atualizado_em = now()
    -- NÃO rebaixa status: uma indicação já 'auto' permanece 'auto'.
  returning id into v_id;

  -- tenta efetivar na hora (caso RAT/BOS e crime já estejam importados)
  perform public.vincular_reds_pendentes();

  return (
    select jsonb_build_object('ok',true,'id',v.id,'status',v.status,'motivo',v.motivo_pendente)
      from public.vinculo_crime_pendente v where v.id = v_id
  );
end; $$;

grant execute on function public.vinculo_crime_indicar(uuid,text,text,text,text,uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM FASE 1. Idempotente. Rodar no SQL Editor.
--  Próximas fases: (2) campos no relatorio-servico.html + opção "Visita
--  Tranquilizadora" no Tipo de atividade → chama vinculo_crime_indicar;
--  (3) painel.html impConfirmar → chama vincular_reds_pendentes após import;
--  (4) analise-criminal.html → badges pendente/auto/manual.
-- ════════════════════════════════════════════════════════════════════════

-- ══════════════════════════════════════════════════════════════════════
--  OFÍCIOS — EXCLUSÃO INTELIGENTE + REAPROVEITAMENTO DE NÚMERO (P1)
--
--  Regra pedida (só vale p/ SAÍDA, que é numerada):
--   1) Se o ofício excluído é o ÚLTIMO número gerado no ano
--      (numero_seq = contadores.ultimo, ou seja, o PRÓXIMO ainda não foi
--      gerado) → REAPROVEITA: apaga de fato o registro e DEVOLVE o contador
--      (ultimo-1), para que o próximo ofício criado receba exatamente esse
--      número, mantendo a sequência sem buraco.
--   2) Se o PRÓXIMO número já foi gerado (numero_seq < contadores.ultimo)
--      → NÃO dá p/ reaproveitar: o ofício vira situação 'EXCLUIDO' guardando
--      a JUSTIFICATIVA, e passa a aparecer APENAS para quem tem visão total
--      (Aux P1 / Admin / Admin Geral / CMT Cia), só para controle. Some da
--      lista dos demais militares.
--   • A justificativa é OBRIGATÓRIA no caso (2).
--   • ENTRADA (sem número) e saídas sem numero_seq → exclusão física direta.
--
--  Depende de: 63 (oficios, oficio_listar, oficio_excluir), 01 (contadores),
--  04 (_sessao_militar). Idempotente. Rodar no SQL Editor.
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) situação 'EXCLUIDO' + colunas de auditoria da exclusão ─────────
alter table public.oficios drop constraint if exists oficios_situacao_check;
alter table public.oficios
  add constraint oficios_situacao_check
  check (situacao in ('REGISTRADO','ARQUIVADO','EXCLUIDO'));

alter table public.oficios add column if not exists excluido_em             timestamptz;
alter table public.oficios add column if not exists excluido_por_matricula  text;
alter table public.oficios add column if not exists excluido_por_nome       text;
alter table public.oficios add column if not exists excluido_motivo         text;

-- ─── 2) LISTAR: esconde os EXCLUIDO de quem NÃO tem visão total ─────────
create or replace function public.oficio_listar(p_token uuid)
returns setof public.oficios
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_gp  text;
  v_pel text;
  v_adm boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- Aux P1 / Admin / Admin Geral / CMT Cia → veem tudo (inclusive EXCLUIDO)
  if public._oficio_escopo_total(v_me.nivel_acesso, v_me.funcao) then
    return query select * from public.oficios order by data_doc desc, created_at desc;
    return;
  end if;

  v_adm := upper(btrim(coalesce(v_me.grupamento_id,''))) like 'ADM%';
  v_gp  := (regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\s*GP',  'i'))[1];
  v_pel := (regexp_match(coalesce(v_me.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1];

  return query
    select * from public.oficios o
     where coalesce(o.situacao,'') <> 'EXCLUIDO'   -- EXCLUIDO só p/ visão total
       and case
       when v_adm then upper(btrim(coalesce(o.grupamento_id,''))) like 'ADM%'
       when coalesce(v_me.nivel_acesso,'') = 'admin_pelotao' and v_pel is not null then
         (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1] = v_pel
       when v_gp is not null and v_pel is not null then
             (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*GP',  'i'))[1] = v_gp
         and (regexp_match(coalesce(o.grupamento_id,''), '(\d+)\s*PEL', 'i'))[1] = v_pel
       else false
     end
     order by o.data_doc desc, o.created_at desc;
end;
$$;

-- ─── 3) EXCLUIR: reaproveita nº OU vira registro EXCLUIDO c/ justificativa
-- Assinatura nova (uuid, uuid, text). Remove a antiga (uuid, uuid).
drop function if exists public.oficio_excluir(uuid, uuid);
create or replace function public.oficio_excluir(p_token uuid, p_id uuid, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_row    public.oficios;
  v_cont   int;
  v_motivo text := nullif(btrim(coalesce(p_motivo,'')),'');
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if coalesce(v_me.nivel_acesso,'') <> 'admin_geral' then
    raise exception 'Exclusão restrita ao Admin Geral.';
  end if;

  select * into v_row from public.oficios where id = p_id;
  if v_row.id is null then raise exception 'Ofício não encontrado.'; end if;

  -- ENTRADA (sem numeração) ou saída sem numero_seq → exclusão física direta
  if v_row.tipo <> 'Saída' or v_row.numero_seq is null then
    delete from public.oficios where id = p_id;
    return jsonb_build_object('acao','removido','reaproveitado',false,'numero',v_row.numero);
  end if;

  -- justificativa é obrigatória p/ excluir saída numerada (controle da P1)
  if v_motivo is null then
    raise exception 'Informe a justificativa da exclusão.';
  end if;

  -- último número gerado no ano
  select ultimo into v_cont from public.contadores where ano = v_row.ano and tipo = 'oficio';

  if v_cont is not null and v_row.numero_seq = v_cont then
    -- é o ÚLTIMO gerado; o próximo ainda não existe → DEVOLVE o número
    delete from public.oficios where id = p_id;
    update public.contadores set ultimo = greatest(ultimo - 1, 0)
      where ano = v_row.ano and tipo = 'oficio';
    return jsonb_build_object(
      'acao','reaproveitado', 'reaproveitado', true,
      'numero', v_row.numero, 'seq', v_row.numero_seq);
  end if;

  -- o PRÓXIMO já foi gerado → não reaproveita; vira registro EXCLUIDO
  update public.oficios set
    situacao               = 'EXCLUIDO',
    excluido_em            = now(),
    excluido_por_matricula = v_me.matricula,
    excluido_por_nome      = coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_completo, v_me.nome_guerra),
    excluido_motivo        = v_motivo
  where id = p_id;

  return jsonb_build_object(
    'acao','excluido_registro', 'reaproveitado', false,
    'numero', v_row.numero, 'seq', v_row.numero_seq);
end;
$$;

grant execute on function public.oficio_excluir(uuid, uuid, text) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Não precisa re-rodar 63. proximo_numero (db/01) segue igual; aqui só
-- devolvemos o contador quando o número excluído era o último.
-- ══════════════════════════════════════════════════════════════════════

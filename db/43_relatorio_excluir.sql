-- ════════════════════════════════════════════════════════════════════════
-- 43_relatorio_excluir.sql
--   Exclusão de Relatório de Serviço pelo Aux P3 ou Admin Geral (lançamento
--   errado/duplicado). SOFT-DELETE (ativo=false) — o relatorio_meus e o
--   relatorio_completo já filtram ativo=true, então some das listas mas o
--   registro é preservado, com carimbo de quem/quando/motivo.
--
--   Depende de: 04 (_sessao_militar), 18 (relatorios).
--   Idempotente. Rodar no SQL Editor.
-- ════════════════════════════════════════════════════════════════════════

alter table public.relatorios add column if not exists excluido_em            timestamptz;
alter table public.relatorios add column if not exists excluido_por_matricula text;
alter table public.relatorios add column if not exists excluido_por_nome      text;
alter table public.relatorios add column if not exists motivo_exclusao        text;

create or replace function public.relatorio_excluir(p_token uuid, p_id uuid, p_justificativa text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_r public.relatorios%rowtype;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if not ( coalesce(v_me.nivel_acesso,'') = 'admin_geral'
        or lower(coalesce(v_me.funcao,'')) like 'aux p3%' ) then
    raise exception 'A exclusão de relatórios é restrita ao Aux P3 ou Admin Geral.';
  end if;

  select * into v_r from public.relatorios where id = p_id;
  if v_r.id is null then raise exception 'Relatório não encontrado.'; end if;
  if coalesce(v_r.ativo, true) = false then raise exception 'Este relatório já está excluído.'; end if;

  update public.relatorios
     set ativo = false,
         excluido_em = now(),
         excluido_por_matricula = v_me.matricula,
         excluido_por_nome = coalesce(v_me.nome_guerra, v_me.nome_completo),
         motivo_exclusao = nullif(btrim(p_justificativa),'')
   where id = p_id;

  return jsonb_build_object('ok', true, 'id', p_id);
end;
$$;
grant execute on function public.relatorio_excluir(uuid, uuid, text) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar depois de 18_relatorios.sql.
-- ════════════════════════════════════════════════════════════════════════

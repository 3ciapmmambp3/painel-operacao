-- ════════════════════════════════════════════════════════════════════════
-- 21_supervisao.sql — Supervisão e Controle (Gestão Operacional)
--
-- Dashboard das equipes do dia, alimentado pelas chamadas do TTA de HOJE
-- (public.tta_chamadas → coluna `equipes` jsonb). A página agrega as equipes,
-- conta equipes/viaturas/militares e permite filtrar por grupamento/pelotão.
--
-- Acesso: Admin Geral, Admin e Admin de Pelotão (decisão do usuário 2026-08-20).
-- Escopo: a Companhia inteira (todas as chamadas do dia); o filtro é no front.
--
-- Depende de: 04_sessoes_e_militares_seguranca.sql (_sessao_militar), 07_tta.sql.
-- Idempotente. Rodar no SQL Editor, depois do 07.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.supervisao_equipes_hoje(p_token uuid)
returns setof public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if coalesce(v_me.nivel_acesso,'') not in ('admin_geral','admin','admin_pelotao') then
    raise exception 'Acesso restrito à Supervisão e Controle (Admin Geral, Admin ou Admin de Pelotão).';
  end if;

  return query
    select *
      from public.tta_chamadas
     where (data_hora_chamada at time zone 'America/Sao_Paulo')::date = v_hoje
     order by gp_responsavel, data_hora_chamada;
end;
$$;

grant execute on function public.supervisao_equipes_hoje(uuid) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 07_tta.sql.
-- ════════════════════════════════════════════════════════════════════════

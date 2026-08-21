-- ════════════════════════════════════════════════════════════════════════
-- 23_supervisao_periodo.sql — Supervisão e Controle por PERÍODO
--
-- Igual ao supervisao_equipes_hoje, mas aceita um intervalo de datas
-- (data início / data término). Sem parâmetros → assume HOJE. Permite conferir
-- quem estava de serviço em tal dia/período.
--
-- Acesso: Admin Geral, Admin e Admin de Pelotão.
-- Depende de: 04_sessoes_e_militares_seguranca.sql, 07_tta.sql.
-- Idempotente. Rodar no SQL Editor, depois do 07.
-- ════════════════════════════════════════════════════════════════════════

create or replace function public.supervisao_equipes_periodo(
  p_token uuid, p_ini date default null, p_fim date default null)
returns setof public.tta_chamadas
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ini  date;
  v_fim  date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then
    raise exception 'Sessão expirada. Faça login novamente.';
  end if;
  if coalesce(v_me.nivel_acesso,'') not in ('admin_geral','admin','admin_pelotao') then
    raise exception 'Acesso restrito à Supervisão e Controle (Admin Geral, Admin ou Admin de Pelotão).';
  end if;

  v_ini := coalesce(p_ini, v_hoje);
  v_fim := coalesce(p_fim, v_ini);
  if v_fim < v_ini then v_fim := v_ini; end if;   -- protege intervalo invertido

  return query
    select *
      from public.tta_chamadas
     where (data_hora_chamada at time zone 'America/Sao_Paulo')::date between v_ini and v_fim
     order by (data_hora_chamada at time zone 'America/Sao_Paulo')::date desc,
              gp_responsavel, data_hora_chamada;
end;
$$;

grant execute on function public.supervisao_equipes_periodo(uuid, date, date) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 07_tta.sql.
-- ════════════════════════════════════════════════════════════════════════

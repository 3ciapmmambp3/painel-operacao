-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — simular o percentual (Cia e Pelotão) de um período candidato
--  Rodar depois do 119/120.
--
--  Usada no modal "Validar / definir período": ao escolher/combinar as opções,
--  mostra ao vivo o PICO de ocupação (Cia e Pelotão) que aquele período geraria,
--  incluindo o próprio militar. Mesma base/regra do bloqueio (_ferias_dia_estoura),
--  então a barra bate com a aprovação. Só quem pode aprovar (P1 / CMT Pel/GP).
-- ══════════════════════════════════════════════════════════════════════
drop function if exists public.ferias_simular_periodo(uuid, uuid, jsonb);
create or replace function public.ferias_simular_periodo(p_token uuid, p_id uuid, p_parcelas jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me record; v_row public.ferias_pedidos; v_crono public.ferias_cronograma;
  v_p1 boolean; v_cmtpel boolean; v_cmtgp boolean;
  v_reconv boolean; v_pel text;
  v_lim_cia numeric; v_tot_cia int; v_pico_cia int := 0;
  v_lim_pel numeric; v_tot_pel int; v_pico_pel int := 0;
  v_dia date; v_cia int; v_pelc int; parc jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  v_p1     := public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao);
  v_cmtpel := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* 'pel')
              or coalesce(v_me.nivel_acesso,'') = 'admin_pelotao';
  v_cmtgp  := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* '(gp|grupamento)')
              or coalesce(v_me.nivel_acesso,'') = 'admin_gp';
  if not (v_p1 or v_cmtpel or v_cmtgp) then raise exception 'Sem permissão.'; end if;

  select * into v_row from public.ferias_pedidos where id = p_id;
  if v_row.id is null then raise exception 'Pedido não encontrado.'; end if;
  v_pel := v_row.pelotao;
  select * into v_crono from public.ferias_cronograma where ano = v_row.ano;
  v_reconv  := coalesce(v_crono.contar_reconvocados, false);
  v_lim_cia := coalesce(v_crono.pct_max_cia, 15);
  v_lim_pel := coalesce((v_crono.limites_pelotao->>v_pel)::numeric, v_crono.pct_max_pelotao, v_crono.pct_max_cia, 15);

  select count(*) into v_tot_cia from public.militares m
   where m.ativo = true and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%' and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'));
  select count(*) into v_tot_pel from public.militares m
   where m.ativo = true and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%' and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
     and public._ferias_pelotao(m.grupamento_id) is not distinct from v_pel;

  for parc in select * from jsonb_array_elements(coalesce(p_parcelas,'[]'::jsonb))
  loop
    if nullif(parc->>'ini','') is null or nullif(parc->>'fim','') is null then continue; end if;
    for v_dia in select gs::date from generate_series((parc->>'ini')::date, (parc->>'fim')::date, interval '1 day') as gs
    loop
      select count(distinct p.militar_id) into v_cia
        from public.ferias_pedidos p join public.militares m on m.id = p.militar_id
        cross join lateral jsonb_array_elements(p.parcelas) pp
       where p.ano = v_row.ano and p.situacao in ('VALIDADO','APROVADO_PEL') and p.id <> p_id
         and m.ativo = true and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
         and upper(coalesce(m.funcao,'')) not like '%ASPM%'
         and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
         and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%' and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
         and nullif(pp->>'ini','')::date <= v_dia and nullif(pp->>'fim','')::date >= v_dia;
      v_cia := v_cia + 1;
      if v_cia > v_pico_cia then v_pico_cia := v_cia; end if;

      if coalesce(v_pel,'') ~ '^[0-9]' and v_tot_pel > 0 then
        select count(distinct p.militar_id) into v_pelc
          from public.ferias_pedidos p join public.militares m on m.id = p.militar_id
          cross join lateral jsonb_array_elements(p.parcelas) pp
         where p.ano = v_row.ano and p.situacao in ('VALIDADO','APROVADO_PEL') and p.id <> p_id
           and p.pelotao is not distinct from v_pel
           and m.ativo = true and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
           and upper(coalesce(m.funcao,'')) not like '%ASPM%'
           and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
           and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%' and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
           and nullif(pp->>'ini','')::date <= v_dia and nullif(pp->>'fim','')::date >= v_dia;
        v_pelc := v_pelc + 1;
        if v_pelc > v_pico_pel then v_pico_pel := v_pelc; end if;
      end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'pode_cia', v_p1,   -- só o Aux P1/Comando enxerga a barra da Cia
    'cia', jsonb_build_object('ferias', v_pico_cia, 'total', v_tot_cia, 'limite', v_lim_cia,
             'pct', case when v_tot_cia>0 then round(100.0*v_pico_cia/v_tot_cia,1) else 0 end,
             'max', floor(v_tot_cia*v_lim_cia/100.0)),
    'pelotao', case when coalesce(v_pel,'') ~ '^[0-9]' and v_tot_pel>0 then
             jsonb_build_object('pelotao', v_pel, 'ferias', v_pico_pel, 'total', v_tot_pel, 'limite', v_lim_pel,
               'pct', round(100.0*v_pico_pel/v_tot_pel,1), 'max', floor(v_tot_pel*v_lim_pel/100.0))
             else null end
  );
end;
$$;
grant execute on function public.ferias_simular_periodo(uuid, uuid, jsonb) to anon;

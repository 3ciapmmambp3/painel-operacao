-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS-PRÊMIO — VAGAS v3: conta por SOBREPOSIÇÃO DE DATAS + mostra números
--
--  Ajustes (user 2026-11-13, "janeiro aparece com vaga mas está cheio"):
--   1) NÃO prende mais ao campo p.ano — conta QUALQUER férias (anual ou prêmio)
--      VALIDADA/APROVADA cujas datas se sobreponham ao período pedido. Assim a
--      concorrência real de janeiro (anuais) é contada, independate do "ano".
--   2) Percorre a janela inteira e devolve SEMPRE os números (pico da Cia e
--      mínimo de presentes no grupamento), p/ a tela mostrar e o P1 conferir.
--
--  Retorna:
--   { vaga:bool,
--     cia:{pico,total,limite,max,dia,ok},
--     grupamento:{presentes_min,total,dia,ok} }
--
--  Regra: Cia ≤ 15% (pico ≤ floor(total*15/100)); cada grupamento mantém ≥2
--  presentes. Depende de 04/119/militares. Redefine ferias_premio_vagas.
--  Idempotente. Rodar depois do 194.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_premio_vagas(p_token uuid, p_ano int, p_ini date, p_fim date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me      record;
  v_crono   public.ferias_cronograma;
  v_reconv  boolean;
  v_grp     text;
  v_lim_cia numeric;
  v_tot_cia int; v_max_cia int;
  v_tot_grp int;
  v_dia     date; v_cia int; v_grp_out int;
  v_peak_cia int := 0; v_peak_cia_dia date;
  v_min_pres int; v_min_pres_dia date;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_ini is null or p_fim is null then return jsonb_build_object('vaga', null); end if;

  select * into v_crono from public.ferias_cronograma where ano = p_ano;
  v_reconv  := coalesce(v_crono.contar_reconvocados, false);
  v_lim_cia := coalesce(v_crono.pct_max_cia, 15);
  v_grp     := v_me.grupamento_id;

  select count(*) into v_tot_cia from public.militares m
   where m.ativo = true
     and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                       and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'));
  if v_tot_cia = 0 then return jsonb_build_object('vaga', true,
       'cia', jsonb_build_object('pico',0,'total',0,'limite',v_lim_cia,'max',0,'ok',true),
       'grupamento', jsonb_build_object('presentes_min',0,'total',0,'ok',true)); end if;

  select count(*) into v_tot_grp from public.militares m
   where m.ativo = true
     and m.grupamento_id is not distinct from v_grp
     and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                       and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'));

  v_max_cia  := floor(v_tot_cia * v_lim_cia / 100.0);
  v_min_pres := v_tot_grp;   -- começa "cheio"

  for v_dia in select gs::date from generate_series(p_ini, p_fim, interval '1 day') as gs
  loop
    -- COMPANHIA: todos de férias nesse dia (qualquer ano/tipo, VALIDADO/APROVADO_PEL)
    select count(distinct p.militar_id) into v_cia
      from public.ferias_pedidos p
      join public.militares m on m.id = p.militar_id
      cross join lateral jsonb_array_elements(p.parcelas) pp
     where p.situacao in ('VALIDADO','APROVADO_PEL')
       and m.ativo = true
       and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and upper(coalesce(m.funcao,'')) not like '%ASPM%'
       and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
       and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                         and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
       and nullif(pp->>'ini','')::date <= v_dia
       and nullif(pp->>'fim','')::date >= v_dia;
    v_cia := v_cia + 1;   -- o próprio candidato
    if v_cia > v_peak_cia then v_peak_cia := v_cia; v_peak_cia_dia := v_dia; end if;

    -- GRUPAMENTO (fração): quantos presentes sobram nesse dia
    if v_tot_grp >= 2 then
      select count(distinct p.militar_id) into v_grp_out
        from public.ferias_pedidos p
        join public.militares m on m.id = p.militar_id
        cross join lateral jsonb_array_elements(p.parcelas) pp
       where p.situacao in ('VALIDADO','APROVADO_PEL')
         and m.grupamento_id is not distinct from v_grp
         and m.ativo = true
         and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
         and upper(coalesce(m.funcao,'')) not like '%ASPM%'
         and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
         and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                           and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
         and nullif(pp->>'ini','')::date <= v_dia
         and nullif(pp->>'fim','')::date >= v_dia;
      if (v_tot_grp - (v_grp_out + 1)) < v_min_pres then
        v_min_pres := v_tot_grp - (v_grp_out + 1); v_min_pres_dia := v_dia;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'vaga', (v_peak_cia <= v_max_cia) and (v_tot_grp < 2 or v_min_pres >= 2),
    'cia', jsonb_build_object('pico', v_peak_cia, 'total', v_tot_cia, 'limite', v_lim_cia,
                              'max', v_max_cia, 'dia', v_peak_cia_dia, 'ok', (v_peak_cia <= v_max_cia)),
    'grupamento', jsonb_build_object('presentes_min', v_min_pres, 'total', v_tot_grp,
                                     'dia', v_min_pres_dia, 'ok', (v_tot_grp < 2 or v_min_pres >= 2))
  );
end;
$$;
grant execute on function public.ferias_premio_vagas(uuid, int, date, date) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 194).
-- ══════════════════════════════════════════════════════════════════════

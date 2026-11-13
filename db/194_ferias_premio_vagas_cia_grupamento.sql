-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS-PRÊMIO — VAGAS: Cia (15%) + grupamento (não ficar só com um)
--
--  Correção (user 2026-11-13): a versão db/192 reusava o motor das anuais
--  (Cia + PELOTÃO), o que estourava quase sempre (pelotão ~33, teto 15% = 4).
--  Para a férias-prêmio a regra é:
--    1) não ultrapassar os 15% da COMPANHIA inteira; e
--    2) em cada GRUPAMENTO (fração) não deixar menos de 2 militares presentes
--       ("não ficar apenas um").
--
--  Retorna só AGREGADOS (nunca dados de terceiros):
--    { vaga:true }
--    { vaga:false, nivel:'cia',        dia, ferias, total, limite }
--    { vaga:false, nivel:'grupamento', dia, grupamento, presentes, total }
--
--  Depende de: 04 (_sessao_militar), 119 (filtro de elegíveis), militares.
--  Redefine public.ferias_premio_vagas (db/192). Idempotente. Rodar depois do 193.
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
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_ini is null or p_fim is null then return jsonb_build_object('vaga', null); end if;

  select * into v_crono from public.ferias_cronograma where ano = p_ano;
  v_reconv  := coalesce(v_crono.contar_reconvocados, false);
  v_lim_cia := coalesce(v_crono.pct_max_cia, 15);
  v_grp     := v_me.grupamento_id;

  -- total elegível da Cia (mesmo filtro do motor das anuais, db/119)
  select count(*) into v_tot_cia from public.militares m
   where m.ativo = true
     and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                       and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'));
  if v_tot_cia = 0 then return jsonb_build_object('vaga', true); end if;

  -- total elegível do grupamento (fração) do militar
  select count(*) into v_tot_grp from public.militares m
   where m.ativo = true
     and m.grupamento_id is not distinct from v_grp
     and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                       and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'));

  v_max_cia := floor(v_tot_cia * v_lim_cia / 100.0);

  for v_dia in select gs::date from generate_series(p_ini, p_fim, interval '1 day') as gs
  loop
    -- 1) COMPANHIA (todos os pelotões) nesse dia
    select count(distinct p.militar_id) into v_cia
      from public.ferias_pedidos p
      join public.militares m on m.id = p.militar_id
      cross join lateral jsonb_array_elements(p.parcelas) pp
     where p.ano = p_ano
       and p.situacao in ('VALIDADO','APROVADO_PEL')
       and m.ativo = true
       and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and upper(coalesce(m.funcao,'')) not like '%ASPM%'
       and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
       and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                         and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
       and nullif(pp->>'ini','')::date <= v_dia
       and nullif(pp->>'fim','')::date >= v_dia;
    v_cia := v_cia + 1;   -- o próprio candidato
    if v_cia > v_max_cia then
      return jsonb_build_object('vaga', false, 'nivel','cia', 'dia', v_dia,
                                'ferias', v_cia, 'total', v_tot_cia, 'limite', v_lim_cia);
    end if;

    -- 2) GRUPAMENTO (fração) do candidato: manter ao menos 2 presentes
    if v_tot_grp >= 2 then
      select count(distinct p.militar_id) into v_grp_out
        from public.ferias_pedidos p
        join public.militares m on m.id = p.militar_id
        cross join lateral jsonb_array_elements(p.parcelas) pp
       where p.ano = p_ano
         and p.situacao in ('VALIDADO','APROVADO_PEL')
         and m.grupamento_id is not distinct from v_grp
         and m.ativo = true
         and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
         and upper(coalesce(m.funcao,'')) not like '%ASPM%'
         and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
         and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                           and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
         and nullif(pp->>'ini','')::date <= v_dia
         and nullif(pp->>'fim','')::date >= v_dia;
      v_grp_out := v_grp_out + 1;   -- o próprio candidato
      if (v_tot_grp - v_grp_out) < 2 then
        return jsonb_build_object('vaga', false, 'nivel','grupamento', 'dia', v_dia,
                                  'grupamento', coalesce(v_grp,'(sem grupamento)'),
                                  'presentes', (v_tot_grp - v_grp_out), 'total', v_tot_grp);
      end if;
    end if;
  end loop;

  return jsonb_build_object('vaga', true);
end;
$$;
grant execute on function public.ferias_premio_vagas(uuid, int, date, date) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 193).
-- ══════════════════════════════════════════════════════════════════════

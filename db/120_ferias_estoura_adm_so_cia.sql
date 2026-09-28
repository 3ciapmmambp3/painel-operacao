-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — ajuste: ADM conta SÓ no percentual da CIA (sem teto de pelotão)
--  Rodar depois do 119.
--
--  Decisão do Aux P1: o ADM (comando/EM) entra na contagem da Cia, mas NÃO
--  tem teto próprio de "pelotão" (efetivo pequeno, não faz a escala como um
--  pelotão operacional). A trava por pelotão passa a valer só para pelotões
--  1–5 (p_pelotao numérico). O ADM continua contando no total/ocupação da Cia.
--  Só redefine _ferias_dia_estoura (o resto do 119 permanece).
-- ══════════════════════════════════════════════════════════════════════

create or replace function public._ferias_dia_estoura(p_ano int, p_parcelas jsonb, p_ignora_id uuid, p_pelotao text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_crono public.ferias_cronograma;
  v_reconv boolean;
  v_lim_cia numeric; v_tot_cia int; v_max_cia int;
  v_lim_pel numeric; v_tot_pel int; v_max_pel int;
  v_checa_pel boolean;
  v_dia date; v_cia int; v_pel int; parc jsonb;
begin
  select * into v_crono from public.ferias_cronograma where ano = p_ano;
  v_reconv  := coalesce(v_crono.contar_reconvocados, false);
  v_lim_cia := coalesce(v_crono.pct_max_cia, 15);
  v_lim_pel := coalesce((v_crono.limites_pelotao->>p_pelotao)::numeric,
                        v_crono.pct_max_pelotao, v_crono.pct_max_cia, 15);
  -- trava de pelotão só para pelotões operacionais (1–5); ADM/sem pelotão fica de fora
  v_checa_pel := coalesce(p_pelotao,'') ~ '^[0-9]';

  select count(*) into v_tot_cia from public.militares m
   where m.ativo = true
     and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                       and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'));
  if v_tot_cia = 0 then return null; end if;

  select count(*) into v_tot_pel from public.militares m
   where m.ativo = true
     and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                       and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
     and public._ferias_pelotao(m.grupamento_id) is not distinct from p_pelotao;

  v_max_cia := floor(v_tot_cia * v_lim_cia / 100.0);
  v_max_pel := case when v_tot_pel > 0 then floor(v_tot_pel * v_lim_pel / 100.0) else 2147483647 end;

  for parc in select * from jsonb_array_elements(coalesce(p_parcelas,'[]'::jsonb))
  loop
    if nullif(parc->>'ini','') is null or nullif(parc->>'fim','') is null then continue; end if;
    for v_dia in
      select gs::date from generate_series((parc->>'ini')::date, (parc->>'fim')::date, interval '1 day') as gs
    loop
      -- Cia (todos os pelotões, inclusive ADM)
      select count(distinct p.militar_id) into v_cia
        from public.ferias_pedidos p
        join public.militares m on m.id = p.militar_id
        cross join lateral jsonb_array_elements(p.parcelas) pp
       where p.ano = p_ano
         and p.situacao in ('VALIDADO','APROVADO_PEL')
         and (p_ignora_id is null or p.id <> p_ignora_id)
         and m.ativo = true
         and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
         and upper(coalesce(m.funcao,'')) not like '%ASPM%'
         and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
         and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                           and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
         and nullif(pp->>'ini','')::date <= v_dia
         and nullif(pp->>'fim','')::date >= v_dia;
      v_cia := v_cia + 1;  -- o próprio candidato
      if v_cia > v_max_cia then
        return jsonb_build_object('nivel','da Cia','dia',v_dia,'ferias',v_cia,'total',v_tot_cia,'limite',v_lim_cia);
      end if;

      -- Pelotão do candidato (só pelotões 1–5)
      if v_checa_pel and v_tot_pel > 0 then
        select count(distinct p.militar_id) into v_pel
          from public.ferias_pedidos p
          join public.militares m on m.id = p.militar_id
          cross join lateral jsonb_array_elements(p.parcelas) pp
         where p.ano = p_ano
           and p.situacao in ('VALIDADO','APROVADO_PEL')
           and (p_ignora_id is null or p.id <> p_ignora_id)
           and p.pelotao is not distinct from p_pelotao
           and m.ativo = true
           and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
           and upper(coalesce(m.funcao,'')) not like '%ASPM%'
           and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
           and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                             and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
           and nullif(pp->>'ini','')::date <= v_dia
           and nullif(pp->>'fim','')::date >= v_dia;
        v_pel := v_pel + 1;
        if v_pel > v_max_pel then
          return jsonb_build_object('nivel','do Pelotão '||coalesce(p_pelotao,'?'),
                                    'dia',v_dia,'ferias',v_pel,'total',v_tot_pel,'limite',v_lim_pel);
        end if;
      end if;
    end loop;
  end loop;
  return null;
end;
$$;

-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS — limite de 15% da Cia por data + toggle de reconvocados (QOR/QPR)
--  Rodar depois do 113/116.
--
--  Regras (pedido do Aux P1):
--   • No máximo 15% do efetivo da Cia de férias numa mesma DATA. A APROVAÇÃO
--     do CMT de Pelotão/Grupamento é BLOQUEADA se o período estourar isso;
--     só o Aux P1 / Comando pode validar acima do limite.
--   • Reconvocados (QOR/QPR): por padrão NÃO entram no percentual. Um flag no
--     cronograma (contar_reconvocados) permite incluí-los quando necessário.
--   • Limite padrão da Cia = 15% (coalesce de pct_max_cia).
-- ══════════════════════════════════════════════════════════════════════

alter table public.ferias_cronograma
  add column if not exists contar_reconvocados boolean not null default false;

-- ─── cronograma: salvar (persiste contar_reconvocados) ─────────────────
create or replace function public.ferias_cronograma_salvar(p_token uuid, p_dados jsonb)
returns public.ferias_cronograma
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_ano int := coalesce(nullif(p_dados->>'ano','')::int,
                        extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_row public.ferias_cronograma;
  v_nome text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Apenas o Aux P1 / Comando pode montar o cronograma de férias.';
  end if;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  insert into public.ferias_cronograma (
    ano, titulo, situacao, data_abertura, data_limite,
    pct_max_cia, pct_max_pelotao, pct_max_grupamento, contar_reconvocados,
    periodos, anexo_pdf, criado_por_matricula, criado_por_nome
  ) values (
    v_ano, nullif(p_dados->>'titulo',''),
    coalesce(nullif(p_dados->>'situacao',''),'RASCUNHO'),
    nullif(p_dados->>'data_abertura','')::date, nullif(p_dados->>'data_limite','')::date,
    nullif(p_dados->>'pct_max_cia','')::numeric,
    nullif(p_dados->>'pct_max_pelotao','')::numeric,
    nullif(p_dados->>'pct_max_grupamento','')::numeric,
    coalesce((p_dados->>'contar_reconvocados')::boolean, false),
    coalesce(p_dados->'periodos','[]'::jsonb), coalesce(p_dados->'anexo_pdf','[]'::jsonb),
    v_me.matricula, v_nome
  )
  on conflict (ano) do update set
    titulo             = case when p_dados ? 'titulo'        then nullif(p_dados->>'titulo','')             else ferias_cronograma.titulo end,
    situacao           = case when p_dados ? 'situacao'      then coalesce(nullif(p_dados->>'situacao',''),'RASCUNHO') else ferias_cronograma.situacao end,
    data_abertura      = case when p_dados ? 'data_abertura' then nullif(p_dados->>'data_abertura','')::date else ferias_cronograma.data_abertura end,
    data_limite        = case when p_dados ? 'data_limite'   then nullif(p_dados->>'data_limite','')::date   else ferias_cronograma.data_limite end,
    pct_max_cia        = case when p_dados ? 'pct_max_cia'        then nullif(p_dados->>'pct_max_cia','')::numeric        else ferias_cronograma.pct_max_cia end,
    pct_max_pelotao    = case when p_dados ? 'pct_max_pelotao'    then nullif(p_dados->>'pct_max_pelotao','')::numeric    else ferias_cronograma.pct_max_pelotao end,
    pct_max_grupamento = case when p_dados ? 'pct_max_grupamento' then nullif(p_dados->>'pct_max_grupamento','')::numeric else ferias_cronograma.pct_max_grupamento end,
    contar_reconvocados= case when p_dados ? 'contar_reconvocados' then coalesce((p_dados->>'contar_reconvocados')::boolean,false) else ferias_cronograma.contar_reconvocados end,
    periodos           = case when p_dados ? 'periodos'  then coalesce(p_dados->'periodos','[]'::jsonb)  else ferias_cronograma.periodos end,
    anexo_pdf          = case when p_dados ? 'anexo_pdf' then coalesce(p_dados->'anexo_pdf','[]'::jsonb) else ferias_cronograma.anexo_pdf end
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function public.ferias_cronograma_salvar(uuid, jsonb) to anon;

-- ─── percentuais: respeita o toggle de reconvocados + limite Cia 15% ───
create or replace function public.ferias_percentuais(p_token uuid, p_ano int default null, p_data date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me   record;
  v_ano  int  := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_dia  date := coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date);
  v_out  jsonb;
  v_crono public.ferias_cronograma;
  v_reconv boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
    raise exception 'Painel de percentuais restrito ao Aux P1 / Comando.';
  end if;
  select * into v_crono from public.ferias_cronograma where ano = v_ano;
  v_reconv := coalesce(v_crono.contar_reconvocados, false);

  with efetivo as (
    select m.id, m.grupamento_id, public._ferias_pelotao(m.grupamento_id) as pelotao
      from public.militares m
     where m.ativo = true
       and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
       and upper(coalesce(m.funcao,'')) not like '%ASPM%'
       and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
       and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                         and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'))
  ),
  em_ferias as (
    select distinct p.militar_id, p.pelotao, p.grupamento_id
      from public.ferias_pedidos p
      join efetivo e on e.id = p.militar_id
      cross join lateral jsonb_array_elements(p.parcelas) parc
     where p.ano = v_ano
       and p.situacao = 'VALIDADO'
       and nullif(parc->>'ini','')::date <= v_dia
       and nullif(parc->>'fim','')::date >= v_dia
  ),
  cia as (
    select (select count(*) from efetivo) as total,
           (select count(*) from em_ferias) as ferias
  ),
  por_pel as (
    select e.pelotao, count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.pelotao is not distinct from e.pelotao) as ferias
      from efetivo e group by e.pelotao
  ),
  por_gp as (
    select e.grupamento_id, count(*) as total,
           (select count(distinct f.militar_id) from em_ferias f where f.grupamento_id is not distinct from e.grupamento_id) as ferias
      from efetivo e group by e.grupamento_id
  )
  select jsonb_build_object(
    'ano', v_ano, 'data', v_dia,
    'contar_reconvocados', v_reconv,
    'limites', jsonb_build_object(
      'cia', coalesce(v_crono.pct_max_cia, 15), 'pelotao', v_crono.pct_max_pelotao, 'grupamento', v_crono.pct_max_grupamento),
    'cia', (select jsonb_build_object('total', total, 'ferias', ferias,
              'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end) from cia),
    'pelotoes', coalesce((select jsonb_agg(jsonb_build_object(
              'pelotao', coalesce(pelotao,'(sem pelotão)'), 'total', total, 'ferias', ferias,
              'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end)
              order by pelotao) from por_pel), '[]'::jsonb),
    'grupamentos', coalesce((select jsonb_agg(jsonb_build_object(
              'grupamento', coalesce(grupamento_id,'(sem GP)'), 'total', total, 'ferias', ferias,
              'pct', case when total>0 then round(100.0*ferias/total,1) else 0 end)
              order by grupamento_id) from por_gp), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;
grant execute on function public.ferias_percentuais(uuid, int, date) to anon;

-- ─── helper: 1º dia em que as parcelas do candidato estouram os 15% ─────
-- Conta os militares (do efetivo, respeitando o toggle) de férias VALIDADAS ou
-- APROVADAS pelo pelotão em cada dia das parcelas, +1 pelo candidato, e compara
-- com floor(total*limite/100). Ignora o próprio pedido (p_ignora_id).
create or replace function public._ferias_dia_estoura(p_ano int, p_parcelas jsonb, p_ignora_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_crono public.ferias_cronograma;
  v_reconv boolean; v_lim numeric; v_total int; v_max int;
  v_dia date; v_cnt int; parc jsonb;
begin
  select * into v_crono from public.ferias_cronograma where ano = p_ano;
  v_reconv := coalesce(v_crono.contar_reconvocados, false);
  v_lim    := coalesce(v_crono.pct_max_cia, 15);

  select count(*) into v_total from public.militares m
   where m.ativo = true
     and m.matricula_clean not in ('0000001','0000002','0000003','0000004')
     and upper(coalesce(m.funcao,'')) not like '%ASPM%'
     and upper(public.unaccent_safe(coalesce(m.posto_graduacao,''))) not like '%CIVIL%'
     and (v_reconv or (upper(coalesce(m.posto_graduacao,'')) not like '%QOR%'
                       and upper(coalesce(m.posto_graduacao,'')) not like '%QPR%'));
  if v_total = 0 then return null; end if;
  v_max := floor(v_total * v_lim / 100.0);

  for parc in select * from jsonb_array_elements(coalesce(p_parcelas,'[]'::jsonb))
  loop
    if nullif(parc->>'ini','') is null or nullif(parc->>'fim','') is null then continue; end if;
    for v_dia in
      select gs::date from generate_series((parc->>'ini')::date, (parc->>'fim')::date, interval '1 day') as gs
    loop
      select count(distinct p.militar_id) into v_cnt
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
      v_cnt := v_cnt + 1;  -- o próprio candidato
      if v_cnt > v_max then
        return jsonb_build_object('dia', v_dia, 'ferias', v_cnt, 'total', v_total,
                                  'limite', v_lim, 'max', v_max);
      end if;
    end loop;
  end loop;
  return null;
end;
$$;

-- ─── aprovação: bloqueia CMT acima de 15% da Cia (Aux P1 pode estourar) ─
create or replace function public.ferias_pedido_aprovar(p_token uuid, p_id uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me   record; v_row public.ferias_pedidos; v_nome text;
  v_p1   boolean; v_cmtpel boolean; v_cmtgp boolean;
  v_meu_pel text;
  v_sit  text := nullif(p_dados->>'situacao','');
  v_parc jsonb; v_estoura jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  select * into v_row from public.ferias_pedidos where id = p_id;
  if v_row.id is null then raise exception 'Pedido não encontrado.'; end if;

  v_p1     := public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao);
  v_cmtpel := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* 'pel')
              or coalesce(v_me.nivel_acesso,'') = 'admin_pelotao';
  v_cmtgp  := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* '(gp|grupamento)')
              or coalesce(v_me.nivel_acesso,'') = 'admin_gp';
  v_meu_pel := public._ferias_pelotao(v_me.grupamento_id);

  if not (v_p1 or v_cmtpel or v_cmtgp) then
    raise exception 'Você não tem permissão para aprovar férias.';
  end if;
  if not v_p1 then
    if v_cmtpel then
      if v_row.pelotao is distinct from v_meu_pel then
        raise exception 'Você só aprova férias do seu pelotão.';
      end if;
    elsif v_cmtgp then
      if v_row.grupamento_id is distinct from v_me.grupamento_id then
        raise exception 'Você só aprova férias do seu grupamento.';
      end if;
    end if;
    if v_sit = 'VALIDADO' then
      raise exception 'A validação final é do Aux P1. Você pode aprovar (Aprovado pelo Pelotão).';
    end if;

    -- BLOQUEIO DOS 15% DA CIA (só p/ comandantes; Aux P1 pode estourar)
    if v_sit in ('APROVADO_PEL','VALIDADO') then
      v_parc := coalesce(p_dados->'parcelas', v_row.parcelas);
      v_estoura := public._ferias_dia_estoura(v_row.ano, v_parc, p_id);
      if v_estoura is not null then
        raise exception 'Excede o limite de % da Cia em % (% de % militares de férias no dia). Ajuste o período — só o Aux P1 pode validar acima do limite.',
          (v_estoura->>'limite')||'%',
          to_char((v_estoura->>'dia')::date,'DD/MM/YYYY'),
          (v_estoura->>'ferias'), (v_estoura->>'total');
      end if;
    end if;
  end if;

  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  update public.ferias_pedidos set
    modalidade  = case when p_dados ? 'modalidade' then nullif(p_dados->>'modalidade','') else modalidade end,
    parcelas    = case when p_dados ? 'parcelas'   then coalesce(p_dados->'parcelas','[]'::jsonb) else parcelas end,
    observacoes = case when p_dados ? 'observacoes' then nullif(p_dados->>'observacoes','') else observacoes end,
    situacao    = case when v_sit is not null then v_sit else situacao end,
    motivo_rejeicao = case when v_sit = 'REJEITADO' then nullif(p_dados->>'motivo_rejeicao','')
                           when v_sit is not null then null else motivo_rejeicao end,
    aprovado_pel_por_matricula = case when v_sit='APROVADO_PEL' then v_me.matricula else aprovado_pel_por_matricula end,
    aprovado_pel_por_nome      = case when v_sit='APROVADO_PEL' then v_nome        else aprovado_pel_por_nome end,
    aprovado_pel_em            = case when v_sit='APROVADO_PEL' then now()          else aprovado_pel_em end,
    validado_p1_por_matricula  = case when v_sit='VALIDADO' then v_me.matricula else validado_p1_por_matricula end,
    validado_p1_por_nome       = case when v_sit='VALIDADO' then v_nome        else validado_p1_por_nome end,
    validado_p1_em             = case when v_sit='VALIDADO' then now()          else validado_p1_em end
  where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function public.ferias_pedido_aprovar(uuid, uuid, jsonb) to anon;

-- Reverter: reaplicar db/105 (ferias_percentuais) e db/113 (ferias_pedido_aprovar,
-- ferias_cronograma_salvar do db/101); drop function _ferias_dia_estoura;
-- alter table ferias_cronograma drop column contar_reconvocados;

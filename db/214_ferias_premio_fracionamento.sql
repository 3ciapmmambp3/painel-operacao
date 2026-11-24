-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS-PRÊMIO — FRACIONAMENTO EM PERÍODOS + VALIDAÇÃO PERÍODO A PERÍODO
--
--  Pedido do user (2026-11-24): o direito é de até 90 dias (3 meses) por lustro.
--  O militar pode fracionar em ATÉ 3 PERÍODOS reais (ex.: 90 direto, ou 60 numa
--  data + 30 em outra, ou 30+30+30), cada um com sua DURAÇÃO (1/2/3 meses) e uma
--  data de início PRETENDIDA (preferência — o comando pode mover). A soma das
--  durações não pode passar de 90 dias.
--
--  O CMT de Pelotão valida CADA PERÍODO individualmente (status por período:
--  PENDENTE → APROVADO_PEL); o Aux P1 (em nome do Cmt Cia) autoriza (VALIDADO).
--  A situação do PEDIDO é o roll-up dos períodos:
--    • todos VALIDADO            → pedido VALIDADO
--    • algum APROVADO_PEL/VALIDADO (mas nem todos VALIDADO) → pedido APROVADO_PEL
--    • nenhum validado           → pedido PENDENTE
--  As PARCELAS que contam no motor de % (db/119) são DERIVADAS dos períodos já
--  validados (APROVADO_PEL/VALIDADO) com datas definidas (ini_def/fim_def).
--  Período ainda pendente NÃO vira parcela → não reserva vaga (correto).
--
--  Quando TODOS os períodos ficam VALIDADO e ainda falta o anexo final, o militar
--  é avisado (Meu Dia) para baixar o requerimento validado, assinar e reanexar
--  em anexo_requerimento_final.
--
--  Estrutura nova de premio.periodos (jsonb):
--    [{ "ordem":1, "etapa":"2 meses", "ini":"2027-03-01",
--       "status":"VALIDADO", "ini_def":"2027-03-10", "fim_def":"2027-05-08" }, ...]
--  (compatível: registros antigos têm premio.opcoes[]+premio.etapas e parcela única;
--   o front lê os dois formatos.)
--
--  Depende de: 101 (tabelas/helpers), 119 (motor %), 190/191/193 (prêmio).
--  Idempotente. Rodar no SQL Editor (depois do 213).
-- ══════════════════════════════════════════════════════════════════════

-- ─── helper: dias de uma etapa ("1 mês"=30, "2 meses"=60, "3 meses"=90) ──
create or replace function public._premio_etapa_dias(p_etapa text)
returns int language sql immutable as $$
  select case
    when lower(trim(coalesce(p_etapa,''))) like '1 m%' then 30
    when lower(trim(coalesce(p_etapa,''))) like '2 m%' then 60
    when lower(trim(coalesce(p_etapa,''))) like '3 m%' then 90
    else (regexp_match(lower(coalesce(p_etapa,'')), '(\d+)\s*m'))[1]::int * 30
  end;
$$;

-- ─── 1) MANIFESTAR: militar declara os PERÍODOS (fracionamento) ─────────
create or replace function public.ferias_premio_manifestar(p_token uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_ano    int := coalesce(nullif(p_dados->>'ano','')::int,
                           extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_crono  public.ferias_cronograma;
  v_hoje   date := (now() at time zone 'America/Sao_Paulo')::date;
  v_int    boolean := coalesce((p_dados->>'interesse')::boolean, false);
  v_premio jsonb;
  v_periodos jsonb := coalesce(p_dados->'periodos','[]'::jsonb);
  v_exerc  int;
  v_sit    text;
  v_ex     record;
  v_row    public.ferias_pedidos;
  v_nome   text;
  v_per    jsonb;
  v_dias   int;
  v_soma   int := 0;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_crono from public.ferias_cronograma where ano = v_ano;
  if v_crono.id is null or v_crono.premio_situacao <> 'ABERTO' then
    raise exception 'A manifestação de férias-prêmio não está aberta neste momento.';
  end if;
  if v_crono.premio_abertura is not null and v_hoje < v_crono.premio_abertura then
    raise exception 'A manifestação de férias-prêmio abre em %.', to_char(v_crono.premio_abertura,'DD/MM/YYYY');
  end if;
  if v_crono.premio_limite is not null and v_hoje > v_crono.premio_limite then
    raise exception 'O prazo da manifestação de férias-prêmio encerrou em %.', to_char(v_crono.premio_limite,'DD/MM/YYYY');
  end if;

  v_exerc := nullif(p_dados->>'exercicio','')::int;

  if v_int then
    if jsonb_typeof(v_periodos) <> 'array' or jsonb_array_length(v_periodos) = 0 then
      raise exception 'Informe ao menos o 1º período (duração e data de início).';
    end if;
    -- valida soma das durações ≤ 90 dias e normaliza status p/ PENDENTE
    for v_per in select * from jsonb_array_elements(v_periodos) loop
      if nullif(v_per->>'ini','') is null then
        raise exception 'Cada período informado precisa ter a data de início.';
      end if;
      v_dias := public._premio_etapa_dias(v_per->>'etapa');
      if v_dias is null or v_dias = 0 then
        raise exception 'Cada período precisa ter a duração (1, 2 ou 3 meses).';
      end if;
      v_soma := v_soma + v_dias;
    end loop;
    if v_soma > 90 then
      raise exception 'A soma dos períodos (% dias) passa do direito de 90 dias (3 meses).', v_soma;
    end if;
    -- normaliza: sempre guarda status=PENDENTE na manifestação (reseta validações antigas)
    select coalesce(jsonb_agg(
             jsonb_build_object('ordem', coalesce((p->>'ordem')::int, (ord)::int),
                                'etapa', p->>'etapa',
                                'ini',   (p->>'ini')::date,
                                'status','PENDENTE')
             order by ord), '[]'::jsonb)
      into v_periodos
      from jsonb_array_elements(v_periodos) with ordinality as t(p, ord);
  else
    v_periodos := '[]'::jsonb;
  end if;

  v_premio := jsonb_build_object(
    'lustro',        nullif(p_dados->>'lustro',''),
    'exercicio',     v_exerc,
    'periodos',      v_periodos,
    'justificativa', nullif(p_dados->>'justificativa','')
  );
  v_sit  := case when v_int then 'PENDENTE' else 'SEM_INTERESSE' end;
  v_nome := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  select * into v_ex from public.ferias_pedidos
   where militar_id = v_me.id and ano = v_ano and tipo = 'PREMIO'
   order by created_at desc limit 1;

  if v_ex.id is not null and v_ex.situacao in ('APROVADO_PEL','VALIDADO') then
    raise exception 'Sua manifestação de férias-prêmio já está %. Para alterar, procure o Aux P1.',
      case v_ex.situacao when 'VALIDADO' then 'validada' else 'aprovada pelo pelotão' end;
  end if;

  if v_ex.id is not null then
    update public.ferias_pedidos set
      interesse   = v_int,
      premio      = v_premio,
      exercicio   = v_exerc,
      parcelas    = '[]'::jsonb,
      situacao    = v_sit, motivo_rejeicao = null
    where id = v_ex.id
    returning * into v_row;
  else
    insert into public.ferias_pedidos (
      cronograma_id, ano, militar_id, militar, pelotao, grupamento_id,
      tipo, exercicio, interesse, premio, parcelas, situacao,
      criado_por_matricula, criado_por_nome
    ) values (
      v_crono.id, v_ano, v_me.id,
      jsonb_build_object('matricula', v_me.matricula, 'nome', v_me.nome_completo,
                         'guerra', v_me.nome_guerra, 'pg', v_me.posto_graduacao),
      public._ferias_pelotao(v_me.grupamento_id), v_me.grupamento_id,
      'PREMIO', v_exerc, v_int, v_premio, '[]'::jsonb, v_sit,
      v_me.matricula, v_nome
    ) returning * into v_row;
  end if;

  return v_row;
end;
$$;
grant execute on function public.ferias_premio_manifestar(uuid, jsonb) to anon;

-- ─── 2) GERIR: CMT de Pelotão/P1 validam CADA PERÍODO individualmente ──
--  p_dados.premio.periodos = [{ordem, etapa, ini, status, ini_def, fim_def}]
--    status aceito do front: PENDENTE | APROVADO_PEL | VALIDADO
--    (CMT de Pelotão: VALIDADO é rebaixado p/ APROVADO_PEL automaticamente)
--  p_dados.situacao = 'REJEITADO' rejeita o pedido inteiro (com motivo_rejeicao).
create or replace function public.ferias_premio_gerir(p_token uuid, p_id uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me      record;
  v_row     public.ferias_pedidos;
  v_nome    text;
  v_podeP1  boolean;
  v_cmtpel  boolean;
  v_mypel   text;
  v_interesse boolean;
  v_premio  jsonb;
  v_periodos jsonb;
  v_arr     jsonb := '[]'::jsonb;
  v_parc    jsonb := '[]'::jsonb;
  v_per     jsonb;
  v_st      text;
  v_ini     date;
  v_fim     date;
  v_dias    int;
  v_tem     boolean := false;
  v_allval  boolean := true;
  v_anyappr boolean := false;
  v_sit     text;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_row from public.ferias_pedidos where id = p_id and tipo = 'PREMIO';
  if v_row.id is null then raise exception 'Manifestação de férias-prêmio não encontrada.'; end if;

  v_podeP1 := public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao);
  v_cmtpel := (coalesce(v_me.funcao,'') ~* '(cmt|comandante)' and coalesce(v_me.funcao,'') ~* 'pel')
              or coalesce(v_me.nivel_acesso,'') = 'admin_pelotao';
  v_mypel  := public._ferias_pelotao(v_me.grupamento_id);
  v_nome   := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  if not v_podeP1 then
    if not (v_cmtpel and v_row.pelotao is not distinct from v_mypel) then
      raise exception 'Você só pode validar manifestações do seu pelotão.';
    end if;
  end if;

  v_interesse := case when p_dados ? 'interesse' then (p_dados->>'interesse')::boolean else v_row.interesse end;
  v_premio    := case when p_dados ? 'premio'    then coalesce(p_dados->'premio','{}'::jsonb) else v_row.premio end;
  v_periodos  := coalesce(v_premio->'periodos','[]'::jsonb);

  -- normaliza período a período: clampa status (CMT não pode VALIDADO) e deriva parcelas
  for v_per in select * from jsonb_array_elements(v_periodos) loop
    v_tem := true;
    v_st  := coalesce(nullif(v_per->>'status',''),'PENDENTE');
    if v_st not in ('PENDENTE','APROVADO_PEL','VALIDADO') then v_st := 'PENDENTE'; end if;
    if not v_podeP1 and v_st = 'VALIDADO' then v_st := 'APROVADO_PEL'; end if;

    -- datas definidas: usa ini_def/fim_def; se faltar fim, calcula pela etapa
    v_ini := nullif(v_per->>'ini_def','')::date;
    v_fim := nullif(v_per->>'fim_def','')::date;
    if v_ini is null then v_ini := nullif(v_per->>'ini','')::date; end if;
    if v_fim is null and v_ini is not null then
      v_dias := public._premio_etapa_dias(v_per->>'etapa');
      if v_dias is not null and v_dias > 0 then v_fim := v_ini + (v_dias - 1); end if;
    end if;

    v_arr := v_arr || jsonb_build_array(jsonb_build_object(
      'ordem',  coalesce((v_per->>'ordem')::int, 1),
      'etapa',  v_per->>'etapa',
      'ini',    nullif(v_per->>'ini','')::date,
      'status', v_st,
      'ini_def', v_ini,
      'fim_def', v_fim));

    if v_st in ('APROVADO_PEL','VALIDADO') then
      v_anyappr := true;
      if v_ini is not null and v_fim is not null then
        v_parc := v_parc || jsonb_build_array(jsonb_build_object(
          'parcela','PREMIO','ordem',coalesce((v_per->>'ordem')::int,1),'ini',v_ini,'fim',v_fim));
      end if;
    end if;
    if v_st <> 'VALIDADO' then v_allval := false; end if;
  end loop;

  v_premio := jsonb_set(coalesce(v_premio,'{}'::jsonb), '{periodos}', v_arr);

  -- roll-up da situação do pedido
  if nullif(p_dados->>'situacao','') = 'REJEITADO' then
    v_sit := 'REJEITADO';
  elsif not coalesce(v_interesse, false) then
    v_sit := 'SEM_INTERESSE';
  elsif v_tem and v_allval then
    v_sit := 'VALIDADO';
  elsif v_anyappr then
    v_sit := 'APROVADO_PEL';
  else
    v_sit := 'PENDENTE';
  end if;

  if v_sit in ('PENDENTE','REJEITADO','SEM_INTERESSE') then v_parc := '[]'::jsonb; end if;

  update public.ferias_pedidos set
    interesse  = v_interesse,
    premio     = v_premio,
    exercicio  = case when p_dados ? 'exercicio' then nullif(p_dados->>'exercicio','')::int else exercicio end,
    parcelas   = v_parc,
    situacao   = v_sit,
    motivo_rejeicao = case when v_sit = 'REJEITADO'
                           then nullif(p_dados->>'motivo_rejeicao','')
                           else null end,
    aprovado_pel_por_matricula = case when v_sit = 'APROVADO_PEL' and aprovado_pel_por_matricula is null then v_me.matricula else aprovado_pel_por_matricula end,
    aprovado_pel_por_nome      = case when v_sit = 'APROVADO_PEL' and aprovado_pel_por_nome is null      then v_nome        else aprovado_pel_por_nome end,
    aprovado_pel_em            = case when v_sit = 'APROVADO_PEL' and aprovado_pel_em is null             then now()         else aprovado_pel_em end,
    validado_p1_por_matricula  = case when v_sit = 'VALIDADO' then v_me.matricula else validado_p1_por_matricula end,
    validado_p1_por_nome       = case when v_sit = 'VALIDADO' then v_nome        else validado_p1_por_nome end,
    validado_p1_em             = case when v_sit = 'VALIDADO' then now()         else validado_p1_em end
  where id = p_id and tipo = 'PREMIO'
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function public.ferias_premio_gerir(uuid, uuid, jsonb) to anon;

-- ─── 3) AVISO MEU DIA: manifestação aberta + reassinatura após validação ──
create or replace function public.ferias_premio_aviso_get(p_token uuid, p_ano int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_ano    int := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_crono  public.ferias_cronograma;
  v_hoje   date := (now() at time zone 'America/Sao_Paulo')::date;
  v_aberto boolean;
  v_ja     boolean := false;
  v_ped    public.ferias_pedidos;
  v_periodos jsonb;
  v_allval boolean := true;
  v_tem    boolean := false;
  v_per    jsonb;
  v_reass  boolean := false;
  v_out    jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_crono from public.ferias_cronograma where ano = v_ano;
  v_aberto := v_crono.id is not null
          and v_crono.premio_situacao = 'ABERTO'
          and (v_crono.premio_abertura is null or v_hoje >= v_crono.premio_abertura)
          and (v_crono.premio_limite   is null or v_hoje <= v_crono.premio_limite);

  -- último pedido PREMIO do militar no ano (p/ "já manifestou" e "reassinar")
  select * into v_ped from public.ferias_pedidos
   where militar_id = v_me.id and ano = v_ano and tipo = 'PREMIO'
   order by created_at desc limit 1;
  v_ja := v_ped.id is not null;

  -- reassinar: todos os períodos VALIDADO e ainda sem anexo final
  if v_ped.id is not null and coalesce(v_ped.interesse,false) and v_ped.situacao = 'VALIDADO' then
    v_periodos := coalesce(v_ped.premio->'periodos','[]'::jsonb);
    for v_per in select * from jsonb_array_elements(v_periodos) loop
      v_tem := true;
      if coalesce(v_per->>'status','') <> 'VALIDADO' then v_allval := false; end if;
    end loop;
    if v_tem and v_allval
       and jsonb_array_length(coalesce(v_ped.anexo_requerimento_final,'[]'::jsonb)) = 0 then
      v_reass := true;
    end if;
  end if;

  v_out := jsonb_build_object('aberto', coalesce(v_aberto,false), 'ano', v_ano);
  if coalesce(v_aberto,false) then
    v_out := v_out || jsonb_build_object('limite', v_crono.premio_limite,
                                         'ja_manifestou', coalesce(v_ja,false));
  end if;
  if v_reass then
    v_out := v_out || jsonb_build_object('reassinar', true, 'pedido_id', v_ped.id);
  end if;
  return v_out;
end;
$$;
grant execute on function public.ferias_premio_aviso_get(uuid, int) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 213).
-- ══════════════════════════════════════════════════════════════════════

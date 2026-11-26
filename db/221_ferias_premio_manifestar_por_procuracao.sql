-- ══════════════════════════════════════════════════════════════════════
--  221 · Férias-Prêmio — Aux P1 lança a manifestação POR OUTRO MILITAR
--
--  Caso: militar SEM acesso ao painel (hipotecado / afastado por ordem
--  judicial) não consegue manifestar. O Aux P1 lança por ele: gera o
--  requerimento, o militar assina fora do sistema e o Aux P1 anexa depois
--  (ferias_premio_anexar JÁ permite Aux P1 anexar em pedido de outro).
--
--  Muda a ferias_premio_manifestar (base db/214):
--   • novo parâmetro p_militar_id (alvo). Quando vem preenchido e ≠ do
--     logado, EXIGE Aux P1/Comando (_ferias_pode_p1) e o pedido passa a
--     pertencer ao ALVO (militar_id/militar/pelotão/grupamento do alvo);
--     criado_por = quem lançou (o Aux P1), p/ auditoria.
--   • no lançamento por procuração, pula a trava de ABERTO/prazo (ação
--     administrativa); o cronograma do ano ainda precisa existir.
--  Chamada normal (militar por si) segue idêntica (p_militar_id = null).
--  Idempotente. Rodar no Supabase. Depende de db/190, db/214.
-- ══════════════════════════════════════════════════════════════════════

-- remove a versão antiga de 2 args p/ não ficar ambígua com a nova (3 args c/ default)
drop function if exists public.ferias_premio_manifestar(uuid, jsonb);

create or replace function public.ferias_premio_manifestar(
  p_token uuid, p_dados jsonb, p_militar_id uuid default null)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_alvo   record;
  v_proc   boolean := false;   -- lançamento por procuração (Aux P1 por outro)
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
  v_criad  text;
  v_per    jsonb;
  v_dias   int;
  v_soma   int := 0;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- resolve o DONO do pedido (ele mesmo, ou o alvo quando o Aux P1 lança por ele)
  if p_militar_id is not null and p_militar_id <> v_me.id then
    if not public._ferias_pode_p1(v_me.nivel_acesso, v_me.funcao) then
      raise exception 'Lançar a manifestação por outro militar é restrito ao Aux P1 / Comando.';
    end if;
    v_proc := true;
    select * into v_alvo from public.militares where id = p_militar_id;
    if v_alvo.id is null then raise exception 'Militar alvo não encontrado.'; end if;
  else
    select * into v_alvo from public.militares where id = v_me.id;
  end if;

  select * into v_crono from public.ferias_cronograma where ano = v_ano;
  if v_crono.id is null then
    raise exception 'A manifestação de férias-prêmio não está aberta neste momento.';
  end if;
  -- trava de ABERTO/prazo vale p/ o militar; o Aux P1 (por procuração) pode lançar fora do prazo
  if not v_proc then
    if v_crono.premio_situacao <> 'ABERTO' then
      raise exception 'A manifestação de férias-prêmio não está aberta neste momento.';
    end if;
    if v_crono.premio_abertura is not null and v_hoje < v_crono.premio_abertura then
      raise exception 'A manifestação de férias-prêmio abre em %.', to_char(v_crono.premio_abertura,'DD/MM/YYYY');
    end if;
    if v_crono.premio_limite is not null and v_hoje > v_crono.premio_limite then
      raise exception 'O prazo da manifestação de férias-prêmio encerrou em %.', to_char(v_crono.premio_limite,'DD/MM/YYYY');
    end if;
  end if;

  v_exerc := nullif(p_dados->>'exercicio','')::int;

  if v_int then
    if jsonb_typeof(v_periodos) <> 'array' or jsonb_array_length(v_periodos) = 0 then
      raise exception 'Informe ao menos o 1º período (duração e data de início).';
    end if;
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
  v_nome := coalesce(v_alvo.posto_graduacao,'') || ' ' || coalesce(v_alvo.nome_guerra, v_alvo.nome_completo);
  v_criad := coalesce(v_me.posto_graduacao,'') || ' ' || coalesce(v_me.nome_guerra, v_me.nome_completo);

  select * into v_ex from public.ferias_pedidos
   where militar_id = v_alvo.id and ano = v_ano and tipo = 'PREMIO'
   order by created_at desc limit 1;

  if v_ex.id is not null and v_ex.situacao in ('APROVADO_PEL','VALIDADO') then
    raise exception 'A manifestação de férias-prêmio deste militar já está %. Para alterar, use a validação.',
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
      v_crono.id, v_ano, v_alvo.id,
      jsonb_build_object('matricula', v_alvo.matricula, 'nome', v_alvo.nome_completo,
                         'guerra', v_alvo.nome_guerra, 'pg', v_alvo.posto_graduacao),
      public._ferias_pelotao(v_alvo.grupamento_id), v_alvo.grupamento_id,
      'PREMIO', v_exerc, v_int, v_premio, '[]'::jsonb, v_sit,
      v_me.matricula, v_criad
    ) returning * into v_row;
  end if;

  return v_row;
end;
$$;
grant execute on function public.ferias_premio_manifestar(uuid, jsonb, uuid) to anon;

notify pgrst, 'reload schema';

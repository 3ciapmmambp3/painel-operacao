-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS-PRÊMIO — aviso de reassinatura dispara já na validação do PELOTÃO
--
--  AJUSTE (2026-11-24): db/215 só acendia "reassinar" quando o pedido estava
--  VALIDADO (validação final do Aux P1 / Cmt Cia) e TODOS os períodos com
--  status 'VALIDADO'. Mas no fluxo real o Cmt de Pelotão altera as datas e
--  valida (situacao = 'APROVADO_PEL'); o militar já deve nesse momento baixar
--  o requerimento com as datas definidas, assinar e reanexar — sem esperar o
--  P1. Com o filtro antigo o militar ficava em APROVADO_PEL e o aviso/arquivo
--  nunca apareciam.
--
--  Agora REASSINAR dispara quando interesse=true, situacao in
--  ('APROVADO_PEL','VALIDADO'), TODOS os períodos com status in
--  ('APROVADO_PEL','VALIDADO') e sem anexo final. O restante (janela ABERTA,
--  retorno) é idêntico ao db/215.
--
--  Depende de: 04 (_sessao_militar), 190 (premio_* / anexo_requerimento_final),
--  214 (premio.periodos[].status), 215. Idempotente. Rodar depois do 215.
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_premio_aviso_get(p_token uuid, p_ano int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me       record;
  v_hoje     date := (now() at time zone 'America/Sao_Paulo')::date;
  v_crono    public.ferias_cronograma;
  v_aberto   boolean := false;
  v_ja       boolean := false;
  v_ped      public.ferias_pedidos;
  v_periodos jsonb;
  v_allval   boolean := true;
  v_tem      boolean := false;
  v_per      jsonb;
  v_reass    boolean := false;
  v_out      jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- ── janela de manifestação ABERTA (respeita p_ano se informado) ──
  if p_ano is not null then
    select * into v_crono from public.ferias_cronograma where ano = p_ano;
  else
    select * into v_crono from public.ferias_cronograma
      where premio_situacao = 'ABERTO'
        and (premio_abertura is null or v_hoje >= premio_abertura)
        and (premio_limite   is null or v_hoje <= premio_limite)
      order by ano desc limit 1;
  end if;
  v_aberto := v_crono.id is not null
          and v_crono.premio_situacao = 'ABERTO'
          and (v_crono.premio_abertura is null or v_hoje >= v_crono.premio_abertura)
          and (v_crono.premio_limite   is null or v_hoje <= v_crono.premio_limite);

  if v_aberto then
    select exists(
      select 1 from public.ferias_pedidos
       where militar_id = v_me.id and ano = v_crono.ano and tipo = 'PREMIO'
    ) into v_ja;
  end if;

  -- ── ÚLTIMO pedido PREMIO do militar em QUALQUER ano (p/ reassinatura) ──
  select * into v_ped from public.ferias_pedidos
   where militar_id = v_me.id and tipo = 'PREMIO'
   order by ano desc, created_at desc limit 1;

  -- dispara já no APROVADO_PEL (Cmt Pelotão validou/alterou) ou no VALIDADO (P1)
  if v_ped.id is not null and coalesce(v_ped.interesse,false)
     and v_ped.situacao in ('APROVADO_PEL','VALIDADO') then
    v_periodos := coalesce(v_ped.premio->'periodos','[]'::jsonb);
    for v_per in select * from jsonb_array_elements(v_periodos) loop
      v_tem := true;
      if coalesce(v_per->>'status','') not in ('APROVADO_PEL','VALIDADO') then v_allval := false; end if;
    end loop;
    if v_tem and v_allval
       and jsonb_array_length(coalesce(v_ped.anexo_requerimento_final,'[]'::jsonb)) = 0 then
      v_reass := true;
    end if;
  end if;

  v_out := jsonb_build_object('aberto', coalesce(v_aberto,false));
  if coalesce(v_aberto,false) then
    v_out := v_out || jsonb_build_object('ano', v_crono.ano,
                                         'limite', v_crono.premio_limite,
                                         'ja_manifestou', coalesce(v_ja,false));
  end if;
  if v_reass then
    v_out := v_out || jsonb_build_object('reassinar', true,
                                         'pedido_id', v_ped.id,
                                         'ano_gozo', v_ped.ano);
  end if;
  return v_out;
end;
$$;
grant execute on function public.ferias_premio_aviso_get(uuid, int) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 215).
-- ══════════════════════════════════════════════════════════════════════

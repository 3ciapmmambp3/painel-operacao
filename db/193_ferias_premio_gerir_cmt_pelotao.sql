-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS-PRÊMIO — CMT de Pelotão também valida (APROVADO_PEL); P1 dá a final
--
--  Fluxo (decisão do user 2026-11-13): o CMT de Pelotão valida os militares do
--  SEU pelotão (situação APROVADO_PEL = "Validado pelo Pelotão"); o Aux P1 (em
--  nome do Cmt de Cia) dá a palavra final (VALIDADO = "Autorizado"). Se o Aux P1
--  validar antes, já fica autorizado (não precisa esperar o pelotão).
--
--  Redefine ferias_premio_gerir (db/191) para aceitar o CMT de Pelotão no ESCOPO
--  do seu pelotão, com teto em APROVADO_PEL (não pode VALIDADO). P1 = tudo.
--
--  Depende de: 101 (_ferias_pode_p1, _ferias_pelotao), 190/191.
--  Idempotente. Rodar no SQL Editor (depois do 192).
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_premio_gerir(p_token uuid, p_id uuid, p_dados jsonb)
returns public.ferias_pedidos
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_row    public.ferias_pedidos;
  v_sit    text := nullif(p_dados->>'situacao','');
  v_nome   text;
  v_podeP1 boolean;
  v_cmtpel boolean;
  v_mypel  text;
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
    -- CMT de Pelotão NÃO dá a palavra final: VALIDADO vira APROVADO_PEL (Validado pelo Pelotão)
    if v_sit = 'VALIDADO' then v_sit := 'APROVADO_PEL'; end if;
  end if;

  update public.ferias_pedidos set
    interesse  = case when p_dados ? 'interesse' then (p_dados->>'interesse')::boolean else interesse end,
    premio     = case when p_dados ? 'premio'    then coalesce(p_dados->'premio','{}'::jsonb) else premio end,
    exercicio  = case when p_dados ? 'exercicio' then nullif(p_dados->>'exercicio','')::int else exercicio end,
    parcelas   = case when p_dados ? 'parcelas'  then coalesce(p_dados->'parcelas','[]'::jsonb) else parcelas end,
    situacao   = case when v_sit is not null then v_sit else situacao end,
    motivo_rejeicao = case when p_dados ? 'motivo_rejeicao' then nullif(p_dados->>'motivo_rejeicao','') else motivo_rejeicao end,
    aprovado_pel_por_matricula = case when v_sit = 'APROVADO_PEL' then v_me.matricula else aprovado_pel_por_matricula end,
    aprovado_pel_por_nome      = case when v_sit = 'APROVADO_PEL' then v_nome        else aprovado_pel_por_nome end,
    aprovado_pel_em            = case when v_sit = 'APROVADO_PEL' then now()         else aprovado_pel_em end,
    validado_p1_por_matricula  = case when v_sit = 'VALIDADO' then v_me.matricula else validado_p1_por_matricula end,
    validado_p1_por_nome       = case when v_sit = 'VALIDADO' then v_nome        else validado_p1_por_nome end,
    validado_p1_em             = case when v_sit = 'VALIDADO' then now()         else validado_p1_em end
  where id = p_id and tipo = 'PREMIO'
  returning * into v_row;

  return v_row;
end;
$$;
grant execute on function public.ferias_premio_gerir(uuid, uuid, jsonb) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 192).
-- ══════════════════════════════════════════════════════════════════════

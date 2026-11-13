-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS-PRÊMIO — consulta de VAGAS para o militar (informativo, não trava)
--
--  Dado um período (ini..fim), diz se há vaga para o militar que consulta,
--  usando o MESMO motor de % das anuais (_ferias_dia_estoura, db/119):
--  verifica o teto da Cia (15%) e o do pelotão/fração do próprio militar.
--  Retorna só AGREGADOS (nunca dados de terceiros):
--    { vaga:true }  ou  { vaga:false, nivel, dia, ferias, total, limite }
--
--  Serve para o formulário do militar MOSTRAR se a data escolhida tende a ter
--  vaga — sem bloquear a manifestação.
--
--  Depende de: 119 (_ferias_dia_estoura), 04 (_sessao_militar), _ferias_pelotao.
--  Idempotente. Rodar no SQL Editor (depois do 191).
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_premio_vagas(p_token uuid, p_ano int, p_ini date, p_fim date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me  record;
  v_pel text;
  v_e   jsonb;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_ini is null or p_fim is null then return jsonb_build_object('vaga', null); end if;

  v_pel := public._ferias_pelotao(v_me.grupamento_id);
  v_e := public._ferias_dia_estoura(
           p_ano,
           jsonb_build_array(jsonb_build_object('parcela','PREMIO','ini',p_ini,'fim',p_fim)),
           null,
           v_pel);

  if v_e is null then
    return jsonb_build_object('vaga', true);
  else
    return v_e || jsonb_build_object('vaga', false);
  end if;
end;
$$;
grant execute on function public.ferias_premio_vagas(uuid, int, date, date) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 191).
-- ══════════════════════════════════════════════════════════════════════

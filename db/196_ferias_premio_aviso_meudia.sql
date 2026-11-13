-- ══════════════════════════════════════════════════════════════════════
--  FÉRIAS-PRÊMIO — aviso no MEU DIA quando a P1 abre a manifestação
--
--  Devolve se a manifestação da prêmio está ABERTA (situação ABERTO + dentro do
--  prazo) para o ano, e se o próprio militar já manifestou. O Meu Dia (inicio.html)
--  usa isso p/ mostrar um card chamando o militar a preencher/anexar o requerimento.
--
--  Depende de: 04 (_sessao_militar), 190 (campos premio_* no cronograma).
--  Idempotente. Rodar no SQL Editor (depois do 195).
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_premio_aviso_get(p_token uuid, p_ano int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_ano    int := coalesce(p_ano, extract(year from (now() at time zone 'America/Sao_Paulo'))::int);
  v_crono  public.ferias_cronograma;
  v_hoje   date := (now() at time zone 'America/Sao_Paulo')::date;
  v_aberto boolean;
  v_ja     boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  select * into v_crono from public.ferias_cronograma where ano = v_ano;
  v_aberto := v_crono.id is not null
          and v_crono.premio_situacao = 'ABERTO'
          and (v_crono.premio_abertura is null or v_hoje >= v_crono.premio_abertura)
          and (v_crono.premio_limite   is null or v_hoje <= v_crono.premio_limite);

  if not coalesce(v_aberto, false) then
    return jsonb_build_object('aberto', false);
  end if;

  select exists(
    select 1 from public.ferias_pedidos
     where militar_id = v_me.id and ano = v_ano and tipo = 'PREMIO'
  ) into v_ja;

  return jsonb_build_object('aberto', true,
                            'limite', v_crono.premio_limite,
                            'ja_manifestou', coalesce(v_ja, false),
                            'ano', v_ano);
end;
$$;
grant execute on function public.ferias_premio_aviso_get(uuid, int) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 195).
-- ══════════════════════════════════════════════════════════════════════

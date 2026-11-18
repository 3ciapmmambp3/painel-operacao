-- ══════════════════════════════════════════════════════════════════════
--  db/199 — FÉRIAS-PRÊMIO: aviso no Meu Dia volta a aparecer
--  Data: 2026-11-18
--
--  BUG: o aviso (db/196) olhava SÓ o ano corrente (extract(year from now) =
--  2026). Mas, desde que o "Ano de gozo" foi desacoplado (16/11), a P1 abre a
--  manifestação no cronograma do ANO DE GOZO (ex.: 2027). Resultado: a RPC
--  devolvia aberto:false e o card não aparecia para NINGUÉM no Meu Dia — ainda
--  que a página de Férias do militar achasse a manifestação (ela varre todos
--  os anos).
--
--  FIX: a RPC passa a procurar a manifestação ABERTA (dentro do prazo) em
--  QUALQUER ano de gozo (ou no ano informado em p_ano, se vier). Mantém a
--  assinatura (uuid, int) — compatível com a chamada atual do inicio.html.
--
--  Depende de: 04 (_sessao_militar), 190 (premio_* no cronograma).
--  Idempotente. Rodar no SQL Editor (depois do 196).
-- ══════════════════════════════════════════════════════════════════════
create or replace function public.ferias_premio_aviso_get(p_token uuid, p_ano int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me     record;
  v_crono  public.ferias_cronograma;
  v_hoje   date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ja     boolean;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;

  -- Manifestação ABERTA (situação = ABERTO e dentro do prazo), em QUALQUER ano
  -- de gozo. Se p_ano for informado, restringe a ele. Preferência pelo ano mais
  -- recente, caso (raramente) haja mais de uma aberta.
  select * into v_crono
    from public.ferias_cronograma c
   where (p_ano is null or c.ano = p_ano)
     and c.premio_situacao = 'ABERTO'
     and (c.premio_abertura is null or v_hoje >= c.premio_abertura)
     and (c.premio_limite   is null or v_hoje <= c.premio_limite)
   order by c.ano desc
   limit 1;

  if v_crono.id is null then
    return jsonb_build_object('aberto', false);
  end if;

  select exists(
    select 1 from public.ferias_pedidos
     where militar_id = v_me.id and ano = v_crono.ano and tipo = 'PREMIO'
  ) into v_ja;

  return jsonb_build_object('aberto', true,
                            'limite', v_crono.premio_limite,
                            'ja_manifestou', coalesce(v_ja, false),
                            'ano', v_crono.ano);
end;
$$;
grant execute on function public.ferias_premio_aviso_get(uuid, int) to anon;

-- ══════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor do Supabase (depois do 196).
-- ══════════════════════════════════════════════════════════════════════

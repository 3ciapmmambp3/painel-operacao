-- ════════════════════════════════════════════════════════════════════════
-- 91_mov_pendencia_cancelar.sql — cancelar pendência de ficha quando a viatura
--                                 sai do TTA (equipe ficou a pé / trocou viatura)
--
-- Cenário: a viatura lançada no TTA quebrou, o TTA foi editado retirando a
-- viatura (equipe a pé) e não houve substituição. A pendência da Ficha de
-- Movimentação (criada pelo TTA por prefixo+dia) continuava ABERTA para o
-- motorista e o comandante, pois nenhuma ficha seria lançada.
--
-- Correção: RPC que CANCELA a pendência ABERTA (ainda sem ficha) de uma viatura.
-- O tta.html chama isso, na edição, para cada viatura que saiu da chamada
-- (estava antes e não está mais) — cobre também a TROCA de viatura.
--
-- Só cancela pendência com atendida=false e mov_id null (nunca mexe em ficha já
-- lançada). Marca cancelada=true (auditoria) e atendida=true (some das listas de
-- pendência sem exigir mudança nas leituras existentes).
--
-- Depende de: 08 (mov_pendencias), 37/84 (mov_pendencia_criar). 04 (_sessao_militar).
-- Idempotente. Rodar no SQL Editor depois do 84.
-- ════════════════════════════════════════════════════════════════════════

alter table public.mov_pendencias add column if not exists cancelada boolean not null default false;

create or replace function public.mov_pendencia_cancelar(
  p_token uuid, p_prefixo text, p_dia date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me record; v_n int;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão inválida ou expirada.'; end if;
  if coalesce(btrim(p_prefixo),'') = '' then return jsonb_build_object('ok', false); end if;

  update public.mov_pendencias
     set atendida = true, cancelada = true
   where prefixo   = btrim(p_prefixo)
     and atendida  = false
     and mov_id is null
     and (p_dia is null or dia = p_dia);
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'canceladas', v_n);
end;
$$;

grant execute on function public.mov_pendencia_cancelar(uuid, text, date) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Ordem no SQL Editor: depois do 84.
-- ════════════════════════════════════════════════════════════════════════

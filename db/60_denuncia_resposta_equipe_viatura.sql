-- ════════════════════════════════════════════════════════════════════════
-- 60_denuncia_resposta_equipe_viatura.sql
--
-- A ficha de resposta da demanda (PDF) passa a mostrar também EQUIPE e VIATURA
-- de quem atendeu — dados que ficam no relatório de serviço, não estavam sendo
-- espelhados na demanda. Acrescenta as colunas e passa a gravá-las na baixa
-- automática (feita ao enviar o relatório). A data já era espelhada
-- (data_resposta).
--
-- Depende de: 01 (denuncias), 05 (denuncia_baixa_automatica). Idempotente.
-- ════════════════════════════════════════════════════════════════════════

alter table public.denuncias add column if not exists resp_equipe  text;  -- equipe do relatório (Cmt/Mot/Patrulheiros)
alter table public.denuncias add column if not exists resp_viatura text;  -- prefixo da viatura empregada

-- Baixa automática (relatório de serviço) — agora também grava equipe e viatura.
-- Recria com 2 parâmetros novos (default null p/ compatibilidade).
drop function if exists public.denuncia_baixa_automatica(uuid, text, text, date, text, text, text, text);

create or replace function public.denuncia_baixa_automatica(
  p_token uuid, p_numero text, p_tipo text, p_data date, p_reds text,
  p_auto_infracao text, p_ato_fiscalizacao text, p_obs text,
  p_equipe text default null, p_viatura text default null
) returns public.denuncias
language plpgsql security definer set search_path = public as $$
declare v_me record; v_row public.denuncias;
begin
  select * into v_me from public._sessao_militar(p_token);
  if v_me.id is null then raise exception 'Sessão expirada. Faça login novamente.'; end if;
  if p_tipo not in ('denuncia','requisicao') then raise exception 'Tipo inválido: %', p_tipo; end if;

  update public.denuncias set
    situacao = 'RESPONDIDA',
    data_resposta = coalesce(p_data, data_resposta),
    numero_reds = coalesce(nullif(p_reds,''), numero_reds),
    numero_auto_infracao = coalesce(nullif(p_auto_infracao,''), numero_auto_infracao),
    numero_ato_fiscalizacao = coalesce(nullif(p_ato_fiscalizacao,''), numero_ato_fiscalizacao),
    observacoes_resposta = coalesce(nullif(p_obs,''), observacoes_resposta),
    resp_equipe = coalesce(nullif(p_equipe,''), resp_equipe),
    resp_viatura = coalesce(nullif(p_viatura,''), resp_viatura),
    atendido_por_matricula = v_me.matricula,
    atendido_por_nome = trim(both ' ' from
      concat(v_me.matricula, ' — ', coalesce(v_me.posto_graduacao,''), ' ', coalesce(v_me.nome_guerra, v_me.nome_completo)))
  where numero = p_numero and tipo = p_tipo
  returning * into v_row;

  return v_row; -- pode ser NULL se não encontrar (falha silenciosa, como hoje)
end;
$$;

grant execute on function public.denuncia_baixa_automatica(uuid, text, text, date, text, text, text, text, text, text) to anon;

-- ════════════════════════════════════════════════════════════════════════
-- FIM. Rodar no SQL Editor (depois do 05).
-- ════════════════════════════════════════════════════════════════════════

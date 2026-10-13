-- ════════════════════════════════════════════════════════════════════════
--  CORREÇÃO PONTUAL — Cartão Programa Nº 012/2026 (DDU 02520092633)
--
--  O relatório 87329a91-404a-45df-826c-5d97992bb9b4 (equipe B, 12/10/2026)
--  respondeu a DDU 02520092633 (REDS 2026-047484068-001, Ato
--  2026.10.01.362.0001593, Finalizada), mas a Demanda 1 do cartão tinha
--  origem=null (foi digitada/importada à mão, sem vir do painel). O casamento
--  automático antigo só olhava origem.numero, então a resposta não entrou no
--  cartão (respostas ficou {}). O relatorio_id ficou gravado mesmo assim.
--
--  O fallback de casamento (extrai o nº do texto "ID da Demanda:") foi corrigido
--  no relatorio-servico.html — daqui pra frente puxa sozinho. Este script só
--  conserta ESTE cartão, gravando a resposta da Demanda 1 e recalculando o
--  status via _cartao_status. Idempotente (reexecutar não duplica). Rodar 1x.
-- ════════════════════════════════════════════════════════════════════════
update public.cartoes_programa c
set respostas = r.resp,
    status    = public._cartao_status(c.demandas, r.resp)
from (
  select jsonb_build_object(
    '1', jsonb_build_object(
      'atendida',        'TOTAL',
      'data_atendimento','2026-10-12',
      'reds',            '2026-047484068-001',
      'ato_fiscalizacao','2026.10.01.362.0001593',
      'por_matricula',   '138.983-2',
      'por_nome',        '3º Sgt PM Bruno Ladeia Ganem',
      'em',              '2026-10-12T21:27:51.69505+00:00'
    )
  ) as resp
) r
where c.id = '12bf2066-642c-46e2-9b1d-c3debc7ce842';

-- Conferência (opcional): deve mostrar status = EM_ATENDIMENTO e a resposta da Demanda 1.
-- select numero, status, respostas from public.cartoes_programa where id = '12bf2066-642c-46e2-9b1d-c3debc7ce842';
-- ════════════════════════════════════════════════════════════════════════
-- FIM.
-- ════════════════════════════════════════════════════════════════════════

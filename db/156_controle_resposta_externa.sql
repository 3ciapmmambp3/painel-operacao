-- ══════════════════════════════════════════════════════════════════════
--  Controle de Demandas — RESPOSTA NO SISTEMA EXTERNO + baixa manual do Aux
--  Rodar no Supabase (SQL Editor). Idempotente. Depende de db/151/152/154/155.
--
--  (1) BAIXA MANUAL pelo Aux (gaveta do painel): usa as funções *_baixar que já
--      existem (nuden/ddu/ri/emergencia_baixar) — nada a criar aqui.
--  (2) RESPOSTA NO SISTEMA EXTERNO: para NUDEN (SEMAD) e DDU (plataforma DDU) o
--      analista lança a resposta no site do órgão. O Aux (P3=NUDEN, P2=DDU)
--      precisa controlar QUANDO isso foi feito. Guardamos a data e quem marcou;
--      a demanda vira 'FINALIZADA' (atendida pela fração E respondida ao órgão).
--      Gravado por PATCH direto (RLS anon update já permite); gate no app.
--
--  As colunas vão nas 4 tabelas (uniformidade); a UI de "sistema externo" só
--  aparece onde faz sentido (NUDEN/DDU). FTP/RI e Emergência ganham só a baixa
--  manual (não têm sistema externo de resposta).
-- ══════════════════════════════════════════════════════════════════════

do $$
declare t text;
begin
  foreach t in array array['nuden_demandas','ddu_demandas','ri_demandas','emergencia_demandas']
  loop
    execute format('alter table public.%I add column if not exists data_resposta_externa date', t);
    execute format('alter table public.%I add column if not exists respondido_externo_por_matricula text', t);
    execute format('alter table public.%I add column if not exists respondido_externo_por_nome text', t);
  end loop;
end $$;

-- Nada mais: a escrita é por PATCH (REST) sob a policy anon update já existente,
-- e a baixa manual reusa as RPCs *_baixar. Fim.

-- ══════════════════════════════════════════════════════════════════════
--  CORREÇÃO — 7 fichas de movimentação com MOTORISTA em matrícula de outra
--  pessoa (matrícula digitada errada na criação da ficha; a importação do
--  Efetivo, ao corrigir o cadastro, deixou a divergência visível).
--
--  Cada UPDATE troca SÓ motorista_matricula + motorista_nome, travado pelo id
--  E pela matrícula errada atual (idempotente: se já corrigido, não faz nada).
--  Rodar UMA vez no SQL Editor do Supabase.
-- ══════════════════════════════════════════════════════════════════════

-- 1) Nathália Núbia Macieira  (estava em 118.404-3 = Wanderson)
update public.mov_viaturas set motorista_matricula='139.230-7', motorista_nome='Nathália Núbia Macieira'
 where id='313b9173-6968-4ce2-98c5-8f2f83fd85a2'
   and regexp_replace(coalesce(motorista_matricula,''),'\D','','g')='1184043';

-- 2) João Paulo Batista Almeida  (estava em 121.394-1 = Rodrigo Aleixo de Franco)
update public.mov_viaturas set motorista_matricula='146.833-9', motorista_nome='João Paulo Batista Almeida'
 where id='e9044409-8f26-4f67-bb18-35aaa17776d3'
   and regexp_replace(coalesce(motorista_matricula,''),'\D','','g')='1213941';

-- 3) Ana Carolina Gomes Costa  (estava em 129.962-7 = Ivan Flávio de Magalhães)
update public.mov_viaturas set motorista_matricula='191.022-3', motorista_nome='Ana Carolina Gomes Costa'
 where id='3c15dff4-3dc4-4f2d-919f-5c2d55ee7526'
   and regexp_replace(coalesce(motorista_matricula,''),'\D','','g')='1299627';

-- 4) Karine dos Reis Magalhães Camilo  (estava em 141.827-6 = Aristóteles Libério)
update public.mov_viaturas set motorista_matricula='171.675-2', motorista_nome='Karine dos Reis Magalhães Camilo'
 where id='3715139e-0ed9-4415-9ec6-253f0867a775'
   and regexp_replace(coalesce(motorista_matricula,''),'\D','','g')='1418276';

-- 5) Aristóteles Libério Braga Rodrigues  (estava em 139.174-7 = Edison Ferreira da Silva)
update public.mov_viaturas set motorista_matricula='141.827-6', motorista_nome='Aristóteles Libério Braga Rodrigues'
 where id='8339d886-916f-48f8-947a-7b288668b6d6'
   and regexp_replace(coalesce(motorista_matricula,''),'\D','','g')='1391747';

-- 6) Ricardo Vinícius Costa  (estava em 156.741-1 = Leandro Saldanha)
update public.mov_viaturas set motorista_matricula='175.366-4', motorista_nome='Ricardo Vinícius Costa'
 where id='ddcd56d7-d77e-45a8-bcb3-414438320bc4'
   and regexp_replace(coalesce(motorista_matricula,''),'\D','','g')='1567411';

-- 7) Wallisson Nunes Ricardo  (estava em 141.381-4 = Welerson Cesar Oliveira)
update public.mov_viaturas set motorista_matricula='141.365-7', motorista_nome='Wallisson Nunes Ricardo'
 where id='466a2edc-73a1-479a-8ae8-cd5f2a764864'
   and regexp_replace(coalesce(motorista_matricula,''),'\D','','g')='1413814';

-- ── Conferência (rodar depois; deve trazer as 7 fichas já com o motorista certo) ──
select id, motorista_matricula, motorista_nome
  from public.mov_viaturas
 where id in (
   '313b9173-6968-4ce2-98c5-8f2f83fd85a2','e9044409-8f26-4f67-bb18-35aaa17776d3',
   '3c15dff4-3dc4-4f2d-919f-5c2d55ee7526','3715139e-0ed9-4415-9ec6-253f0867a775',
   '8339d886-916f-48f8-947a-7b288668b6d6','ddcd56d7-d77e-45a8-bcb3-414438320bc4',
   '466a2edc-73a1-479a-8ae8-cd5f2a764864')
 order by motorista_nome;

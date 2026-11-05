-- ══════════════════════════════════════════════════════════════════════
--  db/174 — Efetivo: limpa ponto e traço do e-mail funcional (matrícula)
--  Data: 2026-11-05
--
--  O e-mail funcional é a matrícula @pmmg.mg.gov.br, mas vários registros
--  entraram com a matrícula formatada:
--      114.413-8@pmmg.mg.gov.br   →  deveria ser  1144138@pmmg.mg.gov.br
--
--  Este script remove APENAS o ponto e o traço da PARTE LOCAL (antes do @).
--  O domínio (pmmg.mg.gov.br) fica intacto — só é tocado quando a parte
--  local é composta só de dígitos/ponto/traço (ou seja, matrícula), então
--  e-mails baseados em nome (joao.silva@...) NÃO são alterados.
--
--  Idempotente: rodar de novo não muda nada (nada mais tem ponto/traço).
-- ══════════════════════════════════════════════════════════════════════

-- (Opcional) PRÉVIA — veja o que vai mudar antes de aplicar:
-- select matricula, email_funcional as antes,
--        regexp_replace(split_part(email_funcional,'@',1),'[.\-]','','g')
--          || '@' || split_part(email_funcional,'@',2) as depois
--   from public.militares
--  where email_funcional like '%@%'
--    and split_part(email_funcional,'@',1) ~ '^[0-9.\-]+$'
--    and split_part(email_funcional,'@',1) ~ '[.\-]'
--  order by matricula;

update public.militares
   set email_funcional =
         regexp_replace(split_part(email_funcional,'@',1),'[.\-]','','g')
         || '@' || split_part(email_funcional,'@',2)
 where email_funcional like '%@%'
   and split_part(email_funcional,'@',1) ~ '^[0-9.\-]+$'   -- parte local = só matrícula (sem letras)
   and split_part(email_funcional,'@',1) ~ '[.\-]';         -- e que ainda tem ponto/traço a limpar

-- ══════════════════════════════════════════════════════════════════════
-- FIM.
-- ══════════════════════════════════════════════════════════════════════

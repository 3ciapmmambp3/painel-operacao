-- ══════════════════════════════════════════════════════════════════════
--  VIRADA DA NUMERAÇÃO — continuar de onde a PLANILHA / FORMULÁRIO parou
--  Rodar no Supabase → SQL Editor NO MOMENTO EM QUE FOR LIGAR CADA MÓDULO.
--
--  Como a numeração funciona:
--    proximo_numero(ano, tipo) devolve  ultimo + 1  (atômico, sem duplicar).
--    Logo, "ultimo" = ÚLTIMO NÚMERO JÁ USADO na planilha/formulário.
--    Ex.: para a próxima DENÚNCIA sair 743/2026, ultimo = 742.
--
--  ⚠️  CADA tipo é um comando SEPARADO. Rode SÓ o(s) tipo(s) que você está
--      ativando agora, com o número certo. NÃO re-rode um tipo que já está
--      em uso no sistema (isso faria a numeração "voltar" para trás).
--
--  PASSO A PASSO (dia da virada de cada módulo):
--    1. Veja o MAIOR número daquele tipo no ANO corrente (na planilha/form).
--    2. Coloque (esse número) no comando do tipo e ajuste o ano se preciso.
--    3. Execute SÓ aquele comando.
--    4. A partir daí registre só no sistema (não use mais a planilha p/ numerar).
-- ══════════════════════════════════════════════════════════════════════

-- ── DENÚNCIA (balcão) ──  próxima => ultimo + 1
insert into public.contadores (ano, tipo, ultimo) values
  (2026, 'denuncia', 742)                 -- << último da planilha (próxima = 743/2026)
on conflict (ano, tipo) do update set ultimo = excluded.ultimo;

-- ── REQUISIÇÃO ──  próxima => ultimo + 1
insert into public.contadores (ano, tipo, ultimo) values
  (2026, 'requisicao', 524)               -- << último da planilha (próxima = 525/2026)
on conflict (ano, tipo) do update set ultimo = excluded.ultimo;

-- ── OFÍCIO (saída) ──  próxima => ultimo + 1
-- ⚠️ AJUSTE o número abaixo com o ÚLTIMO ofício de SAÍDA já usado no formulário
--    Google deste ano, e SÓ ENTÃO execute esta linha.
insert into public.contadores (ano, tipo, ultimo) values
  (2026, 'oficio', 0)                     -- << TROCAR pelo último ofício de saída (ex.: 276 → próxima 277/2026)
on conflict (ano, tipo) do update set ultimo = excluded.ultimo;

-- ── REQUISIÇÃO JUDICIAL ──  próxima => ultimo + 1
-- ⚠️ AJUSTE o número abaixo com a ÚLTIMA requisição judicial já usada no
--    formulário Google deste ano, e SÓ ENTÃO execute esta linha.
insert into public.contadores (ano, tipo, ultimo) values
  (2026, 'req_judicial', 0)               -- << TROCAR pela última requisição judicial (ex.: 40 → próxima 41/2026)
on conflict (ano, tipo) do update set ultimo = excluded.ultimo;

-- Conferência:
--   select * from public.contadores where ano = 2026 order by tipo;

-- ── Vira de ano: quando entrar 2027, cada tipo começa 001/2027 sozinho
--    (não precisa fazer nada). Só rode de novo se quiser forçar outro início.

-- ── LIMPEZA DE TESTES (opcional): se fez registros de teste antes da virada,
--    remova-os. Ex. denúncias:
--      select numero, tipo, municipio, created_at from public.denuncias order by created_at;
--      delete from public.denuncias where id in ('id-1','id-2');
--    Ofícios de teste:
--      select numero, tipo, assunto, created_at from public.oficios order by created_at;
--      delete from public.oficios where id in ('id-1','id-2');   -- (só Admin Geral pelo painel)
-- ══════════════════════════════════════════════════════════════════════

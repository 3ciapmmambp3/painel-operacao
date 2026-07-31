-- ══════════════════════════════════════════════════════════════════════
--  VIRADA DA NUMERAÇÃO — continuar de onde a PLANILHA parou
--  Rodar no Supabase → SQL Editor NO MOMENTO EM QUE FOR LIGAR O SISTEMA.
--
--  Como a numeração funciona:
--    proximo_numero(ano, tipo) devolve  ultimo + 1  (atômico, sem duplicar).
--    Logo, "ultimo" tem que ser o ÚLTIMO NÚMERO JÁ USADO na planilha.
--    Ex.: para a próxima DENÚNCIA sair 743/2026, ultimo = 742.
--         para a próxima REQUISIÇÃO sair 525/2026, ultimo = 524.
--
--  PASSO A PASSO (dia da virada):
--    1. Abra a planilha e veja o MAIOR número de CADA tipo no ANO corrente.
--    2. Ajuste os dois valores abaixo (e o ano, se já for outro).
--    3. Execute este bloco.
--    4. A partir daí, registre SÓ no sistema (não use mais a planilha p/ numerar).
-- ══════════════════════════════════════════════════════════════════════

insert into public.contadores (ano, tipo, ultimo) values
  (2026, 'denuncia',   742),   -- próxima DENÚNCIA   => 743/2026
  (2026, 'requisicao', 524)    -- próxima REQUISIÇÃO => 525/2026
on conflict (ano, tipo) do update set ultimo = excluded.ultimo;

-- Conferência (deve mostrar 742 e 524):
--   select * from public.contadores where ano = 2026 order by tipo;

-- ── Vira de ano: quando entrar 2027, o sistema começa 001/2027 sozinho
--    (não precisa fazer nada). Só rode de novo se quiser forçar outro início.

-- ── LIMPEZA DE TESTES (opcional): se você fez registros de teste antes da
--    virada, remova-os para não aparecerem na Caixa de Entrada / Relatório.
--    Veja o que existe:
--      select numero, tipo, municipio, created_at
--      from public.denuncias order by created_at;
--    Apague os de teste por id (troque pelos ids reais):
--      delete from public.denuncias where id in ('id-1','id-2');
--    Se apagou TODOS os testes e quer reiniciar o contador, rode o insert acima
--    de novo com os números corretos da planilha.

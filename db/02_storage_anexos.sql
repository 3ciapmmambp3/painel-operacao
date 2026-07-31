-- ══════════════════════════════════════════════════════════════════════
--  ANEXOS — Supabase Storage (bucket privado)
--  Rodar no Supabase (SQL Editor). Idempotente: pode rodar mais de uma vez.
--
--  Substitui o antigo fluxo de anexos no Google Drive (conta de serviço não
--  tem cota de armazenamento em Gmail comum → erro 403 storageQuotaExceeded).
--  Aqui os arquivos ficam num bucket PRIVADO do próprio Supabase; o painel:
--    • comprime imagens no navegador antes de subir (nova-denuncia.html);
--    • gera uma signed URL durável (~10 anos) e guarda em denuncias.anexos[].link;
--    • abre esse link no detalhe e dentro do PDF da Ficha.
--
--  Modelo de acesso: o painel usa a ANON KEY (igual ao resto do projeto).
--  O bucket é privado (não listável/anônimo). O que dá acesso é a signed URL
--  (token assinado embutido) — durável e sem exigir login, exatamente como
--  decidido para o PDF encaminhado ao militar de atendimento.
-- ══════════════════════════════════════════════════════════════════════

-- ─── 1) BUCKET PRIVADO ─────────────────────────────────────────────────
-- public=false → nada é servido sem uma signed URL válida.
-- file_size_limit: teto por arquivo (15 MB; imagens já sobem comprimidas).
insert into storage.buckets (id, name, public, file_size_limit)
values ('anexos', 'anexos', false, 15728640)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit;

-- ─── 2) POLÍTICAS (RLS em storage.objects) ─────────────────────────────
-- O painel opera com a role `anon`. Liberamos as operações SÓ para o bucket
-- 'anexos'. A criação de signed URL exige SELECT; o upload exige INSERT; a
-- remoção de um anexo antes de salvar exige DELETE.

drop policy if exists "anexos_anon_select" on storage.objects;
create policy "anexos_anon_select" on storage.objects
  for select to anon
  using (bucket_id = 'anexos');

drop policy if exists "anexos_anon_insert" on storage.objects;
create policy "anexos_anon_insert" on storage.objects
  for insert to anon
  with check (bucket_id = 'anexos');

drop policy if exists "anexos_anon_delete" on storage.objects;
create policy "anexos_anon_delete" on storage.objects
  for delete to anon
  using (bucket_id = 'anexos');

-- Observação: o histórico (denuncias.anexos) guarda { path, nome, tamanho,
-- mime, link }. Anexos antigos que porventura tenham vindo do Drive ainda
-- têm web_view_link; o frontend usa `a.link || a.web_view_link`.

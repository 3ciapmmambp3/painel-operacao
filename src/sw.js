/* ══════════════════════════════════════════════════════════════════════
   sw.js — Service Worker do Painel de Gestão Operacional (PWA).
   Estratégia: NETWORK-FIRST para tudo do próprio domínio (HTML, CSS, JS,
   imagens). Sempre busca a versão mais nova online; o cache é só uma reserva
   para quando o aparelho estiver offline. Assim, todo deploy aparece na hora
   (sem telas/estilos velhos). Requisições externas (Supabase, tiles) e não-GET
   passam direto, sem cache.
   ══════════════════════════════════════════════════════════════════════ */
const VERSION = 'pgo-v2';

self.addEventListener('install', (e) => {
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  const url = new URL(req.url);

  // só cuida de GET do mesmo domínio; o resto (Supabase, POST, tiles) passa direto
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;

  // network-first: tenta a rede, guarda no cache, e só usa o cache se estiver offline
  e.respondWith(
    fetch(req)
      .then((res) => {
        if (res && res.status === 200) {
          const copy = res.clone();
          caches.open(VERSION).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(() =>
        caches.match(req).then((cached) => {
          if (cached) return cached;
          // fallback de navegação offline
          if (req.mode === 'navigate') return caches.match('/index.html');
          return Response.error();
        })
      )
  );
});

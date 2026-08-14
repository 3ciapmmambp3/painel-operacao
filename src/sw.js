/* ══════════════════════════════════════════════════════════════════════
   sw.js — Service Worker do Painel de Gestão Operacional (PWA).
   Estratégia:
     • HTML/navegação → network-first (sempre pega a versão mais nova online;
       usa cache só se estiver offline). Evita telas velhas após deploy.
     • assets estáticos (css/js/png) → stale-while-revalidate (rápido e atualiza
       em segundo plano).
     • Requisições a APIs externas (Supabase, tiles, etc.) e não-GET → passam
       direto, sem cache.
   ══════════════════════════════════════════════════════════════════════ */
const VERSION = 'pgo-v1';
const CORE = [
  '/index.html',
  '/styles/global.css',
  '/assets/icon-192.png',
  '/assets/icon-512.png'
];

self.addEventListener('install', (e) => {
  self.skipWaiting();
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(CORE).catch(() => {})));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  const url = new URL(req.url);

  // só cuida de GET do mesmo domínio; o resto (Supabase, POST, tiles) passa direto
  if (req.method !== 'GET' || url.origin !== self.location.origin) return;

  const isHTML = req.mode === 'navigate' ||
    (req.headers.get('accept') || '').includes('text/html');

  if (isHTML) {
    // network-first
    e.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(VERSION).then((c) => c.put(req, copy));
          return res;
        })
        .catch(() => caches.match(req).then((r) => r || caches.match('/index.html')))
    );
    return;
  }

  // assets: stale-while-revalidate
  e.respondWith(
    caches.match(req).then((cached) => {
      const network = fetch(req).then((res) => {
        if (res && res.status === 200) {
          const copy = res.clone();
          caches.open(VERSION).then((c) => c.put(req, copy));
        }
        return res;
      }).catch(() => cached);
      return cached || network;
    })
  );
});

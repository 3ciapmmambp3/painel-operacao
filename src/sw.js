/* ══════════════════════════════════════════════════════════════════════
   sw.js — Service Worker do Painel de Gestão Operacional (PWA).

   SEM CACHE. O app continua instalável (PWA), mas o service worker NÃO
   guarda nada: todas as requisições vão direto para a rede, então cada
   deploy aparece na hora e nunca há tela em branco por cache desencontrado.
   No activate ele apaga QUALQUER cache antigo que versões anteriores tenham
   deixado no aparelho.
   ══════════════════════════════════════════════════════════════════════ */
self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Sem handler de 'fetch' que intercepte: o navegador faz o fetch normal (rede).
// Isso garante conteúdo sempre atualizado e elimina qualquer cache do SW.

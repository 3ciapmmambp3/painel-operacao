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

// Handler de 'fetch' VAZIO (não chama respondWith): o navegador faz o fetch
// normal pela rede — segue SEM cache e sempre atualizado. Ele existe só porque
// o Chrome exige um service worker COM handler de fetch para disparar o
// beforeinstallprompt (o convite/botão "Instalar app"). Sem isto, o app fica
// instalável só pelo menu do navegador, mas o nosso banner não aparece.
self.addEventListener('fetch', () => {});

/* ══════════════════════════════════════════════════════════════════════
   pwa.js — habilita a instalação do Painel como aplicativo (PWA).
   Injeta o <link rel="manifest">, as metas do iOS/Android e registra o
   service worker. Basta incluir <script src="pwa.js" defer></script> na página.
   ══════════════════════════════════════════════════════════════════════ */
(function () {
  function meta(name, content, attr) {
    attr = attr || 'name';
    if (document.head.querySelector('[' + attr + '="' + name + '"]')) return;
    var m = document.createElement('meta');
    m.setAttribute(attr, name);
    m.setAttribute('content', content);
    document.head.appendChild(m);
  }

  // manifesto
  if (!document.head.querySelector('link[rel="manifest"]')) {
    var l = document.createElement('link');
    l.rel = 'manifest';
    l.href = '/manifest.json';
    document.head.appendChild(l);
  }

  // cor da barra de status / tema
  meta('theme-color', '#0d0d0d');

  // iOS (Safari) — abre em tela cheia e usa o ícone/nome do app
  meta('apple-mobile-web-app-capable', 'yes');
  meta('mobile-web-app-capable', 'yes');
  meta('apple-mobile-web-app-status-bar-style', 'black-translucent');
  meta('apple-mobile-web-app-title', 'Painel Operacional');

  // ícone de toque do iOS
  if (!document.head.querySelector('link[rel="apple-touch-icon"]')) {
    var i = document.createElement('link');
    i.rel = 'apple-touch-icon';
    i.href = '/assets/icon-192.png';
    document.head.appendChild(i);
  }

  // registra o service worker (necessário para o "Instalar app")
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(function (e) {
        console.warn('[PWA] service worker não registrou:', e);
      });
    });
  }
})();

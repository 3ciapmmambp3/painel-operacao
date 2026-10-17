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

  /* ══════════════════════════════════════════════════════════════════════
     Banner próprio de instalação — reaparece para quem dispensou o convite
     nativo. Android/Chrome: captura beforeinstallprompt e oferece um botão
     "Instalar" que chama prompt() na hora. iOS/Safari: não há prompt nativo,
     então mostra as instruções (Compartilhar ▸ Adicionar à Tela de Início).
     Dispensar = "soneca" de 7 dias (volta a aparecer depois). Some de vez
     quando o app já está instalado (standalone) ou após instalar.
     ════════════════════════════════════════════════════════════════════ */
  var SNOOZE_DIAS = 7;
  var deferred = null;

  function isStandalone() {
    try { return window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true; }
    catch (e) { return false; }
  }
  function snoozed() {
    try { return Date.now() < (parseInt(localStorage.getItem('pwa_snooze') || '0', 10) || 0); }
    catch (e) { return false; }
  }
  function soneca() {
    try { localStorage.setItem('pwa_snooze', String(Date.now() + SNOOZE_DIAS * 864e5)); } catch (e) {}
  }
  function limparSoneca() { try { localStorage.removeItem('pwa_snooze'); } catch (e) {} }
  function ehIOS() { return /iphone|ipad|ipod/i.test(navigator.userAgent); }
  function ehSafariIOS() { return ehIOS() && /safari/i.test(navigator.userAgent) && !/crios|fxios|edgios|opt\//i.test(navigator.userAgent); }

  function injetarEstilo() {
    if (document.getElementById('pwa-inst-css')) return;
    var s = document.createElement('style');
    s.id = 'pwa-inst-css';
    s.textContent =
      '#pwa-inst{position:fixed;left:12px;right:12px;bottom:12px;z-index:100000;max-width:560px;margin:0 auto;' +
      'background:#141414;border:1px solid #c9a24b55;border-radius:12px;box-shadow:0 10px 34px rgba(0,0,0,.5);' +
      'padding:12px 14px;display:flex;gap:12px;align-items:center;font-family:inherit;color:#f3f3f3;animation:pwaup .25s ease}' +
      '@keyframes pwaup{from{transform:translateY(16px);opacity:0}to{transform:none;opacity:1}}' +
      '#pwa-inst .ic{font-size:22px;line-height:1}' +
      '#pwa-inst .tx{flex:1;min-width:0;font-size:13px;line-height:1.35}' +
      '#pwa-inst .tx b{color:#e9c87a}' +
      '#pwa-inst .bt{background:#c9a24b;color:#1a1a1a;border:0;border-radius:8px;padding:9px 14px;font-weight:800;font-size:13px;cursor:pointer;white-space:nowrap}' +
      '#pwa-inst .cl{background:transparent;border:0;color:#9aa0a6;font-size:20px;cursor:pointer;padding:2px 6px;line-height:1}' +
      '@media(max-width:480px){#pwa-inst{flex-wrap:wrap}#pwa-inst .tx{flex:1 1 100%;order:1}#pwa-inst .ic{order:0}#pwa-inst .bt{order:2}#pwa-inst .cl{order:3;margin-left:auto}}';
    document.head.appendChild(s);
  }

  function fecharBanner() { var b = document.getElementById('pwa-inst'); if (b) b.remove(); }

  function mostrarBanner(modo) {
    if (isStandalone() || snoozed() || document.getElementById('pwa-inst')) return;
    injetarEstilo();
    var wrap = document.createElement('div');
    wrap.id = 'pwa-inst';
    var texto = (modo === 'ios')
      ? '<b>Instale o Painel</b> no seu iPhone: toque em <b>Compartilhar</b> ▸ <b>Adicionar à Tela de Início</b>.'
      : '<b>Instale o Painel</b> como aplicativo para abrir direto da tela inicial.';
    var botao = (modo === 'ios') ? '' : '<button class="bt" id="pwa-inst-go">📲 Instalar</button>';
    wrap.innerHTML =
      '<span class="ic">📲</span><div class="tx">' + texto + '</div>' + botao +
      '<button class="cl" id="pwa-inst-x" aria-label="Fechar">✕</button>';
    document.body.appendChild(wrap);

    var x = document.getElementById('pwa-inst-x');
    if (x) x.addEventListener('click', function () { soneca(); fecharBanner(); });

    var go = document.getElementById('pwa-inst-go');
    if (go) go.addEventListener('click', function () {
      if (!deferred) { fecharBanner(); return; }
      deferred.prompt();
      deferred.userChoice.then(function (r) {
        if (r && r.outcome === 'accepted') { limparSoneca(); } else { soneca(); }
        deferred = null; fecharBanner();
      });
    });
  }

  // Android/Chrome: o evento fira a cada visita enquanto não instalado — mesmo
  // para quem dispensou o convite nativo. Guardamos e mostramos nosso botão.
  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    deferred = e;
    mostrarBanner('android');
  });

  window.addEventListener('appinstalled', function () {
    deferred = null; limparSoneca(); fecharBanner();
  });

  // iOS Safari não dispara beforeinstallprompt: mostra instruções manuais.
  window.addEventListener('load', function () {
    if (ehSafariIOS() && !isStandalone()) setTimeout(function () { mostrarBanner('ios'); }, 1200);
  });
})();

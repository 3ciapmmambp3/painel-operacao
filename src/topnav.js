/* ══════════════════════════════════════════════════════════════════════
   topnav.js — barra de navegação superior COMPARTILHADA (hubs por seção).

   Uso na página (auth.js precisa vir ANTES):
     <script src="auth.js"></script>
     <script src="topnav.js" data-ativo="p3"></script>

   data-ativo marca o item atual:
     inicio | p1 | p2 | p3 | p4 | p5 | consulta | adm
   A barra é inserida logo após o <header> da página (ou no topo do body,
   se não houver header). O CSS vem do global.css (.topnav / .hubdot).

   Barra: INÍCIO · P1 · P2 · P3 · P4 · P5 · CONSULTA · ADM
   Fonte única — mexer aqui reflete em TODAS as páginas; página nova é só
   incluir este script (não há risco de esquecer um item).
   ══════════════════════════════════════════════════════════════════════ */
(function(){
  const cur = document.currentScript;
  const ativo = (cur && cur.dataset.ativo) || '';

  function montar(){
    const sessao = (typeof sessaoLer === 'function') ? sessaoLer() : null;
    const nivel  = sessao ? sessao.nivel_acesso : 'operacional';
    const isAdmin = ['admin_geral','admin','admin_pelotao','admin_gp'].includes(nivel);
    const on = k => ativo===k ? ' active' : '';

    const nav = document.createElement('nav');
    nav.className = 'topnav';
    nav.id = 'topnav';
    nav.innerHTML = `
      <a class="topnav-link${on('inicio')}" href="inicio.html">🏠 INÍCIO</a>
      <a class="topnav-link${on('p1')}" href="hub-p1.html"><span class="hubdot hub-p1"></span> RECURSOS HUMANOS</a>
      <a class="topnav-link${on('p2')}" href="hub-p2.html"><span class="hubdot hub-p2"></span> INTELIGÊNCIA</a>
      <a class="topnav-link${on('p3')}" href="hub-p3.html"><span class="hubdot hub-p3"></span> EMPREGO OPERACIONAL</a>
      <a class="topnav-link${on('p4')}" href="hub-p4.html"><span class="hubdot hub-p4"></span> APOIO LOGÍSTICO</a>
      <a class="topnav-link${on('p5')}" href="hub-p5.html"><span class="hubdot hub-p5"></span> COMUNICAÇÃO ORGANIZACIONAL</a>
      <a class="topnav-link${on('consulta')}" href="painel.html?tab=consulta">📍 CONSULTA</a>
      <div class="topnav-item" id="admTopnavItem" style="display:${isAdmin?'':'none'};">
        <div class="topnav-link${on('adm')}" data-dropdown="ddAdm">⚙ ADM <span class="chev">▾</span></div>
        <div class="topnav-dropdown" id="ddAdm">
          <a href="painel.html?tab=relatorios">📋 Relatórios</a>
          ${nivel==='admin_geral' ? '<a href="painel.html?tab=importacao">📥 Importação</a>' : ''}
          ${nivel==='admin_geral' ? '<a href="admin.html">⚙️ Administração</a>' : ''}
        </div>
      </div>`;

    const header = document.querySelector('header');
    if (header && header.parentNode) header.insertAdjacentElement('afterend', nav);
    else document.body.insertAdjacentElement('afterbegin', nav);

    // Dropdown (ADM)
    nav.querySelectorAll('.topnav-link[data-dropdown]').forEach(link => {
      link.addEventListener('click', (e) => {
        e.stopPropagation();
        const dd = document.getElementById(link.dataset.dropdown);
        const aberto = dd.classList.contains('open');
        document.querySelectorAll('.topnav-dropdown.open').forEach(d => d.classList.remove('open'));
        if (!aberto) dd.classList.add('open');
      });
    });
    document.addEventListener('click', () => {
      document.querySelectorAll('.topnav-dropdown.open').forEach(d => d.classList.remove('open'));
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', montar);
  else montar();
})();

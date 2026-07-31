/* ══════════════════════════════════════════════════════════════════════
   topnav.js — barra de navegação superior COMPARTILHADA.

   Uso na página (auth.js precisa vir ANTES):
     <script src="auth.js"></script>
     <script src="topnav.js" data-ativo="demandas"></script>

   data-ativo marca o item atual: inicio | operacao | criminal | relatorio |
   demandas | consulta | adm. A barra é inserida logo após o <header> da página
   (ou no topo do body, se não houver header). O CSS vem do global.css (.topnav).

   Assim TODAS as páginas usam a mesma barra — mexer aqui reflete em todas, e
   página nova é só incluir este script (não há mais risco de esquecer um item).
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
      <a class="topnav-link${on('inicio')}" href="painel.html">🏠 INÍCIO</a>
      <div class="topnav-item">
        <div class="topnav-link${on('operacao')}" data-dropdown="ddOperacao">🛡 OPERAÇÃO <span class="chev">▾</span></div>
        <div class="topnav-dropdown" id="ddOperacao">
          <a href="painel.html?tab=operacoes">🛡 OP POE</a>
          <a href="painel.html?tab=gdo-rural">🌿 OP GDO Rural</a>
        </div>
      </div>
      <a class="topnav-link${on('criminal')}" href="analise-criminal.html" style="color:#ef5350;">🔴 ANÁLISE CRIMINAL</a>
      <a class="topnav-link${on('relatorio')}" href="meus-relatorios.html">📄 RELATÓRIO DIÁRIO</a>
      <a class="topnav-link${on('demandas')}" href="denuncias.html">📋 CONTROLE DE DEMANDAS</a>
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

    // Dropdowns (OPERAÇÃO / ADM)
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

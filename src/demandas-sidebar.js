/* ══════════════════════════════════════════════════════════════════════
   demandas-sidebar.js — barra lateral COMPARTILHADA do hub Controle de Demandas.
   Padrão visual unificado "Relatório Diário" (.rd-sidebar): recolhível, com
   tooltips quando recolhida e faixa horizontal no mobile (CSS em global.css).

   Uso na página (auth.js antes; CSS .rd-sidebar vem do global.css):
     <aside class="rd-sidebar" id="demandas-sidebar"></aside>
     <script src="demandas-sidebar.js"></script>

   O item ativo é inferido pela URL (não precisa configurar nada):
     denuncias.html?tipo=denuncia|requisicao
     materiais-tco-semad.html?aba=TCO|SEMAD
     relatorio-demandas.html
   ══════════════════════════════════════════════════════════════════════ */
(function(){
  function montar(){
    const mount = document.getElementById('demandas-sidebar');
    if (!mount) return;

    // garante a classe do componente padrão (mesmo se a página trouxer .sidebar antiga)
    mount.classList.remove('sidebar');
    mount.classList.add('rd-sidebar');

    const sessao = (typeof sessaoLer === 'function') ? sessaoLer() : null;
    const isAG = !!(sessao && sessao.nivel_acesso === 'admin_geral');

    const path = (location.pathname.split('/').pop() || '').toLowerCase();
    const qs = new URLSearchParams(location.search);
    let ativo = '';
    if (path === 'denuncias.html')                ativo = qs.get('tipo') === 'requisicao' ? 'req' : 'den';
    else if (path === 'materiais-tco-semad.html') ativo = qs.get('aba') === 'SEMAD' ? 'mat-semad' : 'mat-tco';
    else if (path === 'relatorio-demandas.html')  ativo = 'relatorio';
    const on = k => ativo === k ? ' ativo' : '';

    const item = (k, href, icone, texto) =>
      `<a class="rd-item${on(k)}" href="${href}" data-tip="${texto}"><span>${icone}</span><span class="lbl">${texto}</span></a>`;
    const soon = (icone, texto) =>
      `<div class="rd-item disabled" data-tip="${texto}"><span>${icone}</span><span class="lbl">${texto}</span><span class="soon">EM BREVE</span></div>`;

    mount.innerHTML = `
      <div class="rd-sidebar-head">
        <span class="rd-sidebar-titulo">DEMANDAS</span>
        <button class="rd-btn-colapsar" id="rdToggle" title="Recolher menu" aria-label="Recolher menu">◂</button>
      </div>
      ${item('den','denuncias.html?tipo=denuncia','📋','Denúncias de Balcão')}
      ${item('req','denuncias.html?tipo=requisicao','📨','Requisições')}
      ${item('mat-tco','materiais-tco-semad.html?aba=TCO','📦','Materiais Acautelados - TCO')}
      ${item('mat-semad','materiais-tco-semad.html?aba=SEMAD','♻️','Materiais Acautelados - SEMAD')}
      ${soon('🌳','IEF / SISFIS')}
      ${soon('🏞️','Unid. Conservação')}
      ${soon('🚨','Emergências Amb.')}
      ${soon('✉️','Ofícios Expedidos')}
      ${soon('🗂️','DADOC / Protocolos')}
      ${isAG ? item('relatorio','relatorio-demandas.html','📊','Relatório') : ''}`;

    // recolher (persistente, mesma chave das telas de Relatório Diário)
    const btn = document.getElementById('rdToggle');
    if (localStorage.getItem('rd_sidebar_colapsada') === '1'){ mount.classList.add('colapsada'); btn.textContent = '▸'; }
    btn.addEventListener('click', () => {
      mount.classList.toggle('colapsada');
      const c = mount.classList.contains('colapsada');
      btn.textContent = c ? '▸' : '◂';
      localStorage.setItem('rd_sidebar_colapsada', c ? '1' : '0');
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', montar);
  else montar();
})();

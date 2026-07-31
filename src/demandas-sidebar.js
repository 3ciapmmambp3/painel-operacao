/* ══════════════════════════════════════════════════════════════════════
   demandas-sidebar.js — barra lateral COMPARTILHADA do hub Controle de Demandas.

   Uso na página (auth.js antes; CSS .sidebar/.mod vem do global.css):
     <aside class="sidebar" id="demandas-sidebar"></aside>
     <script src="demandas-sidebar.js"></script>

   O item ativo é inferido pela URL (não precisa configurar nada):
     denuncias.html?tipo=denuncia|requisicao
     materiais-tco-semad.html?aba=TCO|SEMAD
     relatorio-demandas.html
   Mexer nos módulos aqui reflete em TODAS as telas do hub — sem cópias divergentes.
   ══════════════════════════════════════════════════════════════════════ */
(function(){
  function montar(){
    const mount = document.getElementById('demandas-sidebar');
    if (!mount) return;

    const sessao = (typeof sessaoLer === 'function') ? sessaoLer() : null;
    const isAG = !!(sessao && sessao.nivel_acesso === 'admin_geral');

    const path = (location.pathname.split('/').pop() || '').toLowerCase();
    const qs = new URLSearchParams(location.search);
    let ativo = '';
    if (path === 'denuncias.html')            ativo = qs.get('tipo') === 'requisicao' ? 'req' : 'den';
    else if (path === 'materiais-tco-semad.html') ativo = qs.get('aba') === 'SEMAD' ? 'mat-semad' : 'mat-tco';
    else if (path === 'relatorio-demandas.html')  ativo = 'relatorio';
    const on = k => ativo === k ? ' on' : '';

    const soon = (i,t) => `<div class="mod disabled"><span class="mi">${i}</span> ${t} <span class="soon">EM BREVE</span></div>`;

    mount.innerHTML = `
      <div class="stt">Controle de Demandas</div>
      <a class="mod${on('den')}" href="denuncias.html?tipo=denuncia"><span class="mi">📋</span> Denúncias de Balcão</a>
      <a class="mod${on('req')}" href="denuncias.html?tipo=requisicao"><span class="mi">📨</span> Requisições</a>
      <a class="mod${on('mat-tco')}" href="materiais-tco-semad.html?aba=TCO"><span class="mi">📦</span> Materiais Acautelados - TCO</a>
      <a class="mod${on('mat-semad')}" href="materiais-tco-semad.html?aba=SEMAD"><span class="mi">♻️</span> Materiais Acautelados - SEMAD</a>
      ${soon('🌳','IEF / SISFIS')}
      ${soon('🏞️','Unid. Conservação')}
      ${soon('🚨','Emergências Amb.')}
      ${soon('✉️','Ofícios Expedidos')}
      ${soon('🗂️','DADOC / Protocolos')}
      ${isAG ? `<div class="stt" style="margin-top:14px">Gestão</div>
      <a class="mod${on('relatorio')}" href="relatorio-demandas.html"><span class="mi">📊</span> Relatório</a>` : ''}`;
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', montar);
  else montar();
})();

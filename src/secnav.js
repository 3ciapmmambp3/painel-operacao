/* ══════════════════════════════════════════════════════════════════════
   secnav.js — sidebar secundária POR SEÇÃO (componente reutilizável).

   Uso na página (auth.js precisa vir ANTES; deve haver um .page-layout):
     <script src="auth.js"></script>
     ...
     <div class="page-layout">
       <div class="rd-conteudo"> ... </div>
     </div>
     <script src="secnav.js" data-secao="p1"></script>

   data-secao = p1 | p3 | p4 (a seção "dona" da página atual).
   O componente insere <aside class="rd-sidebar"> como PRIMEIRO filho do
   .page-layout, mostrando SÓ os módulos daquela seção. O item ativo é
   inferido pela página atual (URL). O CSS vem do global.css (.rd-sidebar).
   Fonte única — mexer aqui reflete em TODAS as páginas da mesma seção.
   ══════════════════════════════════════════════════════════════════════ */
(function(){
  const cur = document.currentScript;
  const secao = (cur && cur.dataset.secao) || '';
  const page  = (location.pathname.split('/').pop() || '').toLowerCase();

  const sessao = (typeof sessaoLer === 'function') ? sessaoLer() : null;
  const nivel  = sessao ? (sessao.nivel_acesso || '') : '';
  const funcao = ((sessao && sessao.funcao) || '').toLowerCase();
  const grup   = ((sessao && sessao.grupamento_id) || '').toUpperCase();

  // Mesmas regras de gating que existiam nas páginas (não afrouxar).
  const podeGerenciarTTA = nivel === 'admin_geral' || (funcao === 'aux p1' && grup === 'ADM');
  const podeGerenciarVtr = nivel === 'admin_geral' || funcao.indexOf('aux p4') === 0;

  // Módulos de cada seção (espelham os cards do hub). show:() => oculta quando falso.
  const SECOES = {
    p1: { titulo: 'RECURSOS HUMANOS', itens: [
      {ic:'🎯', t:'TTA (Pré-turno)', h:'tta.html'},
      {ic:'🗂️', t:'Meus TTA',        h:'meus-tta.html'},
      {ic:'⚙️', t:'Gestão do TTA',   h:'tta-gestao.html', show:()=>podeGerenciarTTA},
    ]},
    p3: { titulo: 'EMPREGO OPERACIONAL', itens: [
      {ic:'➕', t:'Novo Relatório',      h:'relatorio-servico.html'},
      {ic:'📄', t:'Lista de Relatórios', h:'meus-relatorios.html'},
      {ic:'📊', t:'Produtividade',       h:'produtividade.html'},
    ]},
    p4: { titulo: 'APOIO LOGÍSTICO', itens: [
      {ic:'🚔', t:'Movimentação de Viaturas', h:'movimentacao-viaturas.html'},
      {ic:'📋', t:'Minhas Movimentações',     h:'minhas-movimentacoes.html'},
      {ic:'⚙️', t:'Gestão de Viaturas',       h:'viaturas-gestao.html', show:()=>podeGerenciarVtr},
      {ic:'⛽', t:'Abastecimento',      h:'abastecimento.html', show:()=>podeGerenciarVtr},
      {ic:'🔧', t:'Revisão da frota',          h:'revisao-frota.html'},
      {ic:'⚠️', t:'Acidentes',                 h:'acidentes.html', show:()=>podeGerenciarVtr},
      {ic:'🔫', t:'SAT',                       h:'https://armamento.bpmmamb.com.br', ext:true},
      {ic:'📦', t:'CPELOG',                    h:'https://inventario.cpelog.com.br/login', ext:true},
      {ic:'🛸', t:'Pilotos de Drone',          h:'https://pilotodrone.bpmmamb.com.br/', ext:true},
      {ic:'🧭', t:'SIGA CPE',                  h:'https://p4.bpmmamb.com.br', ext:true},
    ]},
  };

  const conf = SECOES[secao];
  if (!conf) return;

  function montar(){
  const itensHTML = conf.itens
    .filter(m => !m.show || m.show())
    .map(m => {
      if (m.ext) {
        // Link externo: nova aba, marcador ↗, sem "ativo".
        return `<a class="rd-item" href="${m.h}" target="_blank" rel="noopener noreferrer" data-tip="${m.t}"><span>${m.ic}</span><span class="lbl">${m.t}</span><span style="margin-left:auto;font-size:9px;opacity:.6">↗</span></a>`;
      }
      const ativo = (m.h.toLowerCase() === page) ? ' ativo' : '';
      return `<a class="rd-item${ativo}" href="${m.h}" data-tip="${m.t}"><span>${m.ic}</span><span class="lbl">${m.t}</span></a>`;
    }).join('');

  const aside = document.createElement('aside');
  aside.className = 'rd-sidebar';
  aside.id = 'rdSidebar';
  aside.innerHTML =
    `<div class="rd-sidebar-head">` +
      `<span class="rd-sidebar-titulo">${conf.titulo}</span>` +
      `<button class="rd-btn-colapsar" id="rdBtnColapsar" aria-label="Recolher menu">◂</button>` +
    `</div>` + itensHTML;

  const layout = document.querySelector('.page-layout') || document.querySelector('.rd-shell');
  if (!layout) return;
  layout.insertAdjacentElement('afterbegin', aside);

  // Colapsar (persistente entre páginas, mesma chave de antes).
  const btn = document.getElementById('rdBtnColapsar');
  if (localStorage.getItem('rd_sidebar_colapsada') === '1') { aside.classList.add('colapsada'); btn.textContent = '▸'; }
  btn.addEventListener('click', () => {
    aside.classList.toggle('colapsada');
    const c = aside.classList.contains('colapsada');
    btn.textContent = c ? '▸' : '◂';
    localStorage.setItem('rd_sidebar_colapsada', c ? '1' : '0');
  });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', montar);
  else montar();
})();

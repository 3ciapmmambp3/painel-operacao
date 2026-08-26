/* ══════════════════════════════════════════════════════════════════════
   topnav.js — barra de navegação superior COMPARTILHADA (hubs por seção).

   Uso na página (auth.js precisa vir ANTES):
     <script src="auth.js"></script>
     <script src="topnav.js" data-ativo="p3"></script>

   data-ativo marca o item atual:
     meudia | visaogeral | p1 | p2 | p3 | p4 | p5 | consulta | adm
   Se omitido, a aba ativa é inferida da URL (detectarAtivo).
   A barra é inserida logo após o <header> da página (ou no topo do body,
   se não houver header). O CSS vem do global.css (.topnav / .hubdot).

   Barra: MEU DIA · VISÃO GERAL · P1 · P2 · P3 · P4 · P5 · GESTÃO OPERACIONAL · ADM
   (GESTÃO OPERACIONAL = hub-go.html, só p/ admin; Consulta saiu da barra —
    agora vive em "Links úteis" do Meu Dia.)
   Fonte única — mexer aqui reflete em TODAS as páginas; página nova é só
   incluir este script (não há risco de esquecer um item).
   ══════════════════════════════════════════════════════════════════════ */
(function(){
  const cur = document.currentScript;
  const ativoAttr = (cur && cur.dataset.ativo) || '';

  // Resolve a aba ativa pela URL quando a página não informa data-ativo.
  // Necessário porque painel.html serve VÁRIAS abas (?tab=) com o mesmo script.
  function detectarAtivo(){
    const p = (location.pathname.split('/').pop() || '').toLowerCase();
    if (p === 'inicio.html') return 'meudia';
    const mHub = p.match(/^hub-(p[1-5])\.html$/);
    if (mHub) return mHub[1];
    if (p === 'agenda.html'){
      const s = new URLSearchParams(location.search).get('secao');
      if (/^p[1-5]$/.test(s||'')) return s;
    }
    if (p === 'hub-go.html') return 'go';
    // analise-criminal.html é "dual-home": Inteligência pertence à P2, o
    // resto (Ocorrências, Mapa, Auditorias…) à P3. O parâmetro ?sub decide.
    if (p === 'analise-criminal.html'){
      const sub = new URLSearchParams(location.search).get('sub');
      return sub === 'inteligencia' ? 'p2' : 'p3';
    }
    // admin.html: os painéis de cadastro (Metas/Operações/PAF/FAPI/Quesitos)
    // pertencem à P3 (abertos pelos cards "Gestão e Cadastros" do hub-p3);
    // sem ?tab (ou Relatórios/Importação) é a área de Administração (ADM).
    if (p === 'admin.html'){
      const t = new URLSearchParams(location.search).get('tab') || '';
      if (['metas','operacoes','paf','fapi','quesitos'].includes(t)) return 'p3';
      return 'adm';
    }
    if (p === 'painel.html'){
      const t = new URLSearchParams(location.search).get('tab') || '';
      if (t === 'consulta') return 'consulta';
      // OP POE (operacoes) e OP GDO Rural (gdo-rural) são análise operacional → P3.
      if (['operacoes','gdo-rural'].includes(t)) return 'p3';
      if (['relatorios','importacao'].includes(t)) return 'adm';
      return 'visaogeral';
    }
    return '';
  }
  const ativo = ativoAttr || detectarAtivo();

  // Módulos de cada aba (para o menu suspenso). Espelha os cards dos hubs.
  // A "Agenda da Seção" NÃO entra aqui (é gated por membro — fica só no hub).
  const MODULOS = {
    p1: [
      {ic:'👥', t:'Efetivo', soon:true},
      {ic:'🗓️', t:'TTA — Treinamento Tático', h:'tta.html'},
      {ic:'🏖️', t:'Férias', soon:true},
      {ic:'📰', t:'Publicações', soon:true},
    ],
    p2: [
      {ic:'🕵', t:'Inteligência', h:'analise-criminal.html?sub=inteligencia'},
      {ic:'🧩', t:'Produção de Conhecimento', soon:true},
      {ic:'🎯', t:'Alvos e Monitoramento', soon:true},
      {ic:'📈', t:'Estatística Criminal', soon:true},
    ],
    p3: [
      {ic:'📄', t:'Relatório de Serviço', h:'meus-relatorios.html'},
      {ic:'📋', t:'Controle de Demandas', h:'denuncias.html'},
      {ic:'🛡️', t:'Operações POE', h:'painel.html?tab=operacoes'},
      {ic:'🌿', t:'Operações GDO Rural', h:'painel.html?tab=gdo-rural'},
      {ic:'📊', t:'Produtividade', h:'produtividade.html'},
      {ic:'🔴', t:'Análise Criminal', h:'analise-criminal.html'},
      {ic:'📊', t:'Metas', h:'admin.html?tab=metas'},
      {ic:'🎯', t:'Cadastro de Operações', h:'admin.html?tab=operacoes'},
      {ic:'🌲', t:'PAF', h:'admin.html?tab=paf'},
      {ic:'🏭', t:'FAPI', h:'admin.html?tab=fapi'},
      {ic:'📋', t:'Campos e Quesitos', h:'admin.html?tab=quesitos'},
    ],
    p4: [
      {ic:'📝', t:'Movimentação de Viaturas', h:'movimentacao-viaturas.html'},
      {ic:'📋', t:'Minhas Movimentações', h:'minhas-movimentacoes.html'},
      {ic:'🚔', t:'Gestão de Viaturas', h:'viaturas-gestao.html'},
      {ic:'⛽', t:'Abastecimento', h:'abastecimento.html'},
      {ic:'🔧', t:'Revisão da frota', h:'revisao-frota.html'},
      {ic:'⚠️', t:'Acidentes', h:'acidentes.html'},
      {ic:'🔫', t:'SAT', h:'https://armamento.bpmmamb.com.br', ext:true},
      {ic:'📦', t:'CPELOG', h:'https://inventario.cpelog.com.br/login', ext:true},
      {ic:'🧭', t:'SIGA CPE', h:'https://p4.bpmmamb.com.br', ext:true},
      {ic:'📦', t:'Material e Patrimônio', soon:true},
    ],
    p5: [
      {ic:'📣', t:'Divulgação de Operações', soon:true},
      {ic:'📰', t:'Notícias e Releases', soon:true},
      {ic:'📱', t:'Redes e Clipping', soon:true},
    ],
    go: [
      {ic:'🎯', t:'Supervisão e Controle', h:'supervisao-controle.html'},
      {ic:'📣', t:'Chamada de Instrução', h:'chamada-instrucao.html'},
      {ic:'📊', t:'Painel de Demandas', soon:true},
    ],
  };

  function montar(){
    const sessao = (typeof sessaoLer === 'function') ? sessaoLer() : null;
    const nivel  = sessao ? sessao.nivel_acesso : 'operacional';
    const isAdmin = ['admin_geral','admin','admin_pelotao','admin_gp'].includes(nivel);
    // Gestão Operacional (Supervisão e Controle) = mesma regra da página: sem admin_gp.
    const podeGO = ['admin_geral','admin','admin_pelotao'].includes(nivel);
    const on = k => ativo===k ? ' active' : '';

    // Aba com menu suspenso (mega): clicar no nome vai ao hub; passar o mouse
    // mostra os módulos daquela seção pra ir direto, de qualquer página.
    const tab = (k, href, rot) => {
      const itens = (MODULOS[k]||[]).map(m => m.soon
        ? `<span class="tn-soon"><span class="tn-ic">${m.ic}</span>${m.t}<em>em breve</em></span>`
        : m.ext
          ? `<a href="${m.h}" target="_blank" rel="noopener noreferrer"><span class="tn-ic">${m.ic}</span>${m.t}<em style="margin-left:auto;font-style:normal;opacity:.6">↗</em></a>`
          : `<a href="${m.h}"><span class="tn-ic">${m.ic}</span>${m.t}</a>`).join('');
      return `<div class="topnav-item tn-has">
          <a class="topnav-link${on(k)}" href="${href}">${rot} <span class="chev">▾</span></a>
          <div class="topnav-dropdown tn-mega">${itens}</div>
        </div>`;
    };

    const nav = document.createElement('nav');
    nav.className = 'topnav';
    nav.id = 'topnav';
    nav.innerHTML = `
      <a class="topnav-link${on('meudia')}" href="inicio.html">☀️ MEU DIA</a>
      <a class="topnav-link${on('visaogeral')}" href="painel.html?tab=inicio">📊 VISÃO GERAL</a>
      ${tab('p1','hub-p1.html','<span class="hubdot hub-p1"></span> RECURSOS HUMANOS')}
      ${tab('p2','hub-p2.html','<span class="hubdot hub-p2"></span> INTELIGÊNCIA')}
      ${tab('p3','hub-p3.html','<span class="hubdot hub-p3"></span> EMPREGO OPERACIONAL')}
      ${tab('p4','hub-p4.html','<span class="hubdot hub-p4"></span> APOIO LOGÍSTICO')}
      ${tab('p5','hub-p5.html','<span class="hubdot hub-p5"></span> COMUNICAÇÃO ORGANIZACIONAL')}
      ${podeGO ? tab('go','hub-go.html','🎛️ GESTÃO OPERACIONAL') : ''}
      <div class="topnav-item" id="admTopnavItem" style="display:${isAdmin?'':'none'};">
        <div class="topnav-link${on('adm')}" data-dropdown="ddAdm">⚙ ADM <span class="chev">▾</span></div>
        <div class="topnav-dropdown" id="ddAdm">
          <a href="painel.html?tab=relatorios">📋 Relatórios</a>
          ${nivel==='admin_geral' ? '<a href="painel.html?tab=importacao">📥 Importação</a>' : ''}
          ${nivel==='admin_geral' ? '<a href="admin.html">⚙️ Administração</a>' : ''}
        </div>
      </div>`;

    // CSS do mega-menu (uma vez): abre no hover; itens com ícone; "em breve" apagado.
    if(!document.getElementById('tn-mega-css')){
      const st=document.createElement('style'); st.id='tn-mega-css';
      st.textContent =
        // Barra fixa ao rolar (fica no topo). Injetado aqui p/ vencer os
        // `.topnav{position:relative}` inline de cada página. z-index alto p/
        // ficar acima do conteúdo, abaixo dos modais (9999) e do hover (9990).
        '.topnav{position:sticky;top:0;z-index:900;}'+
        '.topnav-item:hover > .topnav-dropdown{display:block;}'+
        // Enquanto um mega-menu está aberto (hover), a barra sobe acima do conteúdo
        // da página (o painel POE/GDO Rural tem cards com z-index alto que tapavam o menu).
        '.topnav.tn-megaopen{z-index:9990;}'+
        '.topnav-dropdown.tn-mega{min-width:252px;z-index:9990;}'+
        '.topnav-dropdown a,.topnav-dropdown .tn-soon{display:flex;align-items:center;gap:8px;padding:9px 12px;font-size:12.5px;border-radius:6px;white-space:nowrap;}'+
        '.topnav-dropdown .tn-ic{width:18px;text-align:center;flex-shrink:0;}'+
        '.topnav-dropdown .tn-soon{color:var(--text-hint);cursor:default;}'+
        '.topnav-dropdown .tn-soon em{margin-left:auto;font-style:normal;font-size:9px;font-weight:700;text-transform:uppercase;letter-spacing:.4px;border:1px solid var(--border);border-radius:4px;padding:1px 5px;color:var(--text-hint);}';
      document.head.appendChild(st);
    }

    const header = document.querySelector('header');
    if (header && header.parentNode) {
      header.insertAdjacentElement('afterend', nav);
      // Fixa o header (brasões) e a barra no topo. Aplicado INLINE (não via CSS)
      // para vencer o `.topnav{position:relative}` que algumas páginas têm inline.
      header.style.position = 'sticky';
      header.style.top = '0';
      header.style.zIndex = '901';
      nav.style.position = 'sticky';
      nav.style.zIndex = '900';
      const ajustarTop = () => { nav.style.top = (header.offsetHeight || 0) + 'px'; };
      ajustarTop();
      window.addEventListener('resize', ajustarTop);
    } else {
      document.body.insertAdjacentElement('afterbegin', nav);
    }

    // Mega-menu (hover): eleva a barra acima do conteúdo enquanto aberto.
    nav.querySelectorAll('.topnav-item.tn-has').forEach(it => {
      it.addEventListener('mouseenter', () => nav.classList.add('tn-megaopen'));
      it.addEventListener('mouseleave', () => nav.classList.remove('tn-megaopen'));
    });

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

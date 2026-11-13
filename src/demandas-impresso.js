/* ══════════════════════════════════════════════════════════════════════
   demandas-impresso.js — marcador GLOBAL "impressa" por demanda.
   Qualquer militar do grupamento marca/desmarca (🖨 na linha); todos veem.
   Chave = (tabela, codigo). Usa globais do módulo: SB_AUTH_URL, SB_AUTH_KEY,
   e S (sessão com .token). Backend: db/189 (tabela demandas_impressas + RPC
   demanda_impresso_set). Incluído por mc/nuden/ri/ddu/emergencia/denuncias.
   Uso no módulo:
     1) após carregar a lista:  await Impresso.carregar('<tabela>', codigos[])
     2) na linha da tabela:     ${Impresso.icone(codigo)}
   ══════════════════════════════════════════════════════════════════════ */
(function (global) {
  'use strict';
  var St = { tabela: '', map: new Map() };   // codigo -> {por_nome, em}

  function _key() { return (typeof SB_AUTH_KEY !== 'undefined') ? SB_AUTH_KEY : ''; }
  function _api() { return (typeof SB_AUTH_URL !== 'undefined') ? SB_AUTH_URL : ''; }
  function _H() { var k = _key(); return { apikey: k, Authorization: 'Bearer ' + k, 'Content-Type': 'application/json' }; }
  function _tok() { try { return (typeof S !== 'undefined' && S) ? S.token : null; } catch (e) { return null; } }
  function _esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]; }); }
  function _fmt(iso) { if (!iso) return ''; var p = String(iso).slice(0, 10).split('-'); return p.length === 3 ? (p[2] + '/' + p[1] + '/' + p[0]) : ''; }

  // Busca só as demandas MARCADAS da tabela (a tabela demandas_impressas só tem as
  // que alguém marcou → é pequena). 1 requisição (pagina só se passar de 1000 marcadas).
  // O 2º arg (codigos) é ignorado — mantido p/ compatibilidade com as chamadas.
  async function carregar(tabela, _codigos) {
    St.tabela = tabela; St.map = new Map();
    if (!_api()) return;
    try {
      for (var off = 0; off < 50000; off += 1000) {
        var url = _api() + '/rest/v1/demandas_impressas?tabela=eq.' + encodeURIComponent(tabela) + '&select=codigo,por_nome,em';
        var r = await fetch(url, { headers: Object.assign({}, _H(), { 'Range-Unit': 'items', 'Range': off + '-' + (off + 999) }) });
        if (!r.ok) break;
        var arr = await r.json();
        if (!Array.isArray(arr) || !arr.length) break;
        arr.forEach(function (x) { if (x && x.codigo != null) St.map.set(String(x.codigo), { por_nome: x.por_nome || '', em: x.em || '' }); });
        if (arr.length < 1000) break;
      }
    } catch (e) { console.warn('[impresso] carregar', e); }
  }

  function marcada(codigo) { return St.map.has(String(codigo == null ? '' : codigo)); }

  function _tip(on, info) {
    return on
      ? ('Impressa por ' + _esc((info && info.por_nome) || '—') + (info && info.em ? (' em ' + _fmt(info.em)) : '') + ' — clique p/ desmarcar')
      : 'Clique p/ marcar como impressa';
  }
  // Controle estilo checkbox com rótulo "Impresso" (☐/☑), p/ ficar claro e visível.
  function icone(codigo) {
    var c = String(codigo == null ? '' : codigo);
    var on = St.map.has(c), info = on ? St.map.get(c) : null;
    return '<span class="imp-chk' + (on ? ' on' : '') + '" role="button" title="' + _tip(on, info) +
      '" onclick="event.stopPropagation();Impresso.toggle(this,\'' + c.replace(/'/g, "\\'") + '\')">' +
      '<span class="imp-box">' + (on ? '✔' : '') + '</span><span class="imp-lbl">Impresso</span></span>';
  }

  async function toggle(el, codigo) {
    var c = String(codigo == null ? '' : codigo); if (!c) return;
    var tok = _tok();
    if (!tok) { alert('Sessão expirada. Faça login novamente.'); return; }
    var novo = !St.map.has(c);
    if (novo) St.map.set(c, { por_nome: 'você', em: new Date().toISOString() }); else St.map.delete(c);
    _paint(el, novo);
    try {
      var r = await fetch(_api() + '/rest/v1/rpc/demanda_impresso_set', {
        method: 'POST', headers: _H(),
        body: JSON.stringify({ p_token: tok, p_tabela: St.tabela, p_codigo: c, p_impresso: novo })
      });
      if (!r.ok) throw new Error(await r.text());
    } catch (e) {
      if (novo) St.map.delete(c); else St.map.set(c, { por_nome: '', em: '' });
      _paint(el, !novo);
      alert('Não consegui salvar o marcador de impressão: ' + (e.message || e));
    }
  }
  function _paint(el, on) {
    if (!el) return;
    el.classList.toggle('on', on);
    var box = el.querySelector('.imp-box'); if (box) box.textContent = on ? '✔' : '';
    el.title = on ? 'Impressa — clique p/ desmarcar' : 'Clique p/ marcar como impressa';
  }

  // CSS próprio (não depende do módulo).
  try {
    var st = document.createElement('style');
    st.textContent =
      '.imp-chk{display:inline-flex;align-items:center;gap:6px;cursor:pointer;user-select:none;' +
      'font-size:12px;font-weight:700;color:var(--text-muted,#9a9aa2);padding:4px 9px;border-radius:7px;' +
      'border:1px solid var(--border-mid,#444);white-space:nowrap;line-height:1}' +
      '.imp-chk:hover{color:var(--text-white,#ddd);border-color:#777}' +
      '.imp-box{width:16px;height:16px;border-radius:4px;border:1.5px solid #888;display:inline-flex;' +
      'align-items:center;justify-content:center;font-size:12px;line-height:1;color:#fff}' +
      '.imp-chk.on{color:#2e9e46;border-color:#2e9e46;background:rgba(46,158,70,.14)}' +
      '.imp-chk.on .imp-box{background:#2e9e46;border-color:#2e9e46}';
    (document.head || document.documentElement).appendChild(st);
  } catch (e) { }

  global.Impresso = { carregar: carregar, icone: icone, toggle: toggle, marcada: marcada };
})(window);

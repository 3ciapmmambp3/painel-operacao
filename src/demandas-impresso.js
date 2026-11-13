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

  async function carregar(tabela, codigos) {
    St.tabela = tabela; St.map = new Map();
    var cods = Array.from(new Set((codigos || []).map(function (c) { return String(c == null ? '' : c); }).filter(Boolean)));
    if (!cods.length || !_api()) return;
    try {
      for (var i = 0; i < cods.length; i += 200) {
        var slice = cods.slice(i, i + 200);
        var inVal = '(' + slice.map(function (c) { return '"' + c.replace(/"/g, '') + '"'; }).join(',') + ')';
        var url = _api() + '/rest/v1/demandas_impressas?tabela=eq.' + encodeURIComponent(tabela) +
          '&codigo=in.' + encodeURIComponent(inVal) + '&select=codigo,por_nome,em';
        var r = await fetch(url, { headers: _H() });
        if (!r.ok) continue;
        (await r.json()).forEach(function (x) { if (x && x.codigo != null) St.map.set(String(x.codigo), { por_nome: x.por_nome || '', em: x.em || '' }); });
      }
    } catch (e) { console.warn('[impresso] carregar', e); }
  }

  function marcada(codigo) { return St.map.has(String(codigo == null ? '' : codigo)); }

  function icone(codigo) {
    var c = String(codigo == null ? '' : codigo);
    var on = St.map.has(c), info = on ? St.map.get(c) : null;
    var tip = on
      ? ('Impressa por ' + _esc(info.por_nome || '—') + (info.em ? (' em ' + _fmt(info.em)) : '') + ' — clique p/ desmarcar')
      : 'Marcar como impressa';
    return '<span class="imp-ic' + (on ? ' on' : '') + '" role="button" title="' + tip +
      '" onclick="event.stopPropagation();Impresso.toggle(this,\'' + c.replace(/'/g, "\\'") + '\')">🖨</span>';
  }

  async function toggle(el, codigo) {
    var c = String(codigo == null ? '' : codigo); if (!c) return;
    var tok = _tok();
    if (!tok) { alert('Sessão expirada. Faça login novamente.'); return; }
    var novo = !St.map.has(c);
    if (novo) St.map.set(c, { por_nome: 'você', em: new Date().toISOString() }); else St.map.delete(c);
    if (el) { el.classList.toggle('on', novo); el.title = novo ? 'Impressa — clique p/ desmarcar' : 'Marcar como impressa'; }
    try {
      var r = await fetch(_api() + '/rest/v1/rpc/demanda_impresso_set', {
        method: 'POST', headers: _H(),
        body: JSON.stringify({ p_token: tok, p_tabela: St.tabela, p_codigo: c, p_impresso: novo })
      });
      if (!r.ok) throw new Error(await r.text());
    } catch (e) {
      if (novo) St.map.delete(c); else St.map.set(c, { por_nome: '', em: '' });
      if (el) el.classList.toggle('on', !novo);
      alert('Não consegui salvar o marcador de impressão: ' + (e.message || e));
    }
  }

  // CSS próprio (não depende do módulo).
  try {
    var st = document.createElement('style');
    st.textContent =
      '.imp-ic{cursor:pointer;opacity:.33;filter:grayscale(1);font-size:15px;line-height:1;' +
      'padding:1px 3px;border-radius:5px;user-select:none;transition:opacity .12s}' +
      '.imp-ic:hover{opacity:.7}' +
      '.imp-ic.on{opacity:1;filter:none;background:rgba(201,162,74,.18);box-shadow:inset 0 0 0 1px rgba(201,162,74,.5)}';
    (document.head || document.documentElement).appendChild(st);
  } catch (e) { }

  global.Impresso = { carregar: carregar, icone: icone, toggle: toggle, marcada: marcada };
})(window);

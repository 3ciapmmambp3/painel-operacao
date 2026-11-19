/* ──────────────────────────────────────────────────────────────────────
   harpia-camadas.js — DESCOBRIDOR de camadas do GeoServer do Harpia (SCCON)
   Roda NA PÁGINA do Harpia (alertas.sccon.com.br) via bookmarklet, onde o
   acesso ao GeoServer é liberado pelo Referer — de fora dá 403.

   Objetivo: listar os typeNames (camadas) publicados, pra sabermos se existem
   camadas de APP / Reserva Legal / Cobertura do Solo (além da base_sicar_mg do
   imóvel). Só LEITURA de catálogo (GetCapabilities) — não altera nada.
   O resultado aparece numa caixa, com botão de copiar pra mandar de volta.
   ────────────────────────────────────────────────────────────────────── */
(function(){
  if (window.__harpiaCamadasRodando){ return; }
  window.__harpiaCamadasRodando = true;

  // Endpoints de catálogo a tentar (workspace semad-mg + global).
  var BASES = [
    'https://geoserver-dashboard.sccon.com.br/geoserver/semad-mg/wfs',
    'https://geoserver-dashboard.sccon.com.br/geoserver/wfs',
    'https://geoserver.meioambiente.mg.gov.br/IDE/wfs'
  ];
  // Palavras que interessam (passivo ambiental / CAR).
  var ALVO = /(app|preserv|reserva|legal|cobertura|solo|vegeta|uso[_ ]?restr|servid|sicar|imovel|imóvel|hidrog|nascente|car\b)/i;

  function esc(s){ return String(s==null?'':s).replace(/[&<>]/g,function(c){return c==='&'?'&amp;':c==='<'?'&lt;':'&gt;';}); }

  // ── Caixa de saída ────────────────────────────────────────────────────
  var old = document.getElementById('__harpiaCamadasBox'); if (old) old.remove();
  var box = document.createElement('div'); box.id = '__harpiaCamadasBox';
  box.style.cssText = 'position:fixed;top:20px;right:20px;z-index:2147483647;width:420px;max-width:92vw;max-height:84vh;overflow:auto;'
    + 'background:#13161c;color:#e8e8e8;border:1px solid #c9a227;border-radius:12px;padding:14px 16px;'
    + 'font:13px/1.5 Arial,Helvetica,sans-serif;box-shadow:0 16px 48px rgba(0,0,0,.5)';
  box.innerHTML = '<div style="display:flex;align-items:center;gap:8px;margin-bottom:8px">'
    + '<b style="color:#e7c84f;font-size:14px;flex:1">🔎 Camadas do Harpia</b>'
    + '<button id="__hcCopy" style="background:#1f8a4c;color:#fff;border:0;border-radius:6px;padding:5px 9px;cursor:pointer;font-weight:700">📋 Copiar</button>'
    + '<button id="__hcClose" style="background:#333;color:#fff;border:0;border-radius:6px;padding:5px 9px;cursor:pointer">✕</button></div>'
    + '<div id="__hcMsg" style="margin-bottom:8px;color:#b9c2cf">Lendo o catálogo…</div>'
    + '<div id="__hcOut"></div>';
  document.body.appendChild(box);
  var fim = function(){ window.__harpiaCamadasRodando = false; };
  document.getElementById('__hcClose').onclick = function(){ box.remove(); fim(); };

  var textoCopia = '';
  document.getElementById('__hcCopy').onclick = function(){
    try{ navigator.clipboard.writeText(textoCopia); this.textContent = '✔ Copiado'; }
    catch(e){ var t=document.createElement('textarea'); t.value=textoCopia; document.body.appendChild(t); t.select(); document.execCommand('copy'); t.remove(); this.textContent='✔ Copiado'; }
  };

  function setMsg(h){ var el=document.getElementById('__hcMsg'); if(el) el.innerHTML=h; }

  // ── Lê e parseia um GetCapabilities ───────────────────────────────────
  async function lerBase(base){
    var url = base + '?service=WFS&version=1.1.0&request=GetCapabilities';
    try{
      var r = await fetch(url, { credentials:'include' });
      if (!r.ok){ return { base:base, erro:'HTTP '+r.status, nomes:[] }; }
      var txt = await r.text();
      // pega <Name>…</Name> dentro de FeatureType; também captura o <Title> seguinte
      var nomes = [];
      var re = /<(?:[a-z]+:)?FeatureType\b[\s\S]*?<(?:[a-z]+:)?Name>([^<]+)<\/(?:[a-z]+:)?Name>(?:[\s\S]*?<(?:[a-z]+:)?Title>([^<]*)<\/(?:[a-z]+:)?Title>)?/gi;
      var m;
      while ((m = re.exec(txt))){ nomes.push({ nome:m[1], titulo:m[2]||'' }); }
      // fallback: se o regex de FeatureType não casou, pega todos os <Name>
      if (!nomes.length){
        var re2 = /<(?:[a-z]+:)?Name>([^<]+)<\/(?:[a-z]+:)?Name>/gi;
        while ((m = re2.exec(txt))){ nomes.push({ nome:m[1], titulo:'' }); }
      }
      return { base:base, erro:null, nomes:nomes };
    }catch(e){ return { base:base, erro:(e&&e.message)||String(e), nomes:[] }; }
  }

  (async function(){
    var partesCopia = [];
    var outEl = document.getElementById('__hcOut');
    var achouAlvo = 0;
    for (var i=0;i<BASES.length;i++){
      setMsg('Lendo o catálogo… (' + (i+1) + '/' + BASES.length + ')');
      var res = await lerBase(BASES[i]);
      var bloco = document.createElement('div');
      bloco.style.cssText = 'margin-bottom:12px;border-top:1px solid #2a2f38;padding-top:8px';
      var cab = '<div style="color:#9aa4b2;font-size:11px;word-break:break-all;margin-bottom:4px">' + esc(res.base) + '</div>';
      partesCopia.push('### ' + res.base);
      if (res.erro){
        cab += '<div style="color:#e0675a">⚠ ' + esc(res.erro) + '</div>';
        partesCopia.push('  ERRO: ' + res.erro);
      } else if (!res.nomes.length){
        cab += '<div style="color:#e0a04a">nenhuma camada lida</div>';
        partesCopia.push('  (nenhuma camada lida)');
      } else {
        // destaca as que batem com APP/RL/cobertura etc.
        var destaque = res.nomes.filter(function(n){ return ALVO.test(n.nome) || ALVO.test(n.titulo); });
        achouAlvo += destaque.length;
        cab += '<div style="color:#6fcf97;margin-bottom:4px"><b>' + res.nomes.length + '</b> camada(s)'
             + (destaque.length ? (' · <span style="color:#e7c84f">' + destaque.length + ' de interesse (APP/RL/cobertura)</span>') : '') + '</div>';
        var lista = res.nomes.map(function(n){
          var hit = ALVO.test(n.nome) || ALVO.test(n.titulo);
          return '<div style="padding:2px 0;' + (hit?'color:#e7c84f;font-weight:700':'color:#cfd6df') + '">'
               + (hit?'★ ':'• ') + esc(n.nome) + (n.titulo?(' <span style="color:#8b93a0;font-weight:400">— '+esc(n.titulo)+'</span>'):'') + '</div>';
        }).join('');
        cab += lista;
        partesCopia.push(res.nomes.map(function(n){ return '  ' + ((ALVO.test(n.nome)||ALVO.test(n.titulo))?'★ ':'  ') + n.nome + (n.titulo?(' — '+n.titulo):''); }).join('\n'));
      }
      bloco.innerHTML = cab;
      outEl.appendChild(bloco);
    }
    textoCopia = 'CAMADAS GEOSERVER HARPIA\n' + partesCopia.join('\n');
    setMsg(achouAlvo
      ? ('✅ Encontrei <b style="color:#e7c84f">' + achouAlvo + '</b> camada(s) de interesse (★). Clique em <b>📋 Copiar</b> e me mande.')
      : '⚠ Não achei camada separada de APP/Reserva Legal no catálogo. Clique em <b>📋 Copiar</b> e me mande mesmo assim.');
    fim();
  })();
})();

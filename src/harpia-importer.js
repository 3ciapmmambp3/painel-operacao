/* ══════════════════════════════════════════════════════════════════════
   Importador de CAR do Harpia — 3ª Cia PM MAmb
   ----------------------------------------------------------------------
   RODA NA PÁGINA DO HARPIA (alertas.sccon.com.br), via bookmarklet. O acesso
   ao CAR (base_sicar_mg) é liberado pelo Referer da página do Harpia — por isso
   só funciona aqui, e NÃO precisa de login nem senha. Para cada MC pendente
   (com coordenada e sem CAR consultado), busca o imóvel rural que contém o ponto
   e grava no banco (nome do imóvel, CPF, proprietário, área, módulos fiscais,
   município, situação). Depois os dados aparecem no painel pra todos.

   É um fetch simples, igual ao que o próprio Harpia faz — nenhuma credencial
   é usada ou spoofada. Dado pessoal (CPF/proprietário): uso funcional restrito.
   ══════════════════════════════════════════════════════════════════════ */
(function(){
  'use strict';
  if (window.__harpiaImporterRodando){ alert('O importador já está rodando. Aguarde terminar.'); return; }
  if (!/alertas\.sccon\.com\.br/.test(location.host)){
    alert('Abra o HARPIA (alertas.sccon.com.br) e rode o importador por lá.');
    return;
  }
  window.__harpiaImporterRodando = true;

  var SB_URL = 'https://zrnbebjszwkmquzthjfa.supabase.co';
  var SB_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpybmJlYmpzendrbXF1enRoamZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkzOTA4MzEsImV4cCI6MjA5NDk2NjgzMX0.di9t2SOCTLZ2uPFOnTOiy6srvt7GC5cdqenZZScXve4';            // anon key (pública — já vai no painel)
  var H = { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY };
  var WFS = 'https://geoserver-dashboard.sccon.com.br/geoserver/semad-mg/wfs';
  var PAUSA_MS = 220;                   // respiro entre consultas (não martelar)

  // ── Conserta mojibake do dado-fonte (UTF-8 lido como cp1252: "LÃºcia"→"Lúcia") ──
  var CP1252 = {'€':128,'‚':130,'ƒ':131,'„':132,'…':133,'†':134,'‡':135,'ˆ':136,'‰':137,'Š':138,'‹':139,'Œ':140,'Ž':142,'‘':145,'’':146,'“':147,'”':148,'•':149,'–':150,'—':151,'˜':152,'™':153,'š':154,'›':155,'œ':156,'ž':158,'Ÿ':159};
  function fixEnc(s){
    s = (s == null ? '' : String(s));
    if (!/[ÃÂ]./.test(s)) return s;        // sem marcador de mojibake
    try {
      var b = [], i, ch, c;
      for (i = 0; i < s.length; i++){ ch = s[i]; c = ch.charCodeAt(0); b.push(c < 256 ? c : (CP1252[ch] != null ? CP1252[ch] : 63)); }
      return new TextDecoder('utf-8').decode(new Uint8Array(b));
    } catch(e){ return s; }
  }

  // ── Overlay de progresso ──────────────────────────────────────────────
  var box = document.createElement('div');
  box.style.cssText = 'position:fixed;top:16px;right:16px;z-index:2147483647;width:360px;max-width:92vw;background:#13241b;color:#eaf1ec;border:1px solid #2f5e45;border-radius:12px;box-shadow:0 18px 50px rgba(0,0,0,.5);font:13px/1.5 Arial,Helvetica,sans-serif;overflow:hidden';
  box.innerHTML =
    '<div style="background:#1f6b45;padding:10px 14px;font-weight:800;display:flex;align-items:center;gap:8px">🌱 Importar CAR — 3ª Cia'
    + '<button id="hiClose" style="margin-left:auto;background:transparent;border:0;color:#fff;font-size:18px;cursor:pointer;line-height:1">✕</button></div>'
    + '<div style="padding:14px">'
    + '<div id="hiMsg" style="margin-bottom:10px">Procurando MCs pendentes…</div>'
    + '<div style="background:#0c1712;border-radius:8px;height:12px;overflow:hidden;border:1px solid #2f5e45"><div id="hiBar" style="height:100%;width:0;background:#49c07d;transition:width .2s"></div></div>'
    + '<div id="hiStat" style="margin-top:8px;font-size:12px;color:#9fc7b0"></div>'
    + '<div id="hiLog" style="margin-top:10px;max-height:160px;overflow:auto;font-size:11.5px;color:#cfe3d6;border-top:1px solid #244;padding-top:8px;display:none"></div>'
    + '</div>';
  document.body.appendChild(box);
  var elMsg = box.querySelector('#hiMsg'), elBar = box.querySelector('#hiBar'),
      elStat = box.querySelector('#hiStat'), elLog = box.querySelector('#hiLog');
  box.querySelector('#hiClose').onclick = function(){ window.__harpiaCancel = true; box.remove(); window.__harpiaImporterRodando = false; };
  function setMsg(t){ elMsg.innerHTML = t; }
  function setBar(p){ elBar.style.width = Math.round(p*100) + '%'; }
  function setStat(t){ elStat.textContent = t; }
  function log(t){ elLog.style.display='block'; var d=document.createElement('div'); d.textContent=t; elLog.appendChild(d); elLog.scrollTop=elLog.scrollHeight; }
  var sleep = function(ms){ return new Promise(function(r){ setTimeout(r, ms); }); };

  // ── Busca o CAR (imóvel rural) que contém o ponto ─────────────────────
  function cqlPonto(lat, lon){ return 'CONTAINS(the_geom,Point(' + lat + ' ' + lon + '))'; }
  async function buscarCar(lat, lon){
    var url = WFS + '?service=WFS&version=1.1.0&request=GetFeature&typeName=base_sicar_mg&outputFormat=application/json&CQL_FILTER=' + encodeURIComponent(cqlPonto(lat, lon));
    var r = await fetch(url);
    if (!r.ok) throw new Error('HTTP ' + r.status);
    var txt = new TextDecoder('utf-8').decode(await r.arrayBuffer());
    var j = JSON.parse(txt);
    var feats = j.features || [];
    return {
      items: feats.map(function(f){
        var p = f.properties || {};
        return {
          cod_imovel:  p.cod_imovel || '',
          municipio:   fixEnc(p.municipio),
          area:        p.num_area,
          mod_fiscal:  p.mod_fiscal,
          status:      fixEnc(p.des_condic),
          nome_imovel: fixEnc(p.nome_do_im),
          proprietario:fixEnc(p.nome_dos_p),
          cpf:         p.cpf_ou_cnp || ''
        };
      }),
      // polígono do imóvel (GeoJSON) — guardado numa coluna separada (car_geom)
      geoms: feats.map(function(f){
        return { cod_imovel: (f.properties && f.properties.cod_imovel) || '', geometry: f.geometry || null };
      }).filter(function(g){ return g.geometry; })
    };
  }

  // ── Grava no banco (na própria linha do MC) ───────────────────────────
  // car_geom pode não existir ainda (db/204 não rodado) → se o PATCH reclamar
  // da coluna, reenvia SEM ela (não perde o resto). geomOK fica false e avisa.
  var geomColOK = true;
  async function patchLinha(id, body){
    var r = await fetch(SB_URL + '/rest/v1/mc_demandas?id=eq.' + encodeURIComponent(id), {
      method: 'PATCH',
      headers: Object.assign({ 'Content-Type': 'application/json', Prefer: 'return=minimal' }, H),
      body: JSON.stringify(body)
    });
    return r;
  }
  async function salvar(id, items, geoms){
    var body = {
      car_dados: items,
      car_imovel: items.map(function(c){ return c.cod_imovel; }).filter(Boolean).join(', ') || null,
      car_qtd: items.length,
      car_consultado_em: new Date().toISOString()
    };
    if (geomColOK) body.car_geom = (geoms && geoms.length) ? geoms : null;
    var r = await patchLinha(id, body);
    if (!r.ok){
      var t = (await r.text()) || '';
      // coluna car_geom ainda não existe → tira e tenta de novo (uma vez)
      if (geomColOK && /car_geom/.test(t)){
        geomColOK = false; delete body.car_geom;
        r = await patchLinha(id, body);
        if (r.ok) return;
        t = (await r.text()) || '';
      }
      throw new Error('salvar HTTP ' + r.status + ' ' + t.slice(0,80));
    }
  }

  // ── Loop principal ────────────────────────────────────────────────────
  (async function run(){
    try {
      // 1) Carrega TODOS os MCs ativos com coordenada (em páginas). Traz car_dados
      //    para decidir, no cliente, quais ainda NÃO têm proprietário (Harpia) —
      //    o car_consultado_em pode já ter vindo do SICAR, que não traz dono.
      setMsg('Carregando a lista de MCs…');
      var sel = 'id,codigo,coord_x,coord_y,car_dados';
      var filtro = '&coord_y=not.is.null&ativo=eq.true';
      var todos = [], off = 0, PAG = 1000;
      while (!window.__harpiaCancel){
        var rq = await fetch(SB_URL + '/rest/v1/mc_demandas?select=' + sel + filtro + '&order=codigo&limit=' + PAG + '&offset=' + off, { headers: H });
        var lote = await rq.json();
        if (!lote.length) break;
        todos = todos.concat(lote);
        setMsg('Carregando a lista de MCs… <b>' + todos.length + '</b>');
        if (lote.length < PAG) break;
        off += PAG;
      }
      // 2) ids que JÁ têm o polígono (car_geom) — consulta leve (só ids). Serve
      //    p/ backfill da geometria em quem já tinha proprietário mas ainda sem
      //    o polígono. Se a coluna não existe (db/204 não rodado), ignora.
      var geomDone = null;  // null = não dá pra saber → não força backfill de geom
      try {
        var gd = new Set(), goff = 0;
        while (true){
          var rg2 = await fetch(SB_URL + '/rest/v1/mc_demandas?select=id&car_geom=not.is.null' + filtro + '&limit=1000&offset=' + goff, { headers: H });
          if (!rg2.ok) { if (goff===0) { geomDone = null; } break; }
          var lg = await rg2.json();
          if (!Array.isArray(lg) || !lg.length) { if (goff===0 && geomDone===null) geomDone = gd; break; }
          lg.forEach(function(x){ gd.add(x.id); }); geomDone = gd;
          if (lg.length < 1000) break;
          goff += 1000;
        }
      } catch(_g){ geomDone = null; }

      // já tem proprietário/CPF do Harpia?
      var jaTem = function(d){ return Array.isArray(d.car_dados) && d.car_dados.some(function(c){ return c && (c.proprietario || c.cpf); }); };
      // precisa processar se falta proprietário OU (se dá p/ saber) falta o polígono
      var precisa = function(d){ return !jaTem(d) || (geomDone && !geomDone.has(d.id)); };
      var pend = todos.filter(precisa);
      var total = pend.length;
      var semProp = pend.filter(function(d){ return !jaTem(d); }).length;   // faltam nome/CPF
      var soGeom = total - semProp;                                          // já têm dono, falta só o polígono
      if (!total){ setMsg('✅ Nada pendente — proprietário e polígono de todos já importados! (' + todos.length + ' no total)'); setStat(''); window.__harpiaImporterRodando=false; return; }
      var msg = 'Importar do Harpia ' + total + ' MC(s)?\n\n';
      if (semProp) msg += '• ' + semProp + ' sem proprietário (traz nome/CPF + polígono)\n';
      if (soGeom)  msg += '• ' + soGeom + ' só para preencher o POLÍGONO do imóvel (já têm proprietário)\n';
      msg += '\n(' + todos.length + ' no total.) Pode levar alguns minutos. Dá pra acompanhar e fechar quando quiser — o que já foi importado fica salvo, e numa próxima vez ele continua só pelos que faltam.';
      if (!confirm(msg)){
        box.remove(); window.__harpiaImporterRodando = false; return;
      }
      var feito = 0, comCar = 0, semCar = 0, erros = 0;
      for (var k = 0; k < pend.length && !window.__harpiaCancel; k++){
        var d = pend[k];
        var la = parseFloat(d.coord_y), lo = parseFloat(d.coord_x);
        try {
          var res = (isFinite(la) && isFinite(lo)) ? await buscarCar(la, lo) : { items:[], geoms:[] };
          var items = res.items || [];
          await salvar(d.id, items, res.geoms || []);
          if (items.length){ comCar++; log('✔ ' + d.codigo + ' — ' + (items[0].proprietario || items[0].nome_imovel || items.length + ' imóvel(is)') + ((res.geoms && res.geoms.length)?' 🗺️':'')); }
          else { semCar++; log('– ' + d.codigo + ' — sem CAR no ponto'); }
        } catch(e){ erros++; log('✖ ' + d.codigo + ' — ' + e.message); }
        feito++;
        setBar(feito/total);
        setMsg('Importando… <b>' + feito + '/' + total + '</b>');
        setStat('✔ com CAR: ' + comCar + '  ·  – sem CAR: ' + semCar + (erros ? ('  ·  ✖ erros: ' + erros) : ''));
        await sleep(PAUSA_MS);
      }
      if (window.__harpiaCancel){ setMsg('⏹ Interrompido. O que foi importado está salvo.'); }
      else { setMsg('✅ <b>Concluído!</b> ' + feito + ' MC(s) processado(s). Volte ao painel e atualize.'); setBar(1); }
    } catch(e){
      setMsg('❌ Erro: ' + (e && e.message ? e.message : e));
    } finally {
      window.__harpiaImporterRodando = false;
    }
  })();
})();

/* ──────────────────────────────────────────────────────────────────────
   CartaoMapa — mostra as demandas de um cartão num mapa (alfinetes + info).
   Usado pelos cartões visualizáveis (cartao-publico, cartao-programa).
   A coordenada de cada demanda vem de:
     1) campo "coordenadas" (texto) → Coord.paraDecimal
     2) centroide do KML anexo (demandas do Monitoramento Contínuo)
   Carrega o Leaflet sob demanda. Base: satélite Esri (+ ruas OSM).
   ────────────────────────────────────────────────────────────────────── */
window.CartaoMapa = (function(){
  function _kmlFromDataUrl(link){
    const m=/base64,(.*)$/.exec(link||''); if(!m) return '';
    try{ return decodeURIComponent(escape(atob(m[1]))); }catch(e){ try{ return atob(m[1]); }catch(_){ return ''; } }
  }
  function _centroideKml(kml){
    const m=/<coordinates>([\s\S]*?)<\/coordinates>/i.exec(kml||''); if(!m) return null;
    const pares=m[1].trim().split(/\s+/).map(s=>s.split(',')).filter(a=>a.length>=2);
    let sx=0,sy=0,n=0;
    pares.forEach(a=>{ const lo=parseFloat(a[0]), la=parseFloat(a[1]); if(isFinite(lo)&&isFinite(la)){ sx+=lo; sy+=la; n++; } });
    return n?{la:sy/n, lo:sx/n}:null;
  }
  function coordDe(d){
    if(d && d.coordenadas && window.Coord && Coord.paraDecimal){
      const p=Coord.paraDecimal(d.coordenadas);
      if(p && isFinite(p.lat) && isFinite(p.lng)) return {la:p.lat, lo:p.lng};
    }
    const anx=(d && d.anexos)||[];
    for(const a of anx){
      if(a && a.link && (a.kml || /\.kml(\?|$)/i.test(a.nome||''))){
        const c=_centroideKml(_kmlFromDataUrl(a.link)); if(c) return c;
      }
    }
    return null;
  }
  function _loadLeaflet(cb){
    if(window.L) return cb();
    if(!document.getElementById('_cmLeafletCss')){ const c=document.createElement('link'); c.id='_cmLeafletCss'; c.rel='stylesheet'; c.href='https://unpkg.com/leaflet@1.9.4/dist/leaflet.css'; document.head.appendChild(c); }
    let s=document.getElementById('_cmLeafletJs');
    if(s){ s.addEventListener('load',cb); return; }
    s=document.createElement('script'); s.id='_cmLeafletJs'; s.src='https://unpkg.com/leaflet@1.9.4/dist/leaflet.js';
    s.onload=cb; s.onerror=()=>alert('Falha ao carregar o mapa (precisa de internet).'); document.head.appendChild(s);
  }
  function _esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
  function _info(d){
    const rows=[];
    if(d.municipio) rows.push(['Município', d.municipio]);
    if(d.endereco) rows.push(['Endereço', d.endereco]);
    if(d.origem && (d.origem.label||d.origem.numero)) rows.push(['Demanda', ((d.origem.label||'')+' '+(d.origem.numero||'')).trim()]);
    else if(d.texto) rows.push(['', String(d.texto).split('\n')[0]]);
    if(d.observacao) rows.push(['Obs', d.observacao]);
    return rows;
  }
  let _map=null;
  function abrir(demandas, titulo){
    const itens=(demandas||[]).map((d,i)=>({d, i, c:coordDe(d)})).filter(x=>x.c);
    if(!itens.length){ alert('Nenhuma demanda deste cartão tem localização para mapear.\nPreencha o campo "Coordenadas" da demanda (ou use uma demanda do Monitoramento Contínuo, que já traz a coordenada).'); return; }
    _loadLeaflet(()=>_render(itens, titulo));
  }
  function _render(itens, titulo){
    const old=document.getElementById('_cmMapModal'); if(old) old.remove();
    const ov=document.createElement('div'); ov.id='_cmMapModal';
    ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;z-index:99999;padding:14px';
    const box=document.createElement('div');
    box.style.cssText='background:#fff;border-radius:14px;width:min(960px,96vw);height:min(86vh,760px);display:flex;flex-direction:column;overflow:hidden;box-shadow:0 20px 60px rgba(0,0,0,.45)';
    box.innerHTML=
      '<div style="display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid #e2e2e2;flex-wrap:wrap;font-family:Arial">'+
        '<div style="font-size:14px;font-weight:800;color:#7a6b43">🗺️ '+_esc(titulo||('Locais do cartão — '+itens.length+' ponto(s)'))+'</div>'+
        '<div style="font-size:11px;color:#888">clique num alfinete para ver as informações</div>'+
        '<button id="_cmEarth" style="margin-left:auto;background:rgba(66,133,80,.14);border:1px solid #4caf50;color:#2e7d32;border-radius:7px;padding:7px 12px;cursor:pointer;font-weight:700;font-family:Arial" title="Baixa o KML dos pontos e abre o Google Earth (lá: Projetos → Importar arquivo KML).">🌍 Google Earth</button>'+
        '<button id="_cmClose" title="Fechar" style="width:34px;height:34px;border-radius:8px;background:#f0f0f0;border:1px solid #ccc;color:#333;font-size:17px;font-weight:700;cursor:pointer;line-height:1;font-family:Arial;flex-shrink:0">✕</button>'+
      '</div><div id="_cmMap" style="flex:1;min-height:0"></div>';
    ov.appendChild(box); document.body.appendChild(ov);
    const close=()=>{ try{ if(_map){ _map.remove(); _map=null; } }catch(e){} ov.remove(); };
    box.querySelector('#_cmClose').onclick=close; ov.onclick=e=>{ if(e.target===ov) close(); };
    box.querySelector('#_cmEarth').onclick=()=>_googleEarth(itens, titulo);
    const map=L.map('_cmMap',{zoomControl:true}); _map=map;
    const sat=L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',{maxZoom:19,attribution:'Tiles &copy; Esri'});
    const ruas=L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; OpenStreetMap'});
    sat.addTo(map); L.control.layers({'Satélite':sat,'Ruas':ruas},null,{collapsed:true}).addTo(map);
    const pts=[];
    itens.forEach(x=>{
      const c=x.c, d=x.d, n=(d.ordem||x.i+1); pts.push([c.la,c.lo]);
      const icon=L.divIcon({html:'<div style="background:#c62f2b;color:#fff;border:2px solid #fff;border-radius:50%;width:26px;height:26px;display:flex;align-items:center;justify-content:center;font:700 12px Arial;box-shadow:0 1px 4px rgba(0,0,0,.5)">'+n+'</div>',className:'',iconSize:[26,26],iconAnchor:[13,13]});
      const dir='https://www.google.com/maps/dir/?api=1&destination='+c.la+','+c.lo;
      const waze='https://waze.com/ul?ll='+c.la+','+c.lo;
      const info=_info(d).map(r=>(r[0]?'<b>'+_esc(r[0])+':</b> ':'')+_esc(r[1])).join('<br>');
      const popup='<div style="font:12px/1.5 Arial;min-width:190px;max-width:250px"><div style="font-weight:800;color:#8a6d00;margin-bottom:4px">📍 DEMANDA '+_esc(n)+'</div>'+info+'<div style="margin-top:8px"><a href="'+dir+'" target="_blank" rel="noopener" style="color:#1769c4;font-weight:700">🧭 Rota (Maps)</a> &nbsp;·&nbsp; <a href="'+waze+'" target="_blank" rel="noopener" style="color:#0a8fb8;font-weight:700">🚗 Waze</a></div></div>';
      L.marker([c.la,c.lo],{icon}).addTo(map).bindPopup(popup);
    });
    if(pts.length>1) L.polyline(pts,{color:'#ffd54a',weight:2.5,opacity:.85,dashArray:'6,6'}).addTo(map);
    if(pts.length===1) map.setView(pts[0],14); else map.fitBounds(pts,{padding:[40,40]});
    setTimeout(()=>{ try{ map.invalidateSize(); }catch(e){} },160);
  }
  function _kmlDe(itens, titulo){
    const style='<Style id="cmPin"><IconStyle><scale>1.1</scale><Icon><href>http://maps.google.com/mapfiles/kml/pushpin/red-pushpin.png</href></Icon></IconStyle></Style>';
    const pms=itens.map(x=>{
      const c=x.c, d=x.d, n=(d.ordem||x.i+1);
      const desc='<![CDATA[<div style="font:13px Arial">'+_info(d).map(r=>(r[0]?'<b>'+r[0]+':</b> ':'')+String(r[1])).join('<br>')+'</div>]]>';
      return '<Placemark><name>DEMANDA '+_esc(n)+'</name><description>'+desc+'</description><styleUrl>#cmPin</styleUrl><Point><coordinates>'+c.lo+','+c.la+',0</coordinates></Point></Placemark>';
    }).join('\n');
    return '<?xml version="1.0" encoding="utf-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>'+_esc(titulo||'Cartão — locais')+'</name>'+style+pms+'</Document></kml>';
  }
  function _baixa(txt, nome){ try{ const b=new Blob([txt],{type:'application/vnd.google-earth.kml+xml'}); const u=URL.createObjectURL(b); const a=document.createElement('a'); a.href=u; a.download=nome; document.body.appendChild(a); a.click(); a.remove(); setTimeout(()=>URL.revokeObjectURL(u),2000); return true; }catch(e){ return false; } }
  function _googleEarth(itens, titulo){
    _baixa(_kmlDe(itens, titulo), String(titulo||'cartao-locais').replace(/[^\w.-]+/g,'_')+'.kml');
    try{ window.open('https://earth.google.com/web/','_blank','noopener'); }catch(e){}
    setTimeout(()=>alert('KML baixado. No Google Earth: menu → Projetos → Importar arquivo KML → selecione o arquivo baixado.'),300);
  }
  return { abrir, coordDe };
})();

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
  // Anéis dos <Polygon> do KML → arrays de [lat,lon] (p/ desenhar o contorno no mapa, como no Google Earth)
  function _kmlPolys(kml){
    const s=String(kml||''); const out=[];
    (s.match(/<Polygon\b[\s\S]*?<\/Polygon>/gi)||[]).forEach(pg=>{
      (pg.match(/<coordinates>([\s\S]*?)<\/coordinates>/gi)||[]).forEach(r=>{
        const pts=r.replace(/<\/?coordinates>/gi,'').trim().split(/\s+/).map(tok=>{
          const a=tok.split(','); const lo=parseFloat(a[0]), la=parseFloat(a[1]);
          return (isFinite(la)&&isFinite(lo))?[la,lo]:null;
        }).filter(Boolean);
        if(pts.length>=3) out.push(pts);
      });
    });
    return out;
  }
  // Polígonos (contornos) de uma demanda, a partir do KML anexo
  function polysDe(d){
    const anx=(d && d.anexos)||[];
    for(const a of anx){
      if(a && a.link && (a.kml || /\.kml(\?|$)/i.test(a.nome||''))){
        const ps=_kmlPolys(_kmlFromDataUrl(a.link)); if(ps.length) return ps;
      }
    }
    return [];
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
    if(d.car_imovel) rows.push(['CAR', d.car_imovel]);
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
    const pts=[], allLL=[];
    itens.forEach(x=>{
      const c=x.c, d=x.d, n=(d.ordem||x.i+1); pts.push([c.la,c.lo]); allLL.push([c.la,c.lo]);
      // Contorno do polígono do GEOCOD (como no Google Earth)
      polysDe(d).forEach(ring=>{ L.polygon(ring,{color:'#e03a34',weight:2,opacity:.95,fill:true,fillColor:'#e03a34',fillOpacity:.12}).addTo(map); ring.forEach(p=>allLL.push(p)); });
      const icon=L.divIcon({html:'<div style="background:#c62f2b;color:#fff;border:2px solid #fff;border-radius:50%;width:26px;height:26px;display:flex;align-items:center;justify-content:center;font:700 12px Arial;box-shadow:0 1px 4px rgba(0,0,0,.5)">'+n+'</div>',className:'',iconSize:[26,26],iconAnchor:[13,13]});
      const dir='https://www.google.com/maps/dir/?api=1&destination='+c.la+','+c.lo;
      const waze='https://waze.com/ul?ll='+c.la+','+c.lo;
      const info=_info(d).map(r=>(r[0]?'<b>'+_esc(r[0])+':</b> ':'')+_esc(r[1])).join('<br>');
      const popup='<div style="font:12px/1.5 Arial;min-width:190px;max-width:250px"><div style="font-weight:800;color:#8a6d00;margin-bottom:4px">📍 DEMANDA '+_esc(n)+'</div>'+info+'<div style="margin-top:8px"><a href="'+dir+'" target="_blank" rel="noopener" style="color:#1769c4;font-weight:700">🧭 Rota (Maps)</a> &nbsp;·&nbsp; <a href="'+waze+'" target="_blank" rel="noopener" style="color:#0a8fb8;font-weight:700">🚗 Waze</a></div></div>';
      L.marker([c.la,c.lo],{icon}).addTo(map).bindPopup(popup);
    });
    if(pts.length>1) L.polyline(pts,{color:'#ffd54a',weight:2.5,opacity:.85,dashArray:'6,6'}).addTo(map);
    if(allLL.length===1) map.setView(allLL[0],14); else map.fitBounds(allLL,{padding:[40,40]});
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
  function _hav(la1,lo1,la2,lo2){const R=6371,t=Math.PI/180,dla=(la2-la1)*t,dlo=(lo2-lo1)*t,a=Math.sin(dla/2)**2+Math.cos(la1*t)*Math.cos(la2*t)*Math.sin(dlo/2)**2;return 2*R*Math.asin(Math.min(1,Math.sqrt(a)));}
  // Rota multi-parada por TODAS as demandas com coordenada (ordem vizinho-mais-
  // próximo a partir do ponto mais ao norte; teto de 10 paradas). Devolve:
  //  { url, incluidas:[{d,ordem}] em ordem de percurso, excluidas:[{d,ordem}] sem
  //    coordenada (fora da rota), cortadas: nº além do teto de 10 }
  function rotaInfo(demandas){
    const its=(demandas||[]).map((d,i)=>({d,ordem:(d&&d.ordem)||i+1,c:coordDe(d)}));
    const com=its.filter(x=>x.c), excluidas=its.filter(x=>!x.c).map(x=>({d:x.d,ordem:x.ordem}));
    if(!com.length) return {url:'',incluidas:[],excluidas,cortadas:0,primeiro:null};
    if(com.length===1){ const c=com[0].c; return {url:'https://www.google.com/maps/dir/?api=1&travelmode=driving&destination='+encodeURIComponent(c.la+','+c.lo), incluidas:[{d:com[0].d,ordem:com[0].ordem}], excluidas, cortadas:0, primeiro:{la:c.la,lo:c.lo}}; }
    let pend=com.slice(); pend.sort((a,b)=>b.c.la-a.c.la);
    let seq=[pend.shift()], cur=seq[0].c;
    while(pend.length){ let bi=0,bd=Infinity; for(let i=0;i<pend.length;i++){ const dd=_hav(cur.la,cur.lo,pend[i].c.la,pend[i].c.lo); if(dd<bd){bd=dd;bi=i;} } const nx=pend.splice(bi,1)[0]; seq.push(nx); cur=nx.c; }
    let cortadas=0; if(seq.length>10){ cortadas=seq.length-10; seq=seq.slice(0,10); }
    const pt=c=>c.la+','+c.lo, org=seq[0].c, stops=seq.slice(1);
    let url='https://www.google.com/maps/dir/?api=1&travelmode=driving&origin='+encodeURIComponent(pt(org));
    if(stops.length){ const dest=stops[stops.length-1].c, wps=stops.slice(0,-1).map(x=>pt(x.c)); url+='&destination='+encodeURIComponent(pt(dest)); if(wps.length) url+='&waypoints='+encodeURIComponent(wps.join('|')); }
    else url+='&destination='+encodeURIComponent(pt(org));
    return {url, incluidas:seq.map(x=>({d:x.d,ordem:x.ordem})), excluidas, cortadas, primeiro:{la:org.la,lo:org.lo}};
  }
  function rotaUrl(demandas){ return rotaInfo(demandas).url; }
  // Seletor de app: abre a rota no Google Maps (completa) ou Waze (1º ponto).
  function escolherRota(demandas){
    const ri=rotaInfo(demandas);
    if(!ri.url || !ri.primeiro){ alert('Nenhuma demanda com coordenada para traçar a rota.'); return; }
    const n=ri.incluidas.length, waze='https://waze.com/ul?ll='+ri.primeiro.la+','+ri.primeiro.lo;
    const old=document.getElementById('_cmRotaSel'); if(old) old.remove();
    const ov=document.createElement('div'); ov.id='_cmRotaSel';
    ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.5);display:flex;align-items:center;justify-content:center;z-index:100000;padding:16px';
    const box=document.createElement('div');
    box.style.cssText='background:#fff;border-radius:14px;max-width:360px;width:100%;padding:20px;box-shadow:0 20px 60px rgba(0,0,0,.45);font-family:Arial';
    box.innerHTML=
      '<div style="font-size:15px;font-weight:800;color:#7a6b43;margin-bottom:3px">🧭 Abrir a rota em qual app?</div>'+
      '<div style="font-size:11.5px;color:#888;margin-bottom:14px">'+n+' ponto(s) na rota.</div>'+
      '<a href="'+ri.url+'" target="_blank" rel="noopener" style="display:flex;align-items:center;gap:8px;padding:12px 14px;border:1px solid #cbd5e1;border-radius:9px;margin-bottom:9px;color:#1769c4;font-weight:700;text-decoration:none">🧭 Google Maps <span style="margin-left:auto;font-weight:400;color:#888;font-size:11px">rota completa</span></a>'+
      '<a href="'+waze+'" target="_blank" rel="noopener" style="display:flex;align-items:center;gap:8px;padding:12px 14px;border:1px solid #cbd5e1;border-radius:9px;margin-bottom:9px;color:#0a8fb8;font-weight:700;text-decoration:none">🚗 Waze <span style="margin-left:auto;font-weight:400;color:#888;font-size:11px">1º ponto (não faz várias paradas)</span></a>'+
      '<button id="_cmRotaFechar" style="width:100%;margin-top:4px;background:#f0f0f0;border:1px solid #ccc;border-radius:8px;padding:9px;cursor:pointer;font-weight:700;font-family:Arial">Fechar</button>';
    ov.appendChild(box); document.body.appendChild(ov);
    const close=()=>ov.remove();
    box.querySelector('#_cmRotaFechar').onclick=close; ov.onclick=e=>{ if(e.target===ov) close(); };
    box.querySelectorAll('a').forEach(a=>a.addEventListener('click',()=>setTimeout(close,150)));
  }
  function nComCoord(demandas){ return (demandas||[]).filter(d=>coordDe(d)).length; }
  return { abrir, coordDe, polysDe, rotaUrl, rotaInfo, escolherRota, nComCoord };
})();

/* ══════════════════════════════════════════════════════════════════════
   coord.js — parser de coordenadas (3 formatos) + rota no Google Maps.
   Aceita, num único campo (lat e lng juntos):
     • GMS — Graus, Min, Seg:        17°36'45.0"S 41°29'28.7"W
     • GMD — Graus, Min decimais:    17°36.750'S  41°29.470'W
     • Decimal (GG.GGGGGG):          -17.6125, -41.4913
   Hemisférios aceitos: N/S e L(este)/E/O(este)/W. Sem hemisfério, assume o
   sinal (−) e a ordem lat, lng (padrão do "copiar coordenadas" do Maps).
   Usado por novo-cartao / cartao-programa / cartao-publico / cartao-pdf.
   ══════════════════════════════════════════════════════════════════════ */
window.Coord = (function(){
  // Converte UM eixo (string com graus[/min[/seg]] e hemisfério opcional) → decimal.
  function _eixo(s){
    s = String(s||'').toUpperCase().replace(/,/g,'.');           // vírgula = decimal dentro do eixo
    const hemi = (s.match(/[NSLEOW]/)||[])[0] || '';
    const nums = (s.match(/\d+(?:\.\d+)?/g)||[]).map(Number);
    if(!nums.length) return null;
    let dec;
    if(nums.length===1)      dec = nums[0];                        // decimal
    else if(nums.length===2) dec = nums[0] + nums[1]/60;           // GMD
    else                     dec = nums[0] + nums[1]/60 + nums[2]/3600; // GMS
    const neg = /^\s*-/.test(s) || hemi==='S' || hemi==='W' || hemi==='O';
    return neg ? -Math.abs(dec) : Math.abs(dec);
  }
  // String completa → { lat, lng } decimal, ou null.
  function paraDecimal(str){
    if(!str) return null;
    let s = String(str).trim().toUpperCase().replace(/[’`´]/g,"'").replace(/[”]/g,'"');
    if(/[NSLEOW]/.test(s)){
      // dois trechos, cada um terminando num hemisfério
      const m = s.match(/[^NSLEOW]*[NSLEOW]/g);
      if(!m || m.length<2) return null;
      const a=_eixo(m[0]), b=_eixo(m[1]);
      if(a==null||b==null) return null;
      const aLat=/[NS]/.test(m[0]), bLat=/[NS]/.test(m[1]);
      if(aLat && !bLat) return { lat:a, lng:b };
      if(!aLat && bLat) return { lat:b, lng:a };
      return { lat:a, lng:b };
    }
    // sem hemisfério → par decimal (ponto decimal), ordem lat, lng
    const nums = (s.match(/-?\d+(?:\.\d+)?/g)||[]).map(Number);
    if(nums.length>=2) return { lat:nums[0], lng:nums[1] };
    return null;
  }
  function mapsRota(str){
    const c = paraDecimal(str);
    if(!c || isNaN(c.lat) || isNaN(c.lng)) return '';
    return 'https://www.google.com/maps/dir/?api=1&destination='+encodeURIComponent(c.lat+','+c.lng);
  }
  // Rota a partir de um ENDEREÇO em texto (destino que o Google geocodifica).
  function mapsRotaTexto(txt){
    const t = String(txt||'').trim();
    if(!t) return '';
    return 'https://www.google.com/maps/dir/?api=1&destination='+encodeURIComponent(t);
  }
  return { paraDecimal, mapsRota, mapsRotaTexto };
})();

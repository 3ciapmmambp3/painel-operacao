/* ══════════════════════════════════════════════════════════════════════
   FrotaGrup — lista oficial de grupamentos da 3ª Cia (fonte: tabela `grupos`,
   via grupamentos_listar), para os filtros por grupamento nos painéis de frota.
   Organiza por PELOTÃO (optgroups), igual à Fração de Atuação do relatório de
   serviço — porque o mesmo "Nº Gp" se repete nos 5 pelotões, então filtrar só
   pelo Nº do Gp misturaria grupamentos diferentes.

   Uso:
     await FrotaGrup.carregar(API, AKEY);
     sel.innerHTML = '<option value="">Todos os grupamentos</option>' + FrotaGrup.options();
     // casar uma linha:
     //   painéis com gp_responsavel (abast/acidentes): FrotaGrup.mesmoGpr(row.gp_responsavel, fg)
     //   painéis com município (viaturas/revisão/defeitos): FrotaGrup.gprDeMunicipio(muni) === fg
   O <option value> é o gp_responsavel (chave canônica: "GP <CIDADE>").
   ══════════════════════════════════════════════════════════════════════ */
window.FrotaGrup = (function(){
  let LISTA = [];        // [{gpr, completo, gp, pel, cidade}]
  let BY_CIDADE = {};    // canon(cidade) -> gp_responsavel
  const _num = (s, re) => { const m = (s||'').match(re); return m ? +m[1] : null; };
  // Normaliza cidade: MAIÚSCULA, sem acento, só letras/espaço, colapsando as
  // duas grafias erradas do cadastro (MARILIERIA→MARLIERIA, MOLEVADE→MONLEVADE).
  function _canon(s){
    let t = (s||'').toUpperCase().normalize('NFD').replace(/[̀-ͯ]/g,'')
      .replace(/[^A-Z ]/g,' ').replace(/\s+/g,' ').trim();
    return t.replace('MARILIERIA','MARLIERIA').replace('MOLEVADE','MONLEVADE');
  }
  function _canonGpr(s){ return _canon((s||'').replace(/^GP\s+/i,'')); }
  const _esc = s => (s==null?'':String(s)).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

  async function carregar(apiUrl, apiKey){
    try{
      const r = await fetch(`${apiUrl}/rest/v1/rpc/grupamentos_listar`, {
        method:'POST',
        headers:{ apikey:apiKey, Authorization:'Bearer '+apiKey, 'Content-Type':'application/json' },
        body:'{}'
      });
      const rows = await r.json();
      LISTA = (Array.isArray(rows)?rows:[]).map(g=>{
        const c = g.grupamento_completo || '';
        return { gpr:g.gp_responsavel||'', completo:c,
                 gp:_num(c,/(\d+)\s*GP/i), pel:_num(c,/(\d+)\s*PEL/i),
                 cidade:(c.split('/').pop()||'').trim() };
      }).filter(x=>x.gpr);
      LISTA.sort((a,b)=> (a.pel-b.pel) || (a.gp-b.gp));
      BY_CIDADE = {};
      LISTA.forEach(x=>{ const k=_canon(x.cidade); if(k) BY_CIDADE[k]=x.gpr; });
    }catch(e){ LISTA=[]; BY_CIDADE={}; console.warn('FrotaGrup.carregar', e); }
    return LISTA;
  }

  // <optgroup> por pelotão. value = gp_responsavel; rótulo = "Nº Gp · CIDADE".
  // pelFilter (opcional): nº do pelotão para listar só os Gp daquele pelotão.
  function options(pelFilter){
    const p = (pelFilter==null || pelFilter==='') ? null : +pelFilter;
    const byPel = {};
    LISTA.forEach(x=>{ if(p!=null && x.pel!==p) return; (byPel[x.pel]=byPel[x.pel]||[]).push(x); });
    return Object.keys(byPel).map(Number).sort((a,b)=>a-b).map(p=>{
      const opts = byPel[p].map(x=>
        `<option value="${_esc(x.gpr)}">${_esc((x.gp!=null?x.gp+'º Gp · ':'')+x.cidade)}</option>`).join('');
      return `<optgroup label="${p}º Pelotão">${opts}</optgroup>`;
    }).join('');
  }

  function gprDeMunicipio(muni){ return BY_CIDADE[_canon(muni)] || ''; }
  function mesmoGpr(a, b){ const x=_canonGpr(a); return !!x && x===_canonGpr(b); }

  return { carregar, options, gprDeMunicipio, mesmoGpr, get lista(){ return LISTA; } };
})();

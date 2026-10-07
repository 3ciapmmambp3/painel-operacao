/* ══════════════════════════════════════════════════════════════════════
   cartao-pdf.js — Ficha do Cartão Programa (impressão/PDF) + WhatsApp.
   Mesmo padrão da Ficha de Denúncia de Balcão (denuncias.html → gerarPDF):
   abre uma nova janela com o documento branco (brasões + dourado, fontes
   Playfair/Inter), o usuário clica em "Imprimir / PDF" e o Chrome salva.
   O nome padrão do arquivo no Chrome = <title> do documento, então o título
   já sai como "CARTÃO PROGRAMA - <militares> <dd Mmm aaaa>". Anexos são links
   clicáveis (o Chrome preserva os hiperlinks no PDF). Sem biblioteca externa.
   Compartilhado por cartao-programa.html e cartao-publico.html.
   ══════════════════════════════════════════════════════════════════════ */
(function(global){
  'use strict';
  const STLAB={EMITIDO:'Emitido',EM_ATENDIMENTO:'Em atendimento',CONCLUIDO:'Concluído'};
  const ATLAB={TOTAL:'Atendida (total)',PARCIAL:'Atendida (parcial)',NAO:'Não atendida'};
  const MES3=['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'];

  const E = v => (v==null?'':String(v)).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const fmtData = iso => { if(!iso) return '—'; const d=new Date(String(iso).slice(0,10)+'T00:00:00'); return isNaN(d)?String(iso):d.toLocaleDateString('pt-BR'); };
  function dataLonga(iso){ if(!iso) return ''; const d=new Date(String(iso).slice(0,10)+'T00:00:00'); return isNaN(d)?'':(String(d.getDate()).padStart(2,'0')+' '+MES3[d.getMonth()]+' '+d.getFullYear()); }
  function membroArq(s){ const t=String(s||'').trim(); if(!t || /^-*\s*n[ãa]o h[áa]/i.test(t)) return ''; const p=t.split(' - ').map(x=>x.trim()); return (p.length>=3?(p[1]+' '+p.slice(2).join(' ')):t).trim(); }
  function tituloArq(cartao){
    const membros=[cartao.comandante,cartao.motorista].concat(Array.isArray(cartao.patrulheiros)?cartao.patrulheiros:[]).map(membroArq).filter(Boolean);
    const data=dataLonga(cartao.data_empenho);
    return membros.length ? ('CARTÃO PROGRAMA - '+membros.join(', ')+(data?(' '+data):'')) : ('CARTÃO PROGRAMA '+(cartao.numero||''));
  }
  function nomeArq(cartao){ return tituloArq(cartao).replace(/[\\/:*?"<>|]+/g,' ').replace(/\s+/g,' ').trim()+'.pdf'; }
  function mapsRota(coord){
    if(global.Coord) return global.Coord.mapsRota(coord);
    const n=String(coord||'').match(/-?\d+(?:\.\d+)?/g); if(!n||n.length<2) return '';
    return 'https://www.google.com/maps/dir/?api=1&destination='+encodeURIComponent(n[0]+','+n[1]);
  }
  function statusLabel(s){ return STLAB[s]||(s||'—'); }
  function atendidaLabel(a){ return ATLAB[a]||'—'; }

  function _assets(){ try{ return (global.location&&global.location.origin)?global.location.origin:''; }catch(e){ return ''; } }

  // Monta o HTML da ficha. download=true remove a barra e injeta o html2pdf
  // que salva o arquivo automaticamente (usado no "Baixar PDF").
  function html(cartao, download){
    const base=_assets();
    const row=(l,v)=>`<tr><td class="l">${E(l)}</td><td>${(v==null||v==='')?'—':E(v)}</td></tr>`;
    const rowH=(l,h)=>`<tr><td class="l">${E(l)}</td><td>${h||'—'}</td></tr>`;
    const rowBlk=(l,v)=>`<tr><td class="bl" colspan="2"><span class="bl-l">${E(l)}</span><div class="bl-v">${(v==null||v==='')?'—':E(v)}</div></td></tr>`;
    const patr=(Array.isArray(cartao.patrulheiros)?cartao.patrulheiros:[]).filter(Boolean);
    const respostas=cartao.respostas||{};
    const gp = cartao.grupamento_completo || cartao.grupamento_id || '';
    const opTxt = [cartao.operacao,cartao.operacao_descr].filter(Boolean).join(' — ');

    // Dados do serviço
    let dados = row('Grupamento', gp)
      + row('Data de empenho', fmtData(cartao.data_empenho))
      + row('Turno de serviço', cartao.turno)
      + row('Equipe', cartao.equipe)
      + row('Tipo de serviço', cartao.tipo_servico)
      + row('Operação', opTxt)
      + row('Viatura', cartao.viatura)
      + row('Comandante', cartao.comandante)
      + row('Motorista', cartao.motorista)
      + (patr.length?rowBlk('Patrulheiro(s)', patr.join('\n')):'');

    // Demandas (cada uma com sua seção; resposta aparece se atendida)
    const demandas=Array.isArray(cartao.demandas)?cartao.demandas:[];
    let demHtml='';
    demandas.forEach((d,i)=>{
      const ord=d.ordem||(i+1);
      const r=respostas[String(d.ordem)]||respostas[String(i+1)]||null;
      const anx=(d.anexos||[]).filter(a=>a&&a.link);
      const anexoCell=anx.length?anx.map(a=>`<a href="${String(a.link).replace(/"/g,'&quot;')}" target="_blank" rel="noopener">${E(a.nome||'anexo')}</a>`).join('<br>'):'';
      const rota = mapsRota(d.coordenadas);
      const coordCell = d.coordenadas
        ? (rota?`<a href="${rota}" target="_blank" rel="noopener">Rota no Google Maps</a> (${E(d.coordenadas)})`:E(d.coordenadas))
        : '';
      let corpo = rowBlk('Descrição', d.texto)
        + (d.endereco?row('Endereço / referência', d.endereco):'')
        + (d.municipio?row('Município', d.municipio):'')
        + (d.coordenadas?rowH('Coordenadas', coordCell):'')
        + (anx.length?rowH('Anexo', anexoCell):'');
      let resp = (r&&r.atendida)
        ? row('Situação', atendidaLabel(r.atendida))
          + row('Data do atendimento', fmtData(r.data_atendimento))
          + row('Nº REDS (BO/BOS/RAT)', r.reds)
          + row('Nº Auto de Infração', r.auto_infracao)
          + row('Nº Ato de Fiscalização', r.ato_fiscalizacao)
          + (r.obs?rowBlk('Observações da resposta', r.obs):'')
        : '';
      const orig = d.origem && d.origem.numero ? ((d.origem.tipo==='requisicao'?'Requisição':'Denúncia')+' '+d.origem.numero) : '';
      demHtml += `<h4 class="sec">Demanda ${E(ord)}${d.municipio?(' <small>— '+E(d.municipio)+'</small>'):''}${orig?(' <small>· '+E(orig)+'</small>'):''}</h4><table class="t">${corpo}</table>`
        + (resp?`<table class="t resp">${resp}</table>`:'<div class="pend">Pendente de atendimento</div>');
    });
    if(!demandas.length) demHtml='<p class="vazio">Nenhuma demanda lançada.</p>';

    // Observações
    let obs='';
    if(cartao.alterou_escala) obs += rowBlk('Alteração de escala', cartao.motivo_alteracao||'Sim');
    if(cartao.observacoes_equipe) obs += rowBlk('Observações para a equipe', cartao.observacoes_equipe);

    const emitido=[cartao.criado_por_posto,cartao.criado_por_nome].filter(Boolean).join(' ');
    const nrTexto='CARTÃO PROGRAMA Nº '+(cartao.numero||'')+' — 3ª CIA PM MAmb';

    return `<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8"><title>${E(tituloArq(cartao))}</title>
    <link href="https://fonts.googleapis.com/css2?family=Playfair+Display:wght@600;700;800&family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
      *{box-sizing:border-box} body{font-family:'Inter',Arial,Helvetica,sans-serif;color:#000;margin:0;padding:0;background:#e9ece9}
      .vbar{position:sticky;top:0;z-index:10;display:flex;align-items:center;gap:10px;background:#f3efe6;border-bottom:1px solid #d8cfb6;padding:10px 16px}
      .vbar .vt{flex:1;font-weight:700;font-size:13px;color:#6a5a2e}
      .vbar button{font:inherit;font-size:13px;font-weight:700;padding:7px 14px;border-radius:7px;border:1px solid #d8cfb6;background:#fff;color:#4a3f20;cursor:pointer}
      .vbar button.pr{background:#9b8a5c;color:#fff;border-color:#9b8a5c}
      .doc{background:#fff;color:#000;max-width:820px;margin:22px auto;padding:30px 34px;border-radius:12px;box-shadow:0 4px 20px rgba(0,0,0,.12)}
      .doc *{color:#000}
      .view-brasoes{display:flex;align-items:flex-start;justify-content:center;gap:20px;text-align:center;border-bottom:2px solid #9b8a5c;padding-bottom:16px;margin-bottom:22px}
      .view-brasoes img{height:74px;width:auto;flex-shrink:0;margin-top:20px}
      .view-titulo{flex:1;min-width:0;padding-top:20px}
      .view-titulo .vt-orgao{font-size:12.5px;font-weight:800;line-height:1.55;text-transform:uppercase;letter-spacing:.02em}
      .view-titulo h1{font-family:'Playfair Display',serif;font-size:24px;margin:1.1em 0 0;letter-spacing:.02em}
      .view-titulo .vt-id{font-size:11.5px;font-weight:700;margin-top:8px;letter-spacing:.02em}
      h4.sec{font-family:'Playfair Display',serif;font-size:16px;margin:24px 0 8px}
      h4.sec small{font-family:'Inter',sans-serif;font-weight:500;font-size:12px;color:#6a5a2e}
      table.t{width:100%;border-collapse:collapse;margin-bottom:6px;table-layout:fixed}
      table.t td{padding:6px 10px;font-size:14px;line-height:1.45;border:0;border-bottom:1px solid #ddd;vertical-align:top;word-wrap:break-word}
      table.t td.l{width:38%;color:#666;font-weight:600}
      table.t td a{color:#0645ad;text-decoration:underline;word-break:break-all}
      table.t.resp td{background:#f3f7f3;border-bottom-color:#d7e4d7}
      table.t td.bl{padding:8px 10px}
      table.t td.bl .bl-l{display:block;color:#666;font-weight:600;font-size:13px;margin-bottom:3px}
      table.t td.bl .bl-v{white-space:pre-wrap;word-wrap:break-word;line-height:1.5;text-align:justify}
      .pend{font-size:12.5px;color:#9a7b00;font-style:italic;margin:2px 0 8px}
      .vazio{font-style:italic;color:#666}
      .rodape{margin-top:22px;border-top:1px solid #ddd;padding-top:10px;font-size:11.5px;color:#555}
      @media print{@page{margin:0} body{background:#fff} .vbar{display:none!important} .doc{max-width:none;margin:0;padding:16mm;border-radius:0;box-shadow:none}}
      ${download?'.vbar{display:none} body{background:#fff} .doc{max-width:none;margin:0;border-radius:0;box-shadow:none;padding:16mm}':''}
    </style></head><body>
      ${download?'':'<div class="vbar"><span class="vt">👁 Visualização do cartão — confira e clique em Imprimir / PDF</span><button class="pr" onclick="window.print()">🖨 Imprimir / PDF</button><button onclick="window.close()">Fechar</button></div>'}
      <div class="doc">
        <div class="view-brasoes">
          <img src="${base}/assets/escudo-cpe.png" alt="CPE" onerror="this.style.display='none'">
          <div class="view-titulo">
            <div class="vt-orgao">Comando de Policiamento Especializado</div>
            <div class="vt-orgao">Batalhão de Polícia Militar de Meio Ambiente</div>
            <div class="vt-orgao">3ª Companhia de Polícia Militar de Meio Ambiente</div>
            <h1>CARTÃO PROGRAMA</h1>
            <div class="vt-id">${E(nrTexto)}</div>
          </div>
          <img src="${base}/assets/brasao-bpmmamb.png" alt="BPM MAmb" onerror="this.style.display='none'">
        </div>
        <h4 class="sec">Dados do serviço</h4>
        <table class="t">${dados}</table>
        <h4 class="sec" style="border-bottom:1px solid #9b8a5c;padding-bottom:4px">Demandas para atendimento</h4>
        ${demHtml}
        ${obs?`<h4 class="sec">Observações</h4><table class="t">${obs}</table>`:''}
        <div class="rodape">Emitido por ${E(emitido||'—')} · ${fmtData(cartao.criado_em||cartao.created_at)}</div>
      </div>
      ${download?`<script src="https://cdn.jsdelivr.net/npm/html2pdf.js@0.10.2/dist/html2pdf.bundle.min.js"></script><script>(async function(){try{await (document.fonts?document.fonts.ready:0);}catch(e){}try{await Promise.all([].map.call(document.images,function(i){return i.complete?0:new Promise(function(r){i.onload=i.onerror=r;});}));}catch(e){}var el=document.querySelector('.doc');try{await html2pdf().set({margin:0,filename:${JSON.stringify(nomeArq(cartao))},image:{type:'jpeg',quality:0.98},html2canvas:{scale:2,useCORS:true,backgroundColor:'#ffffff'},jsPDF:{unit:'mm',format:'a4',orientation:'portrait'},pagebreak:{mode:['css','legacy']}}).from(el).save();}catch(e){console.error('html2pdf',e);}try{parent.postMessage('cp-pdf-done','*');}catch(e){}})();</script>`:''}
    </body></html>`;
  }

  // Abre a visualização (nova janela) p/ conferir e imprimir/salvar.
  function imprimir(cartao){
    const w=global.open('', '_blank');
    if(!w){ alert('Permita pop-ups para visualizar/imprimir o cartão.'); return false; }
    w.document.write(html(cartao, false)); w.document.close();
    return true;
  }

  // Baixa o PDF direto (sem diálogo): renderiza a ficha num iframe oculto e o
  // html2pdf salva o arquivo com o nome padrão. Fallback = abre a visualização.
  function baixar(cartao){
    let ifr;
    try{
      ifr=document.createElement('iframe');
      ifr.setAttribute('aria-hidden','true');
      ifr.style.cssText='position:fixed;left:-10000px;top:0;width:820px;height:1400px;border:0;opacity:0';
      document.body.appendChild(ifr);
      let done=false;
      const cleanup=()=>{ if(done) return; done=true; try{global.removeEventListener('message',onmsg);}catch(e){} setTimeout(()=>{ try{ifr.remove();}catch(e){} },400); };
      const onmsg=e=>{ if(e && e.data==='cp-pdf-done') cleanup(); };
      global.addEventListener('message', onmsg);
      const d=ifr.contentDocument||(ifr.contentWindow&&ifr.contentWindow.document);
      if(!d){ ifr.remove(); return imprimir(cartao); }
      d.open(); d.write(html(cartao, true)); d.close();
      setTimeout(cleanup, 25000);
      return true;
    }catch(e){ try{ if(ifr) ifr.remove(); }catch(_){} return imprimir(cartao); }
  }

  // WhatsApp: manda o texto + o LINK público do cartão (o PDF sai pelo botão
  // "Baixar PDF" → Salvar como PDF). Abre o app com a mensagem pronta.
  function whatsapp(cartao, publicUrl){
    const texto = `*CARTÃO PROGRAMA Nº ${cartao.numero||''}*\n`+
      `${cartao.grupamento_completo||cartao.grupamento_id||''}\n`+
      `Data: ${fmtData(cartao.data_empenho)} · Turno: ${cartao.turno||'—'} · Equipe ${cartao.equipe||'—'}`+
      (publicUrl ? `\n\nAbra o cartão: ${publicUrl}` : '');
    global.open('https://wa.me/?text='+encodeURIComponent(texto), '_blank');
    return 'link';
  }

  global.CartaoPDF = { baixar, imprimir, whatsapp, html, nomeArq, tituloArq, statusLabel, atendidaLabel };
})(window);

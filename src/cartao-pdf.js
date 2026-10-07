/* ══════════════════════════════════════════════════════════════════════
   cartao-pdf.js — geração do PDF do Cartão Programa + envio por WhatsApp.
   Compartilhado por cartao-programa.html (listagem) e cartao-publico.html
   (view pública). Sem dependências além do jsPDF 2.5.1 (UMD), carregado sob
   demanda do mesmo CDN já usado no painel. Documento com anexos CLICÁVEIS
   (doc.textWithLink) — padrão de PDF do painel.
   ══════════════════════════════════════════════════════════════════════ */
(function(global){
  'use strict';
  const GOLD = [155, 138, 92];
  const DARK = [26, 16, 0];
  const INK  = [33, 33, 33];
  const MUTED = [110, 110, 110];
  const CDN = 'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js';

  function _esc(s){ return (s==null?'':String(s)); }
  function _data(iso){ if(!iso) return '—'; const d=new Date(String(iso).slice(0,10)+'T00:00:00'); return isNaN(d)?String(iso):d.toLocaleDateString('pt-BR'); }

  function carregarJsPDF(){
    return new Promise((res, rej)=>{
      if(global.jspdf && global.jspdf.jsPDF) return res(global.jspdf.jsPDF);
      const s=document.createElement('script'); s.src=CDN;
      s.onload=()=>{ (global.jspdf && global.jspdf.jsPDF) ? res(global.jspdf.jsPDF) : rej(new Error('jsPDF não carregou')); };
      s.onerror=()=>rej(new Error('Falha ao carregar o jsPDF (sem internet?)'));
      document.head.appendChild(s);
    });
  }

  // Normaliza nomes de status p/ rótulo amigável.
  function statusLabel(s){
    return ({EMITIDO:'Emitido', EM_ATENDIMENTO:'Em atendimento', CONCLUIDO:'Concluído'})[s] || (s||'—');
  }
  function atendidaLabel(a){
    return ({TOTAL:'Atendida (total)', PARCIAL:'Atendida (parcial)', NAO:'Não atendida'})[a] || '—';
  }

  // Constrói e devolve o doc jsPDF já montado.
  async function build(cartao){
    const JsPDF = await carregarJsPDF();
    const doc = new JsPDF({ orientation:'portrait', unit:'mm', format:'a4' });
    const PW = doc.internal.pageSize.getWidth();   // 210
    const PH = doc.internal.pageSize.getHeight();   // 297
    const M = 14;                                   // margem
    const W = PW - M*2;
    let y = M;

    const demandas = Array.isArray(cartao.demandas) ? cartao.demandas : [];
    const respostas = cartao.respostas || {};

    function ensure(h){ if(y + h > PH - 16){ doc.addPage(); y = M; } }
    function rule(){ doc.setDrawColor(...GOLD); doc.setLineWidth(0.5); doc.line(M, y, PW-M, y); }
    function kv(label, value, x, w){
      doc.setFont('helvetica','bold'); doc.setFontSize(7.5); doc.setTextColor(...MUTED);
      doc.text(String(label).toUpperCase(), x, y);
      doc.setFont('helvetica','normal'); doc.setFontSize(9.5); doc.setTextColor(...INK);
      const lines = doc.splitTextToSize(_esc(value||'—'), w);
      doc.text(lines, x, y+4.2);
      return 4.2 + lines.length*4.4;
    }

    // ── Cabeçalho ──
    doc.setFillColor(...DARK); doc.rect(0,0,PW,26,'F');
    doc.setTextColor(...GOLD); doc.setFont('helvetica','bold'); doc.setFontSize(13);
    doc.text('CARTÃO PROGRAMA', M, 11);
    doc.setTextColor(230,230,230); doc.setFont('helvetica','normal'); doc.setFontSize(8.5);
    doc.text('Polícia Militar de Minas Gerais · 3ª Cia PM de Meio Ambiente', M, 17);
    doc.setFont('helvetica','bold'); doc.setFontSize(11); doc.setTextColor(...GOLD);
    doc.text('Nº '+_esc(cartao.numero||'—'), PW-M, 11, {align:'right'});
    doc.setFont('helvetica','normal'); doc.setFontSize(8.5); doc.setTextColor(230,230,230);
    doc.text(statusLabel(cartao.status), PW-M, 17, {align:'right'});
    y = 34;

    // ── Dados do serviço (grade 2 col) ──
    const colW = (W-6)/2, xL=M, xR=M+colW+6;
    let hL = kv('Grupamento', cartao.grupamento_completo || cartao.grupamento_id, xL, colW);
    let hR = kv('Data de empenho', _data(cartao.data_empenho)+'   ·   Turno: '+_esc(cartao.turno||'—'), xR, colW);
    y += Math.max(hL,hR)+2;
    ensure(14);
    hL = kv('Equipe', cartao.equipe||'—', xL, colW);
    hR = kv('Tipo de serviço', cartao.tipo_servico||'—', xR, colW);
    y += Math.max(hL,hR)+2;
    ensure(14);
    const opTxt = [cartao.operacao, cartao.operacao_descr].filter(Boolean).join(' — ') || '—';
    hL = kv('Operação', opTxt, xL, colW);
    hR = kv('Viatura', cartao.viatura||'—', xR, colW);
    y += Math.max(hL,hR)+3;

    // ── Equipe empregada ──
    ensure(10); rule(); y+=5;
    doc.setFont('helvetica','bold'); doc.setFontSize(8.5); doc.setTextColor(...GOLD);
    doc.text('EQUIPE EMPREGADA', M, y); y+=5;
    const patr = Array.isArray(cartao.patrulheiros) ? cartao.patrulheiros.filter(Boolean) : [];
    let h1 = kv('Comandante', cartao.comandante, xL, colW);
    let h2 = kv('Motorista', cartao.motorista, xR, colW);
    y += Math.max(h1,h2)+2;
    if(patr.length){ ensure(12); const hh = kv('Patrulheiro(s)', patr.join('  ·  '), xL, W); y += hh+2; }

    // ── Demandas ──
    ensure(10); rule(); y+=5;
    doc.setFont('helvetica','bold'); doc.setFontSize(8.5); doc.setTextColor(...GOLD);
    doc.text('DEMANDAS PARA ATENDIMENTO', M, y); y+=6;

    if(!demandas.length){
      doc.setFont('helvetica','italic'); doc.setFontSize(9.5); doc.setTextColor(...MUTED);
      doc.text('Nenhuma demanda lançada.', M, y); y+=6;
    }
    demandas.forEach((d,i)=>{
      const ord = _esc(d.ordem || (i+1));
      const r = respostas[String(d.ordem)] || respostas[String(i+1)] || null;
      ensure(26);
      // título da demanda
      doc.setFillColor(245,242,232); doc.setDrawColor(...GOLD); doc.setLineWidth(0.3);
      doc.roundedRect(M, y, W, 7, 1, 1, 'FD');
      doc.setFont('helvetica','bold'); doc.setFontSize(9); doc.setTextColor(...DARK);
      doc.text('DEMANDA '+ord + (d.municipio?('  —  '+_esc(d.municipio)):''), M+3, y+4.8);
      y+=10;
      // texto
      doc.setFont('helvetica','normal'); doc.setFontSize(9.3); doc.setTextColor(...INK);
      const tl = doc.splitTextToSize(_esc(d.texto||'—'), W);
      tl.forEach(line=>{ ensure(5); doc.text(line, M, y); y+=4.6; });
      if(d.endereco){ ensure(5); doc.setFontSize(8.5); doc.setTextColor(...MUTED); doc.text('Endereço/ref.: '+_esc(d.endereco), M, y); y+=4.6; }
      // anexos clicáveis
      const anx = Array.isArray(d.anexos) ? d.anexos.filter(a=>a && a.link) : [];
      if(anx.length){
        ensure(5); doc.setFontSize(8.5); doc.setTextColor(...MUTED); doc.text('Anexos:', M, y);
        let ax = M+14;
        anx.forEach((a,ai)=>{
          const label = (a.nome ? _esc(a.nome) : ('anexo '+(ai+1)));
          const tw = doc.getTextWidth(label)+4;
          if(ax+tw > PW-M){ y+=5; ax=M+14; ensure(5); }
          doc.setTextColor(40,90,160);
          doc.textWithLink('• '+label, ax, y, {url:a.link});
          ax += tw+4;
        });
        y+=5.5;
      }
      // resposta (se já atendida)
      if(r && r.atendida){
        ensure(10);
        doc.setFillColor(238,246,238); doc.setDrawColor(70,150,70); doc.setLineWidth(0.3);
        const parts = [
          atendidaLabel(r.atendida),
          r.reds? ('REDS: '+_esc(r.reds)) : '',
          r.auto_infracao? ('Auto: '+_esc(r.auto_infracao)) : '',
          r.ato_fiscalizacao? ('Ato Fisc.: '+_esc(r.ato_fiscalizacao)) : '',
          r.data_atendimento? ('Data: '+_data(r.data_atendimento)) : ''
        ].filter(Boolean).join('   ·   ');
        const rl = doc.splitTextToSize('✔ '+parts + (r.obs?('\nObs.: '+_esc(r.obs)):''), W-6);
        const bh = rl.length*4.4 + 4;
        doc.roundedRect(M, y, W, bh, 1, 1, 'FD');
        doc.setFont('helvetica','normal'); doc.setFontSize(8.5); doc.setTextColor(40,110,40);
        doc.text(rl, M+3, y+5);
        y += bh+2;
      }
      y+=3;
    });

    // ── Observações / alteração de escala ──
    const obs = cartao.observacoes_equipe;
    if(obs || cartao.alterou_escala){
      ensure(12); rule(); y+=5;
      doc.setFont('helvetica','bold'); doc.setFontSize(8.5); doc.setTextColor(...GOLD);
      doc.text('OBSERVAÇÕES', M, y); y+=5;
      if(cartao.alterou_escala){ const hh=kv('Alteração de escala', cartao.motivo_alteracao||'Sim', M, W); y+=hh+2; }
      if(obs){ doc.setFont('helvetica','normal'); doc.setFontSize(9.3); doc.setTextColor(...INK);
        doc.splitTextToSize(_esc(obs), W).forEach(l=>{ ensure(5); doc.text(l, M, y); y+=4.6; }); }
    }

    // ── Rodapé em todas as páginas ──
    const emitido = [cartao.criado_por_posto, cartao.criado_por_nome].filter(Boolean).join(' ');
    const pags = doc.internal.getNumberOfPages();
    for(let p=1;p<=pags;p++){
      doc.setPage(p);
      doc.setDrawColor(...GOLD); doc.setLineWidth(0.3); doc.line(M, PH-12, PW-M, PH-12);
      doc.setFont('helvetica','normal'); doc.setFontSize(7.5); doc.setTextColor(...MUTED);
      doc.text('Emitido por '+(emitido||'—')+'  ·  '+_data(cartao.criado_em||cartao.created_at), M, PH-8);
      doc.text(`Pág. ${p}/${pags}`, PW-M, PH-8, {align:'right'});
    }
    return doc;
  }

  function nomeArq(cartao){ return 'Cartao-Programa-'+String(cartao.numero||'').replace(/\//g,'-')+'.pdf'; }

  async function baixar(cartao){ const doc = await build(cartao); doc.save(nomeArq(cartao)); }
  async function blob(cartao){ const doc = await build(cartao); return doc.output('blob'); }

  // Envio por WhatsApp: no celular compartilha o PRÓPRIO PDF (Web Share API);
  // onde não dá, abre o WhatsApp com o LINK público do cartão.
  async function whatsapp(cartao, publicUrl){
    const texto = `*CARTÃO PROGRAMA Nº ${cartao.numero||''}*\n`+
      `${cartao.grupamento_completo||cartao.grupamento_id||''}\n`+
      `Data: ${_data(cartao.data_empenho)} · Turno: ${cartao.turno||'—'} · Equipe ${cartao.equipe||'—'}\n`+
      (publicUrl ? `\nAbra o cartão: ${publicUrl}` : '');
    try{
      const b = await blob(cartao);
      const file = new File([b], nomeArq(cartao), {type:'application/pdf'});
      if(navigator.canShare && navigator.canShare({files:[file]})){
        await navigator.share({ files:[file], title:'Cartão Programa '+(cartao.numero||''), text:texto });
        return 'share';
      }
    }catch(e){ if(e && e.name==='AbortError') return 'abort'; /* cai p/ link */ }
    window.open('https://wa.me/?text='+encodeURIComponent(texto), '_blank');
    return 'link';
  }

  global.CartaoPDF = { build, baixar, blob, whatsapp, carregarJsPDF, statusLabel, atendidaLabel, nomeArq };
})(window);

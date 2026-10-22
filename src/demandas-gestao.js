/* ══════════════════════════════════════════════════════════════════════
   demandas-gestao.js — seções de GESTÃO na gaveta do Controle de Demandas
   (compartilhado por nuden.html, ddu.html, ri.html, emergencia.html).

   Depende de globais já definidos no <script> inline de cada página:
     GERIR, GERIR_LABEL, atual, DADOS, API, H, TBL, S, MILITAR,
     atendidaN, fmtData, _patchAtual, render, kpis, abrir, toast
   e dos opcionais por módulo:
     RPC_BAIXAR    (ex. 'nuden_baixar')              — baixa manual
     SISTEMA_EXTERNO ('SEMAD' | 'Plataforma DDU' | '') — resposta externa
     FONTE + AUTO_URL (só FTP/Emergência)            — espelho da baixa na planilha

   Carregar DEPOIS do <script> inline:  <script src="demandas-gestao.js"></script>
   E em abrir(d) acrescentar:  + (GERIR ? gestaoExtraHtml(d) : '')
   ══════════════════════════════════════════════════════════════════════ */
(function(){
  if (document.getElementById('demandas-gestao-css')) return;
  const st = document.createElement('style'); st.id='demandas-gestao-css';
  st.textContent = `
    .bxgrid{display:grid;grid-template-columns:1fr 1fr;gap:10px 14px;margin:4px 0 12px}
    .bxgrid label{display:flex;flex-direction:column;gap:4px;font-size:10.5px;letter-spacing:.3px;text-transform:uppercase;color:var(--gold);font-weight:700}
    .bxgrid label.full{grid-column:1/-1}
    .bxgrid input,.bxgrid textarea{background:var(--bg-input);border:1px solid var(--border-mid);border-radius:7px;padding:8px 10px;color:var(--text-white);font-size:13px;outline:none;font-family:inherit;text-transform:none;letter-spacing:0;font-weight:400}
    .bxgrid input:focus,.bxgrid textarea:focus{border-color:var(--gold)}
    .hintx{font-size:10.5px;color:var(--text-hint);margin-top:7px}
    @media(max-width:560px){.bxgrid{grid-template-columns:1fr}}
  `;
  document.head.appendChild(st);
})();

function _ge(id){ return document.getElementById(id) || {}; }

// HTML das seções extras da gaveta (baixa manual + resposta externa)
function gestaoExtraHtml(d){
  if (typeof GERIR === 'undefined' || !GERIR) return '';
  let html = '';

  // ── Baixa manual (só enquanto não atendida) ──
  if (typeof RPC_BAIXAR !== 'undefined' && RPC_BAIXAR && !atendidaN(d)){
    html += `<div class="sec-t">Baixa manual · ${GERIR_LABEL}</div>`+
      `<div class="rs">`+
        `<div class="bxgrid">`+
          `<label>Data do atendimento<input type="date" id="bx-data"></label>`+
          `<label>Nº REDS (BO/BOS/RAT)<input id="bx-reds" placeholder="2026-000000000-000"></label>`+
          `<label>Nº GAIA / Ato de Fiscalização<input id="bx-gaia"></label>`+
          `<label>Nº Auto de Infração<input id="bx-auto"></label>`+
          `<label class="full">Resultado<input id="bx-result" placeholder="CONSTATADO / NÃO CONSTATADO…"></label>`+
          `<label class="full">Observações<textarea id="bx-obs" rows="2"></textarea></label>`+
        `</div>`+
        `<button class="anxbtn" onclick="darBaixaManual()">Registrar baixa</button>`+
        `<div class="hintx">Registra o atendimento igual ao Relatório de Serviço (grava no banco${(typeof FONTE!=='undefined'&&typeof AUTO_URL!=='undefined'&&AUTO_URL)?' e espelha na planilha':''}).</div>`+
      `</div>`;
  }

  // ── Resposta no sistema externo (SEMAD / plataforma DDU) ──
  if (typeof SISTEMA_EXTERNO !== 'undefined' && SISTEMA_EXTERNO){
    const jaExt = d.data_resposta_externa;
    html += `<div class="sec-t">Resposta no sistema externo · ${SISTEMA_EXTERNO}</div>`+
      (jaExt
        ? `<div class="rs" style="background:var(--success-bg);border-color:rgba(102,187,106,.35)">`+
            `✔ Respondida no <b>${SISTEMA_EXTERNO}</b> em <b>${fmtData(jaExt)}</b>${d.respondido_externo_por_nome?` · ${d.respondido_externo_por_nome}`:''}`+
            `<button class="anxbtn" style="margin-left:8px" onclick="desfazerExterno()">Desfazer</button></div>`
        : `<div class="rs">`+
            `<div style="margin-bottom:8px">Marque quando a resposta foi lançada no <b>${SISTEMA_EXTERNO}</b>:</div>`+
            `<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">`+
              `<input type="date" id="ext-data" class="yearsel">`+
              `<button class="anxbtn" onclick="marcarExterno()">Marcar como respondida</button>`+
            `</div>`+
            `<div class="hintx">Controle do Aux: não altera a baixa interna; marca a demanda como <b>FINALIZADA</b>.</div>`+
          `</div>`);
  }
  return html;
}

async function darBaixaManual(){
  if (!atual) return;
  const data = _ge('bx-data').value || new Date().toISOString().slice(0,10);
  const p_dados = {
    codigo: atual.codigo,
    data_atendimento: data,
    numero_reds: _ge('bx-reds').value || null,
    numero_gaia: _ge('bx-gaia').value || null,
    numero_auto_infracao: _ge('bx-auto').value || null,
    resultado: _ge('bx-result').value || null,
    observacoes_resposta: _ge('bx-obs').value || null,
    atendido_por_matricula: (S && S.matricula) || null,
    atendido_por_nome: MILITAR || null
  };
  try{
    const r = await fetch(`${API}/rest/v1/rpc/${RPC_BAIXAR}`, { method:'POST', headers:H, body: JSON.stringify({ p_dados }) });
    if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
    // espelho na planilha (FTP/Emergência têm FONTE + AUTO_URL)
    if (typeof FONTE !== 'undefined' && typeof AUTO_URL !== 'undefined' && AUTO_URL){
      try { await fetch(AUTO_URL, { method:'POST', headers:{'Content-Type':'text/plain;charset=utf-8'},
        body: JSON.stringify({ action:'baixar', fonte:FONTE, codigo:atual.codigo, atendimento:{
          data_atendimento:p_dados.data_atendimento, numero_reds:p_dados.numero_reds,
          numero_gaia:p_dados.numero_gaia, status_atendimento:'RESPONDIDA' } }) }); }
      catch(e){ /* espelho é best-effort */ }
    }
    Object.assign(atual, {
      data_atendimento:p_dados.data_atendimento,
      numero_reds:p_dados.numero_reds||atual.numero_reds,
      numero_gaia:p_dados.numero_gaia||atual.numero_gaia,
      numero_auto_infracao:p_dados.numero_auto_infracao||atual.numero_auto_infracao,
      resultado:p_dados.resultado||atual.resultado,
      observacoes_resposta:p_dados.observacoes_resposta||atual.observacoes_resposta,
      situacao:'RESPONDIDA', atendido_por_nome:MILITAR
    });
    const i = DADOS.findIndex(x=>x.id===atual.id); if (i>=0) DADOS[i]=atual;
    render(); kpis(); abrir(atual); toast('Baixa registrada.');
  }catch(e){ toast('Erro: '+(e.message||e)); }
}

async function marcarExterno(){
  if (!atual) return;
  const dt = _ge('ext-data').value || new Date().toISOString().slice(0,10);
  try{
    await _patchAtual({ data_resposta_externa:dt, situacao:'FINALIZADA',
      respondido_externo_por_matricula:(S&&S.matricula)||null, respondido_externo_por_nome:MILITAR||null });
    render(); kpis(); abrir(atual); toast('Marcada como respondida no '+SISTEMA_EXTERNO+'.');
  }catch(e){ toast('Erro: '+(e.message||e)); }
}

async function desfazerExterno(){
  if (!atual) return;
  try{
    await _patchAtual({ data_resposta_externa:null,
      situacao:(atual.data_atendimento?'RESPONDIDA':'PENDENTE'),
      respondido_externo_por_matricula:null, respondido_externo_por_nome:null });
    render(); kpis(); abrir(atual); toast('Resposta externa desfeita.');
  }catch(e){ toast('Erro: '+(e.message||e)); }
}

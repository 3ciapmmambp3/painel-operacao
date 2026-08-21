/*  ═══════════════════════════════════════════════════════════════════════
    APPS-SCRIPT-demandas.gs — Ponte de leitura do Painel de Demandas.

    Porta a lógica do app externo painel-3cia (lib/sheets.ts) para um Web App
    do Google Apps Script que LÊ a planilha de demandas + FÉRIAS e devolve o
    dashboard JÁ CALCULADO em JSON (totais, por tipo, por GP, atrasadas,
    pendentes, sugestão de apoio, férias). A página `painel-demandas.html` do
    painel só renderiza — não precisa de conta de serviço nem googleapis.

    COMO PUBLICAR:
      1. Abra a PLANILHA DE DEMANDAS no Google Sheets.
      2. Extensões → Apps Script. Cole TODO este arquivo (é JavaScript; os
         comentários // são válidos — NÃO cole markdown).
      3. Ajuste SHEET_ID abaixo (ou deixe '' para usar a planilha ativa).
      4. Implantar → Nova implantação → Tipo "App da Web":
         Executar como = Eu; Quem tem acesso = Qualquer pessoa.
      5. Copie a URL /exec e cole em DEMANDAS_SCRIPT_URL em painel-demandas.html.

    Colunas (fixas, A:N) em cada aba de tipo: A=id(0) B=data(1) D=município(3)
    E=GP(4) [DDU: I=GP(8)] K=situação(10). FERIAS: B=grupamento(1) D=militar(3)
    L=início(11) M=fim(12) N=grupamento longo(13).
    ═══════════════════════════════════════════════════════════════════════ */

var SHEET_ID = '';  // '' = planilha ativa (deste projeto). Ou cole o id da planilha de demandas.

var ABAS_CONFIG = [
  { key: 'NUDEN',      nome: 'NUDEN',      prazo: 90 },
  { key: 'DDU',        nome: 'DDU',        prazo: 90 },
  { key: 'FTP',        nome: 'FTP',        prazo: 4  },
  { key: 'EMERGENCIA', nome: 'EMERGENCIA', prazo: 4  },
  { key: 'REQUISICAO', nome: 'REQUISICAO', prazo: 20 },
  { key: 'DENUNCIA',   nome: 'DENUNCIA',   prazo: 90 },
  { key: 'MC',         nome: 'MC',         prazo: 45 }
];
var FERIAS_ABA = 'FERIAS';

var ORDEM_GPs = [
  '1 GP / 1 PEL / 3 CIA PM MAMB / BPM MAMB/GOVERNADOR VALADARES',
  '2 GP / 1 PEL / 3 CIA PM MAMB / BPM MAMB/MANTENA',
  '3 GP / 1 PEL / 3 CIA PM MAMB / BPM MAMB/AIMORES',
  '4 GP / 1 PEL / 3 CIA PM MAMB / BPM MAMB/CONSELHEIRO PENA',
  '5 GP / 1 PEL / 3 CIA PM MAMB / BPM MAMB/GUANHAES',
  '6 GP / 1 PEL / 3 CIA PM MAMB / BPM MAMB/SANTA MARIA DO SUACUI',
  '7 GP / 1 PEL / 3 CIA PM MAMB / BPM MAMB/SAO JOAO EVANGELISTA',
  '1 GP / 2 PEL / 3 CIA PM MAMB / BPM MAMB/IPATINGA',
  '2 GP / 2 PEL / 3 CIA PM MAMB / BPM MAMB/MARILIERIA',
  '3 GP / 2 PEL / 3 CIA PM MAMB / BPM MAMB/PINGO D AGUA',
  '4 GP / 2 PEL / 3 CIA PM MAMB / BPM MAMB/JOAO MOLEVADE',
  '5 GP / 2 PEL / 3 CIA PM MAMB / BPM MAMB/BARAO DE COCAIS',
  '6 GP / 2 PEL / 3 CIA PM MAMB / BPM MAMB/ITABIRA',
  '1 GP / 3 PEL / 3 CIA PM MAMB / BPM MAMB/MANHUACU',
  '2 GP / 3 PEL / 3 CIA PM MAMB / BPM MAMB/ALTO CAPARAO',
  '3 GP / 3 PEL / 3 CIA PM MAMB / BPM MAMB/MUTUM',
  '4 GP / 3 PEL / 3 CIA PM MAMB / BPM MAMB/IPANEMA',
  '5 GP / 3 PEL / 3 CIA PM MAMB / BPM MAMB/CARATINGA',
  '6 GP / 3 PEL / 3 CIA PM MAMB / BPM MAMB/PONTE NOVA',
  '7 GP / 3 PEL / 3 CIA PM MAMB / BPM MAMB/RAUL SOARES',
  '1 GP / 4 PEL / 3 CIA PM MAMB / BPM MAMB/TEOFILO OTONI',
  '2 GP / 4 PEL / 3 CIA PM MAMB / BPM MAMB/AGUAS FORMOSAS',
  '3 GP / 4 PEL / 3 CIA PM MAMB / BPM MAMB/ITAMBACURI',
  '4 GP / 4 PEL / 3 CIA PM MAMB / BPM MAMB/MALACACHETA',
  '5 GP / 4 PEL / 3 CIA PM MAMB / BPM MAMB/NANUQUE',
  '6 GP / 4 PEL / 3 CIA PM MAMB / BPM MAMB/NOVO CRUZEIRO',
  '1 GP / 5 PEL / 3 CIA PM MAMB / BPM MAMB/ALMENARA',
  '2 GP / 5 PEL / 3 CIA PM MAMB / BPM MAMB/ARACUAI',
  '3 GP / 5 PEL / 3 CIA PM MAMB / BPM MAMB/ITAOBIM',
  '4 GP / 5 PEL / 3 CIA PM MAMB / BPM MAMB/JEQUITINHONHA',
  '5 GP / 5 PEL / 3 CIA PM MAMB / BPM MAMB/PEDRA AZUL',
  '6 GP / 5 PEL / 3 CIA PM MAMB / BPM MAMB/RIO DO PRADO',
  '7 GP / 5 PEL / 3 CIA PM MAMB / BPM MAMB/SALTO DA DIVISA'
];
var ORDEM_IDX = {}; ORDEM_GPs.forEach(function(gp, i){ ORDEM_IDX[gp] = i; });

function norm(s){ return String(s == null ? '' : s).trim().toUpperCase().normalize('NFD').replace(/[̀-ͯ]/g, ''); }
function pelotaoDeGP(gp){ var m = gp.match(/(\d)\s*PEL/); return m ? m[1] : '?'; }
function nomeCurtoGP(gp){ var p = gp.split('/'); return (p[p.length-1] || gp).trim(); }
function cidadeDe(gp){ return norm(nomeCurtoGP(gp)); }

// Resolve GP (curto "GP CIDADE" OU longo) para o rótulo oficial de ORDEM_GPs.
function resolveGP(raw){
  if (!raw) return null;
  var full = norm(raw);
  for (var i=0;i<ORDEM_GPs.length;i++){ if (norm(ORDEM_GPs[i]) === full) return ORDEM_GPs[i]; }
  // por cidade (última parte após "/", ou o texto sem prefixo "GP ")
  var city = norm(String(raw).split('/').pop()).replace(/^GP\s+/, '');
  var mGP = String(raw).match(/^(\d)\s*GP/i);
  var mPEL = String(raw).match(/(\d)\s*PEL/i);
  var achou = null, candidatos = [];
  for (var j=0;j<ORDEM_GPs.length;j++){
    if (cidadeDe(ORDEM_GPs[j]) === city){ candidatos.push(ORDEM_GPs[j]); }
  }
  if (candidatos.length === 1) return candidatos[0];
  if (candidatos.length > 1 && mGP && mPEL){
    for (var k=0;k<candidatos.length;k++){
      if (candidatos[k].indexOf(mGP[1]+' GP')===0 && candidatos[k].indexOf(mPEL[1]+' PEL')>=0) return candidatos[k];
    }
  }
  return candidatos.length ? candidatos[0] : null;
}

function getSituacao(v){
  var s = norm(v);
  if (s === 'ATRASADA' || s === 'ATR') return 'ATRASADA';
  if (s === 'PENDENTE' || s === 'PEN') return 'PENDENTE';
  if (s === 'RESPONDIDA' || s === 'RES' || s === 'OK') return 'RESPONDIDA';
  return 'PENDENTE';
}
function parseData(v){
  if (v == null || v === '') return null;
  if (Object.prototype.toString.call(v) === '[object Date]' && !isNaN(v.getTime())) return v;
  var s = String(v).trim(), m;
  m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/); if (m) return new Date(+m[3], +m[2]-1, +m[1]);
  m = s.match(/^(\d{4})-(\d{2})-(\d{2})/);        if (m) return new Date(+m[1], +m[2]-1, +m[3]);
  return null;
}
function fmtData(d){ if(!d) return ''; return ('0'+d.getDate()).slice(-2)+'/'+('0'+(d.getMonth()+1)).slice(-2)+'/'+d.getFullYear(); }
function fmtIso(d){ if(!d) return ''; return d.getFullYear()+'-'+('0'+(d.getMonth()+1)).slice(-2)+'-'+('0'+d.getDate()).slice(-2); }

function calcularPainel(anoFiltro){
  var ss = SHEET_ID ? SpreadsheetApp.openById(SHEET_ID) : SpreadsheetApp.getActiveSpreadsheet();
  var hoje = new Date(); hoje.setHours(0,0,0,0);
  var todosAnos = {}, porTipoMap = {}, porGPMap = {}, porGPTipo = {};
  var atrasadas = [], pendentes = [];
  var totalRec=0, totalAtr=0, totalPen=0, totalRes=0;

  ORDEM_GPs.forEach(function(gp){
    porGPMap[gp] = { gp: gp, gpCurto: nomeCurtoGP(gp), pelotao: pelotaoDeGP(gp),
      rec:0, atr:0, pen:0, res:0, efetivo:0, emFerias:0, disponiveis:0, eficiencia:100 };
  });

  ABAS_CONFIG.forEach(function(cfg){
    porTipoMap[cfg.key] = { key: cfg.key, prazo: cfg.prazo, rec:0, atr:0, pen:0, res:0 };
    var sh = ss.getSheetByName(cfg.nome); if (!sh) return;
    var rows = sh.getDataRange().getValues(); if (rows.length <= 1) return;
    for (var r=1; r<rows.length; r++){
      var row = rows[r] || []; if (row.length < 2) continue;
      var sit = getSituacao(row[10]);
      var gpRaw = cfg.nome === 'DDU' ? String(row[8]||'') : String(row[4]||'');
      var gpOf = resolveGP(gpRaw);
      if (!gpOf || !porGPMap[gpOf]) continue;
      var dataObj = parseData(row[1]);
      var ano = dataObj ? dataObj.getFullYear() : null;
      if (ano) todosAnos[ano] = true;
      if (anoFiltro && ano && ano !== anoFiltro) continue;
      var mun = String(row[3]||'').trim();
      var idDem = String(row[0]||'').trim();
      totalRec++; porTipoMap[cfg.key].rec++; porGPMap[gpOf].rec++;
      if (!porGPTipo[gpOf]) porGPTipo[gpOf] = {};
      if (!porGPTipo[gpOf][cfg.key]) porGPTipo[gpOf][cfg.key] = { rec:0, atr:0, pen:0, res:0 };
      porGPTipo[gpOf][cfg.key].rec++;
      if (sit === 'ATRASADA'){
        totalAtr++; porTipoMap[cfg.key].atr++; porGPMap[gpOf].atr++; porGPTipo[gpOf][cfg.key].atr++;
        var diff = Math.floor((hoje.getTime() - (dataObj ? dataObj.getTime() : hoje.getTime()))/86400000);
        atrasadas.push({ tipo: cfg.key, gp: gpOf, gpCurto: nomeCurtoGP(gpOf), pelotao: pelotaoDeGP(gpOf),
          municipio: mun, dataStr: fmtData(dataObj), prazo: cfg.prazo,
          diasAtraso: Math.max(0, diff - cfg.prazo), ano: ano||0, demanda: idDem });
      } else if (sit === 'PENDENTE'){
        totalPen++; porTipoMap[cfg.key].pen++; porGPMap[gpOf].pen++; porGPTipo[gpOf][cfg.key].pen++;
        pendentes.push({ tipo: cfg.key, gp: gpOf, gpCurto: nomeCurtoGP(gpOf), pelotao: pelotaoDeGP(gpOf),
          municipio: mun, dataStr: fmtData(dataObj), prazo: cfg.prazo, ano: ano||0, demanda: idDem });
      } else {
        totalRes++; porTipoMap[cfg.key].res++; porGPMap[gpOf].res++; porGPTipo[gpOf][cfg.key].res++;
      }
    }
  });

  // Efetivo e Férias
  var militaresPorGP = {}, feriasHojeCount = {}, feriasLista = [], feriasHojeLista = [];
  var fsh = ss.getSheetByName(FERIAS_ABA);
  if (fsh){
    var fRows = fsh.getDataRange().getValues();
    var EXC = ['CMT','SRAI','P1','P2','P3','P4','P5'];
    for (var fr=1; fr<fRows.length; fr++){
      var frow = fRows[fr] || []; if (frow.length < 4) continue;
      var gpRawB = String(frow[1]||'').trim(), gpRawN = String(frow[13]||'').trim();
      var militar = String(frow[3]||'').trim();
      var ini = parseData(frow[11]), fim = parseData(frow[12]);
      if (!militar || !ini || !fim) continue;
      if (EXC.indexOf(gpRawB.toUpperCase()) >= 0) continue;
      var gpOf = resolveGP(gpRawB) || resolveGP(gpRawN);
      var fimD = new Date(fim); fimD.setHours(23,59,59);
      var emFerias = ini <= hoje && fimD >= hoje;
      var reg = { gp: gpOf||gpRawB||'N/A', gpCurto: gpOf?nomeCurtoGP(gpOf):(gpRawB||'N/A'),
        pelotao: gpOf?pelotaoDeGP(gpOf):'N/A', militar: militar,
        inicio: fmtData(ini), fim: fmtData(fim), inicioIso: fmtIso(ini), fimIso: fmtIso(fim), gpLocal: gpRawB };
      if (gpOf && porGPMap[gpOf]){
        if (!militaresPorGP[gpOf]) militaresPorGP[gpOf] = {};
        militaresPorGP[gpOf][militar] = true;
        if (emFerias){ feriasHojeCount[gpOf] = (feriasHojeCount[gpOf]||0)+1; feriasHojeLista.push(reg); }
      } else if (emFerias){ feriasHojeLista.push(reg); }
      feriasLista.push(reg);
    }
  }

  ORDEM_GPs.forEach(function(gp){
    var g = porGPMap[gp];
    g.efetivo = militaresPorGP[gp] ? Object.keys(militaresPorGP[gp]).length : 0;
    g.emFerias = feriasHojeCount[gp] || 0;
    g.disponiveis = Math.max(0, g.efetivo - g.emFerias);
    g.eficiencia = g.rec > 0 ? Math.round((g.res/g.rec)*100) : 100;
  });

  var porGPArr = Object.keys(porGPMap).map(function(k){return porGPMap[k];})
    .sort(function(a,b){ return (ORDEM_IDX[a.gp]||999) - (ORDEM_IDX[b.gp]||999); });
  var precisam = porGPArr.filter(function(g){ return g.atr>0 || g.pen>0; })
    .sort(function(a,b){ return (b.atr*3+b.pen) - (a.atr*3+a.pen); });
  var apoio = precisam.map(function(gpN){
    var cands = porGPArr.filter(function(g){ return g.gp!==gpN.gp && g.eficiencia>=75 && g.efetivo>=3 && g.disponiveis>=3; });
    var toCand = function(g){ return { gp: g, motivo: (g.disponiveis-2)+' militar(es) apto(s) para apoio (Eficiencia: '+g.eficiencia+'%)' }; };
    return { gpNecessita: gpN,
      intraPlotao: cands.filter(function(g){return g.pelotao===gpN.pelotao;}).slice(0,6).map(toCand),
      extraPlotao: cands.filter(function(g){return g.pelotao!==gpN.pelotao;}).slice(0,5).map(toCand) };
  });

  return {
    totalRec: totalRec, totalAtr: totalAtr, totalPen: totalPen, totalRes: totalRes,
    porTipo: Object.keys(porTipoMap).map(function(k){return porTipoMap[k];}),
    porGP: porGPArr, porGPTipo: porGPTipo,
    atrasadas: atrasadas.sort(function(a,b){return b.diasAtraso - a.diasAtraso;}),
    pendentes: pendentes, apoio: apoio,
    todasFerias: feriasLista, feriasHoje: feriasHojeLista,
    anos: Object.keys(todosAnos).map(Number).sort(function(a,b){return b-a;}),
    atualizadoEm: Utilities.formatDate(new Date(), 'America/Sao_Paulo', 'dd/MM/yyyy HH:mm')
  };
}

function doGet(e){
  try {
    var ano = e && e.parameter && e.parameter.ano ? parseInt(e.parameter.ano, 10) : null;
    var dados = calcularPainel(ano || undefined);
    return ContentService.createTextOutput(JSON.stringify(dados)).setMimeType(ContentService.MimeType.JSON);
  } catch (err) {
    return ContentService.createTextOutput(JSON.stringify({ error: String(err) })).setMimeType(ContentService.MimeType.JSON);
  }
}

/* ══════════════════════════════════════════════════════════════════════
   APPS-SCRIPT-nuden-sync.gs — NUDEN: planilha → Supabase (painel-operacao)
   3ª Cia PM MAmb · Controle de Demandas

   O QUE FAZ
     Lê as DUAS abas da planilha "NUDEN - 3ª CIA MAMB", mapeia as colunas
     POR NOME (as abas têm ordem e nomes diferentes), deduplica por CÓDIGO
     DEMANDA (== Nº DADOC/SENHA) preferindo a aba do robô, e manda tudo para
     o Supabase via RPC public.nuden_sync (upsert). Rode manualmente a 1ª vez
     (menu Executar → nudenSyncAgora) e depois instale o gatilho de tempo
     (instalarGatilhoNuden) para rodar sozinho.

   COMO USAR
     1. Abra a planilha dona (conta 3ciapmmamb.p3) → Extensões → Apps Script.
     2. Cole este arquivo. Confira NUDEN_SHEET_ID abaixo ('' = planilha ativa).
     3. Rode nudenSyncAgora uma vez (autorize o acesso). Veja o Log.
     4. Rode instalarGatilhoNuden (cria 1 gatilho a cada FREQ_HORAS horas).
   ══════════════════════════════════════════════════════════════════════ */

// ─── CONFIG ────────────────────────────────────────────────────────────
var SUPABASE_URL  = 'https://zrnbebjszwkmquzthjfa.supabase.co';
var SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpybmJlYmpzendrbXF1enRoamZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkzOTA4MzEsImV4cCI6MjA5NDk2NjgzMX0.di9t2SOCTLZ2uPFOnTOiy6srvt7GC5cdqenZZScXve4';

var NUDEN_SHEET_ID = '1Pp1X2_R0J62CmvrHLaumbxG_fbVQZCxybCvabDqDuog'; // '' = planilha ativa
var NUDEN_DRIVE_FOLDER = '1JO_llTri4rw5pY7bkV3uC1FECQL-zf6s';          // pasta dos PDFs da NUDEN ('' = não anexa PDF)
var FREQ_HORAS     = 6;     // frequência do gatilho de tempo
var PRAZO_DIAS     = 85;    // fallback p/ calcular vencimento quando a planilha não traz

// Cada aba: nome, linha do cabeçalho e o mapa campo→[nomes aceitos do cabeçalho].
// O resolvedor normaliza (maiúsculas, sem acento, espaços colapsados) e pega a
// 1ª coluna cujo cabeçalho casar com qualquer alias — robusto a variações.
var ABAS = [
  { nome: 'NUDEN_3_CIA', fonte_aba: 'robo', header: 2, map: {
      codigo:              ['CODIGO DEMANDA','CODIGO DA DEMANDA'],
      tipo_demanda:        ['DENUNCIA','TIPO DE DEMANDA','TIPO DA DEMANDA'],
      data_gerada:         ['DATA GERADA'],
      natureza:            ['NATUREZA DA INFRACAO','NATUREZA'],
      municipio:           ['MUNICIPIO'],
      endereco:            ['ENDERECO'],
      fracao_responsavel:  ['FRACAO RESPONSAVEL'],
      data_envio:          ['DATA ENVIO A FRACAO','DATA DE ENVIO A FRACAO'],
      data_vencimento:     ['DATA VENCIMENTO','DATA DE VENCIMENTO'],
      status_prazo:        ['STATUS DO PRAZO'],
      data_atendimento:    ['DATA ATENDIMENTO','DATA DO ATENDIMENTO'],
      numero_gaia:         ['NUMERO DO GAIA','N DO GAIA','GAIA'],
      numero_reds:         ['NUMERO DO REDS','N DO REDS','REDS'],
      resultado:           ['RESULTADO'],
      status_atendimento:  ['STATUS DO ATENDIMENTO'],
      info_complementares: ['INFORMACOES COMPLEMENTARES','INFORMACOES']
  }},
  { nome: 'NUDEN_03CIAMAMB', fonte_aba: 'manual', header: 1, map: {
      codigo:              ['N DADOC/SENHA','N DADOC SENHA','DADOC/SENHA','DADOC','SENHA'],
      tipo_demanda:        ['TIPO DE DEMANDA','TIPO DA DEMANDA'],
      data_gerada:         ['DATA GERADA'],
      natureza:            ['TIPO INFRACAO','TIPO DE INFRACAO','NATUREZA'],
      municipio:           ['MUNICIPIO'],
      endereco:            ['ENDERECO'],
      fracao_responsavel:  ['GRUPAMENTO','FRACAO RESPONSAVEL'],
      data_envio:          ['DATA ENVIADO PARA O GRUPAMENTO','DATA ENVIO'],
      data_vencimento:     ['EXPIRACAO','DATA PRORROGADA','VENCIMENTO'],
      status_prazo:        ['SITUACAO'],
      data_atendimento:    ['DATA DA RESPONSTA','DATA DA RESPOSTA','DATA RESPOSTA','DATA_FISC_PMMG','DATA FISC PMMG'],
      numero_reds:         ['N REDS','NUMERO DO REDS','REDS'],
      status_atendimento:  ['STATUS','STATUS RESPOSTA A SEMAD'],
      info_complementares: ['OBSERVACOES','INFORMACOES']
  }}
];

// ─── EXECUÇÃO ──────────────────────────────────────────────────────────
function nudenSyncAgora() {
  var ss = NUDEN_SHEET_ID ? SpreadsheetApp.openById(NUDEN_SHEET_ID) : SpreadsheetApp.getActiveSpreadsheet();
  var porCodigo = {};   // codigo → linha normalizada (robô sobrescreve manual)
  var pdfs = indexarPdfsDrive();   // nomeNormalizado → { file_id, nome, web_view_link }

  ABAS.forEach(function (cfg) {
    var sh = ss.getSheetByName(cfg.nome);
    if (!sh) { Logger.log('Aba não encontrada: ' + cfg.nome); return; }
    var dados = sh.getDataRange().getValues();
    if (dados.length < cfg.header) return;

    var cabec = dados[cfg.header - 1].map(normHead);
    var idx = {};
    Object.keys(cfg.map).forEach(function (campo) {
      idx[campo] = acharCol(cabec, cfg.map[campo]);
    });

    for (var i = cfg.header; i < dados.length; i++) {
      var linha = dados[i];
      var cod = cel(linha, idx.codigo);
      if (!cod) continue;

      var obj = {
        codigo:              cod,
        tipo_demanda:        cel(linha, idx.tipo_demanda),
        data_gerada:         data(linha, idx.data_gerada),
        natureza:            cel(linha, idx.natureza),
        municipio:           cel(linha, idx.municipio),
        endereco:            cel(linha, idx.endereco),
        fracao_responsavel:  cel(linha, idx.fracao_responsavel),
        data_envio:          data(linha, idx.data_envio),
        data_vencimento:     data(linha, idx.data_vencimento),
        status_prazo:        cel(linha, idx.status_prazo),
        data_atendimento:    data(linha, idx.data_atendimento),
        numero_gaia:         cel(linha, idx.numero_gaia),
        numero_reds:         cel(linha, idx.numero_reds),
        resultado:           cel(linha, idx.resultado),
        status_atendimento:  cel(linha, idx.status_atendimento),
        info_complementares: cel(linha, idx.info_complementares),
        fonte_aba:           cfg.fonte_aba,
        raw:                 { aba: cfg.nome }
      };
      // fallback de vencimento: envio + PRAZO_DIAS quando a planilha não traz
      if (!obj.data_vencimento && obj.data_envio) obj.data_vencimento = addDias(obj.data_envio, PRAZO_DIAS);

      // PDF da denúncia: casa um arquivo do Drive cujo nome contenha o código
      var pdf = acharPdf(pdfs, cod);
      if (pdf) obj.anexos = [pdf];

      // dedupe: robô é autoritativo; não deixa a manual sobrescrever a robô
      var ja = porCodigo[cod];
      if (!ja || cfg.fonte_aba === 'robo') porCodigo[cod] = obj;
    }
  });

  var linhas = Object.keys(porCodigo).map(function (k) { return porCodigo[k]; });
  Logger.log('NUDEN: ' + linhas.length + ' demandas para sincronizar.');
  if (!linhas.length) return;

  // envia em lotes p/ não estourar o corpo da requisição
  var LOTE = 500, inseridas = 0, atualizadas = 0;
  for (var j = 0; j < linhas.length; j += LOTE) {
    var r = enviarRpc('nuden_sync', { linhas: linhas.slice(j, j + LOTE) });
    if (r && r[0]) { inseridas += r[0].inseridas || 0; atualizadas += r[0].atualizadas || 0; }
  }
  Logger.log('NUDEN sync OK — inseridas: ' + inseridas + ' · atualizadas: ' + atualizadas);
}

function enviarRpc(fn, body) {
  var res = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/' + fn, {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: SUPABASE_ANON, Authorization: 'Bearer ' + SUPABASE_ANON },
    payload: JSON.stringify(body),
    muteHttpExceptions: true
  });
  var code = res.getResponseCode();
  if (code >= 300) { Logger.log('RPC ' + fn + ' ERRO ' + code + ': ' + res.getContentText()); return null; }
  try { return JSON.parse(res.getContentText()); } catch (e) { return null; }
}

// ─── GATILHO ───────────────────────────────────────────────────────────
function instalarGatilhoNuden() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'nudenSyncAgora') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('nudenSyncAgora').timeBased().everyHours(FREQ_HORAS).create();
  Logger.log('Gatilho NUDEN instalado: a cada ' + FREQ_HORAS + 'h.');
}

// ─── DRIVE (PDF da denúncia) ───────────────────────────────────────────
// Indexa os arquivos da pasta NUDEN uma vez; depois casa por código no nome.
function indexarPdfsDrive() {
  var idx = [];
  if (!NUDEN_DRIVE_FOLDER) return idx;
  try {
    var folder = DriveApp.getFolderById(NUDEN_DRIVE_FOLDER);
    var it = folder.getFiles();
    while (it.hasNext()) {
      var f = it.next();
      idx.push({ nomeNorm: normCod(f.getName()), file_id: f.getId(), nome: f.getName(),
                 web_view_link: 'https://drive.google.com/file/d/' + f.getId() + '/view' });
    }
  } catch (e) { Logger.log('Drive NUDEN indisponível: ' + e); }
  return idx;
}
function acharPdf(idx, codigo) {
  var c = normCod(codigo);
  if (!c || !idx.length) return null;
  for (var i = 0; i < idx.length; i++) if (idx[i].nomeNorm.indexOf(c) >= 0)
    return { file_id: idx[i].file_id, nome: idx[i].nome, web_view_link: idx[i].web_view_link };
  return null;
}
function normCod(s) { return String(s == null ? '' : s).toUpperCase().replace(/[^A-Z0-9]/g, ''); }

// ─── HELPERS ───────────────────────────────────────────────────────────
function normHead(s) {
  return String(s == null ? '' : s)
    .normalize('NFD').replace(/[̀-ͯ]/g, '')   // tira acento
    .toUpperCase().replace(/[.º°]/g, '')       // tira ponto e símbolo de grau
    .replace(/\s+/g, ' ').trim();
}
function acharCol(cabec, aliases) {
  var al = aliases.map(normHead);
  for (var c = 0; c < cabec.length; c++) if (al.indexOf(cabec[c]) >= 0) return c;
  // fallback: casa por "contém" (cabeçalho começa com / inclui o alias)
  for (var c2 = 0; c2 < cabec.length; c2++)
    for (var a = 0; a < al.length; a++)
      if (al[a] && cabec[c2].indexOf(al[a]) >= 0) return c2;
  return -1;
}
function cel(linha, i) {
  if (i == null || i < 0 || i >= linha.length) return '';
  var v = linha[i];
  return (v == null) ? '' : String(v).trim();
}
function data(linha, i) {           // devolve ISO yyyy-mm-dd ou ''
  if (i == null || i < 0 || i >= linha.length) return '';
  var v = linha[i];
  if (v instanceof Date) return iso(v);
  var s = String(v == null ? '' : v).trim();
  if (!s) return '';
  var m = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})$/);   // dd/mm/aaaa
  if (m) { var a = m[3].length === 2 ? '20' + m[3] : m[3]; return a + '-' + pad(m[2]) + '-' + pad(m[1]); }
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10);
  var d = new Date(s); return isNaN(d) ? '' : iso(d);
}
function iso(d)   { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
function pad(n)   { return String(n).length < 2 ? '0' + n : String(n); }
function addDias(isoStr, n) {
  var p = isoStr.split('-').map(Number);
  return iso(new Date(p[0], p[1] - 1, p[2] + n));
}

/* ══════════════════════════════════════════════════════════════════════
   AutomaçãoCastro.gs — NUDEN, DDU, FTP/RI e Emergência: planilha ↔ Supabase
   3ª Cia PM MAmb · Controle de Demandas (painel-operacao)
   >>> No editor do Apps Script, nomeie este arquivo como "AutomaçãoCastro". <<<

   O QUE FAZ
     1) SYNC (planilha → Supabase): lê as abas de cada FONTE, mapeia as colunas
        POR NOME, deduplica por CÓDIGO, casa o(s) documento(s) do Drive e manda
        tudo p/ o Supabase via RPC (*_sync, upsert). Completa Ato/REDS/data das
        ATENDIDAS ANTIGAS por uma aba de respostas (BD_*).
     2) WEB APP (painel → planilha+Drive+Supabase): doPost com
        action='lancar'  → sobe o PDF no Drive, gera o código, grava a linha na
                            planilha e chama *_sync (espelha nos 3 lugares);
        action='baixar'  → espelha o atendimento de volta na planilha (a baixa
                            no banco é feita pelo Relatório via *_baixar).

     COMANDOS (menu Executar):
       nudenSyncAgora / dduSyncAgora / riSyncAgora / emergenciaSyncAgora
       sincronizarTudo       → todas as fontes (use este no gatilho)
       instalarGatilhoNuden  → cria 1 gatilho de tempo p/ sincronizarTudo

   PUBLICAR O WEB APP (p/ o lançamento manual funcionar):
     Implantar ▸ Nova implantação ▸ Tipo "App da Web" ▸ Executar como EU ▸
     Quem tem acesso "Qualquer pessoa" ▸ copiar a URL /exec e colar em
     AUTOMACAO_CASTRO_URL no src/config.js (ou no topo de ri.html/emergencia.html).

   PRÉ-REQUISITOS (conta que roda o script, ex. 3ciapmmamb.p3):
     • ACESSO DE EDIÇÃO às 4 planilhas e às pastas do Drive.
     • rode db/151 (NUDEN), db/152 (DDU), db/154 (RI) e db/155 (Emergência).

   Tudo encapsulado no namespace AutomacaoCastro (sem colidir com outros .gs).
   ══════════════════════════════════════════════════════════════════════ */

// ─── COMANDOS (únicos globais) ─────────────────────────────────────────
function nudenSyncAgora()       { return AutomacaoCastro.run('NUDEN'); }
function dduSyncAgora()         { return AutomacaoCastro.run('DDU'); }
function riSyncAgora()          { return AutomacaoCastro.run('RI'); }
function emergenciaSyncAgora()  { return AutomacaoCastro.run('EMERGENCIA'); }
function sincronizarTudo()      { ['NUDEN','DDU','RI','EMERGENCIA'].forEach(function(k){ AutomacaoCastro.run(k); }); }
function instalarGatilhoNuden() { return AutomacaoCastro.instalarGatilho(); }

// ─── WEB APP (lançamento manual / espelho da baixa, chamado pelo painel) ─
function doPost(e)             { return AutomacaoCastro.doPost(e); }
function doGet(e)              { return AutomacaoCastro.doGet(e); }

// ─── MÓDULO ────────────────────────────────────────────────────────────
var AutomacaoCastro = (function () {

  var COMUM = {
    SUPABASE_URL:  'https://zrnbebjszwkmquzthjfa.supabase.co',
    SUPABASE_ANON: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpybmJlYmpzendrbXF1enRoamZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkzOTA4MzEsImV4cCI6MjA5NDk2NjgzMX0.di9t2SOCTLZ2uPFOnTOiy6srvt7GC5cdqenZZScXve4',
    FREQ_HORAS: 6,
    PRAZO_DIAS: 85
  };

  // Mapa padrão da aba do ROBÔ (NUDEN_3_CIA e DDU_3_CIA têm o MESMO layout).
  var MAP_ROBO = {
    codigo:              ['CODIGO DEMANDA','CODIGO DA DEMANDA'],
    tipo_demanda:        ['TIPO DE DEMANDA','DENUNCIA'],
    data_gerada:         ['DATA GERADA'],
    natureza:            ['NATUREZA DA INFRACAO','NATUREZA'],
    municipio:           ['MUNICIPIO'],
    endereco:            ['ENDERECO'],
    fracao_responsavel:  ['FRACAO RESPONSAVEL'],
    data_envio:          ['DATA ENVIO A FRACAO','DATA DE ENVIO A FRACAO'],
    data_vencimento:     ['DATA VENCIMENTO','DATA DE VENCIMENTO'],
    status_prazo:        ['STATUS DO PRAZO'],
    data_atendimento:    ['DATA ATENDIMENTO','DATA DO ATENDIMENTO'],
    numero_gaia:         ['NUMERO DO GAIA','N DO GAIA','GAIA','ATO DE FISCALIZACAO','N CODIGO ID SISFIS','ID SISFIS'],
    numero_reds:         ['NUMERO DO REDS','N DO REDS','REDS'],
    resultado:           ['RESULTADO'],
    status_atendimento:  ['STATUS DO ATENDIMENTO'],
    info_complementares: ['INFORMACOES COMPLEMENTARES','INFORMACOES']
  };

  var FONTES = {
    NUDEN: {
      rpc: 'nuden_sync',
      sheetId: '1Pp1X2_R0J62CmvrHLaumbxG_fbVQZCxybCvabDqDuog',
      driveFolder: '1JO_llTri4rw5pY7bkV3uC1FECQL-zf6s',
      tipoDefault: 'DENÚNCIA',
      // completa Ato/REDS/data das atendidas antigas
      dadoc: { aba: 'BD_DENUNCIASDADOC', cod: 0, data: 1, reds: 3, atoCols: [2] },
      abas: [
        { nome: 'NUDEN_3_CIA', fonte_aba: 'robo', header: 2, map: MAP_ROBO },
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
            numero_gaia:         ['N CODIGO ID SISFIS','CODIGO ID SISFIS','ID SISFIS','SISFIS','ATO DE FISCALIZACAO'],
            numero_reds:         ['N REDS','NUMERO DO REDS','REDS'],
            status_atendimento:  ['STATUS','STATUS RESPOSTA A SEMAD'],
            info_complementares: ['OBSERVACOES','INFORMACOES']
        }}
      ]
    },
    DDU: {
      rpc: 'ddu_sync',
      sheetId: '110Y-aQXzc7WiDHIt5KNfm77lycreIPB0kUQN7VxDMRY',
      driveFolder: '1GqD_xvw5gUcozhEAYV4oQl7FrIBpaTK5',
      tipoDefault: 'DDU',
      dadoc: { aba: 'RESPOSTADDU', cod: 0, data: 3, reds: 1, atoCols: [4, 2] },  // ato = ID SISFIS, senão AUTO
      abas: [
        { nome: 'DDU_3_CIA', fonte_aba: 'robo', header: 2, map: MAP_ROBO },
        { nome: 'DDU_3ªCIAMAMB', fonte_aba: 'manual', header: 1, map: {
            codigo:              ['PROTOCOLO'],
            data_gerada:         ['DATA GERADA'],
            natureza:            ['TIPO DE INFRACAO','TIPO INFRACAO','NATUREZA'],
            municipio:           ['CIDADE','MUNICIPIO'],
            fracao_responsavel:  ['GP RESPONSAVEL','GRUPAMENTO'],
            data_envio:          ['DATA ENVIADA','DATA ENVIO'],
            data_vencimento:     ['EXPIRACAO','DATA PRORROGADA'],
            status_prazo:        ['SITUACAO'],
            data_atendimento:    ['DATA ATENDIMENTO','DATA RESPOSTA DDU'],
            numero_gaia:         ['N SISFIS','SISFIS','AUTO DE INFRACAO/NOTIFICACAO','AUTO'],
            numero_reds:         ['REDS'],
            status_atendimento:  ['STATUS RESPOSTA A PLATAFORNA DDU','STATUS']
        }}
      ]
    },
    RI: {
      rpc: 'ri_sync',
      sheetId: '1n7AYqalb-Bs1l2y7cUl9_6GxwNmQR3IcTzvbd7nogGw',
      driveFolder: '1LwYWj4MQF110dOrygv8HWk2DTwKiZwVm',
      tipoDefault: 'FTP',
      prazoDias: 4,
      dadoc: { aba: 'BD_FTP', cod: 0, data: 1, reds: 2, atoCols: [3] },
      abas: [
        { nome: 'FTP 3ª CIA MAMB', fonte_aba: 'manual', header: 1, map: {
            codigo:              ['RI/ANO','RI ANO'],
            natureza:            ['NOME UC'],
            endereco:            ['TIPO UC'],
            municipio:           ['MUNICIPIO'],
            fracao_responsavel:  ['GRUPAMENTO'],
            data_gerada:         ['DATA RECEBIDO'],
            data_envio:          ['DATA ENVIADO PARA O GRUPAMENTO','DATA ENVIADO'],
            data_vencimento:     ['EXPIRACAO'],
            status_prazo:        ['SITUACAO'],
            data_atendimento:    ['DATA RESPOSTA','DATA FISCALIZACAO'],
            numero_gaia:         ['ID SISFIS','SISFIS'],
            numero_reds:         ['REDS'],
            status_atendimento:  ['STATUS'],
            info_complementares: ['PROTOCOLO DE ENVIO','PROTOCOLO']
        }}
      ]
    },
    EMERGENCIA: {
      rpc: 'emergencia_sync',
      sheetId: '1HSyM-g1KPgai4n6KFknvNz8nnnzr3J7_ljGJk3NV0uE',
      driveFolder: '1z0ZceiGhQbyRq2bp2RKP1gmAzCgZmgpN',
      tipoDefault: 'EMERGÊNCIA',
      prazoDias: 4,
      dadoc: { aba: 'BD_EMERGENCIA', cod: 0, data: 1, reds: 2, atoCols: [3] },
      abas: [
        { nome: 'EMERGENCIA_3ªCIAMAMB', fonte_aba: 'manual', header: 2, map: {
            codigo:              ['N PROTOC','PROTOCOLO','N PROTOCOLO'],
            natureza:            ['MODALIDADE DO ACIDENTE','MODALIDADE'],
            info_complementares: ['PRODUTO'],
            municipio:           ['MUNICIPIO'],
            fracao_responsavel:  ['GRUPAMENTO'],
            data_gerada:         ['DATA'],
            data_atendimento:    ['DATA DO ATENDIMENTO','DATA ATENDIMENTO'],
            status_prazo:        ['SITUACAO'],
            numero_gaia:         ['SISFIS'],
            numero_reds:         ['REDS'],
            status_atendimento:  ['STATUS']
        }}
      ]
    }
  };

  // ─── EXECUÇÃO (por fonte) ────────────────────────────────────────────
  function run(fonteKey) {
    var F = FONTES[fonteKey];
    if (!F) { Logger.log('Fonte desconhecida: ' + fonteKey); return; }
    var ss = SpreadsheetApp.openById(F.sheetId);
    var porCodigo = {};
    var drive = indexarDrive(F.driveFolder);
    var dadoc = indexarDadoc(ss, F.dadoc);

    F.abas.forEach(function (cfg) {
      var sh = ss.getSheetByName(cfg.nome);
      if (!sh) { Logger.log('[' + fonteKey + '] aba não encontrada: ' + cfg.nome); return; }
      var dados = sh.getDataRange().getValues();
      if (dados.length < cfg.header) return;
      var cabec = dados[cfg.header - 1].map(normHead);
      var idx = {}; Object.keys(cfg.map).forEach(function (campo) { idx[campo] = acharCol(cabec, cfg.map[campo]); });

      // coluna "CLIQUE PARA BAIXAR": o link do PDF já está na própria linha
      // (mais confiável que casar pelo nome do arquivo no Drive). Lê o hyperlink
      // tanto de célula-link quanto de fórmula =HYPERLINK.
      var idxLink = acharCol(cabec, ['CLIQUE PARA BAIXAR', 'BAIXAR', 'LINK DO PDF']);
      var rtvLink = null, fmLink = null;
      if (idxLink >= 0 && dados.length > cfg.header) {
        var rng = sh.getRange(cfg.header + 1, idxLink + 1, dados.length - cfg.header, 1);
        try { rtvLink = rng.getRichTextValues(); } catch (e) {}
        try { fmLink = rng.getFormulas(); } catch (e) {}
      }

      for (var i = cfg.header; i < dados.length; i++) {
        var linha = dados[i];
        var cod = cel(linha, idx.codigo);
        if (!cod) continue;
        var obj = {
          codigo: cod,
          tipo_demanda:        cel(linha, idx.tipo_demanda) || F.tipoDefault || '',
          data_gerada:         dataIso(linha, idx.data_gerada),
          natureza:            cel(linha, idx.natureza),
          municipio:           cel(linha, idx.municipio),
          endereco:            cel(linha, idx.endereco),
          fracao_responsavel:  cel(linha, idx.fracao_responsavel),
          data_envio:          dataIso(linha, idx.data_envio),
          data_vencimento:     dataIso(linha, idx.data_vencimento),
          status_prazo:        cel(linha, idx.status_prazo),
          data_atendimento:    dataIso(linha, idx.data_atendimento),
          numero_gaia:         cel(linha, idx.numero_gaia),
          numero_reds:         cel(linha, idx.numero_reds),
          resultado:           cel(linha, idx.resultado),
          status_atendimento:  cel(linha, idx.status_atendimento),
          info_complementares: cel(linha, idx.info_complementares),
          fonte_aba:           cfg.fonte_aba,
          raw:                 { aba: cfg.nome }
        };
        var _base = obj.data_envio || obj.data_gerada;
        var _prazo = F.prazoDias || COMUM.PRAZO_DIAS;
        if (!obj.data_vencimento && _base) obj.data_vencimento = addDias(_base, _prazo);
        // 1º) link direto da coluna "CLIQUE PARA BAIXAR"; 2º) Drive pelo código/número.
        var slink = linkDaCelula(rtvLink, fmLink, i - cfg.header, idxLink);
        if (slink) obj.anexos = [{ tipo: 'arquivo', nome: 'Documento (' + cod + ')', web_view_link: slink }];
        else { var anx = acharAnexos(drive, cod, obj.municipio); if (anx) obj.anexos = anx; }
        var ja = porCodigo[cod];
        if (!ja || cfg.fonte_aba === 'robo') porCodigo[cod] = obj;
      }
    });

    // completa o Ato/REDS/data das atendidas ANTIGAS (só o que estiver vazio)
    Object.keys(porCodigo).forEach(function (cod) {
      var o = porCodigo[cod], d = dadoc[normCod(cod)];
      if (!d) return;
      if (!o.numero_gaia && d.ato)       o.numero_gaia = d.ato;
      if (!o.numero_reds && d.reds)      o.numero_reds = d.reds;
      if (!o.data_atendimento && d.data) o.data_atendimento = d.data;
    });

    var linhas = Object.keys(porCodigo).map(function (k) { return porCodigo[k]; });
    Logger.log('[' + fonteKey + '] ' + linhas.length + ' demandas para sincronizar.');
    if (!linhas.length) return;

    var LOTE = 500, ins = 0, upd = 0;
    for (var j = 0; j < linhas.length; j += LOTE) {
      var r = enviarRpc(F.rpc, { linhas: linhas.slice(j, j + LOTE) });
      if (r && r[0]) { ins += r[0].inseridas || 0; upd += r[0].atualizadas || 0; }
    }
    Logger.log('[' + fonteKey + '] OK — inseridas: ' + ins + ' · atualizadas: ' + upd);
  }

  function enviarRpc(fn, body) {
    var res = UrlFetchApp.fetch(COMUM.SUPABASE_URL + '/rest/v1/rpc/' + fn, {
      method: 'post', contentType: 'application/json',
      headers: { apikey: COMUM.SUPABASE_ANON, Authorization: 'Bearer ' + COMUM.SUPABASE_ANON },
      payload: JSON.stringify(body), muteHttpExceptions: true
    });
    var code = res.getResponseCode();
    if (code >= 300) { Logger.log('RPC ' + fn + ' ERRO ' + code + ': ' + res.getContentText()); return null; }
    try { return JSON.parse(res.getContentText()); } catch (e) { return null; }
  }

  function instalarGatilho() {
    ScriptApp.getProjectTriggers().forEach(function (t) {
      var h = t.getHandlerFunction();
      if (['sincronizarTudo','nudenSyncAgora','dduSyncAgora','riSyncAgora','emergenciaSyncAgora'].indexOf(h) >= 0) ScriptApp.deleteTrigger(t);
    });
    ScriptApp.newTrigger('sincronizarTudo').timeBased().everyHours(COMUM.FREQ_HORAS).create();
    Logger.log('Gatilho instalado: sincronizarTudo a cada ' + COMUM.FREQ_HORAS + 'h.');
  }

  // ─── DRIVE ────────────────────────────────────────────────────────────
  function indexarDrive(folderId) {
    var idx = { folderMap: {}, fileMap: {}, folderDig: {}, fileDig: {}, fileNum: {}, folderNum: {} };
    if (!folderId) return idx;
    try {
      var root = DriveApp.getFolderById(folderId);
      var fi = root.getFiles();
      while (fi.hasNext()) {
        var f = fi.next(), nm = f.getName();
        var item = { tipo: 'arquivo', nome: nm, web_view_link: fileUrl(f.getId()) };
        var k = normCod(semExt(nm)); (idx.fileMap[k] = idx.fileMap[k] || []).push(item);
        var dk = soDig(nm); if (dk) (idx.fileDig[dk] = idx.fileDig[dk] || []).push(item);
        var nnum = primeiroNum(nm); if (nnum) (idx.fileNum[nnum] = idx.fileNum[nnum] || []).push(item);
      }
      var fo = root.getFolders();
      while (fo.hasNext()) {
        var sub = fo.next(), fn = sub.getName();
        var o = { tipo: 'pasta', nome: fn, web_view_link: 'https://drive.google.com/drive/folders/' + sub.getId() };
        idx.folderMap[normCod(fn)] = o;
        var fdk = soDig(fn); if (fdk && !idx.folderDig[fdk]) idx.folderDig[fdk] = o;
        var fnum = primeiroNum(fn); if (fnum) (idx.folderNum[fnum] = idx.folderNum[fnum] || []).push(o);
      }
    } catch (e) { Logger.log('Drive indisponível (' + folderId + '): ' + e); }
    return idx;
  }
  // casa anexos de uma demanda: 1) código exato (pasta/arquivo), 2) só dígitos,
  // 3) pelo NÚMERO da demanda (antes da "/"), ex. arquivo "RI 718 APA ... - Município"
  //    → desempata pelo município quando há mais de um com o mesmo número.
  function acharAnexos(idx, codigo, municipio) {
    var k = normCod(codigo); if (!k) return null;
    var dk = soDig(codigo);
    if (idx.folderMap[k])        return [idx.folderMap[k]];
    if (idx.fileMap[k])          return idx.fileMap[k].slice();
    if (dk && idx.folderDig[dk]) return [idx.folderDig[dk]];
    if (dk && idx.fileDig[dk])   return idx.fileDig[dk].slice();
    var num = primeiroNum(String(codigo).split('/')[0]);
    if (num) {
      var fold = (idx.folderNum && idx.folderNum[num]) || [];
      var arqs = (idx.fileNum && idx.fileNum[num]) || [];
      var cands = fold.concat(arqs);
      if (cands.length === 1) return [cands[0]];
      if (cands.length > 1) {
        var mk = normCod(municipio || '');
        if (mk) { var m = cands.filter(function (c) { return normCod(c.nome).indexOf(mk) >= 0; }); if (m.length) return [m[0]]; }
        return [cands[0]];   // mesmo número, município não casou → pega o 1º
      }
    }
    return null;
  }
  // extrai o link do PDF da célula "CLIQUE PARA BAIXAR" (célula-link ou =HYPERLINK)
  function linkDaCelula(rtv, fm, r, idxLink) {
    if (idxLink < 0 || r < 0) return '';
    try {
      if (rtv && rtv[r] && rtv[r][0]) {
        var u = rtv[r][0].getLinkUrl();
        if (u) return u;
        var runs = rtv[r][0].getRuns ? rtv[r][0].getRuns() : null;
        if (runs) for (var j = 0; j < runs.length; j++) { var ru = runs[j].getLinkUrl(); if (ru) return ru; }
      }
    } catch (e) {}
    if (fm && fm[r] && fm[r][0]) { var m = String(fm[r][0]).match(/HYPERLINK\(\s*"([^"]+)"/i); if (m) return m[1]; }
    return '';
  }

  // ─── Ato/REDS antigos (BD_DENUNCIASDADOC / RESPOSTADDU) ───────────────
  function indexarDadoc(ss, cfg) {
    var map = {};
    if (!cfg) return map;
    var sh = ss.getSheetByName(cfg.aba); if (!sh) return map;
    var vs = sh.getDataRange().getValues();
    for (var i = 1; i < vs.length; i++) {
      var cod = String(vs[i][cfg.cod] == null ? '' : vs[i][cfg.cod]).trim(); if (!cod) continue;
      var k = normCod(cod); if (map[k]) continue;
      var ato = '';
      for (var a = 0; a < (cfg.atoCols || []).length; a++) {
        var v = String(vs[i][cfg.atoCols[a]] == null ? '' : vs[i][cfg.atoCols[a]]).trim();
        if (v) { ato = v; break; }
      }
      map[k] = { data: dataVal(vs[i][cfg.data]), ato: ato, reds: String(vs[i][cfg.reds] == null ? '' : vs[i][cfg.reds]).trim() };
    }
    return map;
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────
  function normHead(s) {
    return String(s == null ? '' : s).normalize('NFD').replace(/[̀-ͯ]/g, '')
      .toUpperCase().replace(/[.ºª°]/g, '').replace(/\s+/g, ' ').trim();
  }
  function acharCol(cabec, aliases) {
    var al = aliases.map(normHead);
    for (var c = 0; c < cabec.length; c++) if (al.indexOf(cabec[c]) >= 0) return c;
    for (var c2 = 0; c2 < cabec.length; c2++)
      for (var a = 0; a < al.length; a++) if (al[a] && cabec[c2].indexOf(al[a]) >= 0) return c2;
    return -1;
  }
  function cel(linha, i) { if (i == null || i < 0 || i >= linha.length) return ''; var v = linha[i]; return (v == null) ? '' : String(v).trim(); }
  function dataIso(linha, i) { if (i == null || i < 0 || i >= linha.length) return ''; return dataVal(linha[i]); }
  function dataVal(v) {
    if (v instanceof Date) return iso(v);
    var s = String(v == null ? '' : v).trim(); if (!s) return '';
    var m = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})$/);
    if (m) { var a = m[3].length === 2 ? '20' + m[3] : m[3]; return a + '-' + pad(m[2]) + '-' + pad(m[1]); }
    if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10);
    var d = new Date(s); return isNaN(d) ? '' : iso(d);
  }
  function normCod(s) { return String(s == null ? '' : s).toUpperCase().replace(/[^A-Z0-9]/g, ''); }
  function soDig(s)   { return String(s == null ? '' : s).replace(/\D/g, ''); }
  function primeiroNum(s) { var m = String(s == null ? '' : s).match(/\d+/); return m ? String(parseInt(m[0], 10)) : ''; }
  function semExt(s)  { return String(s == null ? '' : s).replace(/\.[A-Za-z0-9]{1,5}$/, ''); }
  function fileUrl(id){ return 'https://drive.google.com/file/d/' + id + '/view'; }
  function iso(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function pad(n) { return String(n).length < 2 ? '0' + n : String(n); }
  function addDias(isoStr, n) { var p = isoStr.split('-').map(Number); return iso(new Date(p[0], p[1] - 1, p[2] + n)); }

  // ─── WEB APP: lançamento manual / espelho da baixa ───────────────────
  function jsonOut(obj) {
    return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
  }
  function doGet(e) {
    return jsonOut({ ok: true, service: 'AutomacaoCastro', fontes: Object.keys(FONTES) });
  }
  function doPost(e) {
    var p = {};
    try { p = JSON.parse((e && e.postData && e.postData.contents) || '{}'); }
    catch (err) { return jsonOut({ ok: false, error: 'JSON inválido' }); }
    try {
      if (p.action === 'lancar') return jsonOut(lancar(p));
      if (p.action === 'baixar') return jsonOut(baixarSheet(p));
      return jsonOut({ ok: false, error: 'ação desconhecida: ' + p.action });
    } catch (err2) {
      return jsonOut({ ok: false, error: String(err2 && err2.message || err2) });
    }
  }

  // resolve a aba principal (manual) + cabeçalho + índices de todas as colunas
  function _mainSheet(F) {
    var cfg = F.abas[0];
    var sh = SpreadsheetApp.openById(F.sheetId).getSheetByName(cfg.nome);
    if (!sh) throw new Error('aba não encontrada: ' + cfg.nome);
    var cabec = sh.getRange(cfg.header, 1, 1, sh.getLastColumn()).getValues()[0].map(normHead);
    return { sh: sh, cfg: cfg, cabec: cabec, header: cfg.header };
  }
  // escreve, numa linha, os campos cujo alias casa no cabeçalho (datas viram Date)
  function _escreverCampos(ctx, rowIndex, campos) {
    Object.keys(campos).forEach(function (campo) {
      var aliases = ctx.cfg.map[campo]; if (!aliases) return;
      var c = acharCol(ctx.cabec, aliases); if (c < 0) return;
      var v = campos[campo]; if (v == null || v === '') return;
      if (/^\d{4}-\d{2}-\d{2}/.test(String(v))) { var q = String(v).slice(0,10).split('-'); v = new Date(+q[0], +q[1]-1, +q[2]); }
      ctx.sh.getRange(rowIndex, c + 1).setValue(v);
    });
  }
  // próximo código 'NNN/ANO' olhando a coluna de código da aba principal
  function gerarCodigo(F, ano) {
    var ctx = _mainSheet(F);
    var cc = acharCol(ctx.cabec, ctx.cfg.map.codigo);
    var max = 0;
    if (cc >= 0) {
      var vals = ctx.sh.getRange(ctx.header + 1, cc + 1, Math.max(0, ctx.sh.getLastRow() - ctx.header), 1).getValues();
      for (var i = 0; i < vals.length; i++) {
        var m = String(vals[i][0] == null ? '' : vals[i][0]).match(/^\s*(\d+)\s*\/\s*(\d{4})\s*$/);
        if (m && m[2] === String(ano) && +m[1] > max) max = +m[1];
      }
    }
    return (max + 1) + '/' + ano;
  }
  function uploadPdf(F, codigo, pdf) {
    if (!pdf || !pdf.dataBase64) return null;
    var bytes = Utilities.base64Decode(pdf.dataBase64);
    var nome = (pdf.name || (codigo.replace(/\//g, '_') + '.pdf'));
    var blob = Utilities.newBlob(bytes, pdf.mime || 'application/pdf', nome);
    var file = DriveApp.getFolderById(F.driveFolder).createFile(blob);
    try { file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW); } catch (e) {}
    return { tipo: 'arquivo', nome: nome, web_view_link: fileUrl(file.getId()) };
  }

  function lancar(p) {
    var F = FONTES[p.fonte]; if (!F) throw new Error('fonte inválida: ' + p.fonte);
    var d = p.dados || {};
    var ano = p.ano || (d.data_gerada ? String(d.data_gerada).slice(0,4) : new Date().getFullYear());
    var codigo = (p.codigo && String(p.codigo).trim()) || gerarCodigo(F, ano);

    // vencimento: usa o informado, senão base (envio/gerada) + prazo
    var venc = d.data_vencimento || '';
    if (!venc) { var base = d.data_envio || d.data_gerada; if (base) venc = addDias(String(base).slice(0,10), F.prazoDias || COMUM.PRAZO_DIAS); }

    // 1) PDF → Drive
    var anexo = null;
    try { anexo = uploadPdf(F, codigo, p.pdf); } catch (e) { Logger.log('upload falhou: ' + e); }

    // 2) grava a linha na planilha (espelho) + link do PDF em "CLIQUE PARA BAIXAR"
    var ctx = _mainSheet(F);
    var rowIndex = ctx.sh.getLastRow() + 1;
    var campos = {
      codigo: codigo, tipo_demanda: d.tipo_demanda || F.tipoDefault,
      natureza: d.natureza, endereco: d.endereco, municipio: d.municipio,
      fracao_responsavel: d.fracao_responsavel,
      data_gerada: d.data_gerada, data_envio: d.data_envio,
      data_vencimento: venc, info_complementares: d.info_complementares
    };
    try {
      _escreverCampos(ctx, rowIndex, campos);
      if (anexo) { var cb = acharCol(ctx.cabec, ['CLIQUE PARA BAIXAR','BAIXAR','PDF']); if (cb >= 0) ctx.sh.getRange(rowIndex, cb + 1).setFormula('=HYPERLINK("' + anexo.web_view_link + '";"CLIQUE PARA BAIXAR")'); }
    } catch (e) { Logger.log('append planilha falhou: ' + e); }

    // 3) Supabase (upsert) — fonte da verdade do painel
    var obj = {
      codigo: codigo, tipo_demanda: d.tipo_demanda || F.tipoDefault,
      data_gerada: d.data_gerada || '', natureza: d.natureza || '',
      municipio: d.municipio || '', endereco: d.endereco || '',
      fracao_responsavel: d.fracao_responsavel || '',
      data_envio: d.data_envio || '', data_vencimento: venc || '',
      info_complementares: d.info_complementares || '',
      fonte_aba: 'painel', raw: { lancado_por: p.por || null, aba: ctx.cfg.nome }
    };
    if (anexo) obj.anexos = [anexo];
    var r = enviarRpc(F.rpc, { linhas: [obj] });
    if (!r) throw new Error('Supabase recusou o lançamento (verifique a migração ' + F.rpc + ').');
    return { ok: true, codigo: codigo, anexo: anexo };
  }

  // espelha o atendimento de volta na planilha (a baixa no banco é do Relatório)
  function baixarSheet(p) {
    var F = FONTES[p.fonte]; if (!F) throw new Error('fonte inválida: ' + p.fonte);
    var codigo = String(p.codigo || '').trim(); if (!codigo) throw new Error('código ausente');
    var a = p.atendimento || {};
    var ctx = _mainSheet(F);
    var cc = acharCol(ctx.cabec, ctx.cfg.map.codigo); if (cc < 0) throw new Error('coluna de código não encontrada');
    var vals = ctx.sh.getRange(ctx.header + 1, cc + 1, Math.max(0, ctx.sh.getLastRow() - ctx.header), 1).getValues();
    var alvo = normCod(codigo), row = -1;
    for (var i = 0; i < vals.length; i++) { if (normCod(vals[i][0]) === alvo) { row = ctx.header + 1 + i; break; } }
    if (row < 0) return { ok: false, error: 'código não encontrado na planilha (nada a espelhar)' };
    _escreverCampos(ctx, row, {
      data_atendimento: a.data_atendimento, numero_reds: a.numero_reds,
      numero_gaia: a.numero_gaia, status_atendimento: a.status_atendimento || 'RESPONDIDA'
    });
    return { ok: true, row: row };
  }

  return { run: run, instalarGatilho: instalarGatilho, doGet: doGet, doPost: doPost };
})();

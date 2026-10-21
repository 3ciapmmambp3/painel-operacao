/* ══════════════════════════════════════════════════════════════════════
   AutomaçãoCastro.gs — NUDEN e DDU: planilha → Supabase (painel-operacao)
   3ª Cia PM MAmb · Controle de Demandas
   >>> No editor do Apps Script, nomeie este arquivo como "AutomaçãoCastro". <<<

   O QUE FAZ
     Lê as abas de cada FONTE (NUDEN e DDU 181), mapeia as colunas POR NOME,
     deduplica por CÓDIGO DEMANDA (prefere a aba do robô), casa o(s)
     documento(s) do Drive pelo código e manda tudo para o Supabase via RPC
     (nuden_sync / ddu_sync — upsert). Completa o Ato/REDS/data das ATENDIDAS
     ANTIGAS por uma aba de respostas (BD_DENUNCIASDADOC / RESPOSTADDU).

     COMANDOS (menu Executar):
       nudenSyncAgora        → sincroniza só a NUDEN
       dduSyncAgora          → sincroniza só o DDU
       sincronizarTudo       → as duas (use este no gatilho)
       instalarGatilhoNuden  → cria 1 gatilho de tempo p/ sincronizarTudo

   PRÉ-REQUISITOS (conta que roda o script, ex. 3ciapmmamb.p3):
     • precisa de ACESSO às 2 planilhas (NUDEN e DDU) e às 2 pastas do Drive.
     • rode db/151 (NUDEN) e db/152 (DDU) no Supabase antes.

   Tudo encapsulado no namespace AutomacaoCastro (sem colidir com outros .gs).
   ══════════════════════════════════════════════════════════════════════ */

// ─── COMANDOS (únicos globais) ─────────────────────────────────────────
function nudenSyncAgora()       { return AutomacaoCastro.run('NUDEN'); }
function dduSyncAgora()         { return AutomacaoCastro.run('DDU'); }
function sincronizarTudo()      { AutomacaoCastro.run('NUDEN'); AutomacaoCastro.run('DDU'); }
function instalarGatilhoNuden() { return AutomacaoCastro.instalarGatilho(); }

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
        if (!obj.data_vencimento && obj.data_envio) obj.data_vencimento = addDias(obj.data_envio, COMUM.PRAZO_DIAS);
        var anx = acharAnexos(drive, cod); if (anx) obj.anexos = anx;
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
      if (h === 'sincronizarTudo' || h === 'nudenSyncAgora' || h === 'dduSyncAgora') ScriptApp.deleteTrigger(t);
    });
    ScriptApp.newTrigger('sincronizarTudo').timeBased().everyHours(COMUM.FREQ_HORAS).create();
    Logger.log('Gatilho instalado: sincronizarTudo a cada ' + COMUM.FREQ_HORAS + 'h.');
  }

  // ─── DRIVE ────────────────────────────────────────────────────────────
  function indexarDrive(folderId) {
    var idx = { folderMap: {}, fileMap: {}, folderDig: {}, fileDig: {} };
    if (!folderId) return idx;
    try {
      var root = DriveApp.getFolderById(folderId);
      var fi = root.getFiles();
      while (fi.hasNext()) {
        var f = fi.next(), nm = f.getName();
        var item = { tipo: 'arquivo', nome: nm, web_view_link: fileUrl(f.getId()) };
        var k = normCod(semExt(nm)); (idx.fileMap[k] = idx.fileMap[k] || []).push(item);
        var dk = soDig(nm); if (dk) (idx.fileDig[dk] = idx.fileDig[dk] || []).push(item);
      }
      var fo = root.getFolders();
      while (fo.hasNext()) {
        var sub = fo.next(), fn = sub.getName();
        var o = { nome: fn, web_view_link: 'https://drive.google.com/drive/folders/' + sub.getId() };
        idx.folderMap[normCod(fn)] = o;
        var fdk = soDig(fn); if (fdk && !idx.folderDig[fdk]) idx.folderDig[fdk] = o;
      }
    } catch (e) { Logger.log('Drive indisponível (' + folderId + '): ' + e); }
    return idx;
  }
  function acharAnexos(idx, codigo) {
    var k = normCod(codigo); if (!k) return null;
    var dk = soDig(codigo);
    if (idx.folderMap[k])        return [{ tipo: 'pasta', nome: idx.folderMap[k].nome, web_view_link: idx.folderMap[k].web_view_link }];
    if (idx.fileMap[k])          return idx.fileMap[k].slice();
    if (dk && idx.folderDig[dk]) return [{ tipo: 'pasta', nome: idx.folderDig[dk].nome, web_view_link: idx.folderDig[dk].web_view_link }];
    if (dk && idx.fileDig[dk])   return idx.fileDig[dk].slice();
    return null;
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
      .toUpperCase().replace(/[.º°]/g, '').replace(/\s+/g, ' ').trim();
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
  function semExt(s)  { return String(s == null ? '' : s).replace(/\.[A-Za-z0-9]{1,5}$/, ''); }
  function fileUrl(id){ return 'https://drive.google.com/file/d/' + id + '/view'; }
  function iso(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function pad(n) { return String(n).length < 2 ? '0' + n : String(n); }
  function addDias(isoStr, n) { var p = isoStr.split('-').map(Number); return iso(new Date(p[0], p[1] - 1, p[2] + n)); }

  return { run: run, instalarGatilho: instalarGatilho };
})();

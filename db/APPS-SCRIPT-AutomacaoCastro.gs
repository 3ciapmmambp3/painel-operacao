/* ══════════════════════════════════════════════════════════════════════
   AutomaçãoCastro.gs — NUDEN: planilha → Supabase (painel-operacao)
   3ª Cia PM MAmb · Controle de Demandas
   >>> No editor do Apps Script, nomeie este arquivo como "AutomaçãoCastro"
       (para não confundir com o "Automação (Anderson)" do mesmo projeto). <<<

   O QUE FAZ
     Lê as DUAS abas da planilha "NUDEN - 3ª CIA MAMB", mapeia as colunas
     POR NOME (as abas têm ordem e nomes diferentes), deduplica por CÓDIGO
     DEMANDA (== Nº DADOC/SENHA) preferindo a aba do robô, e manda tudo para
     o Supabase via RPC public.nuden_sync (upsert). Rode manualmente a 1ª vez
     (menu Executar → nudenSyncAgora) e depois instale o gatilho de tempo
     (instalarGatilhoNuden) para rodar sozinho.

   IMPORTANTE (convivência): este arquivo pode ficar no MESMO projeto Apps
   Script de outros scripts (ex.: "Automação (Anderson)") — TUDO está dentro
   do namespace AutomacaoCastro, então NÃO há colisão de nomes. Globais só os
   dois comandos do menu abaixo.

   COMO USAR
     1. Abra a planilha dona (conta 3ciapmmamb.p3) → Extensões → Apps Script.
     2. Cole este arquivo (um novo .gs). Confira NUDEN_SYNC.CFG abaixo.
     3. Rode nudenSyncAgora uma vez (autorize o acesso). Veja o Log.
     4. Rode instalarGatilhoNuden (cria 1 gatilho a cada FREQ_HORAS horas).
   ══════════════════════════════════════════════════════════════════════ */

// ─── COMANDOS DO MENU (únicos globais) ─────────────────────────────────
function nudenSyncAgora()        { return AutomacaoCastro.run(); }
function instalarGatilhoNuden()  { return AutomacaoCastro.instalarGatilho(); }

// ─── MÓDULO (tudo encapsulado p/ não colidir com outros scripts) ───────
var AutomacaoCastro = (function () {

  // ─── CONFIG ──────────────────────────────────────────────────────────
  var CFG = {
    SUPABASE_URL:  'https://zrnbebjszwkmquzthjfa.supabase.co',
    SUPABASE_ANON: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpybmJlYmpzendrbXF1enRoamZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkzOTA4MzEsImV4cCI6MjA5NDk2NjgzMX0.di9t2SOCTLZ2uPFOnTOiy6srvt7GC5cdqenZZScXve4',
    SHEET_ID:      '1Pp1X2_R0J62CmvrHLaumbxG_fbVQZCxybCvabDqDuog', // '' = planilha ativa
    DRIVE_FOLDER:  '1JO_llTri4rw5pY7bkV3uC1FECQL-zf6s',            // pasta dos PDFs ('' = não anexa)
    FREQ_HORAS:    6,    // frequência do gatilho
    PRAZO_DIAS:    85    // fallback de vencimento = envio + 85d
  };

  // Cada aba: nome, linha do cabeçalho e o mapa campo→[nomes aceitos do cabeçalho].
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
        numero_gaia:         ['NUMERO DO GAIA','N DO GAIA','GAIA','NUMERO DO ATO DE FISCALIZACAO','ATO DE FISCALIZACAO','N CODIGO ID SISFIS','NUMERO CODIGO ID SISFIS','CODIGO ID SISFIS','ID SISFIS'],
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
        // "Nº Código ID SISFIS" era o SISFIS antigamente; HOJE é o Ato de Fiscalização (== GAIA).
        numero_gaia:         ['N CODIGO ID SISFIS','NUMERO CODIGO ID SISFIS','CODIGO ID SISFIS','ID SISFIS','SISFIS','ATO DE FISCALIZACAO','NUMERO DO ATO DE FISCALIZACAO','NUMERO DO GAIA','GAIA'],
        numero_reds:         ['N REDS','NUMERO DO REDS','REDS'],
        status_atendimento:  ['STATUS','STATUS RESPOSTA A SEMAD'],
        info_complementares: ['OBSERVACOES','INFORMACOES']
    }}
  ];

  // ─── EXECUÇÃO ────────────────────────────────────────────────────────
  function run() {
    var ss = CFG.SHEET_ID ? SpreadsheetApp.openById(CFG.SHEET_ID) : SpreadsheetApp.getActiveSpreadsheet();
    var porCodigo = {};
    var drive = indexarDrive();
    var dadoc = indexarDadoc(ss);   // código → { ato, reds, data } (atendimentos ANTIGOS, pré-painel)

    ABAS.forEach(function (cfg) {
      var sh = ss.getSheetByName(cfg.nome);
      if (!sh) { Logger.log('Aba não encontrada: ' + cfg.nome); return; }
      var dados = sh.getDataRange().getValues();
      if (dados.length < cfg.header) return;

      var cabec = dados[cfg.header - 1].map(normHead);
      var idx = {};
      Object.keys(cfg.map).forEach(function (campo) { idx[campo] = acharCol(cabec, cfg.map[campo]); });

      for (var i = cfg.header; i < dados.length; i++) {
        var linha = dados[i];
        var cod = cel(linha, idx.codigo);
        if (!cod) continue;

        var obj = {
          codigo:              cod,
          tipo_demanda:        cel(linha, idx.tipo_demanda),
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
        if (!obj.data_vencimento && obj.data_envio) obj.data_vencimento = addDias(obj.data_envio, CFG.PRAZO_DIAS);

        var anx = acharAnexos(drive, cod);
        if (anx) obj.anexos = anx;

        var ja = porCodigo[cod];
        if (!ja || cfg.fonte_aba === 'robo') porCodigo[cod] = obj;
      }
    });

    // Completa o Ato de Fiscalização (=GAIA)/REDS/data das ATENDIDAS ANTIGAS
    // a partir da BD_DENUNCIASDADOC — só preenche o que estiver vazio.
    Object.keys(porCodigo).forEach(function (cod) {
      var o = porCodigo[cod], d = dadoc[normCod(cod)];
      if (!d) return;
      if (!o.numero_gaia && d.ato)       o.numero_gaia = d.ato;
      if (!o.numero_reds && d.reds)      o.numero_reds = d.reds;
      if (!o.data_atendimento && d.data) o.data_atendimento = d.data;
    });

    var linhas = Object.keys(porCodigo).map(function (k) { return porCodigo[k]; });
    Logger.log('NUDEN: ' + linhas.length + ' demandas para sincronizar.');
    if (!linhas.length) return;

    var LOTE = 500, inseridas = 0, atualizadas = 0;
    for (var j = 0; j < linhas.length; j += LOTE) {
      var r = enviarRpc('nuden_sync', { linhas: linhas.slice(j, j + LOTE) });
      if (r && r[0]) { inseridas += r[0].inseridas || 0; atualizadas += r[0].atualizadas || 0; }
    }
    Logger.log('NUDEN sync OK — inseridas: ' + inseridas + ' · atualizadas: ' + atualizadas);
  }

  function enviarRpc(fn, body) {
    var res = UrlFetchApp.fetch(CFG.SUPABASE_URL + '/rest/v1/rpc/' + fn, {
      method: 'post', contentType: 'application/json',
      headers: { apikey: CFG.SUPABASE_ANON, Authorization: 'Bearer ' + CFG.SUPABASE_ANON },
      payload: JSON.stringify(body), muteHttpExceptions: true
    });
    var code = res.getResponseCode();
    if (code >= 300) { Logger.log('RPC ' + fn + ' ERRO ' + code + ': ' + res.getContentText()); return null; }
    try { return JSON.parse(res.getContentText()); } catch (e) { return null; }
  }

  function instalarGatilho() {
    ScriptApp.getProjectTriggers().forEach(function (t) {
      if (t.getHandlerFunction() === 'nudenSyncAgora') ScriptApp.deleteTrigger(t);
    });
    ScriptApp.newTrigger('nudenSyncAgora').timeBased().everyHours(CFG.FREQ_HORAS).create();
    Logger.log('Gatilho NUDEN instalado: a cada ' + CFG.FREQ_HORAS + 'h.');
  }

  // ─── DRIVE (documento(s) da denúncia) ────────────────────────────────
  // O arquivo/subpasta é nomeado pelo CÓDIGO DEMANDA (coluna B) — que pode ser
  // o antigo "D148683" OU o protocolo novo "2026.10.01.503.0001872". Indexa
  // UMA vez (mapa exato por nome normalizado): arquivos soltos no topo e
  // subpastas (demandas com vários documentos). Os arquivos de cada subpasta
  // são lidos sob demanda (só quando a subpasta casa) p/ não estourar a quota.
  function indexarDrive() {
    var idx = { folderMap: {}, fileMap: {}, files: [] };
    if (!CFG.DRIVE_FOLDER) return idx;
    try {
      var root = DriveApp.getFolderById(CFG.DRIVE_FOLDER);
      var fi = root.getFiles();
      while (fi.hasNext()) {
        var f = fi.next(), nm = f.getName();
        var item = { nome: nm, norm: normCod(nm), web_view_link: fileUrl(f.getId()), tipo: 'arquivo' };
        idx.files.push(item);
        var k = normCod(semExt(nm)); (idx.fileMap[k] = idx.fileMap[k] || []).push(item);
      }
      var fo = root.getFolders();
      while (fo.hasNext()) {
        var sub = fo.next(), fn = sub.getName();
        idx.folderMap[normCod(fn)] = { nome: fn, folder: sub, url: 'https://drive.google.com/drive/folders/' + sub.getId() };
      }
    } catch (e) { Logger.log('Drive NUDEN indisponível: ' + e); }
    return idx;
  }
  // Anexos de um código: subpasta exata (>1 arquivo → PASTA; 1 → o arquivo);
  // senão arquivo exato (nome sem extensão == código); senão contém o código.
  function acharAnexos(idx, codigo) {
    var k = normCod(codigo); if (!k) return null;
    var fd = idx.folderMap[k];
    if (fd) {
      var arqs = [];
      try { var it = fd.folder.getFiles(); while (it.hasNext()) { var ff = it.next(); arqs.push({ tipo: 'arquivo', nome: ff.getName(), web_view_link: fileUrl(ff.getId()) }); } } catch (e) {}
      if (arqs.length === 1) return [arqs[0]];
      return [{ tipo: 'pasta', nome: fd.nome, web_view_link: fd.url, qtd: arqs.length }];
    }
    if (idx.fileMap[k]) return idx.fileMap[k].slice();
    var achados = idx.files.filter(function (x) { return x.norm.indexOf(k) >= 0; });
    return achados.length ? achados : null;
  }
  function normCod(s) { return String(s == null ? '' : s).toUpperCase().replace(/[^A-Z0-9]/g, ''); }
  function semExt(s)  { return String(s == null ? '' : s).replace(/\.[A-Za-z0-9]{1,5}$/, ''); }
  function fileUrl(id){ return 'https://drive.google.com/file/d/' + id + '/view'; }

  // BD_DENUNCIASDADOC: Ato de Fiscalização (=GAIA) das atendidas ANTIGAS.
  // Colunas: A=Nº DENÚNCIA (SENHA) · B=DATA ATENDIMENTO · C=ATO DE FISCALIZAÇÃO · D=Nº REDS
  function indexarDadoc(ss) {
    var map = {};
    var sh = ss.getSheetByName('BD_DENUNCIASDADOC'); if (!sh) return map;
    var vs = sh.getDataRange().getValues();
    for (var i = 1; i < vs.length; i++) {
      var cod = String(vs[i][0] == null ? '' : vs[i][0]).trim(); if (!cod) continue;
      var k = normCod(cod); if (map[k]) continue;   // 1ª ocorrência vence
      map[k] = {
        data: dataVal(vs[i][1]),
        ato:  String(vs[i][2] == null ? '' : vs[i][2]).trim(),
        reds: String(vs[i][3] == null ? '' : vs[i][3]).trim()
      };
    }
    return map;
  }

  // ─── HELPERS ──────────────────────────────────────────────────────────
  function normHead(s) {
    return String(s == null ? '' : s)
      .normalize('NFD').replace(/[̀-ͯ]/g, '')
      .toUpperCase().replace(/[.º°]/g, '')
      .replace(/\s+/g, ' ').trim();
  }
  function acharCol(cabec, aliases) {
    var al = aliases.map(normHead);
    for (var c = 0; c < cabec.length; c++) if (al.indexOf(cabec[c]) >= 0) return c;
    for (var c2 = 0; c2 < cabec.length; c2++)
      for (var a = 0; a < al.length; a++)
        if (al[a] && cabec[c2].indexOf(al[a]) >= 0) return c2;
    return -1;
  }
  function cel(linha, i) {
    if (i == null || i < 0 || i >= linha.length) return '';
    var v = linha[i]; return (v == null) ? '' : String(v).trim();
  }
  function dataIso(linha, i) {
    if (i == null || i < 0 || i >= linha.length) return '';
    return dataVal(linha[i]);
  }
  function dataVal(v) {
    if (v instanceof Date) return iso(v);
    var s = String(v == null ? '' : v).trim();
    if (!s) return '';
    var m = s.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})$/);
    if (m) { var a = m[3].length === 2 ? '20' + m[3] : m[3]; return a + '-' + pad(m[2]) + '-' + pad(m[1]); }
    if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10);
    var d = new Date(s); return isNaN(d) ? '' : iso(d);
  }
  function iso(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function pad(n) { return String(n).length < 2 ? '0' + n : String(n); }
  function addDias(isoStr, n) { var p = isoStr.split('-').map(Number); return iso(new Date(p[0], p[1] - 1, p[2] + n)); }

  return { run: run, instalarGatilho: instalarGatilho };
})();

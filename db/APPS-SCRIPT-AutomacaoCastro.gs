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
function mcSyncAgora()          { return AutomacaoCastro.runMC(); }   // reconcilia aba MC → Supabase + casa PDF
function sincronizarTudo()      { ['NUDEN','DDU','RI','EMERGENCIA'].forEach(function(k){ AutomacaoCastro.run(k); }); AutomacaoCastro.runMC(); }
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
    },
    // MONITORAMENTO CONTÍNUO — fluxo próprio (carga de LOTE pelo painel). A aba MC
    // é a planilha-controle corrente; o Drive MC guarda as pastas por lote (PDF
    // croqui + KML mestre que o painel soltou). Chave = GEOCOD_IEF. Prazo 45d.
    MC: {
      rpc: 'mc_sync',
      sheetId: '195fFn-DPmExOWL3jNMj-8nuhP0pwJ7g0Hk9RRrmvegY',
      driveFolder: '1vZRSSJQzQrVxDW8fBemqGGG_1B1bdSsV',
      tipoDefault: 'MC',
      prazoDias: 45,
      abas: [
        { nome: 'MC', fonte_aba: 'manual', header: 1, map: {
            codigo:              ['GEOCOD_IEF','GEOCOD'],
            municipio:           ['MUNICIPIO'],
            fracao_responsavel:  ['N GRUPAMENTO','GRUPAMENTO'],
            data_gerada:         ['DATA RECEBIDO NA 3 CIA PMMAMB','DATA RECEBIDO'],
            data_envio:          ['DATA ENVIADO PARA O GRUPAMENTO','DATA ENVIADO'],
            data_vencimento:     ['EXPIRACAO'],
            status_prazo:        ['SITUACAO'],
            data_atendimento:    ['DATA RESPOSTA','DATA_FISC_PMMG','DATA FISC PMMG'],
            numero_gaia:         ['ID SISFIS','SISFIS'],
            numero_reds:         ['N REDS','REDS'],
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
        else { var anx = acharAnexos(drive, cod); if (anx) obj.anexos = anx; }
        var ja = porCodigo[cod];
        if (!ja || cfg.fonte_aba === 'robo') porCodigo[cod] = obj;
      }
    });

    // ── ANEXO por NÚMERO (quando não veio por link nem por código exato) ──
    // O nome do arquivo traz só o nº do RI (sem o ano) e o nº se repete entre anos.
    // Nº ÚNICO (1 ano só) → casa direto; nº que REPETE entre anos → só casa com o
    // arquivo do ano certo (não espalha o PDF de 2026 em 2024/2025).
    var numAnos = {};
    Object.keys(porCodigo).forEach(function (cod) {
      var n = primeiroNum(String(cod).split('/')[0]);
      var a = (String(cod).split('/')[1] || '').replace(/\D/g, '');
      if (n) { numAnos[n] = numAnos[n] || {}; if (a) numAnos[n][a] = 1; }
    });
    Object.keys(porCodigo).forEach(function (cod) {
      var o = porCodigo[cod];
      if (o.anexos && o.anexos.length) return;
      var n = primeiroNum(String(cod).split('/')[0]); if (!n) return;
      var a = (String(cod).split('/')[1] || '').replace(/\D/g, '');
      var ambiguo = (numAnos[n] ? Object.keys(numAnos[n]).length : 0) > 1;
      var anx = acharAnexosPorNumero(drive, n, o.municipio, a, ambiguo);
      if (anx) o.anexos = anx;
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
        var item = { tipo: 'arquivo', id: f.getId(), nome: nm, ano: anoDoNome(nm), web_view_link: fileUrl(f.getId()) };
        var k = normCod(semExt(nm)); (idx.fileMap[k] = idx.fileMap[k] || []).push(item);
        var dk = soDig(nm); if (dk) (idx.fileDig[dk] = idx.fileDig[dk] || []).push(item);
        var nnum = primeiroNum(nm); if (nnum) (idx.fileNum[nnum] = idx.fileNum[nnum] || []).push(item);
      }
      var fo = root.getFolders();
      while (fo.hasNext()) {
        var sub = fo.next(), fn = sub.getName();
        var o = { tipo: 'pasta', id: sub.getId(), nome: fn, ano: anoDoNome(fn), web_view_link: 'https://drive.google.com/drive/folders/' + sub.getId() };
        idx.folderMap[normCod(fn)] = o;
        var fdk = soDig(fn); if (fdk && !idx.folderDig[fdk]) idx.folderDig[fdk] = o;
        var fnum = primeiroNum(fn); if (fnum) (idx.folderNum[fnum] = idx.folderNum[fnum] || []).push(o);
      }
    } catch (e) { Logger.log('Drive indisponível (' + folderId + '): ' + e); }
    return idx;
  }
  // casa anexos pelo CÓDIGO EXATO (pasta/arquivo com o nome = código, inclui ano).
  function acharAnexos(idx, codigo) {
    var k = normCod(codigo); if (!k) return null;
    var dk = soDig(codigo);
    if (idx.folderMap[k])        return [idx.folderMap[k]];
    if (idx.fileMap[k])          return idx.fileMap[k].slice();
    if (dk && idx.folderDig[dk]) return [idx.folderDig[dk]];
    if (dk && idx.fileDig[dk])   return idx.fileDig[dk].slice();
    return null;
  }
  // casa pelo NÚMERO da demanda (arquivo "RI 718 APA ... - Município", sem o ano).
  // requireAno=true (quando o nº repete entre anos): só casa com o arquivo do MESMO
  // ANO (ano no nome do arquivo ou, na falta, a data de criação no Drive) — evita
  // colar o PDF de 2026 nas demandas de 2024/2025 com o mesmo número.
  function acharAnexosPorNumero(idx, num, municipio, ano, requireAno) {
    if (!num) return null;
    var cands = ((idx.folderNum && idx.folderNum[num]) || []).concat((idx.fileNum && idx.fileNum[num]) || []);
    if (!cands.length) return null;
    if (cands.length > 1 && municipio) {
      var mk = normCod(municipio);
      var m = cands.filter(function (c) { return normCod(c.nome).indexOf(mk) >= 0; });
      if (m.length) cands = m;
    }
    if (requireAno && ano) {
      var y = cands.filter(function (c) { return anoDoArquivo(c) === String(ano); });
      if (!y.length) return null;   // nenhum arquivo do ano certo → não casa
      cands = y;
    }
    return [cands[0]];
  }
  // ano a partir do NOME (token 20xx) ou, se o nome não tiver, da data de criação.
  function anoDoNome(s) { var m = String(s == null ? '' : s).match(/(?:^|\D)(20\d{2})(?:\D|$)/); return m ? m[1] : ''; }
  function anoDoArquivo(item) {
    if (item && item.ano) return String(item.ano);
    try {
      if (item && item.id) {
        var f = (item.tipo === 'pasta') ? DriveApp.getFolderById(item.id) : DriveApp.getFileById(item.id);
        return String(f.getDateCreated().getFullYear());
      }
    } catch (e) {}
    return '';
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
      if (p.action === 'mc_listar_lotes') return jsonOut(mcListarLotes());
      if (p.action === 'mc_lote')          return jsonOut(mcLote(p));
      if (p.action === 'mc_importar')      return jsonOut(runMC() || { ok: true });
      if (p.action === 'mc_kml_backfill')  return jsonOut(mcKmlBackfill(p));
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

  // ═══════════════════════════════════════════════════════════════════════
  //  MONITORAMENTO CONTÍNUO (MC) — fluxo próprio
  //  Carga de LOTE: o painel manda {action:'mc_lote', loteId|lote, offset, limit}.
  //  O Apps Script lê o KML mestre da pasta (ExtendedData = todos os dados),
  //  separa 1 KML por GEOCOD (em memória, guardado no banco p/ download no
  //  painel), casa o PDF croqui pelo prefixo GEOCOD, resolve GP/PEL no GRUPOS,
  //  escreve na aba MC e manda ao Supabase. Roda PAGINADO (progresso no painel).
  //  runMC() reconcilia aba MC → Supabase (puxa de volta REDS/ato/data que o
  //  Aux lançar na planilha) e re-casa os PDFs.
  // ═══════════════════════════════════════════════════════════════════════

  // acentos → letra base (p/ casar MUNICIPIO entre KML/planilha e GRUPOS)
  function normMuni(s) {
    return String(s == null ? '' : s).normalize('NFD').replace(/[̀-ͯ]/g, '')
      .toUpperCase().replace(/[^A-Z0-9]/g, '');
  }
  function _dt(isoStr) { var p = String(isoStr).slice(0, 10).split('-'); return new Date(+p[0], (+p[1]) - 1, +p[2]); }

  // lê a aba GRUPOS → { MUNICIPIOnorm: { gp, pel } }
  function lerGrupos() {
    var map = {};
    try {
      var sh = SpreadsheetApp.openById(FONTES.MC.sheetId).getSheetByName('GRUPOS');
      if (!sh) return map;
      var vs = sh.getDataRange().getValues();
      for (var i = 0; i < vs.length; i++) {
        var muni = String(vs[i][0] == null ? '' : vs[i][0]).trim(); if (!muni) continue;
        var k = normMuni(muni);
        if (k === 'MUNICIPIO' || k === 'DADOSDAFRACAO' || !k) continue;
        if (!map[k]) map[k] = { gp: String(vs[i][1] || '').trim(), pel: String(vs[i][2] || '').trim() };
      }
    } catch (e) { Logger.log('GRUPOS indisponível: ' + e); }
    return map;
  }

  // acha a pasta do lote no Drive MC (por id, senão por nome)
  function _mcFolder(p) {
    var root = DriveApp.getFolderById(FONTES.MC.driveFolder);
    if (p.loteId) { try { return DriveApp.getFolderById(p.loteId); } catch (e) {} }
    var nm = String(p.lote || '').trim();
    var fo = root.getFolders();
    while (fo.hasNext()) { var f = fo.next(); if (f.getName().trim() === nm) return f; }
    throw new Error('pasta do lote não encontrada no Drive MC: ' + (p.lote || p.loteId || ''));
  }

  // KML mestre = o .kml da pasta com mais placemarks (texto UTF-8)
  // Usa searchFiles (filtro no servidor do Drive) p/ não iterar os ~370 PDFs
  // da pasta — iterar getFiles() inteiro custava ~90s/pasta. Fallback: getFiles().
  function _mcMasterKml(folder) {
    var it, best = null, bestN = -1;
    try { it = folder.searchFiles('title contains ".kml"'); }
    catch (e) { it = folder.getFiles(); }
    while (it.hasNext()) {
      var f = it.next(), nm = f.getName();
      if (!/\.kml$/i.test(nm)) continue;
      var t = f.getBlob().getDataAsString('UTF-8');
      var n = (t.match(/<Placemark/g) || []).length;
      if (n > bestN) { bestN = n; best = t; }
    }
    return best;
  }
  function _mcSplit(text) {
    var schema = (text.match(/<Schema\b[\s\S]*?<\/Schema>/) || [''])[0];
    var pms = text.match(/<Placemark\b[\s\S]*?<\/Placemark>/g) || [];
    return { schema: schema, placemarks: pms };
  }
  function _mcData(pm) {
    var d = {}, re = /<SimpleData name="([^"]+)">([\s\S]*?)<\/SimpleData>/g, m;
    while ((m = re.exec(pm))) { d[m[1]] = m[2]; }
    return d;
  }
  function _mcWrapKml(schema, geocod, pm) {
    return '<?xml version="1.0" encoding="utf-8" ?>\n<kml xmlns="http://www.opengis.net/kml/2.2">\n' +
           '<Document id="root_doc">\n' + schema + '\n<Folder><name>MC_' + geocod + '</name>\n' +
           pm + '\n</Folder>\n</Document></kml>\n';
  }
  // indexa PDFs por GEOCOD (prefixo numérico do nome) — recursivo raso
  function _mcIndexPdfs(folder) { var m = {}; _mcWalkPdfs(folder, m, 2); return m; }
  function _mcIndexPdfsRec(folderId) {
    var m = {}; try { _mcWalkPdfs(DriveApp.getFolderById(folderId), m, 0); } catch (e) { Logger.log('MC drive: ' + e); }
    return m;
  }
  function _mcWalkPdfs(folder, map, depth) {
    var fi = folder.getFiles();
    while (fi.hasNext()) {
      var f = fi.next(), nm = f.getName();
      if (!/\.pdf$/i.test(nm)) continue;
      var g = (nm.match(/^(\d+)/) || [])[1]; if (!g) continue;
      if (!map[g]) map[g] = { tipo: 'arquivo', nome: nm, web_view_link: fileUrl(f.getId()) };
    }
    if (depth < 3) { var fo = folder.getFolders(); while (fo.hasNext()) { _mcWalkPdfs(fo.next(), map, depth + 1); } }
  }

  // lista as pastas (lotes) do Drive MC p/ o painel escolher qual carregar
  // extrai {empresa, data(iso)} do nome da pasta — aceita AAAA-MM-DD e DD-MM-AAAA
  function _mcParseNome(nome) {
    function p2(n) { n = String(n); return n.length < 2 ? '0' + n : n; }
    var s = String(nome || '').trim(), iso = '', m;
    if ((m = s.match(/(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})/)))      iso = m[1] + '-' + p2(m[2]) + '-' + p2(m[3]);
    else if ((m = s.match(/(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4})/))) iso = m[3] + '-' + p2(m[2]) + '-' + p2(m[1]);
    var empresa = s.replace(/\s*\d{1,4}[-\/.]\d{1,2}[-\/.]\d{1,4}.*$/, '').trim();
    return { empresa: _mcEmpresaNorm(empresa), empresaRaw: empresa, data: iso };
  }

  // 8/12/15 CIA foram incorporadas à 3 CIA (junção) — arquivos antigos entram como 3 CIA
  function _mcEmpresaNorm(emp) {
    var m = String(emp || '').match(/^\s*(\d{1,3})\s*(?:ª|a)?\s*CIA\b/i);
    if (m && (m[1] === '8' || m[1] === '12' || m[1] === '15')) return '3 CIA';
    return String(emp || '').trim();
  }

  function mcListarLotes() {
    var F = FONTES.MC;
    var root = DriveApp.getFolderById(F.driveFolder), out = [], fo = root.getFolders();
    // lotes já carregados (coluna PASTA DRIVE MC da aba MC) → {nome: qtd}
    var carregados = {};
    try {
      var sh = SpreadsheetApp.openById(F.sheetId).getSheetByName(F.abas[0].nome);
      if (sh && sh.getLastRow() > 1) {
        var cab = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(normHead);
        var cY = acharCol(cab, ['PASTA DRIVE MC']);
        if (cY >= 0) {
          var col = sh.getRange(2, cY + 1, sh.getLastRow() - 1, 1).getValues();
          for (var z = 0; z < col.length; z++) {
            var v = String(col[z][0] == null ? '' : col[z][0]).trim();
            if (v) carregados[v] = (carregados[v] || 0) + 1;
          }
        }
      }
    } catch (e) {}
    while (fo.hasNext()) {
      var f = fo.next(), nome = String(f.getName()).trim(), pn = _mcParseNome(nome);
      out.push({ id: f.getId(), nome: nome, empresa: pn.empresa, empresaRaw: pn.empresaRaw, data: pn.data,
                 carregado: !!carregados[nome], qtd: carregados[nome] || 0 });
    }
    // por data desc; sem data por último; desempate por nome desc
    out.sort(function (a, b) {
      var da = a.data || '', db = b.data || '';
      if (da && db) return da < db ? 1 : (da > db ? -1 : (a.nome < b.nome ? 1 : -1));
      if (da && !db) return -1;
      if (!da && db) return 1;
      return a.nome < b.nome ? 1 : -1;
    });
    return { ok: true, lotes: out };
  }

  // CARGA DE LOTE (paginada): processa [offset, offset+limit) do KML mestre
  function mcLote(p) {
    var F = FONTES.MC;
    var folder = _mcFolder(p), lote = folder.getName().trim();
    var offset = Math.max(0, parseInt(p.offset || 0, 10) || 0);
    var limit  = Math.max(1, parseInt(p.limit || 60, 10) || 60);

    var kmlText = _mcMasterKml(folder);
    if (!kmlText) throw new Error('KML mestre (.kml) não encontrado na pasta do lote');
    var sp = _mcSplit(kmlText), pms = sp.placemarks, total = pms.length;
    if (!total) throw new Error('KML sem placemarks (<Placemark>)');

    var slice = pms.slice(offset, offset + limit);
    if (!slice.length) return { ok: true, done: true, total: total, processed: 0, nextOffset: total, lote: lote };

    var pdfIdx = _mcIndexPdfs(folder), grupos = lerGrupos();
    var hoje = iso(new Date()), venc = addDias(hoje, F.prazoDias);

    var sh = SpreadsheetApp.openById(F.sheetId).getSheetByName(F.abas[0].nome);
    var ncol = sh.getLastColumn();
    var cabec = sh.getRange(1, 1, 1, ncol).getValues()[0].map(normHead);
    function C(al) { return acharCol(cabec, al); }
    var cA = C(['DATA GERADA']), cB = C(['DATA RECEBIDO NA 3 CIA PMMAMB', 'DATA RECEBIDO']),
        cG = C(['EXPIRACAO']), cI = C(['SITUACAO']), cJ = C(['STATUS']),
        cK = C(['N GRUPAMENTO', 'GRUPAMENTO']), cL = C(['PELOTAO']),
        cM = C(['MUNICIPIO']), cN = C(['GEOCOD_IEF', 'GEOCOD']),
        cT = C(['CLIQUE NO ICONE PDF PARA BAIXAR', 'CLIQUE NO ICONE PDF', 'CLIQUE PARA BAIXAR']),
        cX = C(['KML']), cY = C(['PASTA DRIVE MC']);

    // idempotência do append: geocods já na planilha
    var jaSet = {};
    if (cN >= 0 && sh.getLastRow() > 1) {
      var col = sh.getRange(2, cN + 1, sh.getLastRow() - 1, 1).getValues();
      for (var z = 0; z < col.length; z++) { var gg = String(col[z][0] == null ? '' : col[z][0]).trim(); if (gg) jaSet[gg] = 1; }
    }

    var linhasSb = [], novasSheet = [], pdfRows = [];
    for (var i = 0; i < slice.length; i++) {
      var pm = slice[i], d = _mcData(pm);
      var geocod = String(d.GEOCOD_IEF || '').trim(); if (!geocod) continue;
      var municipio = String(d.MUNICIPIO || '').trim();
      var g = grupos[normMuni(municipio)] || { gp: '', pel: '' };
      var pdf = pdfIdx[geocod] || null;
      var dFim = dataVal(d.DATA_FINAL), dIni = dataVal(d.DATA_INIC);

      linhasSb.push({
        codigo: geocod, tipo_demanda: 'MC',
        data_gerada: hoje, data_vencimento: venc,
        natureza: String(d.BIOMA_IBGE || '').trim(),
        municipio: municipio, endereco: String(d.NUFIS || '').trim(),
        fracao_responsavel: g.gp || '',
        hectares: String(d.HECTARES || '').replace(',', '.'),
        data_inic: dIni, data_final: dFim,
        mes_ref: String(d.MES_REF || '').trim(), ano_ref: String(d.ANO_REF || '').trim(),
        coord_x: String(d.X || '').replace(',', '.'), coord_y: String(d.Y || '').replace(',', '.'),
        regional: String(d.NUFIS || '').trim(), bioma: String(d.BIOMA_IBGE || '').trim(),
        id_semad: String(d.ID || '').trim(), lote: lote,
        kml_content: _mcWrapKml(sp.schema, geocod, pm),
        fonte_aba: 'painel',
        raw: { pelotao: g.pel || '', grupamento: g.gp || '', nufis: String(d.NUFIS || '').trim() },
        anexos: pdf ? [pdf] : []
      });

      if (!jaSet[geocod]) {
        jaSet[geocod] = 1;
        var row = new Array(ncol); for (var c = 0; c < ncol; c++) row[c] = '';
        if (cA >= 0 && dFim) row[cA] = _dt(dFim);
        if (cB >= 0) row[cB] = _dt(hoje);
        if (cG >= 0) row[cG] = _dt(venc);
        if (cJ >= 0) row[cJ] = 'PENDENTE';
        if (cK >= 0) row[cK] = g.gp || '';
        if (cL >= 0) row[cL] = g.pel || '';
        if (cM >= 0) row[cM] = municipio;
        if (cN >= 0) row[cN] = geocod;
        if (cX >= 0) row[cX] = 'KML gerado (painel)';
        if (cY >= 0) row[cY] = lote;
        novasSheet.push(row);
        pdfRows.push(pdf ? pdf.web_view_link : '');
      }
    }

    if (novasSheet.length) {
      var startRow = sh.getLastRow() + 1;
      sh.getRange(startRow, 1, novasSheet.length, ncol).setValues(novasSheet);
      if (cT >= 0) for (var k = 0; k < pdfRows.length; k++)
        if (pdfRows[k]) sh.getRange(startRow + k, cT + 1).setFormula('=HYPERLINK("' + pdfRows[k] + '";"CLIQUE PARA BAIXAR")');
    }

    var ins = 0, upd = 0;
    if (linhasSb.length) { var r = enviarRpc(F.rpc, { linhas: linhasSb }); if (r && r[0]) { ins = r[0].inseridas || 0; upd = r[0].atualizadas || 0; } }

    var next = offset + limit;
    return { ok: true, done: next >= total, total: total, processed: slice.length,
             nextOffset: Math.min(next, total), inseridas: ins, atualizadas: upd, lote: lote };
  }

  // BACKFILL de KML individual: varre o KML mestre das pastas (folderIds) e preenche
  // kml_content das linhas já existentes (via mc_set_kml, só UPDATE — não mexe em data/baixa).
  // O painel pagina por pasta e manda um lote de folderIds por chamada.
  function mcKmlBackfill(p) {
    var ids = p.folderIds;
    if (typeof ids === 'string') { try { ids = JSON.parse(ids); } catch (e) { ids = ids ? [ids] : []; } }
    if (!ids && p.folderId) ids = [p.folderId];
    if (!ids || !ids.length) return { ok: true, pastas: 0, geocods: 0, atualizadas: 0, semKml: [] };

    var rowsAll = [], semKml = [];
    for (var fi = 0; fi < ids.length; fi++) {
      var folder;
      try { folder = DriveApp.getFolderById(ids[fi]); } catch (e) { continue; }
      var kmlText = _mcMasterKml(folder);
      if (!kmlText) { semKml.push(folder.getName()); continue; }
      var sp = _mcSplit(kmlText), pms = sp.placemarks;
      for (var i = 0; i < pms.length; i++) {
        var d = _mcData(pms[i]), g = String(d.GEOCOD_IEF || '').trim();
        if (!g) continue;
        rowsAll.push({ codigo: g, kml: _mcWrapKml(sp.schema, g, pms[i]) });
      }
    }

    var upd = 0, LOTE = 400;
    for (var j = 0; j < rowsAll.length; j += LOTE) {
      var r = enviarRpc('mc_set_kml', { linhas: rowsAll.slice(j, j + LOTE) });
      if (typeof r === 'number') upd += r;
      else if (r && r.length) upd += (typeof r[0] === 'number' ? r[0] : 0);
    }
    return { ok: true, pastas: ids.length, geocods: rowsAll.length, atualizadas: upd, semKml: semKml };
  }

  // RECONCILIA aba MC → Supabase (puxa REDS/ato/data que o Aux lançar) + re-casa PDFs
  function runMC() {
    var F = FONTES.MC, cfg = F.abas[0];
    var sh = SpreadsheetApp.openById(F.sheetId).getSheetByName(cfg.nome);
    if (!sh) { Logger.log('[MC] aba não encontrada'); return { ok: false, erro: 'aba MC não encontrada', total: 0, inseridas: 0, atualizadas: 0 }; }
    var dados = sh.getDataRange().getValues();
    if (dados.length < cfg.header) return { ok: true, total: 0, inseridas: 0, atualizadas: 0 };
    var cabec = dados[cfg.header - 1].map(normHead);
    var idx = {}; Object.keys(cfg.map).forEach(function (k) { idx[k] = acharCol(cabec, cfg.map[k]); });
    var cL = acharCol(cabec, ['PELOTAO']), cY = acharCol(cabec, ['PASTA DRIVE MC']);
    var pdfIdx = _mcIndexPdfsRec(F.driveFolder);
    var porCodigo = {};
    for (var i = cfg.header; i < dados.length; i++) {
      var linha = dados[i], cod = cel(linha, idx.codigo); if (!cod) continue;
      var obj = {
        codigo: cod, tipo_demanda: 'MC',
        data_gerada: dataIso(linha, idx.data_gerada),
        municipio: cel(linha, idx.municipio),
        fracao_responsavel: cel(linha, idx.fracao_responsavel),
        data_envio: dataIso(linha, idx.data_envio),
        data_vencimento: dataIso(linha, idx.data_vencimento),
        status_prazo: cel(linha, idx.status_prazo),
        data_atendimento: dataIso(linha, idx.data_atendimento),
        numero_gaia: cel(linha, idx.numero_gaia),
        numero_reds: cel(linha, idx.numero_reds),
        status_atendimento: cel(linha, idx.status_atendimento),
        lote: cY >= 0 ? cel(linha, cY) : '',
        fonte_aba: 'manual', raw: { aba: cfg.nome, pelotao: cL >= 0 ? cel(linha, cL) : '' }
      };
      var pdf = pdfIdx[String(cod).trim()]; if (pdf) obj.anexos = [pdf];
      porCodigo[cod] = obj;
    }
    var linhas = Object.keys(porCodigo).map(function (k) { return porCodigo[k]; });
    Logger.log('[MC] ' + linhas.length + ' demandas para sincronizar.');
    if (!linhas.length) return { ok: true, total: 0, inseridas: 0, atualizadas: 0 };
    var LOTE = 500, ins = 0, upd = 0;
    for (var j = 0; j < linhas.length; j += LOTE) {
      var r = enviarRpc(F.rpc, { linhas: linhas.slice(j, j + LOTE) });
      if (r && r[0]) { ins += r[0].inseridas || 0; upd += r[0].atualizadas || 0; }
    }
    Logger.log('[MC] OK — inseridas: ' + ins + ' · atualizadas: ' + upd);
    return { ok: true, total: linhas.length, inseridas: ins, atualizadas: upd };
  }

  return { run: run, runMC: runMC, mcLote: mcLote, mcListarLotes: mcListarLotes,
           mcKmlBackfill: mcKmlBackfill,
           instalarGatilho: instalarGatilho, doGet: doGet, doPost: doPost };
})();

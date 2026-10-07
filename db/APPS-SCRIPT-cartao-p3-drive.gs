/*  ═══════════════════════════════════════════════════════════════════════
    APPS-SCRIPT-cartao-p3-drive.gs — BUSCA de arquivos por chave no Drive.

    Web App na conta 3ciapmmamb.p3@gmail.com (dona das pastas de cada tipo de
    demanda). Dado um folderId + "chave" (GEOCODE, protocolo, nº da RI…), acha
    os arquivos cujo NOME casa com a chave, na pasta E nas subpastas (1 nível),
    e devolve os links. Usa a BUSCA INDEXADA do Drive (searchFiles) escopada à
    pasta — rápido mesmo em pastas com milhares de arquivos (ex.: MC).

    Casamento: o nome do arquivo contém a chave ignorando pontuação
    (ex.: GEOCODE 13040284 casa com "13040284_2026_09_VIRGEM DA LAPA_CROQUI_MC.pdf"
    e com "MC VIRGEM DA LAPA - 13040284.kml"). Subpasta cujo NOME casa com a
    chave → inclui todos os arquivos dela (caso "pasta por protocolo").

    PASTAS (3ciapmmamb.p3):
      MC=1vZRSSJQzQrVxDW8fBemqGGG_1B1bdSsV · NUDEN=1JO_llTri4rw5pY7bkV3uC1FECQL-zf6s
      DEN_BALCAO=14x1aFthJJw_crfg1uz3l_47_djtIFaLE · RI=1LwYWj4MQF110dOrygv8HWk2DTwKiZwVm
      EMERGENCIA=1z0ZceiGhQbyRq2bp2RKP1gmAzCgZmgpN

    PUBLICAR: script.google.com (logado em 3ciapmmamb.p3) → cole isto → Implantar
    → App da Web (Executar como: Eu; Quem acessa: Qualquer pessoa). Ao ATUALIZAR,
    use "Gerenciar implantações → editar (lápis) → Versão: Nova versão" p/ manter
    a MESMA URL /exec.

    ENTRADA (GET): ?action=buscar&folderId=<id>&chave=<chave>
    SAÍDA (JSON):  { ok:true, arquivos:[ {nome,link,mime,id} ] }
    ═══════════════════════════════════════════════════════════════════════ */
var MAX_RESULTADOS = 30;
var MAX_SUBPASTAS  = 120;   // teto de subpastas visitadas

function doGet(e) {
  try {
    var p = (e && e.parameter) || {};
    if (p.action !== 'buscar') return _json({ ok:true, msg:'Cartão P3 Drive — use ?action=buscar&folderId=..&chave=..' });
    var folderId = String(p.folderId || '');
    var chaveRaw = String(p.chave || '');
    var chaveN   = _norm(chaveRaw);
    if (!folderId || !chaveN) return _json({ ok:false, erro:'folderId e chave são obrigatórios' });

    var token = _token(chaveRaw);            // maior sequência alfanumérica (p/ a query indexada)
    var root  = DriveApp.getFolderById(folderId);
    var achados = [], vistos = {};

    _buscarNaPasta(root, token, chaveN, achados, vistos);   // arquivos diretos do root
    var subs = root.getFolders(), ns = 0;
    while (subs.hasNext() && ns++ < MAX_SUBPASTAS && achados.length < MAX_RESULTADOS) {
      var sub = subs.next();
      if (_norm(sub.getName()).indexOf(chaveN) !== -1) {
        // subpasta nomeada pela chave → inclui TODOS os arquivos dela
        var it = sub.getFiles();
        while (it.hasNext() && achados.length < MAX_RESULTADOS) _add(it.next(), achados, vistos);
      } else {
        _buscarNaPasta(sub, token, chaveN, achados, vistos);
      }
    }
    return _json({ ok:true, arquivos: achados });
  } catch (err) {
    return _json({ ok:false, erro:String(err) });
  }
}

// Busca indexada dentro de UMA pasta (filhos diretos) por "title contains token",
// refinando pelo nome normalizado conter a chave.
function _buscarNaPasta(folder, token, chaveN, achados, vistos) {
  if (achados.length >= MAX_RESULTADOS) return;
  var it;
  try {
    if (token) it = folder.searchFiles("title contains '" + token.replace(/'/g, '') + "' and trashed = false");
    else       it = folder.getFiles();
  } catch (e) { it = folder.getFiles(); }
  while (it.hasNext() && achados.length < MAX_RESULTADOS) {
    var f = it.next();
    if (_norm(f.getName()).indexOf(chaveN) !== -1) _add(f, achados, vistos);
  }
}

function _add(f, achados, vistos) {
  if (vistos[f.getId()] || achados.length >= MAX_RESULTADOS) return;
  vistos[f.getId()] = true;
  try { f.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW); } catch (e) {}
  achados.push({ nome:f.getName(), id:f.getId(), mime:f.getMimeType(),
                 link:'https://drive.google.com/file/d/' + f.getId() + '/view' });
}

// maior "run" alfanumérico da chave (ex.: "305/2026"→"2026"; "13040284"→"13040284")
function _token(s) {
  var runs = String(s || '').match(/[A-Za-z0-9]+/g) || [];
  runs.sort(function(a, b){ return b.length - a.length; });
  return runs[0] || '';
}
function _norm(s) { return String(s || '').toUpperCase().replace(/[^A-Z0-9]/g, ''); }
function _json(obj) { return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON); }

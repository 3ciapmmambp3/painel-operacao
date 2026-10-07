/*  ═══════════════════════════════════════════════════════════════════════
    APPS-SCRIPT-cartao-p3-drive.gs — BUSCA de arquivos por chave no Drive.

    Web App na conta 3ciapmmamb.p3@gmail.com (dona das pastas de cada tipo de
    demanda). Dado um folderId + "chave" (GEOCODE, protocolo, nº da RI…), acha
    os arquivos cujo NOME casa com a chave e devolve os links.

    ESTRATÉGIA (rápida, independe de quantas subpastas existam): UMA busca GLOBAL
    indexada do Drive por "title contains <token>" (acha o arquivo em qualquer
    subpasta num só passo), filtrando pelo nome normalizado conter a chave e
    confirmando que o arquivo está SOB a pasta do tipo. Também acha subpasta
    nomeada pela chave e inclui os arquivos dela (caso "pasta por protocolo").

    Casamento ignora pontuação: GEOCODE 13040284 casa com
    "13040284_2026_09_VIRGEM DA LAPA_CROQUI_MC.pdf" e "MC ... - 13040284.kml".

    PUBLICAR/ATUALIZAR: cole este código no editor, **Ctrl+S (salvar)**, e
    Implantar → Gerenciar implantações → lápis → Versão: "Nova versão" →
    Implantar (mantém a MESMA URL /exec).

    ENTRADA (GET): ?action=buscar&folderId=<id>&chave=<chave>
    SAÍDA (JSON):  { ok:true, arquivos:[ {nome,link,mime,id} ] }
    ═══════════════════════════════════════════════════════════════════════ */
var MAX_RESULTADOS = 30;
var MAX_SCAN       = 500;   // teto de candidatos varridos (segurança p/ tokens amplos)
var MAX_DEPTH      = 7;     // profundidade da checagem de "está sob a pasta"

function doGet(e) {
  try {
    var p = (e && e.parameter) || {};
    if (p.action !== 'buscar') return _json({ ok:true, msg:'Cartão P3 Drive — use ?action=buscar&folderId=..&chave=..' });
    var folderId = String(p.folderId || '');
    var chaveRaw = String(p.chave || '');
    var chaveN   = _norm(chaveRaw);
    if (!folderId || !chaveN) return _json({ ok:false, erro:'folderId e chave são obrigatórios' });
    DriveApp.getFolderById(folderId); // valida (lança se inválido)

    var token = _token(chaveRaw);
    var achados = [], vistos = {}, scan = 0;
    var qtok = token ? ("title contains '" + token.replace(/'/g, '') + "' and ") : '';

    // 1) arquivos cujo NOME casa (busca global indexada), confirmando ancestral
    var it = DriveApp.searchFiles(qtok + 'trashed = false');
    while (it.hasNext() && achados.length < MAX_RESULTADOS && scan++ < MAX_SCAN) {
      var f = it.next();
      if (_norm(f.getName()).indexOf(chaveN) === -1) continue;
      if (!_sob(f, folderId, 0)) continue;
      _add(f, achados, vistos);
    }
    // 2) subpasta nomeada pela chave (ex.: pasta por protocolo) → inclui os arquivos dela
    if (token) {
      var itf = DriveApp.searchFolders(qtok + 'trashed = false'); var fscan = 0;
      while (itf.hasNext() && achados.length < MAX_RESULTADOS && fscan++ < 200) {
        var sf = itf.next();
        if (_norm(sf.getName()).indexOf(chaveN) === -1) continue;
        if (sf.getId() !== folderId && !_sob(sf, folderId, 0)) continue;
        var fit = sf.getFiles();
        while (fit.hasNext() && achados.length < MAX_RESULTADOS) _add(fit.next(), achados, vistos);
      }
    }
    return _json({ ok:true, arquivos: achados });
  } catch (err) {
    return _json({ ok:false, erro:String(err) });
  }
}

// true se o item (arquivo/pasta) é descendente da pasta folderId (sobe pelos pais)
function _sob(item, folderId, depth) {
  if (depth > MAX_DEPTH) return false;
  var ps = item.getParents();
  while (ps.hasNext()) {
    var par = ps.next();
    if (par.getId() === folderId) return true;
    if (_sob(par, folderId, depth + 1)) return true;
  }
  return false;
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

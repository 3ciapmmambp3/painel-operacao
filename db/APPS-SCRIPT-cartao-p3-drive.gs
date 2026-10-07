/*  ═══════════════════════════════════════════════════════════════════════
    APPS-SCRIPT-cartao-p3-drive.gs — BUSCA de arquivos por chave no Drive.

    Web App publicado na conta 3ciapmmamb.p3@gmail.com (dona das pastas de
    cada tipo de demanda). Dado um folderId + uma "chave" (GEOCODE, protocolo,
    nº da denúncia/RI…), varre a pasta E suas subpastas e devolve os links dos
    arquivos cujo NOME (ou o nome da subpasta que os contém) casa com a chave.
    Usado pelo Cartão Programa para já anexar o PDF (e o KML, no MC) da demanda
    puxada da planilha.

    PASTAS (3ciapmmamb.p3):
      MC          = 1vZRSSJQzQrVxDW8fBemqGGG_1B1bdSsV   (PDF + KML por GEOCODE)
      NUDEN       = 1JO_llTri4rw5pY7bkV3uC1FECQL-zf6s   (PDF ou subpasta)
      DEN_BALCAO  = 14x1aFthJJw_crfg1uz3l_47_djtIFaLE
      RI/FTP      = 1LwYWj4MQF110dOrygv8HWk2DTwKiZwVm
      EMERGENCIA  = 1z0ZceiGhQbyRq2bp2RKP1gmAzCgZmgpN

    COMO PUBLICAR:
      1. script.google.com (logado em 3ciapmmamb.p3) → Novo projeto → cole isto.
      2. Implantar → Nova implantação → App da Web:
         Executar como = Eu (3ciapmmamb.p3); Quem acessa = Qualquer pessoa.
      3. Autorize os escopos. Copie a URL /exec e mande ao painel
         (constante CARTAO_P3_DRIVE_URL em src/auth.js).

    ENTRADA (GET, evita preflight):  ?action=buscar&folderId=<id>&chave=<chave>
    SAÍDA (JSON): { ok:true, arquivos:[ {nome,link,mime,id} ] }
      O link devolvido é de VISUALIZAÇÃO e o arquivo é compartilhado como
      "qualquer pessoa com o link" (para abrir pelo cartão/PDF).

    Casamento: compara a chave e o nome do arquivo/subpasta "normalizados"
    (só letras+números, maiúsculas). Assim "305/2026" casa com "305-2026" e
    "RI 305_2026.pdf". Limite de segurança de recursão e de resultados.
    ═══════════════════════════════════════════════════════════════════════ */
var MAX_RESULTADOS = 30;
var MAX_PASTAS     = 400;   // teto de subpastas visitadas (evita varredura infinita)

function doGet(e) {
  try {
    var p = (e && e.parameter) || {};
    if (p.action !== 'buscar') return _json({ ok:true, msg:'Cartão P3 Drive — use ?action=buscar&folderId=..&chave=..' });
    var folderId = String(p.folderId || '');
    var chaveN   = _norm(p.chave || '');
    if (!folderId || !chaveN) return _json({ ok:false, erro:'folderId e chave são obrigatórios' });

    var root = DriveApp.getFolderById(folderId);
    var achados = [];
    var visitadas = { n:0 };
    _varrer(root, chaveN, false, achados, visitadas);

    // dedup por id + compartilha + monta link
    var vistos = {}, out = [];
    for (var i=0; i<achados.length && out.length<MAX_RESULTADOS; i++) {
      var f = achados[i];
      if (vistos[f.getId()]) continue;
      vistos[f.getId()] = true;
      try { f.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW); } catch (err) {}
      out.push({ nome:f.getName(), id:f.getId(), mime:f.getMimeType(),
                 link:'https://drive.google.com/file/d/' + f.getId() + '/view' });
    }
    return _json({ ok:true, arquivos: out });
  } catch (err) {
    return _json({ ok:false, erro:String(err) });
  }
}

// Varre a pasta: inclui arquivos cujo nome casa com a chave, OU todos os
// arquivos de uma subpasta cujo NOME casa com a chave (pasta por GEOCODE etc.).
function _varrer(pasta, chaveN, pastaCasou, achados, st) {
  if (st.n++ > MAX_PASTAS || achados.length >= MAX_RESULTADOS) return;
  var files = pasta.getFiles();
  while (files.hasNext() && achados.length < MAX_RESULTADOS) {
    var f = files.next();
    if (pastaCasou || _norm(f.getName()).indexOf(chaveN) !== -1) achados.push(f);
  }
  var subs = pasta.getFolders();
  while (subs.hasNext() && achados.length < MAX_RESULTADOS) {
    var sub = subs.next();
    var casou = pastaCasou || _norm(sub.getName()).indexOf(chaveN) !== -1;
    _varrer(sub, chaveN, casou, achados, st);
  }
}

function _norm(s) { return String(s || '').toUpperCase().replace(/[^A-Z0-9]/g, ''); }
function _json(obj) { return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON); }

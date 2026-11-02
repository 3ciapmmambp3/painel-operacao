/*  ═══════════════════════════════════════════════════════════════════════
    APPS-SCRIPT-nuden-drive.gs — Upload dos anexos da NUDEN/SISDEN no DRIVE.

    Web App que RECEBE um arquivo (base64) da Edge Function `sisden-sync` e o
    grava na pasta do Drive da NUDEN (a mesma já usada: 1JO_...), dentro de uma
    subpasta por PROTOCOLO. Devolve o link de visualização, que a função guarda
    em nuden_demandas.anexos[].link.

    POR QUE APPS SCRIPT (e não conta de serviço):
      Conta de serviço do Google NÃO tem cota de Drive em Gmail comum (403
      storageQuotaExceeded). O Web App "Executar como: Eu" roda com a cota da
      própria conta — que é dona/editora da pasta 1JO_...

    COMO PUBLICAR (uma vez):
      1. Logar no Drive com a conta que tem acesso de EDITOR à pasta 1JO_...
         (a conta da NUDEN — 3ciapmmamb.p3@gmail.com, conforme o projeto).
      2. script.google.com → Novo projeto → cole TODO este arquivo.
      3. (Opcional) ajuste PASTA_PADRAO_ID abaixo com o ID da pasta NUDEN, p/ não
         precisar mandar pastaId em cada chamada. Já deixei o 1JO_... como padrão.
      4. Implantar → Nova implantação → Tipo "App da Web":
           Executar como = Eu;  Quem tem acesso = Qualquer pessoa.
      5. Autorize os escopos (Drive) quando pedir.
      6. Copie a URL /exec e informe ao Claude → vira o secret SISDEN_DRIVE_URL
         na Edge Function.

    ENTRADA (POST, corpo = JSON):
        { protocolo:'2026.10.01.503.0002556', nome:'arquivo.pdf',
          mime:'application/pdf', base64:'…', pastaId:'<opcional>' }
    SAÍDA (JSON):
        { ok:true, id:'<fileId>', link:'https://drive.google.com/file/d/<id>/view',
          nome:'arquivo.pdf', existente:false }
        { ok:false, erro:'mensagem' }

    DEDUP: se já existe um arquivo com o MESMO nome na subpasta do protocolo,
    NÃO duplica — devolve o link do existente (existente:true). Assim, re-rodar
    a sync não enche o Drive de cópias.
    ═══════════════════════════════════════════════════════════════════════ */

// ID da pasta NUDEN no Drive (a mesma que o projeto já usa). '' = cria
// "Painel - Anexos/nuden" na raiz do Drive da conta que publica.
var PASTA_PADRAO_ID = '1JO_llTri4rw5pY7bkV3uC1FECQL-zf6s';

function doPost(e) {
  try {
    var body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    var protocolo = _limpaNome(body.protocolo) || 'sem-protocolo';
    var nome = String(body.nome || 'arquivo');
    var mime = String(body.mime || 'application/octet-stream');
    var b64  = String(body.base64 || '');
    var pastaId = String(body.pastaId || PASTA_PADRAO_ID || '');
    if (!b64) return _json({ ok:false, erro:'sem conteúdo (base64 vazio)' });

    var raiz = pastaId ? DriveApp.getFolderById(pastaId)
                       : _garante(_garante(DriveApp.getRootFolder(), 'Painel - Anexos'), 'nuden');
    var pasta = _garante(raiz, protocolo);   // subpasta por protocolo

    // DEDUP por nome dentro da subpasta do protocolo
    var jaTem = pasta.getFilesByName(nome);
    if (jaTem.hasNext()) {
      var ex = jaTem.next();
      return _json({ ok:true, id:ex.getId(), nome:nome, existente:true,
                     link:'https://drive.google.com/file/d/' + ex.getId() + '/view' });
    }

    var bytes = Utilities.base64Decode(b64);
    var blob  = Utilities.newBlob(bytes, mime, nome);
    var file  = pasta.createFile(blob);
    file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);

    return _json({ ok:true, id:file.getId(), nome:nome, existente:false,
                   link:'https://drive.google.com/file/d/' + file.getId() + '/view' });
  } catch (err) {
    return _json({ ok:false, erro:String(err) });
  }
}

function doGet() {
  return _json({ ok:true, msg:'NUDEN Drive uploader ativo. Use POST.' });
}

// nome de pasta/arquivo seguro (sem "/", sem lixo)
function _limpaNome(v) {
  var s = String(v || '').replace(/[^A-Za-z0-9 ._-]+/g, '').trim();
  return s.slice(0, 80);
}
function _garante(pai, nome) {
  var it = pai.getFoldersByName(nome);
  return it.hasNext() ? it.next() : pai.createFolder(nome);
}
function _json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

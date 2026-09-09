/*  ═══════════════════════════════════════════════════════════════════════
    APPS-SCRIPT-oficios-drive.gs — Upload de anexos no Google DRIVE.

    Web App que RECEBE um arquivo (base64) do painel e o grava no Drive da
    conta que publica o script (Executar como: Eu = 3ciapmmamb@gmail.com), devolvendo
    um link de visualização. Assim os anexos dos Ofícios (e da Requisição
    Judicial) ficam no Drive da unidade, e não no Storage do Supabase.

    POR QUE APPS SCRIPT (e não conta de serviço):
      Conta de serviço do Google NÃO tem cota de Drive própria (Gmail comum →
      403 storageQuotaExceeded). O Web App "Executar como: Eu" roda com a cota
      do próprio Gmail 3ciapmmamb@gmail.com — que é o que queremos.

    COMO PUBLICAR:
      1. drive.google.com da conta 3ciapmmamb@gmail.com → crie a pasta raiz (ex.:
         "Ofícios - 3ª Cia PM MAmb") e copie o ID dela (da URL da pasta).
      2. script.google.com → Novo projeto. Cole TODO este arquivo.
      3. Ajuste ROOT_FOLDER_ID abaixo com o ID da pasta (ou deixe '' para
         gravar em "Painel - Anexos/oficios/ANO" na raiz do Drive).
      4. Implantar → Nova implantação → Tipo "App da Web":
         Executar como = Eu (3ciapmmamb@gmail.com); Quem tem acesso = Qualquer pessoa.
      5. Autorize os escopos quando pedir.
      6. Copie a URL /exec e cole no painel em src/auth.js, na constante
         OFICIOS_DRIVE_URL (deixe '' para usar o Supabase Storage). As telas
         nova-oficio.html e oficios.html já usam essa constante; se o Drive
         falhar, caem no Supabase Storage automaticamente (fallback).

    ENTRADA (POST, corpo = JSON como text/plain p/ evitar preflight CORS):
        { nome:'arquivo.pdf', mime:'application/pdf', ano:2026, base64:'…' }
    SAÍDA (JSON):
        { ok:true, id:'<fileId>', link:'https://drive.google.com/file/d/<id>/view' }
        { ok:false, erro:'mensagem' }
    ═══════════════════════════════════════════════════════════════════════ */

var ROOT_FOLDER_ID = '';   // ID da pasta raiz no Drive. '' = cria "Painel - Anexos" na raiz.
var SUBPASTA       = 'oficios';

function doPost(e) {
  try {
    var body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    var nome = String(body.nome || 'arquivo');
    var mime = String(body.mime || 'application/octet-stream');
    var ano  = String(body.ano  || (new Date()).getFullYear());
    var b64  = String(body.base64 || '');
    if (!b64) return _json({ ok:false, erro:'sem conteúdo (base64 vazio)' });

    var bytes = Utilities.base64Decode(b64);
    var blob  = Utilities.newBlob(bytes, mime, nome);

    var pasta = _pastaDoAno(ano);
    var file  = pasta.createFile(blob);
    // link de visualização p/ quem tiver o link (o painel guarda esse link)
    file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);

    return _json({ ok:true, id:file.getId(), link:'https://drive.google.com/file/d/' + file.getId() + '/view' });
  } catch (err) {
    return _json({ ok:false, erro:String(err) });
  }
}

function doGet() {
  return _json({ ok:true, msg:'Ofícios Drive uploader ativo. Use POST.' });
}

// pasta ROOT/oficios/ANO (cria o que faltar)
function _pastaDoAno(ano) {
  var root = ROOT_FOLDER_ID ? DriveApp.getFolderById(ROOT_FOLDER_ID) : _garantePasta(DriveApp.getRootFolder(), 'Painel - Anexos');
  var sub  = _garantePasta(root, SUBPASTA);
  return _garantePasta(sub, ano);
}
function _garantePasta(pai, nome) {
  var it = pai.getFoldersByName(nome);
  return it.hasNext() ? it.next() : pai.createFolder(nome);
}
function _json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

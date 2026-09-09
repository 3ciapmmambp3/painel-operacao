/*  ═══════════════════════════════════════════════════════════════════════
    APPS-SCRIPT-inteligencia-drive.gs — Upload de anexos da INTELIGÊNCIA.

    ⚠️ CONTA SEPARADA: este deve ser publicado na conta **si.8ciamamb@gmail.com**
    (NÃO na do 3ciapmmamb, que é a dos Ofícios/Requisição Judicial). O código é
    igual ao APPS-SCRIPT-oficios-drive.gs de propósito — o que muda é a CONTA que
    publica: o "Executar como: Eu" faz os arquivos irem pro Drive dessa conta.

    Web App que RECEBE um arquivo (base64) do painel e o grava no Drive da conta
    que publica (Executar como: Eu = si.8ciamamb@gmail.com), devolvendo um link.
    Os anexos da Inteligência (analise-criminal.html) passam a ir pra cá em vez
    do Supabase Storage. Subpasta = 'inteligencia'.

    POR QUE APPS SCRIPT (e não conta de serviço):
      Conta de serviço do Google NÃO tem cota de Drive própria (Gmail comum →
      403 storageQuotaExceeded). O Web App "Executar como: Eu" roda com a cota
      do próprio Gmail si.8ciamamb@gmail.com — que é o que queremos.

    COMO PUBLICAR:
      1. Logado em si.8ciamamb@gmail.com: script.google.com → Novo projeto.
         Cole TODO este arquivo.
      2. (Opcional) Ajuste ROOT_FOLDER_ID com o ID de uma pasta, ou deixe ''
         para gravar em "Painel - Anexos/inteligencia/ANO" na raiz do Drive.
      3. Implantar → Nova implantação → Tipo "App da Web":
         Executar como = Eu (si.8ciamamb@gmail.com); Quem tem acesso = Qualquer pessoa.
      4. Autorize os escopos quando pedir.
      5. Copie a URL /exec e cole no painel em src/auth.js, na constante
         INTEL_DRIVE_URL (deixe '' para usar o Supabase Storage). O
         analise-criminal.html já usa essa constante; se o Drive falhar, cai no
         Supabase Storage automaticamente (fallback).

    ENTRADA (POST, corpo = JSON como text/plain p/ evitar preflight CORS):
        { nome:'arquivo.pdf', mime:'application/pdf', ano:2026,
          subpasta:'inteligencia', base64:'…' }
    SAÍDA (JSON):
        { ok:true, id:'<fileId>', link:'https://drive.google.com/file/d/<id>/view' }
        { ok:false, erro:'mensagem' }
    ═══════════════════════════════════════════════════════════════════════ */

var ROOT_FOLDER_ID = '';   // ID da pasta raiz no Drive. '' = cria "Painel - Anexos" na raiz.
var SUBPASTA       = 'inteligencia';  // default (o painel manda 'inteligencia')

function doPost(e) {
  try {
    var body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    var nome = String(body.nome || 'arquivo');
    var mime = String(body.mime || 'application/octet-stream');
    var ano  = String(body.ano  || (new Date()).getFullYear());
    var sub  = _limpaPasta(body.subpasta) || SUBPASTA;  // 'oficios', 'requisicao-judicial', …
    var b64  = String(body.base64 || '');
    if (!b64) return _json({ ok:false, erro:'sem conteúdo (base64 vazio)' });

    var bytes = Utilities.base64Decode(b64);
    var blob  = Utilities.newBlob(bytes, mime, nome);

    var pasta = _pastaDoAno(ano, sub);
    var file  = pasta.createFile(blob);
    // link de visualização p/ quem tiver o link (o painel guarda esse link)
    file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);

    return _json({ ok:true, id:file.getId(), link:'https://drive.google.com/file/d/' + file.getId() + '/view' });
  } catch (err) {
    return _json({ ok:false, erro:String(err) });
  }
}

function doGet() {
  return _json({ ok:true, msg:'Painel Drive uploader ativo. Use POST.' });
}

// pasta ROOT/<subpasta>/ANO (cria o que faltar)
function _pastaDoAno(ano, subpasta) {
  var root = ROOT_FOLDER_ID ? DriveApp.getFolderById(ROOT_FOLDER_ID) : _garantePasta(DriveApp.getRootFolder(), 'Painel - Anexos');
  var sub  = _garantePasta(root, subpasta || SUBPASTA);
  return _garantePasta(sub, ano);
}
// só letras/números/-/_/espaço (evita subpasta maliciosa ou com "/")
function _limpaPasta(v) {
  var s = String(v || '').replace(/[^A-Za-z0-9 _-]+/g, '').trim();
  return s.slice(0, 60);
}
function _garantePasta(pai, nome) {
  var it = pai.getFoldersByName(nome);
  return it.hasNext() ? it.next() : pai.createFolder(nome);
}
function _json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

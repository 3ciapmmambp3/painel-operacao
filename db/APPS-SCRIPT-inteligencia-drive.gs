/*  ═══════════════════════════════════════════════════════════════════════
    APPS-SCRIPT-inteligencia-drive.gs — Upload de anexos da INTELIGÊNCIA.

    ⚠️ CONTA SEPARADA: este deve ser publicado na conta **si.8ciamamb@gmail.com**
    (NÃO na do 3ciapmmamb, que é a dos Ofícios/Requisição Judicial). O código é
    igual ao APPS-SCRIPT-oficios-drive.gs de propósito — o que muda é a CONTA que
    publica: o "Executar como: Eu" faz os arquivos irem pro Drive dessa conta.

    Web App que RECEBE um arquivo (base64) do painel e o grava no Drive da conta
    que publica (Executar como: Eu = si.8ciamamb@gmail.com), devolvendo um link.
    Os anexos da Inteligência / Missões (analise-criminal.html) passam a ir pra cá
    em vez do Supabase Storage. Subpasta = 'inteligencia'.

    POR QUE APPS SCRIPT (e não conta de serviço):
      Conta de serviço do Google NÃO tem cota de Drive própria (Gmail comum →
      403 storageQuotaExceeded). O Web App "Executar como: Eu" roda com a cota
      do próprio Gmail si.8ciamamb@gmail.com — que é o que queremos.

    ⚠️ COMPARTILHAMENTO (correção 2026-11-09):
      O `DriveApp.setSharing(ANYONE_WITH_LINK, VIEW)` legado passou a FALHAR — o
      arquivo ficava "Restrito" e só a conta dona abria (outras contas recebiam
      "Você precisa de acesso"). Agora o arquivo é liberado pelo **Serviço
      Avançado "Drive"** (`_tornarPublico`), com o setSharing legado só como
      último recurso. Para funcionar de forma confiável:
        → No editor do Apps Script: menu **Serviços** (ícone +) → adicionar
          **"Drive API"** (identificador `Drive`). Salve e republique.
      Sem isso ele cai no método legado, que pode voltar a falhar.

    COMO PUBLICAR:
      1. Logado em si.8ciamamb@gmail.com: script.google.com → Novo projeto.
         Cole TODO este arquivo.
      2. Menu **Serviços** → adicionar **Drive API** (passo do compartilhamento).
      3. (Opcional) Ajuste ROOT_FOLDER_ID com o ID de uma pasta, ou deixe ''
         para gravar em "Painel - Anexos/inteligencia/ANO" na raiz do Drive.
      4. Implantar → Nova implantação → Tipo "App da Web":
         Executar como = Eu (si.8ciamamb@gmail.com); Quem tem acesso = Qualquer pessoa.
      5. Autorize os escopos quando pedir (inclui Drive).
      6. Copie a URL /exec e cole no painel em src/auth.js, na constante
         INTEL_DRIVE_URL (deixe '' para usar o Supabase Storage). O
         analise-criminal.html já usa essa constante; se o Drive falhar, cai no
         Supabase Storage automaticamente (fallback).

    ► CONSERTAR ANEXOS JÁ EXISTENTES (que ficaram "Restrito"):
      Depois de ativar o Drive API, selecione a função **corrigirCompartilhamento**
      no topo do editor e clique ▶ Executar. Ela re-libera, de uma vez, toda a
      árvore de "Painel - Anexos" (pastas + arquivos). Rode uma única vez.

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
    // Libera o arquivo (qualquer pessoa com o link → leitor) de forma robusta.
    _tornarPublico(file.getId());

    return _json({ ok:true, id:file.getId(), link:'https://drive.google.com/file/d/' + file.getId() + '/view' });
  } catch (err) {
    return _json({ ok:false, erro:String(err) });
  }
}

function doGet() {
  return _json({ ok:true, msg:'Painel Drive uploader ativo. Use POST.' });
}

/** Torna um arquivo/pasta PÚBLICO (qualquer pessoa com o link → leitor).
 *  Caminho principal = Serviço Avançado "Drive" (API v3, depois v2), porque o
 *  DriveApp.setSharing legado passou a falhar (arquivo ficava "Restrito").
 *  Retorna true se algum método aplicou. */
function _tornarPublico(id) {
  // 1) Serviço Avançado "Drive" — API v3
  try {
    if (typeof Drive !== 'undefined' && Drive.Permissions && Drive.Permissions.create) {
      Drive.Permissions.create({ type: 'anyone', role: 'reader' }, id, { supportsAllDrives: true });
      return true;
    }
  } catch (e1) { /* tenta v2 */ }
  // 2) Serviço Avançado "Drive" — API v2
  try {
    if (typeof Drive !== 'undefined' && Drive.Permissions && Drive.Permissions.insert) {
      Drive.Permissions.insert({ type: 'anyone', role: 'reader', withLink: true }, id);
      return true;
    }
  } catch (e2) { /* tenta legado */ }
  // 3) Fallback legado (pode falhar — por isso ative o Drive API acima)
  try {
    try { DriveApp.getFileById(id).setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW); return true; }
    catch (ef) { DriveApp.getFolderById(id).setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW); return true; }
  } catch (e3) {}
  return false;
}

/** RODAR UMA VEZ no editor (selecione → ▶ Executar): re-libera toda a árvore de
 *  "Painel - Anexos" (pastas + arquivos antigos que ficaram "Restrito"). */
function corrigirCompartilhamento() {
  var root;
  if (ROOT_FOLDER_ID) {
    root = DriveApp.getFolderById(ROOT_FOLDER_ID);
  } else {
    var it = DriveApp.getRootFolder().getFoldersByName('Painel - Anexos');
    if (!it.hasNext()) { Logger.log('Pasta "Painel - Anexos" não encontrada.'); return; }
    root = it.next();
  }
  var n = _liberarRec(root, 0);
  Logger.log('Compartilhamento corrigido em ' + n + ' item(ns) (pastas + arquivos).');
}
function _liberarRec(folder, n) {
  _tornarPublico(folder.getId()); n++;
  var fs = folder.getFiles();
  while (fs.hasNext()) { _tornarPublico(fs.next().getId()); n++; }
  var fo = folder.getFolders();
  while (fo.hasNext()) { n = _liberarRec(fo.next(), n); }
  return n;
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
  if (it.hasNext()) return it.next();
  var nova = pai.createFolder(nome);
  _tornarPublico(nova.getId());   // pasta nova já pública → arquivos dentro herdam
  return nova;
}
function _json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

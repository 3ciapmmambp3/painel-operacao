// ─────────────────────────────────────────────────────────────────────
// Espelho da Ficha de Movimentacao de Viaturas (Supabase -> Google Sheets)
//
// COLE ESTE ARQUIVO INTEIRO no editor do Apps Script (Extensoes -> Apps Script).
// E so codigo JavaScript. NAO cole titulos de markdown (linhas com "#") — no
// Apps Script comentario e "//", nunca "#".
//
// O SHEET_ID ja vem cravado abaixo (aponta para a sua planilha), entao NAO
// precisa configurar Script Property. Depois: Implantar -> App da Web
// (executar como "Eu", acesso "Qualquer pessoa") e me mande a URL /exec.
// ─────────────────────────────────────────────────────────────────────

// ID da planilha do espelho: a parte da URL ENTRE "/d/" e "/edit"
// (sem "/edit", sem "#gid=0").
var SHEET_ID_PADRAO = '1qugZSao5daiWnLTElLdgBVgSWpFv1xvlvUZPv-Nsoks';

var CABECALHO = [
  'ID', 'Criado em', 'Prefixo', 'Placa',
  'Motorista', 'Matricula', 'Lotacao', 'Local de utilizacao', 'Tipo de empenho',
  'Km inicial', 'Km final', 'Km rodados', 'Inicio', 'Termino',
  'Comb. ao armar', 'Comb. ao devolver',
  'Abasteceu?', 'Abastecimentos (resumo)',
  'Acidente?', 'Manutencao?', 'Avaria?', 'Higienizou?', 'TAQ/Embarcacao?', 'Aeronave?',
  'Observacoes', 'GP responsavel', 'Grupamento', 'Registrado por',
  'Qtd. comprovantes', 'Comprovantes (links)'
];

function _prop(k, def){
  var v = PropertiesService.getScriptProperties().getProperty(k);
  return (v == null || v === '') ? def : v;
}

// Aceita ID puro OU a URL inteira (extrai o trecho entre /d/ e /edit) e
// remove sujeira colada por engano (#gid=0, ?..., /edit).
function _extrairId(s){
  s = String(s || '').trim();
  var m = s.match(/\/d\/([a-zA-Z0-9_-]+)/);
  if (m) return m[1];
  return s.replace(/[#?\/].*$/, '');
}

function _fmtData(iso){
  if (!iso) return '';
  var d = new Date(iso);
  if (isNaN(d.getTime())) return String(iso);
  return Utilities.formatDate(d, Session.getScriptTimeZone() || 'America/Sao_Paulo', 'dd/MM/yyyy HH:mm');
}

function _sn(b){ return (b === true || b === 'true' || b === 't') ? 'Sim' : 'Nao'; }

function _resumoAbastecimento(dados){
  try{
    var itens = (dados && dados.abastecimento && dados.abastecimento.itens) || [];
    if (!itens.length) return '';
    return itens.map(function(it){
      var p = [];
      if (it.fonte) p.push(it.fonte);
      if (it.combustivel) p.push(it.combustivel);
      if (it.litros) p.push(it.litros + ' L');
      if (it.valor_total) p.push('R$ ' + it.valor_total);
      return p.join(' - ');
    }).join('  |  ');
  }catch(e){ return ''; }
}

function _montarLinha(d){
  var dados = d.dados || {};
  var anexos = d.anexos || [];
  var links = anexos.map(function(a){ return a.link || a.web_view_link || a.path || ''; })
                    .filter(function(x){ return x; });
  return [
    d.id || '',
    _fmtData(d.criado_em),
    d.prefixo || '', d.placa || '',
    d.motorista_nome || '', d.motorista_matricula || '',
    d.lotacao_motorista || '', d.local_utilizacao || '', d.tipo_empenho || '',
    d.km_inicial != null ? d.km_inicial : '',
    d.km_final != null ? d.km_final : '',
    d.km_rodados != null ? d.km_rodados : '',
    _fmtData(d.inicio), _fmtData(d.termino),
    d.comb_armar || '', d.comb_devolver || '',
    _sn(d.tem_abastecimento), _resumoAbastecimento(dados),
    _sn(d.tem_acidente), _sn(d.tem_manutencao), _sn(d.tem_avaria),
    _sn(d.tem_limpeza), _sn(d.tem_taq), _sn(d.tem_aeronave),
    d.observacoes || '', d.gp_responsavel || '', d.grupamento_completo || '',
    d.criado_por_nome || '',
    links.length, links.join('\n')
  ];
}

function _aba(){
  var ss = SpreadsheetApp.openById(_extrairId(_prop('SHEET_ID', SHEET_ID_PADRAO)));
  var nome = _prop('ABA', 'Fichas');
  var sh = ss.getSheetByName(nome) || ss.insertSheet(nome);
  if (sh.getLastRow() === 0){
    sh.appendRow(CABECALHO);
    sh.getRange(1, 1, 1, CABECALHO.length).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  return sh;
}

function doPost(e){
  try{
    var raw = (e && e.parameter && e.parameter.payload) || '';
    if (!raw) throw new Error('payload vazio');
    var d = JSON.parse(raw);
    var sh = _aba();
    var linha = _montarLinha(d);

    // casa por ID (coluna A) -> atualiza; senao, acrescenta
    var achou = -1;
    if (d.id && sh.getLastRow() > 1){
      var ids = sh.getRange(2, 1, sh.getLastRow() - 1, 1).getValues();
      for (var i = 0; i < ids.length; i++){
        if (String(ids[i][0]) === String(d.id)){ achou = i + 2; break; }
      }
    }
    if (achou > 0) sh.getRange(achou, 1, 1, linha.length).setValues([linha]);
    else           sh.appendRow(linha);

    return ContentService
      .createTextOutput(JSON.stringify({ ok: true, id: d.id || null, atualizou: achou > 0 }))
      .setMimeType(ContentService.MimeType.JSON);
  }catch(err){
    return ContentService
      .createTextOutput(JSON.stringify({ ok: false, erro: String(err) }))
      .setMimeType(ContentService.MimeType.JSON);
  }
}

function doGet(){
  return ContentService
    .createTextOutput(JSON.stringify({ ok: true, servico: 'espelho-ficha-mov' }))
    .setMimeType(ContentService.MimeType.JSON);
}

// Opcional: rode UMA vez pelo editor (botao Executar, funcao "testar") para
// autorizar o script e criar o cabecalho na planilha antes do primeiro envio.
function testar(){
  var sh = _aba();
  Logger.log('Aba pronta: ' + sh.getName() + ' | linhas: ' + sh.getLastRow());
}

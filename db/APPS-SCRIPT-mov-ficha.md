# Espelho da Ficha de Movimentação na planilha (Supabase → Google Sheets)

> **O que é.** A Ficha de Movimentação de Viaturas salva tudo no **Supabase**
> (tabela `mov_viaturas` + fotos no Storage). Este Apps Script é um **Web App**
> que recebe, a cada ficha salva, a linha completa e a **espelha numa planilha
> Google** — uma linha por movimentação, com os **links dos comprovantes**
> (URLs assinadas duráveis do Storage, clicáveis). Serve para **envio a órgãos
> externos**: o órgão recebe a planilha (ou a exporta em XLSX/CSV/PDF pelo
> próprio Google Sheets) e baixa cada comprovante pelo link.
>
> O painel **não deixa de salvar** se o espelho falhar: o envio é
> *fire-and-forget* (POST para um iframe oculto), a fonte da verdade continua
> sendo o Supabase. A planilha é uma **cópia para distribuição**, não o sistema.

O espelho **casa por `ID`** (a coluna A): reenviar/editar a mesma ficha
**atualiza a linha existente** em vez de duplicar.

## Setup

> ⚠️ **Cole SÓ o código JavaScript** (o conteúdo do bloco `Código.gs`, ou o arquivo
> pronto `APPS-SCRIPT-mov-ficha.gs`). **NÃO cole os títulos deste `.md`** — linhas
> que começam com `#` são formatação do documento, e o Apps Script rejeita (lá o
> comentário é `//`). Foi isso que dava o erro de "não salva".

1. Na planilha do espelho → **Extensões → Apps Script**.
2. Cole **só** o `Código.gs` abaixo (o `SHEET_ID` já vem cravado no código, apontando
   para a sua planilha — **não precisa** configurar Script Property).
3. **Implantar → Nova implantação → Tipo: App da Web**
   - *Executar como*: **Eu**
   - *Quem pode acessar*: **Qualquer pessoa** (o painel envia sem login).
   - Implantar → copie a **URL do app da Web** (`.../exec`).
4. Me mande essa URL — eu colo em `MOV_SCRIPT_URL` no topo do `<script>` de
   `src/movimentacao-viaturas.html` (substitui `COLE_AQUI…`) e commito.

> Ao **alterar o código**, use **Implantar → Gerenciar implantações → (lápis) →
> Nova versão** para manter a **mesma URL** (não crie implantação nova, senão a
> URL muda e você precisa recolar em `MOV_SCRIPT_URL`).

## `Código.gs`

```javascript
// ── Espelho da Ficha de Movimentação de Viaturas (Supabase → Sheets) ──
// Recebe o POST do painel (campo "payload" = a linha JSON de mov_viaturas)
// e escreve/atualiza uma linha na planilha. Casa por ID (coluna A).

// ID da planilha do espelho. É a parte da URL ENTRE "/d/" e "/edit"
// — NUNCA inclua "/edit" nem "#gid=0". Já vem cravado aqui, então
// NÃO precisa configurar Script Property (o property, se existir, tem prioridade).
var SHEET_ID_PADRAO = '1qugZSao5daiWnLTElLdgBVgSWpFv1xvlvUZPv-Nsoks';

var CABECALHO = [
  'ID', 'Criado em', 'Prefixo', 'Placa',
  'Motorista', 'Matrícula', 'Lotação', 'Local de utilização', 'Tipo de empenho',
  'Km inicial', 'Km final', 'Km rodados', 'Início', 'Término',
  'Comb. ao armar', 'Comb. ao devolver',
  'Abasteceu?', 'Abastecimentos (resumo)',
  'Acidente?', 'Manutenção?', 'Avaria?', 'Higienizou?', 'TAQ/Embarcação?', 'Aeronave?',
  'Observações', 'GP responsável', 'Grupamento', 'Registrado por',
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

function _sn(b){ return (b === true || b === 'true' || b === 't') ? 'Sim' : 'Não'; }

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
      return p.join(' · ');
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

    // casa por ID (coluna A) → atualiza; senão, acrescenta
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
```

## Notas

- **Fuso horário / formatos.** As datas saem formatadas `dd/MM/yyyy HH:mm` no
  fuso do script (padrão `America/Sao_Paulo`). Ajuste em **Project Settings →
  Time zone** se necessário.
- **Comprovantes.** Os links já são URLs assinadas duráveis (~10 anos) do
  Supabase Storage — o órgão externo abre/baixa direto, sem login. Vão numa só
  célula separados por quebra de linha.
- **Exportar para o órgão.** Na planilha: **Arquivo → Fazer o download →**
  `.xlsx` / `.csv` / `.pdf`. Ou filtre por prefixo/GP/mês antes de exportar.
- **Não confunda** com `APPS-SCRIPT-viaturas.md` (aquele, de sincronizar o
  *cadastro* da frota planilha→Supabase, foi **descontinuado**). Este aqui vai
  no sentido inverso e é o espelho vivo das **fichas**.
```

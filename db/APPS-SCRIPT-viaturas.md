# Importar o cadastro de VIATURAS (planilha → Supabase)

> ⚠️ **DECISÃO (2026-08-13): a frota é gerenciada PELO PAINEL** (Gestão de Viaturas:
> incluir/editar/transferir/remover). **NÃO use este Apps Script de sincronização**
> automática — ele sobrescreveria as edições feitas no painel. A carga inicial já
> foi feita pelo `09_seed_viaturas.sql`. Mantido aqui só como referência histórica /
> caso um dia queira voltar a sincronizar pela planilha.


A planilha de viaturas (`1B4a5t7m2FFDNo3bG0KRMNkOCNZqVAhVrR45YFzs-Ylg`) é a **fonte** —
ela é atualizada com frequência. Este Apps Script lê a planilha e faz **upsert**
na tabela `public.viaturas` do Supabase (por `prefixo`). Só escreve as colunas do
cadastro — **não** mexe em `situacao_operacional` (isso é gerido pelo Aux P4 no painel).

## Por que service_role?
A escrita na tabela `viaturas` é protegida por RLS (o painel só LÊ). Como o Apps
Script roda no servidor do Google (a chave não fica exposta ao navegador), ele usa a
**service_role key** do Supabase, que passa pelo RLS. Guarde-a nas *Script Properties*
(nunca no código, nunca no painel).

## Setup
1. Abra a planilha de viaturas → **Extensões → Apps Script**.
2. Cole o código abaixo (arquivo `Código.gs`).
3. **Project Settings → Script Properties** → adicione:
   - `SB_SERVICE_ROLE` = a *service_role* key (Supabase → Project Settings → API → `service_role`, **secret**).
4. Rode `importarViaturas` uma vez (autorize). Confira no Supabase que a tabela `viaturas` populou.
5. (Opcional) Rode `criarGatilho` uma vez para sincronizar automaticamente a cada 6h.

```javascript
const SUPABASE_URL = 'https://zrnbebjszwkmquzthjfa.supabase.co';
function _key(){ return PropertiesService.getScriptProperties().getProperty('SB_SERVICE_ROLE'); }

function importarViaturas(){
  const sh = SpreadsheetApp.getActiveSpreadsheet().getSheets()[0]; // 1ª aba (gid 0)
  const rows = sh.getDataRange().getValues();
  const header = rows[0].map(v => String(v).trim().toUpperCase());
  const col = frag => header.findIndex(h => h.indexOf(frag.toUpperCase()) >= 0);

  const iPel=col('PEL PM'), iGp=col('GP PM'), iMun=col('MUNIC'), iPref=col('PREFIXO'),
        iModelo=col('MARCA'), iAno=col('ANO DE FABRIC'), iTracao=col('TRA'),
        iPlaca=col('PLACA'), iTipo=col('TIPO DE BEM'), iObs=col('OBSERVA'),
        iSit=col('SITUAÇÃO DA VIATURA');

  const S = i => (i >= 0 ? String(rows_r[i] == null ? '' : rows_r[i]).trim() : '');
  let rows_r;
  const out = [];
  for (let r = 1; r < rows.length; r++){
    rows_r = rows[r];
    const prefixo = S(iPref);
    if (!prefixo) continue;
    out.push({
      prefixo: prefixo,
      placa: S(iPlaca) || null,
      marca_modelo: S(iModelo) || null,
      ano: parseInt(S(iAno), 10) || null,
      tracao: S(iTracao) || null,
      tipo_bem: S(iTipo) || null,
      pel: S(iPel) || null,
      gp: S(iGp) || null,
      municipio: S(iMun) || null,
      situacao_viatura: S(iSit) || null,
      observacao: S(iObs) || null,
      ativo: true
    });
  }
  if (!out.length){ Logger.log('Nenhuma viatura encontrada — confira os nomes das colunas.'); return; }

  const url = SUPABASE_URL + '/rest/v1/viaturas?on_conflict=prefixo';
  const key = _key();
  const resp = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: key, Authorization: 'Bearer ' + key,
               Prefer: 'resolution=merge-duplicates,return=minimal' },
    payload: JSON.stringify(out),
    muteHttpExceptions: true
  });
  Logger.log('HTTP ' + resp.getResponseCode() + ' — ' + out.length + ' viaturas. ' + resp.getContentText());
}

function criarGatilho(){
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'importarViaturas') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('importarViaturas').timeBased().everyHours(6).create();
  Logger.log('Gatilho criado: importarViaturas a cada 6h.');
}
```

> **Upsert seguro:** `on_conflict=prefixo` + `merge-duplicates` atualiza só as colunas
> enviadas. `situacao_operacional`, baixas e movimentações **não** são tocadas.

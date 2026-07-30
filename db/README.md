# Banco — Módulo Denúncias / Requisições

Ordem de execução no **Supabase → SQL Editor**:

| Ordem | Arquivo | O que faz |
|------|---------|-----------|
| pré | (já feito por você) | tabelas `municipios_grupos` e `grupos` |
| 1 | `00_grupamentos_view.sql` | view `vw_municipio_grupamento` (município → grupamento **completo**) |
| 2 | `01_denuncias.sql` | contador atômico, tabela `denuncias`, função `criar_denuncia`, RLS |

## Como funciona a numeração (sem duplicidade)
O número **não** é gerado no navegador. Ao registrar, o front chama a função
`criar_denuncia(...)`, que:
1. deriva o **grupamento completo** a partir do município (via a view);
2. gera o próximo número do **ano + tipo** com incremento atômico (trava de linha) —
   dois lançamentos simultâneos recebem 059 e 060, nunca dois 059;
3. insere e devolve a linha com o número definitivo.

Denúncia e requisição têm sequências **separadas** por ano (igual à planilha).

## Teste rápido (no SQL Editor)
```sql
select numero, grupamento_completo, situacao
from public.criar_denuncia('{
  "tipo":"denuncia","municipio":"GOVERNADOR VALADARES","tema":"Flora",
  "origem":"Diretamente ao policial","descricao":"teste de fluxo",
  "registrado_por_matricula":"146.322-3","registrado_por_nome":"3º Sgt Edison"
}'::jsonb);
-- deve retornar algo como  001/2026 | 1 GP / 1 PEL / 3 CIA PM MAMB / GOVERNADOR VALADARES | PENDENTE
```

## Frontend
`src/nova-denuncia.html` já está plugado:
- lê os municípios da view e deriva o grupamento completo ao escolher o município;
- registra via `criar_denuncia` (reaproveita a chave anon do `auth.js`);
- exige login (usa a sessão do `auth.js`; sem sessão, redireciona para `index.html`).

## Anexos (Google Drive) — pendente de setup
O upload chama a Edge Function `upload-anexo`. Enquanto ela não estiver publicada,
o formulário **registra normalmente sem anexos** (o arquivo aparece como "falhou").
Para ativar os anexos, siga `EDGE-FUNCTION-drive.md`.

## Ainda não incluído (por opção)
- Seed dos 215 municípios: você já populou `municipios_grupos` (221 linhas), então não é necessário.
- Migração do histórico (~500 registros da planilha antiga): não incluída nesta v1.
- Espelho para a planilha (Apps Script): próxima etapa.

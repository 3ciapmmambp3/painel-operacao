# Banco — Módulo Denúncias / Requisições

Ordem de execução no **Supabase → SQL Editor**:

| Ordem | Arquivo | O que faz |
|------|---------|-----------|
| pré | (já feito por você) | tabelas `municipios_grupos` e `grupos` |
| 1 | `00_grupamentos_view.sql` | view `vw_municipio_grupamento` (município → grupamento **completo**) |
| 2 | `01_denuncias.sql` | contador atômico, tabela `denuncias`, função `criar_denuncia`, RLS |
| 3 | `02_storage_anexos.sql` | bucket privado `anexos` + políticas (upload/leitura/remoção via anon) |
| virada | `03_seed_contadores.sql` | **no dia de ligar o sistema:** ajusta a numeração para continuar de onde a planilha parou |

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

## Anexos (Supabase Storage)
Os anexos vão para um **bucket privado `anexos`** no próprio Supabase — basta rodar
`02_storage_anexos.sql` e criar o bucket (o SQL já cria; se preferir, dá pra criar
pelo Dashboard → Storage → New bucket, **privado**). O upload é direto do navegador
(sem Edge Function): imagens são comprimidas, sobe pro Storage e guarda uma **signed
URL durável** em `denuncias.anexos[].link`. Se o bucket/políticas não existirem, o
anexo aparece como "falhou" e o registro é salvo normalmente sem ele.

> O caminho antigo por **Google Drive** (`EDGE-FUNCTION-drive.md`) foi **descontinuado**:
> conta de serviço não tem cota de armazenamento em Gmail comum (erro 403).

## Ainda não incluído (por opção)
- Seed dos 215 municípios: você já populou `municipios_grupos` (221 linhas), então não é necessário.
- Migração do histórico (~500 registros da planilha antiga): não incluída nesta v1.
- Espelho para a planilha (Apps Script): próxima etapa.

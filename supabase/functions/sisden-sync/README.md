# sisden-sync — sincronização NUDEN (SISDEN/SEMAD) → Supabase

Edge Function que puxa as denúncias do **SISDEN oficial** (API do eco-sistemas /
GAIA) e grava na tabela `public.nuden_demandas`, **sem depender do robô do Sgt
Anderson**. Reaproveita a RPC `nuden_sync` (db/151): upsert por **CÓDIGO
(= Protocolo)** → **só novas inserem**, as existentes são atualizadas sem apagar
a baixa feita no painel.

> **Estado:** ESQUELETO (2026-10-30). Falta travar 3 formatos do JSON na 1ª
> chamada real (campo do token no login; shape da lista; origem do vencimento) —
> ver os `TODO(confirmar)` no `index.ts`. O `console.log` já imprime as chaves
> reais pra fecharmos o mapeamento.

## 1) Contas do robô (failover entre 2 logins)
Pode usar a sua conta **e** a do outro militar — o robô tenta a 1ª; se a senha
mudou/trancou, cai pra a 2ª sozinho. Troca = só editar o secret (sem mexer no código).

```bash
# opção A (recomendada): um JSON com as contas
supabase secrets set SISDEN_ACCOUNTS='[{"cpf":"000.000.000-00","senha":"..."},{"cpf":"111.111.111-11","senha":"..."}]'

# opção B: pares numerados
supabase secrets set SISDEN_CPF_1=000.000.000-00 SISDEN_SENHA_1=...
supabase secrets set SISDEN_CPF_2=111.111.111-11 SISDEN_SENHA_2=...
```
`SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` já existem no ambiente das Edge Functions.

## 2) Deploy
```bash
cd painel-operacao-git
supabase functions deploy sisden-sync
```

## 3) Rodar em DRY-RUN primeiro (padrão seguro — NÃO grava nada)
O padrão já é `DRY_RUN=true`. A função só **compara** os protocolos da API com os
códigos já no banco e devolve o resumo (quantas novas × quantas já existem).
```bash
supabase functions invoke sisden-sync --no-verify-jwt
# resposta esperada: { dry_run:true, puxadas, mapeadas, ja_no_banco, novas, exemplos_novas }
```
✅ **Gate da Fase 0:** se `ja_no_banco` fizer sentido e `exemplos_novas` forem
protocolos realmente novos, a dedup está certa. Se aparecer tudo como "nova"
sendo que já deveriam existir → o formato da chave diverge (protocolo × `D######`);
ajustar o mapeamento antes de ligar a escrita.

## 4) Ligar a escrita (só depois de validar o dry-run)
```bash
supabase secrets set DRY_RUN=false
supabase functions invoke sisden-sync --no-verify-jwt
# agora chama nuden_sync → upsert real (insere novas, atualiza existentes)
```

## 5) Agendar (pg_cron / Cron do Supabase)
No painel do Supabase: **Edge Functions → sisden-sync → Cron** (ex.: a cada 3h),
ou via SQL com `pg_cron` + `pg_net`:
```sql
select cron.schedule('sisden-sync-3h', '0 */3 * * *', $$
  select net.http_post(
    url := 'https://<PROJ>.functions.supabase.co/sisden-sync',
    headers := jsonb_build_object('Authorization','Bearer <SERVICE_ROLE_KEY>')
  );
$$);
```

## Variáveis (todas opcionais, têm default)
| var | default | p/ quê |
|---|---|---|
| `DRY_RUN` | `true` | `false` = grava de verdade |
| `SISDEN_STATUS` | `Encaminhada` | filtro de status (pendentes) |
| `SISDEN_ID_SUPRAM` | `221` | SUPRAM da 3ª Cia |
| `SISDEN_PAGE_SIZE` | `100` | paginação |
| `SISDEN_PRAZO_DIAS` | `90` | fallback p/ vencimento quando a API não manda |
| `SISDEN_BASE` | `https://ecosistemas.meioambiente.mg.gov.br` | base do site |

## Falta (próximas fases)
- **Fase 2 — Drive:** baixar o PDF/anexos da denúncia no SISDEN e subir na pasta
  `1JO_...` (como já é feito), linkando em `nuden_demandas.anexos`. Reusar o
  Apps Script que já tem acesso ao Drive (conta 3ciapmmamb.p3).
- **Requisições:** o SISDEN tem Denúncias **e** Requisições (módulo à parte) —
  replicar o mesmo molde depois.
- **DDU:** é OUTRO site/sistema — inspecionar quando houver acesso.

# Painel de Controle de Operações — 3ª CIA PM MAmb

Sistema de acompanhamento de metas POE e GDO Rural da 3ª Companhia de Policiamento de Meio Ambiente.

## Funcionalidades

- **OP POE** — Controle de metas e realizado por natureza/grupamento
- **OP GDO RURAL** — Monitoramento de operações em Zona Rural com mapa interativo
- **Grupamentos** — Tabela de municípios e grupamentos
- **Admin** — Gestão de usuários com importação via Excel

## Desenvolvimento local

```bash
npm install
npm run dev
```

Acesse: http://localhost:3000

## Publicação

O projeto é um site estático hospedado no Vercel.
Não requer build — os arquivos em `/src` são servidos diretamente.

## Observações de segurança

- A API Key do Google Sheets é pública (somente leitura)
- Dados de usuários ficam no localStorage do navegador
- Perfis e senhas são gerenciados localmente

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Operational panel ("Painel de Operações") for the **3ª Companhia de Polícia Militar de Meio Ambiente (3ª Cia PM MAmb)** of Minas Gerais. UI and domain language are **Brazilian Portuguese** — keep it that way (labels, messages, comments). PMMG visual identity: dark theme, gold accent.

## Commands

```bash
npm install
npm run dev      # live-server on ./src at http://localhost:3000 (also: npm start)
```

- **No build step.** Files in `src/` are served as-is (static). Deploy is Vercel `@vercel/static` (see `vercel.json`).
- **No test suite and no linter.** Don't invent one; verify changes by loading the page in the browser.
- **Database changes** live in `db/*.sql` and are run **manually** in the Supabase SQL Editor, in filename order (`00_…` before `01_…`). They are written to be idempotent (re-runnable).

## Architecture

### Multi-page static app, no framework
Each screen is a **standalone HTML file in `src/`** with its own inline `<style>` and `<script>`. There is no bundler, no shared JS module system, no components. Shared pieces:
- `src/styles/global.css` — the design system: CSS custom properties on `:root` (`--gold #9b8a5c`, `--bg-page`, `--bg-card`, `--text-*`, semantic `--success/--danger/--info`, etc.) plus header/tabs/table primitives. **Always style through these tokens**; pages re-declare only layout-specific rules inline.
- `src/auth.js` — authentication, session, and the Supabase REST helpers. Included via `<script src="auth.js">` on every authenticated page.

Navigation between screens is plain `window.location.href='page.html'` (see the `topnav` in `painel.html`). `index.html` is the login page; pages guard themselves by reading the session and redirecting to `index.html` when absent.

### Three separate backends (know which one a feature uses)
1. **Supabase (Postgres via PostgREST)** — auth and the structured operational data. URL + **anon key are hardcoded** in `auth.js` (`SB_AUTH_URL`, `SB_AUTH_KEY`) and reused by other pages by referencing those globals. Tables: `militares`, `municipios_grupos`, `grupos`, `denuncias`, `contadores`, plus the view `vw_municipio_grupamento`. Row Level Security is enabled; the frontend uses the anon key, so **scope checks are enforced in JS**, not by the DB.
2. **Google Apps Script + Google Sheets** — the daily service report ("relatório de serviço"). `SCRIPT_URL` in `relatorio-servico.html`/`meus-relatorios.html`. Reads via `?action=…` (e.g. `meusRelatorios`, `buscarRelatorioCompleto`); **saves by POSTing a form to a hidden iframe** (not fetch). Dropdown option lists come from a `referenceCache` fetched from the same script.
3. **Google Sheets API v4 (read-only public API key)** — POE / GDO Rural metas in `painel.html` (`API_KEY`, `SHEET_ID`). Maps use Leaflet loaded from CDN at runtime; OSM tiles are proxied through the `/osm-tiles/...` route in `vercel.json`.

### Authentication & authorization (custom, not Supabase Auth)
- Login matches `matricula` + a **SHA-256 hash** of the password against the `militares` table (`auth_login` in `auth.js`). No Supabase Auth / JWT.
- Session is stored in **`sessionStorage` key `poe_sessao_v2`** (deliberately not localStorage — expires on browser close). Read it with `sessaoLer()`.
- Access levels, ascending: `NIVEIS = ['operacional','admin_gp','admin_pelotao','admin','admin_geral']`.
- A militar's unit is `session.grupamento_id`, a lotação **string** that contains `"N GP / M PEL"`. `_pelotaoNum()` / `_gpNum()`-style parsing extracts the numbers; `auth_podeVerGrupamento(session, grupamento_id)` is the canonical scope check (admin/admin_geral = all; admin_pelotao = same pelotão; admin_gp/operacional = own grupamento). Reuse these — don't reinvent scope logic.

### "Controle de Demandas" module (denúncias/requisições)
This is the newest, most integrated feature and the template for future demand modules.
- **Data model:** `denuncias` unifies both types via `tipo` (`'denuncia'` = walk-in "Denúncia de Balcão", `'requisicao'` = external órgão). Numbering is **per (ano, tipo)** and assigned **atomically in the DB**, never in the browser — always insert through the `criar_denuncia(jsonb)` RPC, which locks the `contadores` row, derives the responsible grupamento from the município via `vw_municipio_grupamento`, and returns the row with its definitive `numero`.
- **Grupamento is derived from the município of the fact**, not from the logged-in user's unit — a militar can direct a demand to any grupamento. The full label (`grupamento_completo`, e.g. `1 GP / 1 PEL / 3 CIA PM MAMB / GOVERNADOR VALADARES`) comes from joining `municipios_grupos` → `grupos`.
- **Pages:** `nova-denuncia.html` (register), `denuncias.html` (the hub: left sidebar of demand modules, scope selector for admins, filters incl. year, detail drawer, atendimento form, and the official "Ficha" PDF generated via `window.print()` on a new window — no PDF library).
- **Attachments** go to **Google Drive** (a Supabase Edge Function `upload-anexo`, see `db/EDGE-FUNCTION-drive.md`); only the Drive `file_id`/`web_view_link` is stored in `denuncias.anexos` (jsonb).
- **"Baixa automática":** submitting `relatorio-servico.html` PATCHes matching `denuncias` rows to `RESPONDIDA` with the attendance fields (REDS, Auto de Infração, Ato de Fiscalização, date, obs) — see `marcarDemandasAtendidas()`. It matches by `numero` + `tipo` parsed from the report's "Denúncia de Balcão" / "Requisição" categories.

## Conventions

- Match the existing file's style: inline `<style>`/`<script>`, token-based CSS, Portuguese identifiers/labels, no external runtime deps except the few CDN libs already used (Leaflet).
- When adding a page that reads Supabase, reuse `SB_AUTH_URL`/`SB_AUTH_KEY` from `auth.js` rather than redeclaring keys.
- New demand types should follow the denúncias pattern: a Postgres table + (if numbered) the atomic-counter approach, a page under the `Controle de Demandas` sidebar, and scope via `auth_podeVerGrupamento`.

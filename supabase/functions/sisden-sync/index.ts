// ══════════════════════════════════════════════════════════════════════
//  Edge Function: sisden-sync
//  Sincroniza DENÚNCIAS (sisden-api) e REQUISIÇÕES (sisreq) do SISDEN/SEMAD
//  direto da API oficial para a tabela public.nuden_demandas.
//
//  Fluxo: login (eco-ui) → p/ cada FONTE ligada: puxa a lista → detalhe das
//  novas (natureza só p/ denúncia; anexos p/ Drive) → nuden_sync (upsert por
//  protocolo; protocolo é único no sistema → denúncia e requisição não colidem).
//
//  SECRETS: SISDEN_CPF_1/SISDEN_SENHA_1 (ou SISDEN_ACCOUNTS).
//  DRY_RUN=true (padrão) não grava. SISDEN_REQUISICOES=true liga requisições.
//  SISDEN_ANEXOS=true liga o upload de anexos (Drive via SISDEN_DRIVE_URL).
// ══════════════════════════════════════════════════════════════════════

import { createClient } from "jsr:@supabase/supabase-js@2";

// ─── Config ─────────────────────────────────────────────────────────────
const HOST          = Deno.env.get("SISDEN_BASE")      ?? "https://ecosistemas.meioambiente.mg.gov.br";
const ID_SUPRAM     = Deno.env.get("SISDEN_ID_SUPRAM") ?? "221";
const STATUS        = Deno.env.get("SISDEN_STATUS")    ?? "Encaminhada";
const PAGE_SIZE     = Number(Deno.env.get("SISDEN_PAGE_SIZE") ?? "100");
const MAX_PAGES     = Number(Deno.env.get("SISDEN_MAX_PAGES") ?? "200");
const DET_CONC      = Number(Deno.env.get("SISDEN_DET_CONC") ?? "8");
const DRY_RUN       = (Deno.env.get("DRY_RUN") ?? "true").toLowerCase() !== "false";

// Fontes (ligar/desligar + prazo de vencimento em dias)
const DEN_ON        = (Deno.env.get("SISDEN_DENUNCIAS")   ?? "true").toLowerCase()  !== "false";
const REQ_ON        = (Deno.env.get("SISDEN_REQUISICOES") ?? "false").toLowerCase() === "true";
const DEN_PRAZO     = Number(Deno.env.get("SISDEN_PRAZO_DIAS")     ?? "90");
const REQ_PRAZO     = Number(Deno.env.get("SISDEN_REQ_PRAZO_DIAS") ?? "90");

// Detalhe (natureza/anexos) + backfill
const DETALHE_ON    = (Deno.env.get("SISDEN_DETALHE") ?? "true").toLowerCase() !== "false";
const DETALHE_MAX   = Number(Deno.env.get("SISDEN_DETALHE_MAX") ?? "50");
const BACKFILL      = (Deno.env.get("BACKFILL") ?? "false").toLowerCase() === "true";
const BACKFILL_MAX  = Number(Deno.env.get("BACKFILL_MAX") ?? "1000");
const BACKFILL_SO   = (Deno.env.get("SISDEN_BACKFILL_SO") ?? "").split(",").map((s) => s.trim()).filter(Boolean);

// Anexos no Drive (via Apps Script)
const DRIVE_URL     = Deno.env.get("SISDEN_DRIVE_URL") ?? "";
const ANEXOS_ON     = (Deno.env.get("SISDEN_ANEXOS") ?? "true").toLowerCase() !== "false";
const ANEXOS_MAX    = Number(Deno.env.get("SISDEN_ANEXOS_MAX") ?? "20");
const ANEXOS_SKIP_SE_EXISTE = (Deno.env.get("SISDEN_ANEXOS_SKIP_EXISTE") ?? "true").toLowerCase() !== "false";
const ANEXOS_TESTE_PASTA = Deno.env.get("SISDEN_ANEXOS_TESTE_PASTA") ?? "";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ─── Descritor de FONTE ─────────────────────────────────────────────────
// Confirmado ao vivo (2026-11-02): denúncia=sisden-api, requisição=sisreq;
// ambos /backOffice/<recurso>[?...|/{protocolo}|/anexos/{id}/download].
type Fonte = { tipo: string; base: string; recurso: string; prazo: number; temNatureza: boolean };
const FONTES: Fonte[] = [];
if (DEN_ON) FONTES.push({ tipo: "DENÚNCIA",   base: "/sisden-api/api", recurso: "denuncias",   prazo: DEN_PRAZO, temNatureza: true });
if (REQ_ON) FONTES.push({ tipo: "REQUISIÇÃO", base: "/sisreq/api",     recurso: "requisicoes", prazo: REQ_PRAZO, temNatureza: false });

// ─── Contas do robô (failover) ─────────────────────────────────────────
type Conta = { cpf: string; senha: string };
function carregarContas(): Conta[] {
  const raw = Deno.env.get("SISDEN_ACCOUNTS");
  if (raw) {
    try { const arr = JSON.parse(raw); if (Array.isArray(arr)) return arr.filter((a) => a?.cpf && a?.senha); } catch {}
  }
  const contas: Conta[] = [];
  for (let i = 1; i <= 5; i++) {
    const cpf = Deno.env.get(`SISDEN_CPF_${i}`); const senha = Deno.env.get(`SISDEN_SENHA_${i}`);
    if (cpf && senha) contas.push({ cpf, senha });
  }
  return contas;
}
function extrairToken(j: unknown): string | null {
  if (!j || typeof j !== "object") return null;
  const o = j as Record<string, any>;
  return o.token ?? o.accessToken ?? o.access_token ?? o.jwt ?? o.data?.token ?? o.data?.accessToken ?? o.data?.access_token ?? null;
}
function extrairLista(j: unknown): any[] {
  if (Array.isArray(j)) return j;
  const o = (j ?? {}) as Record<string, any>;
  const itens = o.content ?? o.data ?? o.items ?? o.rows ?? o.denuncias ?? o.requisicoes ?? [];
  return Array.isArray(itens) ? itens : [];
}
async function login(conta: Conta): Promise<string | null> {
  const url = `${HOST}/eco-ui/api/auth/login`;
  const cpfDig = conta.cpf.replace(/\D/g, "");
  // O login do SISDEN (atualização 2026-11-12) exige o CPF COM máscara 000.000.000-00
  // + chave `password`. Deriva a máscara dos dígitos (independe de como o secret guardou).
  const cpfMask = cpfDig.length === 11 ? cpfDig.replace(/(\d{3})(\d{3})(\d{3})(\d{2})/, "$1.$2.$3-$4") : conta.cpf;
  const tag = `...${cpfDig.slice(-3)}`;
  const candidatos: Record<string, string>[] = [
    { cpf: cpfMask, password: conta.senha },                 // ← contrato novo (confirmado ao vivo 2026-11-12)
    { cpf: cpfDig, password: conta.senha },                  // fallbacks de compatibilidade
    { cpf: cpfMask, senha: conta.senha }, { cpf: cpfDig, senha: conta.senha },
    { login: cpfMask, senha: conta.senha }, { username: cpfMask, password: conta.senha },
  ];
  for (let i = 0; i < candidatos.length; i++) {
    const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", "Accept": "application/json" }, body: JSON.stringify(candidatos[i]) }).catch(() => null);
    if (!r) continue;
    if (!r.ok) { console.warn(`[login] ${tag} formato#${i} -> HTTP ${r.status}`); continue; }
    const j = await r.json().catch(() => null); const tk = extrairToken(j);
    if (tk) { console.log(`[login] ok ${tag} formato#${i}`); return tk; }
  }
  return null;
}
async function loginComFailover(contas: Conta[]): Promise<string> {
  for (const c of contas) { const tk = await login(c).catch(() => null); if (tk) return tk; }
  throw new Error("Nenhuma conta do SISDEN conseguiu logar (verifique os secrets SISDEN_ACCOUNTS).");
}

// ─── Puxa a lista de 1 fonte (paginado) ─────────────────────────────────
async function puxarLista(token: string, f: Fonte): Promise<any[]> {
  const todas: any[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const url = `${HOST}${f.base}/backOffice/${f.recurso}`
      + `?page=${page}&pageSize=${PAGE_SIZE}&status=${encodeURIComponent(STATUS)}&idSupram=${ID_SUPRAM}&isTecnico=true`;
    const r = await fetch(url, { headers: { "Authorization": `Bearer ${token}`, "Accept": "application/json" } });
    if (!r.ok) throw new Error(`[${f.recurso}] HTTP ${r.status} na pagina ${page}`);
    const itens = extrairLista(await r.json());
    if (itens.length === 0) break;
    todas.push(...itens);
    if (itens.length < PAGE_SIZE) break;
  }
  console.log(`[${f.recurso}] total puxado: ${todas.length}`);
  return todas;
}

// ─── Detalhe de 1 item (natureza/anexos não vêm na lista) ───────────────
let _detLogou: Record<string, boolean> = {};
async function buscarDetalhe(token: string, f: Fonte, item: any): Promise<any | null> {
  const proto = item?.protocolo ?? item?.codigo;
  if (!proto) return null;
  const url = `${HOST}${f.base}/backOffice/${f.recurso}/${encodeURIComponent(String(proto))}`;
  const r = await fetch(url, { headers: { "Authorization": `Bearer ${token}`, "Accept": "application/json" } }).catch(() => null);
  if (!r || !r.ok) { console.warn(`[detalhe/${f.recurso}] HTTP ${r?.status ?? "ERR"} p/ ${proto}`); return null; }
  const j = await r.json().catch(() => null);
  const det = (j && typeof j === "object" && !Array.isArray(j)) ? (j.data ?? j.denuncia ?? j.requisicao ?? j) : null;
  if (det && !_detLogou[f.recurso]) { console.log(`[detalhe/${f.recurso}] campos:`, Object.keys(det)); _detLogou[f.recurso] = true; }
  return det;
}

// tabela de atividades (id -> nome) p/ traduzir a natureza (só denúncias)
async function carregarAtividades(token: string): Promise<Map<number, string>> {
  const m = new Map<number, string>();
  try {
    const r = await fetch(`${HOST}/sisden-api/api/atividades`, { headers: { "Authorization": `Bearer ${token}`, "Accept": "application/json" } });
    if (!r.ok) { console.warn(`[atividades] HTTP ${r.status}`); return m; }
    const j = await r.json(); const arr = Array.isArray(j) ? j : (j.data ?? j.content ?? []);
    for (const a of arr) {
      if (a?.id == null) continue;
      const nome = a.descricao ? (a.tematica ? `${a.tematica} - ${a.descricao}` : String(a.descricao)) : (a.codigo ?? null);
      if (nome) m.set(Number(a.id), nome);
    }
    console.log(`[atividades] carregadas: ${m.size}`);
  } catch (e) { console.warn("[atividades] erro:", e); }
  return m;
}
function naturezaDeDetalhe(det: any, ativ: Map<number, string>): string | null {
  let ad = det?.atividades_denuncias;
  if (typeof ad === "string") { try { ad = JSON.parse(ad); } catch { ad = null; } }
  if (!Array.isArray(ad) || ad.length === 0) return null;
  const nomes: string[] = [];
  for (const a of ad) { const id = Number(a?.atividade_id ?? a?.id); if (!id) continue; nomes.push(ativ.get(id) ?? `#${id}`); }
  return nomes.length ? [...new Set(nomes)].join("; ") : null;
}
function enriquecerComDetalhe(linha: any, det: any, ativ: Map<number, string>, f: Fonte) {
  if (!det) return linha;
  return {
    ...linha,
    natureza: f.temNatureza ? (linha.natureza ?? naturezaDeDetalhe(det, ativ)) : linha.natureza,
    data_gerada: linha.data_gerada ?? soData(pick(det, "created_at")),
    info_complementares: linha.info_complementares ?? pick(det, "informacao_complementar", "informacoes_complementares", "descricao_complementar"),
  };
}

// ─── Anexos (baixa do SISDEN → sobe no Drive via Apps Script) ───────────
const MIMES: Record<string, string> = {
  pdf: "application/pdf", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp",
  doc: "application/msword", docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel", xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  mp4: "video/mp4", zip: "application/zip", txt: "text/plain",
};
function bytesToBase64(bytes: Uint8Array): string {
  let bin = ""; const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(bin);
}
// download CONFIRMADO: ${base}/backOffice/${recurso}/anexos/{id}/download
async function baixarArquivo(token: string, f: Fonte, a: any): Promise<{ nome: string; mime: string; base64: string } | null> {
  const id = a?.id; if (id == null) return null;
  const nome = String(a?.nome_arquivo ?? a?.nome ?? `arquivo-${id}`);
  const ext = String(a?.extensao ?? (nome.split(".").pop() ?? "")).toLowerCase();
  const mimeFallback = MIMES[ext] ?? "application/octet-stream";
  const url = `${HOST}${f.base}/backOffice/${f.recurso}/anexos/${id}/download`;
  const r = await fetch(url, { headers: { "Authorization": `Bearer ${token}` } }).catch(() => null);
  if (!r || !r.ok) { console.warn(`[anexo/${f.recurso}] HTTP ${r?.status ?? "ERR"} id=${id}`); return null; }
  const ct = (r.headers.get("content-type") || "").toLowerCase();
  if (ct.includes("application/json") || ct.includes("text/html")) { console.warn(`[anexo/${f.recurso}] resposta não-arquivo id=${id}`); return null; }
  const buf = new Uint8Array(await r.arrayBuffer());
  if (buf.byteLength === 0) return null;
  const mime = ct && !ct.includes("octet-stream") ? ct.split(";")[0].trim() : mimeFallback;
  return { nome, mime, base64: bytesToBase64(buf) };
}
async function subirDrive(pasta: string, nome: string, mime: string, base64: string): Promise<any | null> {
  const r = await fetch(DRIVE_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ protocolo: pasta, nome, mime, base64 }) }).catch(() => null);
  if (!r) return null;
  return await r.json().catch(() => null);
}
async function pastaJaTemArquivos(pasta: string): Promise<boolean> {
  const r = await fetch(DRIVE_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "check", protocolo: pasta }) }).catch(() => null);
  if (!r) return false;
  const j = await r.json().catch(() => null);
  return !!(j && j.temArquivos);
}
async function processarAnexos(token: string, f: Fonte, det: any, protocolo: string): Promise<any[]> {
  let arqs = det?.arquivos;
  if (typeof arqs === "string") { try { arqs = JSON.parse(arqs); } catch { arqs = null; } }
  if (!Array.isArray(arqs) || arqs.length === 0) return [];
  const pasta = ANEXOS_TESTE_PASTA || protocolo;
  if (ANEXOS_SKIP_SE_EXISTE && await pastaJaTemArquivos(pasta)) {
    console.log(`[anexo/${f.recurso}] ${protocolo}: pasta já tem arquivos → pulando`);
    return [];
  }
  const anexos: any[] = [];
  for (const a of arqs.slice(0, ANEXOS_MAX)) {
    const baixado = await baixarArquivo(token, f, a).catch(() => null);
    if (!baixado) continue;
    const up = await subirDrive(pasta, baixado.nome, baixado.mime, baixado.base64).catch(() => null);
    if (up?.ok && up.link) anexos.push({ nome: baixado.nome, mime: baixado.mime, tamanho: a?.tamanho ?? null, file_id: up.id, link: up.link, fonte: f.recurso });
    else console.warn(`[anexo/${f.recurso}] upload Drive falhou ${pasta}/${baixado.nome}:`, up?.erro ?? "sem resposta");
  }
  return anexos;
}

// ─── Mapeia 1 item (denúncia ou requisição) → linha do nuden_sync ───────
function pick(o: any, ...keys: string[]) { for (const k of keys) if (o?.[k] != null && o[k] !== "") return o[k]; return null; }
function nomeMunicipio(d: any): string | null {
  const m = d?.municipio; if (!m) return null;
  if (typeof m === "string") return m;
  if (typeof m === "object") return m.nome ?? m.nomeMunicipio ?? m.descricao ?? m.municipio ?? null;
  return null;
}
function montarEndereco(d: any): string | null {
  const partes = [d?.logradouro, d?.numero, d?.bairro].map((x) => (x == null ? "" : String(x).trim())).filter(Boolean);
  let end = partes.join(", ");
  if (d?.cep) end += (end ? " - CEP " : "CEP ") + d.cep;
  if (d?.ponto_referencia) end += (end ? " (ref.: " : "(ref.: ") + String(d.ponto_referencia).trim() + ")";
  return end || null;
}
function soData(v: any): string | null {
  if (!v) return null; const s = String(v);
  const m = s.match(/(\d{4})-(\d{2})-(\d{2})/) || s.match(/(\d{2})\/(\d{2})\/(\d{4})/);
  if (!m) return null;
  return m[0].includes("/") ? `${m[3]}-${m[2]}-${m[1]}` : `${m[1]}-${m[2]}-${m[3]}`;
}
function addDias(iso: string | null, dias: number): string | null {
  if (!iso) return null;
  const d = new Date(iso + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + dias);
  return d.toISOString().slice(0, 10);
}
function mapear(d: any, f: Fonte) {
  const data_gerada = soData(pick(d, "created_at"));
  const data_envio  = soData(pick(d, "data_encaminhamento"));
  const data_vencimento = addDias(data_envio ?? data_gerada, f.prazo);
  const endereco = f.recurso === "requisicoes" ? pick(d, "endereco_requisicao") : montarEndereco(d);
  return {
    codigo: pick(d, "protocolo", "codigo"),
    tipo_demanda: f.tipo,                         // DENÚNCIA | REQUISIÇÃO
    data_gerada,
    natureza: f.temNatureza ? pick(d, "natureza", "tematica", "naturezaInfracao") : null,
    municipio: nomeMunicipio(d),
    endereco,
    fracao_responsavel: null,
    data_envio, data_vencimento,
    status_prazo: null,
    info_complementares: pick(d, "informacao_complementar", "informacoes_complementares"),
    fonte_aba: f.recurso === "requisicoes" ? "sisreq" : "sisden",
    raw: d,
  };
}

// ─── Processa 1 fonte inteira (puxa → dedup → detalhe/anexos → grava) ───
async function processarFonte(sb: any, token: string, f: Fonte): Promise<any> {
  const brutas = await puxarLista(token, f);
  const linhas = brutas.map((d) => mapear(d, f)).filter((l) => l.codigo);
  const protocolos = linhas.map((l) => String(l.codigo));

  const existentes = new Set<string>();
  for (let i = 0; i < protocolos.length; i += 500) {
    const lote = protocolos.slice(i, i + 500);
    const { data, error } = await sb.from("nuden_demandas").select("codigo").in("codigo", lote);
    if (error) throw new Error(`select nuden_demandas: ${error.message}`);
    for (const row of data ?? []) existentes.add(row.codigo);
  }
  const novas = protocolos.filter((p) => !existentes.has(p));

  const porProtocolo = new Map<string, any>();
  for (const d of brutas) { const p = pick(d, "protocolo", "codigo"); if (p) porProtocolo.set(String(p), d); }

  let detalhe: any = { ativo: DETALHE_ON };
  if (DETALHE_ON) {
    const alvos = BACKFILL ? (BACKFILL_SO.length ? protocolos.filter((p) => BACKFILL_SO.includes(p)) : protocolos)
                : novas.length ? novas
                : (DRY_RUN && brutas.length ? [String(pick(brutas[0], "protocolo", "codigo"))] : []);
    const limitados = alvos.slice(0, BACKFILL ? BACKFILL_MAX : DETALHE_MAX);
    const ativ = (f.temNatureza && limitados.length) ? await carregarAtividades(token) : new Map<number, string>();
    const presDet = { natureza: 0, data_gerada: 0, info_complementares: 0 } as Record<string, number>;
    const fazAnexos = ANEXOS_ON && !!DRIVE_URL;
    let ok = 0, falhou = 0, anexosOk = 0;
    for (let i = 0; i < limitados.length; i += DET_CONC) {
      const lote = limitados.slice(i, i + DET_CONC);
      const dets = await Promise.all(lote.map((p) => { const item = porProtocolo.get(p); return item ? buscarDetalhe(token, f, item).catch(() => null) : Promise.resolve(null); }));
      for (let k = 0; k < lote.length; k++) {
        const p = lote[k], det = dets[k];
        if (!det) { falhou++; continue; }
        ok++;
        const idx = linhas.findIndex((l: any) => String(l.codigo) === p);
        if (idx >= 0) {
          linhas[idx] = enriquecerComDetalhe(linhas[idx], det, ativ, f);
          for (const c of Object.keys(presDet)) if (linhas[idx][c] != null && linhas[idx][c] !== "") presDet[c]++;
          if (fazAnexos && !DRY_RUN) { const ax = await processarAnexos(token, f, det, p).catch(() => []); if (ax.length) { linhas[idx].anexos = ax; anexosOk += ax.length; } }
        }
      }
    }
    detalhe = { ativo: true, backfill: BACKFILL, atividades: ativ.size, tentados: limitados.length, ok, falhou, preenchidos_detalhe: presDet, anexos: { ativo: fazAnexos, subidos: anexosOk } };
  }

  const campos = ["codigo", "tipo_demanda", "data_gerada", "natureza", "municipio", "endereco", "data_envio", "data_vencimento", "info_complementares"] as const;
  const preenchidos: Record<string, number> = {};
  for (const c of campos) preenchidos[c] = linhas.filter((l: any) => l[c] != null && l[c] !== "").length;

  const resumo: any = { tipo: f.tipo, puxadas: brutas.length, mapeadas: linhas.length, ja_no_banco: existentes.size, novas: novas.length, exemplos_novas: novas.slice(0, 5), preenchidos, detalhe };
  if (DRY_RUN) return resumo;
  const { data, error } = await sb.rpc("nuden_sync", { linhas });
  if (error) throw new Error(`nuden_sync (${f.recurso}): ${error.message}`);
  resumo.nuden_sync = data;
  return resumo;
}

// ─── Handler ───────────────────────────────────────────────────────────
Deno.serve(async (_req) => {
  const t0 = Date.now();
  try {
    const contas = carregarContas();
    if (contas.length === 0) return json(500, { erro: "Nenhuma conta configurada (SISDEN_ACCOUNTS ou SISDEN_CPF_n/SISDEN_SENHA_n)." });
    if (FONTES.length === 0) return json(200, { aviso: "Nenhuma fonte ligada (SISDEN_DENUNCIAS/SISDEN_REQUISICOES)." });

    const token = await loginComFailover(contas);
    const sb = createClient(SUPABASE_URL, SERVICE_KEY);
    const fontes: Record<string, any> = {};
    for (const f of FONTES) fontes[f.recurso] = await processarFonte(sb, token, f);

    const body: any = { dry_run: DRY_RUN, fontes, ms: Date.now() - t0 };
    if (DRY_RUN) body.aviso = "DRY_RUN ativo — nada foi gravado.";
    return json(200, body);
  } catch (e) {
    console.error("[sisden-sync] erro:", e);
    return json(500, { erro: String((e as any)?.message ?? e) });
  }
});

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json" } });
}

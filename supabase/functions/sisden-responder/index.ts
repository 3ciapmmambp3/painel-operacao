// ══════════════════════════════════════════════════════════════════════
//  Edge Function: sisden-responder
//  Envia em LOTE as respostas ao SISDEN (status "Retorno da área Técnica").
//  SEMPRE acionada pelo usuário (abrir a URL) — NUNCA pelo cron.
//
//  Candidatas = demandas que estão PENDENTES no SISDEN AGORA (status
//  "Encaminhada", a mesma lista que o sync puxa) E que têm Nº GAIA (Ato) +
//  Nº REDS preenchidos no banco (baixa feita) E ainda não respondidas
//  (respondida_sisden_em null). Isso EXCLUI o histórico antigo (que não está
//  mais pendente no SISDEN).
//
//  Pra cada: detalhe (encaminhamento) → travar → POST resposta (FormData) →
//  marca respondida_sisden_em.
//  Texto: "<Denúncia|Requisição> atendida conforme ato de fiscalização nº
//  <GAIA> e REDS nº <REDS>".  data_retorno = hoje.
//
//  RESPONDER_DRY_RUN=true (PADRÃO, secret PRÓPRIO — não o DRY_RUN do sync):
//  NÃO envia — só devolve a LISTA do que seria enviado. false = envia.
//
//  API confirmada (denúncia, 2026-11-02):
//    POST .../backOffice/denuncias/{protocolo}/travar {servidor_responsavel_nome, unidades_usuario:[221]}
//    POST .../backOffice/denuncias/encaminhamentos/{encId}/resposta  (FormData)
//  Requisição = mesmo padrão sob /sisreq/api/.../requisicoes/... (a confirmar no 1º envio).
// ══════════════════════════════════════════════════════════════════════

import { createClient } from "jsr:@supabase/supabase-js@2";

const HOST        = Deno.env.get("SISDEN_BASE")      ?? "https://ecosistemas.meioambiente.mg.gov.br";
const ID_SUPRAM   = Deno.env.get("SISDEN_ID_SUPRAM") ?? "221";
const STATUS      = Deno.env.get("SISDEN_STATUS")    ?? "Encaminhada";
const PAGE_SIZE   = Number(Deno.env.get("SISDEN_PAGE_SIZE") ?? "100");
const MAX_PAGES   = Number(Deno.env.get("SISDEN_MAX_PAGES") ?? "200");
const DRY_RUN     = (Deno.env.get("RESPONDER_DRY_RUN") ?? "true").toLowerCase() !== "false";
const MAX         = Number(Deno.env.get("SISDEN_RESPONDER_MAX") ?? "500");
const RESP_DEN    = (Deno.env.get("SISDEN_RESP_DENUNCIAS")   ?? "true").toLowerCase()  !== "false";
const RESP_REQ    = (Deno.env.get("SISDEN_RESP_REQUISICOES") ?? "true").toLowerCase()  !== "false";
const NOME_FIXO   = Deno.env.get("SISDEN_SERVIDOR_NOME") ?? "";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

type Fonte = { tipo: string; base: string; recurso: string; label: string };
const FONTES: Fonte[] = [];
if (RESP_DEN) FONTES.push({ tipo: "DENÚNCIA",   base: "/sisden-api/api", recurso: "denuncias",   label: "Denúncia" });
if (RESP_REQ) FONTES.push({ tipo: "REQUISIÇÃO", base: "/sisreq/api",     recurso: "requisicoes", label: "Requisição" });

// ─── Login (igual sisden-sync) ─────────────────────────────────────────
type Conta = { cpf: string; senha: string };
function carregarContas(): Conta[] {
  const raw = Deno.env.get("SISDEN_ACCOUNTS");
  if (raw) { try { const a = JSON.parse(raw); if (Array.isArray(a)) return a.filter((x) => x?.cpf && x?.senha); } catch {} }
  const c: Conta[] = [];
  for (let i = 1; i <= 5; i++) { const cpf = Deno.env.get(`SISDEN_CPF_${i}`); const senha = Deno.env.get(`SISDEN_SENHA_${i}`); if (cpf && senha) c.push({ cpf, senha }); }
  return c;
}
function extrairToken(j: any): string | null {
  if (!j || typeof j !== "object") return null;
  return j.token ?? j.accessToken ?? j.access_token ?? j.jwt ?? j.data?.token ?? j.data?.accessToken ?? null;
}
async function login(conta: Conta): Promise<{ token: string; cpf: string } | null> {
  const cpfDig = conta.cpf.replace(/\D/g, "");
  const cands = [{ cpf: cpfDig, senha: conta.senha }, { cpf: conta.cpf, senha: conta.senha }, { login: cpfDig, senha: conta.senha }, { usuario: cpfDig, senha: conta.senha }, { cpf: cpfDig, password: conta.senha }, { username: cpfDig, password: conta.senha }];
  for (const body of cands) {
    const r = await fetch(`${HOST}/eco-ui/api/auth/login`, { method: "POST", headers: { "Content-Type": "application/json", "Accept": "application/json" }, body: JSON.stringify(body) }).catch(() => null);
    if (!r || !r.ok) continue;
    const tk = extrairToken(await r.json().catch(() => null));
    if (tk) return { token: tk, cpf: cpfDig };
  }
  return null;
}
async function loginComFailover(contas: Conta[]): Promise<{ token: string; cpf: string }> {
  for (const c of contas) { const r = await login(c).catch(() => null); if (r) return r; }
  throw new Error("Nenhuma conta do SISDEN conseguiu logar (secrets SISDEN_ACCOUNTS).");
}
function pick(o: any, ...ks: string[]) { for (const k of ks) if (o?.[k] != null && o[k] !== "") return o[k]; return null; }

// lista de PENDENTES de 1 fonte → set de protocolos (status Encaminhada)
async function puxarPendentes(token: string, f: Fonte): Promise<Set<string>> {
  const set = new Set<string>();
  for (let page = 1; page <= MAX_PAGES; page++) {
    const url = `${HOST}${f.base}/backOffice/${f.recurso}?page=${page}&pageSize=${PAGE_SIZE}&status=${encodeURIComponent(STATUS)}&idSupram=${ID_SUPRAM}&isTecnico=true`;
    const r = await fetch(url, { headers: { "Authorization": `Bearer ${token}`, "Accept": "application/json" } });
    if (!r.ok) throw new Error(`[${f.recurso}] HTTP ${r.status} pág ${page}`);
    const j = await r.json(); const itens = Array.isArray(j) ? j : (j.content ?? j.data ?? j.items ?? j[f.recurso] ?? []);
    if (!Array.isArray(itens) || itens.length === 0) break;
    for (const it of itens) { const p = it?.protocolo ?? it?.codigo; if (p) set.add(String(p)); }
    if (itens.length < PAGE_SIZE) break;
  }
  return set;
}

async function nomeServidor(token: string, cpf: string): Promise<string> {
  if (NOME_FIXO) return NOME_FIXO;
  try {
    const r = await fetch(`${HOST}/sisden-api/api/getUsuario/${cpf}`, { headers: { "Authorization": `Bearer ${token}`, "Accept": "application/json" } });
    if (r.ok) { const j = await r.json(); const u = j?.data ?? j; const n = pick(u, "nome", "nomeCompleto", "nome_completo", "servidor_responsavel_nome"); if (n) return String(n); }
  } catch {}
  return "";
}
async function buscarDetalhe(token: string, f: Fonte, protocolo: string): Promise<any | null> {
  const r = await fetch(`${HOST}${f.base}/backOffice/${f.recurso}/${encodeURIComponent(protocolo)}`, { headers: { "Authorization": `Bearer ${token}`, "Accept": "application/json" } }).catch(() => null);
  if (!r || !r.ok) return null;
  const j = await r.json().catch(() => null);
  return (j && typeof j === "object" && !Array.isArray(j)) ? (j.data ?? j.denuncia ?? j.requisicao ?? j) : null;
}
function acharEncaminhamento(det: any): any | null {
  let encs = det?.encaminhamentos;
  if (typeof encs === "string") { try { encs = JSON.parse(encs); } catch { encs = null; } }
  if (!Array.isArray(encs) || encs.length === 0) return null;
  return encs.find((e) => e?.retorno == null && String(e?.idEstruturaOrganizacional) === ID_SUPRAM)
      ?? encs.find((e) => e?.retorno == null) ?? encs[encs.length - 1];
}
async function travar(token: string, f: Fonte, protocolo: string, nome: string) {
  await fetch(`${HOST}${f.base}/backOffice/${f.recurso}/${encodeURIComponent(protocolo)}/travar`, {
    method: "POST", headers: { "Authorization": `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ servidor_responsavel_nome: nome, unidades_usuario: [Number(ID_SUPRAM)] }),
  }).catch(() => null);
}
async function enviarResposta(token: string, f: Fonte, encId: number | string, texto: string, hoje: string, nome: string): Promise<{ ok: boolean; status: number; erro?: string }> {
  const fd = new FormData();
  fd.append("data_retorno", hoje);
  fd.append("numeroProcesso", "");
  fd.append("status_do_ato", "undefined");
  fd.append("retorno", `<p>${texto}</p>`);
  fd.append("servidor_responsavel_nome", nome);
  fd.append("status", "Retorno da área Técnica");
  const r = await fetch(`${HOST}${f.base}/backOffice/${f.recurso}/encaminhamentos/${encId}/resposta`, { method: "POST", headers: { "Authorization": `Bearer ${token}` }, body: fd }).catch(() => null);
  if (!r) return { ok: false, status: 0, erro: "sem resposta" };
  if (!r.ok) { const t = await r.text().catch(() => ""); return { ok: false, status: r.status, erro: t.slice(0, 200) }; }
  return { ok: true, status: r.status };
}

// ─── Handler ───────────────────────────────────────────────────────────
Deno.serve(async (_req) => {
  const t0 = Date.now();
  // data_retorno = SEMPRE o dia de HOJE em Brasília (UTC-3), nunca a data do
  // atendimento do Relatório. (Brasil sem horário de verão desde 2019.)
  const hoje = new Date(Date.now() - 3 * 3600 * 1000).toISOString().slice(0, 10);
  try {
    const contas = carregarContas();
    if (contas.length === 0) return json(500, { erro: "Nenhuma conta configurada." });
    const sb = createClient(SUPABASE_URL, SERVICE_KEY);
    const { token, cpf } = await loginComFailover(contas);

    // 1) pendentes AGORA no SISDEN (por fonte)
    const pendPorFonte: { f: Fonte; protos: Set<string> }[] = [];
    for (const f of FONTES) pendPorFonte.push({ f, protos: await puxarPendentes(token, f) });
    const todosPend = pendPorFonte.flatMap((x) => [...x.protos]);

    // 2) no banco, quais desses têm Ato+REDS e ainda não respondidos
    const dados = new Map<string, any>();
    for (let i = 0; i < todosPend.length; i += 300) {
      const lote = todosPend.slice(i, i + 300);
      const { data, error } = await sb.from("nuden_demandas")
        .select("codigo, numero_gaia, numero_reds, municipio, respondida_sisden_em").in("codigo", lote);
      if (error) throw new Error(`select: ${error.message}`);
      for (const row of data ?? []) dados.set(row.codigo, row);
    }

    // 3) candidatas = pendente + tem Ato+REDS + não respondida
    const candidatas: { codigo: string; f: Fonte; municipio: string; gaia: string; reds: string; texto: string }[] = [];
    for (const { f, protos } of pendPorFonte) {
      for (const p of protos) {
        const d = dados.get(p);
        if (!d) continue;
        if (d.respondida_sisden_em) continue;
        const gaia = (d.numero_gaia ?? "").toString().trim();
        const reds = (d.numero_reds ?? "").toString().trim();
        if (!gaia || !reds) continue;
        candidatas.push({ codigo: p, f, municipio: d.municipio, gaia, reds, texto: `${f.label} atendida conforme ato de fiscalização nº ${gaia} e REDS nº ${reds}` });
      }
    }

    const resumoPend = Object.fromEntries(pendPorFonte.map((x) => [x.f.recurso, x.protos.size]));

    if (DRY_RUN) {
      return json(200, {
        dry_run: true,
        pendentes_no_sisden: resumoPend,
        total_candidatas: candidatas.length,
        por_tipo: { denuncias: candidatas.filter((c) => c.f.recurso === "denuncias").length, requisicoes: candidatas.filter((c) => c.f.recurso === "requisicoes").length },
        amostra: candidatas.slice(0, 20).map((c) => ({ codigo: c.codigo, tipo: c.f.label, municipio: c.municipio, texto: c.texto, data_retorno: hoje })),
        aviso: "DRY_RUN ativo — NADA foi enviado. Confira; p/ enviar, RESPONDER_DRY_RUN=false.",
        ms: Date.now() - t0,
      });
    }

    // ENVIO REAL
    const nome = await nomeServidor(token, cpf);
    if (!nome) return json(500, { erro: "Não consegui o nome do servidor (defina SISDEN_SERVIDOR_NOME)." });
    const resultados: any[] = [];
    let enviadas = 0, puladas = 0, falhas = 0;
    for (const c of candidatas.slice(0, MAX)) {
      try {
        const det = await buscarDetalhe(token, c.f, c.codigo);
        if (!det) { falhas++; resultados.push({ codigo: c.codigo, ok: false, erro: "detalhe não encontrado" }); continue; }
        const status = (det.status ?? "").toString();
        if (status && status.toLowerCase() !== STATUS.toLowerCase()) {
          await sb.from("nuden_demandas").update({ respondida_sisden_em: new Date().toISOString() }).eq("codigo", c.codigo);
          puladas++; resultados.push({ codigo: c.codigo, ok: true, pulada: true, motivo: `status ${status}` }); continue;
        }
        const enc = acharEncaminhamento(det);
        if (!enc?.id) { falhas++; resultados.push({ codigo: c.codigo, ok: false, erro: "sem encaminhamento" }); continue; }
        await travar(token, c.f, c.codigo, nome);
        const env = await enviarResposta(token, c.f, enc.id, c.texto, hoje, nome);
        if (env.ok) {
          await sb.from("nuden_demandas").update({ respondida_sisden_em: new Date().toISOString() }).eq("codigo", c.codigo);
          enviadas++; resultados.push({ codigo: c.codigo, ok: true });
        } else { falhas++; resultados.push({ codigo: c.codigo, ok: false, status: env.status, erro: env.erro }); }
      } catch (e) { falhas++; resultados.push({ codigo: c.codigo, ok: false, erro: String((e as any)?.message ?? e) }); }
    }
    return json(200, { dry_run: false, pendentes_no_sisden: resumoPend, total_candidatas: candidatas.length, enviadas, puladas, falhas, resultados: resultados.slice(0, 80), ms: Date.now() - t0 });
  } catch (e) {
    console.error("[sisden-responder] erro:", e);
    return json(500, { erro: String((e as any)?.message ?? e) });
  }
});

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json" } });
}

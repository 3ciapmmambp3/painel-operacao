// ══════════════════════════════════════════════════════════════════════
//  Edge Function: sisden-responder
//  Envia em LOTE as respostas ao SISDEN (status "Retorno da área Técnica").
//  SEMPRE acionada pelo usuário — NUNCA pelo cron.
//
//  DUAS formas de usar:
//   • NAVEGADOR (recomendado): abrir a URL mostra uma PÁGINA com a lista das
//     prontas e um botão "Responder". Você digita um PIN (uma vez — fica
//     salvo no navegador) e clica. Nada de trocar segredo.
//   • API/JSON: chamada programática; nesse modo RESPONDER_DRY_RUN controla
//     (true=só lista, false=envia). O modo página NÃO usa isso (o PIN é a trava).
//
//  Candidatas = PENDENTES no SISDEN agora (status Encaminhada) ∩ banco com
//  Nº GAIA(Ato)+Nº REDS ∩ respondida_sisden_em null. Exclui o histórico.
//  Pra cada: detalhe→encaminhamento→travar→POST resposta(FormData, data=hoje)→
//  marca no banco (data_resposta_externa/FINALIZADA, como o botão do painel).
//
//  SECRETS: SISDEN_* (login), SISDEN_SERVIDOR_NOME, e RESPONDER_PIN (a senha
//  do botão — defina uma vez). SISDEN_RESP_DENUNCIAS/REQUISICOES, RESPONDER_MAX.
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
const PIN         = Deno.env.get("RESPONDER_PIN") ?? "";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

type Fonte = { tipo: string; base: string; recurso: string; label: string };
const FONTES: Fonte[] = [];
if (RESP_DEN) FONTES.push({ tipo: "DENÚNCIA",   base: "/sisden-api/api", recurso: "denuncias",   label: "Denúncia" });
if (RESP_REQ) FONTES.push({ tipo: "REQUISIÇÃO", base: "/sisreq/api",     recurso: "requisicoes", label: "Requisição" });

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
function marcaRespondida(nome: string, hoje: string) {
  return {
    respondida_sisden_em: new Date().toISOString(),
    data_resposta_externa: hoje,
    situacao: "FINALIZADA",
    respondido_externo_por_nome: `${nome} (robô)`,
  };
}

type Cand = { codigo: string; f: Fonte; municipio: string; gaia: string; reds: string; texto: string };

// calcula as candidatas (pendentes no SISDEN ∩ banco com Ato+REDS não respondido)
async function calcular(sb: any, token: string): Promise<{ candidatas: Cand[]; resumoPend: Record<string, number> }> {
  const pend: { f: Fonte; protos: Set<string> }[] = [];
  for (const f of FONTES) pend.push({ f, protos: await puxarPendentes(token, f) });
  const todos = pend.flatMap((x) => [...x.protos]);
  const dados = new Map<string, any>();
  for (let i = 0; i < todos.length; i += 300) {
    const lote = todos.slice(i, i + 300);
    const { data, error } = await sb.from("nuden_demandas").select("codigo, numero_gaia, numero_reds, municipio, respondida_sisden_em").in("codigo", lote);
    if (error) throw new Error(`select: ${error.message}`);
    for (const row of data ?? []) dados.set(row.codigo, row);
  }
  const candidatas: Cand[] = [];
  for (const { f, protos } of pend) {
    for (const p of protos) {
      const d = dados.get(p);
      if (!d || d.respondida_sisden_em) continue;
      const gaia = (d.numero_gaia ?? "").toString().trim();
      const reds = (d.numero_reds ?? "").toString().trim();
      if (!gaia || !reds) continue;
      candidatas.push({ codigo: p, f, municipio: d.municipio, gaia, reds, texto: `${f.label} atendida conforme ato de fiscalização nº ${gaia} e REDS nº ${reds}` });
    }
  }
  return { candidatas, resumoPend: Object.fromEntries(pend.map((x) => [x.f.recurso, x.protos.size])) };
}

// envia o lote; devolve o relatório
async function enviarLote(sb: any, token: string, nome: string, hoje: string, candidatas: Cand[]) {
  const resultados: any[] = [];
  let enviadas = 0, puladas = 0, falhas = 0;
  for (const c of candidatas.slice(0, MAX)) {
    try {
      const det = await buscarDetalhe(token, c.f, c.codigo);
      if (!det) { falhas++; resultados.push({ codigo: c.codigo, ok: false, erro: "detalhe não encontrado" }); continue; }
      const status = (det.status ?? "").toString();
      if (status && status.toLowerCase() !== STATUS.toLowerCase()) {
        await sb.from("nuden_demandas").update(marcaRespondida(nome, hoje)).eq("codigo", c.codigo);
        puladas++; resultados.push({ codigo: c.codigo, ok: true, pulada: true }); continue;
      }
      const enc = acharEncaminhamento(det);
      if (!enc?.id) { falhas++; resultados.push({ codigo: c.codigo, ok: false, erro: "sem encaminhamento" }); continue; }
      await travar(token, c.f, c.codigo, nome);
      const env = await enviarResposta(token, c.f, enc.id, c.texto, hoje, nome);
      if (env.ok) { await sb.from("nuden_demandas").update(marcaRespondida(nome, hoje)).eq("codigo", c.codigo); enviadas++; resultados.push({ codigo: c.codigo, ok: true }); }
      else { falhas++; resultados.push({ codigo: c.codigo, ok: false, status: env.status, erro: env.erro }); }
    } catch (e) { falhas++; resultados.push({ codigo: c.codigo, ok: false, erro: String((e as any)?.message ?? e) }); }
  }
  return { enviadas, puladas, falhas, resultados };
}

// ─── Páginas HTML (modo navegador) ─────────────────────────────────────
function esc(s: any): string { return String(s ?? "").replace(/[&<>"]/g, (m) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" } as any)[m]); }
const CSS = `body{font-family:system-ui,Segoe UI,Arial,sans-serif;max-width:900px;margin:0 auto;padding:16px;color:#222;background:#f7f7f8}
h1{font-size:20px;color:#8a1b1b} .box{background:#fff;border:1px solid #e3e3e6;border-radius:10px;padding:16px;margin:12px 0}
.big{font-size:34px;font-weight:700} .muted{color:#777;font-size:13px}
table{width:100%;border-collapse:collapse;font-size:13px} th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eee}
th{color:#666;font-weight:600} .btn{background:#8a1b1b;color:#fff;border:0;border-radius:8px;padding:12px 20px;font-size:16px;font-weight:700;cursor:pointer}
.btn:disabled{background:#bbb;cursor:default} input{padding:10px;border:1px solid #ccc;border-radius:8px;font-size:15px}
.ok{color:#1b7a2f} .err{color:#b00}`;
function pagina(titulo: string, corpo: string): Response {
  return new Response(`<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(titulo)}</title><style>${CSS}</style></head><body>${corpo}</body></html>`, { headers: { "Content-Type": "text/html; charset=utf-8" } });
}
function paginaPrevia(candidatas: Cand[], resumoPend: Record<string, number>): Response {
  const nDen = candidatas.filter((c) => c.f.recurso === "denuncias").length;
  const nReq = candidatas.filter((c) => c.f.recurso === "requisicoes").length;
  const pend = Object.entries(resumoPend).map(([k, v]) => `${v} ${k}`).join(" · ");
  const linhas = candidatas.slice(0, 500).map((c) => `<tr><td>${esc(c.codigo)}</td><td>${esc(c.f.label)}</td><td>${esc(c.municipio)}</td><td>${esc(c.texto)}</td></tr>`).join("");
  const temPin = PIN ? "" : `<div class="box err">⚠️ Defina o segredo <b>RESPONDER_PIN</b> no Supabase (uma senha sua) p/ liberar o botão.</div>`;
  const vazio = candidatas.length === 0;
  const form = vazio ? `<div class="box"><div class="big ok">Nenhuma resposta pendente 🎉</div><div class="muted">Pendentes no SISDEN: ${esc(pend)}.</div></div>`
    : `<div class="box">
        <div class="big">${candidatas.length} respostas prontas</div>
        <div class="muted">${nDen} denúncias · ${nReq} requisições · pendentes no SISDEN: ${esc(pend)}</div>
        <form method="POST" id="frm" style="margin-top:14px;display:flex;gap:10px;align-items:center;flex-wrap:wrap">
          <input type="password" id="pin" name="pin" placeholder="PIN" autocomplete="off" style="width:140px">
          <button class="btn" type="submit"${PIN ? "" : " disabled"}>Responder ${candidatas.length} ao SISDEN</button>
          <span class="muted">A data será a de hoje.</span>
        </form>
        ${temPin}
       </div>
       <div class="box"><table><thead><tr><th>Protocolo</th><th>Tipo</th><th>Município</th><th>Resposta</th></tr></thead><tbody>${linhas}</tbody></table></div>`;
  const js = `<script>
    var pf=document.getElementById('pin'); if(pf){ pf.value=localStorage.getItem('resp_pin')||''; }
    var frm=document.getElementById('frm'); if(frm){ frm.addEventListener('submit',function(e){
      if(!pf.value){ alert('Digite o PIN.'); e.preventDefault(); return; }
      if(!confirm('Enviar ${candidatas.length} respostas ao SISDEN? É uma ação oficial, no seu nome.')){ e.preventDefault(); return; }
      localStorage.setItem('resp_pin', pf.value);
      var b=frm.querySelector('button'); b.disabled=true; b.textContent='Enviando… aguarde';
    }); }
  </script>`;
  return pagina("Responder NUDEN/SISDEN", `<h1>Responder NUDEN/SISDEN</h1>${form}${vazio ? "" : js}`);
}
function paginaResultado(res: { enviadas: number; puladas: number; falhas: number; resultados: any[] }): Response {
  const falhasLista = res.resultados.filter((r) => !r.ok).slice(0, 50).map((r) => `<tr><td>${esc(r.codigo)}</td><td class="err">${esc(r.erro || r.status)}</td></tr>`).join("");
  return pagina("Respostas enviadas", `<h1>Respostas enviadas</h1>
    <div class="box"><div class="big ok">${res.enviadas} enviadas</div>
    <div class="muted">${res.puladas} já respondidas (puladas) · ${res.falhas} falhas</div></div>
    ${res.falhas ? `<div class="box"><b>Falhas:</b><table>${falhasLista}</table></div>` : ""}
    <div class="box"><a href="?ui=1">← Voltar / atualizar a lista</a></div>`);
}

// ─── Handler ───────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  const t0 = Date.now();
  const hoje = new Date(Date.now() - 3 * 3600 * 1000).toISOString().slice(0, 10); // hoje em Brasília
  const url = new URL(req.url);
  const aceitaHtml = (req.headers.get("accept") || "").includes("text/html");
  const modoUI = url.searchParams.get("ui") === "1" || aceitaHtml || req.method === "POST";
  try {
    const contas = carregarContas();
    if (contas.length === 0) return modoUI ? pagina("Erro", `<div class="box err">Nenhuma conta configurada.</div>`) : json(500, { erro: "Nenhuma conta configurada." });
    const sb = createClient(SUPABASE_URL, SERVICE_KEY);
    const { token, cpf } = await loginComFailover(contas);
    const { candidatas, resumoPend } = await calcular(sb, token);

    // ── ENVIO pela PÁGINA (POST com PIN) ──
    if (req.method === "POST") {
      const form = await req.formData().catch(() => null);
      const pinEnviado = form ? String(form.get("pin") ?? "") : "";
      if (!PIN || pinEnviado !== PIN) return pagina("PIN inválido", `<h1>PIN inválido</h1><div class="box err">PIN incorreto ou RESPONDER_PIN não definido.</div><div class="box"><a href="?ui=1">← Voltar</a></div>`);
      const nome = await nomeServidor(token, cpf);
      if (!nome) return pagina("Erro", `<div class="box err">Sem nome do servidor (defina SISDEN_SERVIDOR_NOME).</div>`);
      const res = await enviarLote(sb, token, nome, hoje, candidatas);
      return paginaResultado(res);
    }

    // ── PÁGINA de prévia (navegador) ──
    if (modoUI) return paginaPrevia(candidatas, resumoPend);

    // ── API/JSON (programático) ──
    const resumoJson = { pendentes_no_sisden: resumoPend, total_candidatas: candidatas.length, por_tipo: { denuncias: candidatas.filter((c) => c.f.recurso === "denuncias").length, requisicoes: candidatas.filter((c) => c.f.recurso === "requisicoes").length } };
    if (DRY_RUN) return json(200, { dry_run: true, ...resumoJson, amostra: candidatas.slice(0, 20).map((c) => ({ codigo: c.codigo, tipo: c.f.label, municipio: c.municipio, texto: c.texto, data_retorno: hoje })), aviso: "DRY_RUN — nada enviado.", ms: Date.now() - t0 });
    const nome = await nomeServidor(token, cpf);
    if (!nome) return json(500, { erro: "Sem nome do servidor (SISDEN_SERVIDOR_NOME)." });
    const res = await enviarLote(sb, token, nome, hoje, candidatas);
    return json(200, { dry_run: false, ...resumoJson, ...res, resultados: res.resultados.slice(0, 80), ms: Date.now() - t0 });
  } catch (e) {
    const msg = String((e as any)?.message ?? e);
    console.error("[sisden-responder] erro:", msg);
    return modoUI ? pagina("Erro", `<h1>Erro</h1><div class="box err">${esc(msg)}</div>`) : json(500, { erro: msg });
  }
});

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json" } });
}

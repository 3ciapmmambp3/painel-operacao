// ══════════════════════════════════════════════════════════════════════
//  Edge Function: sisden-sync
//  Sincroniza as denúncias do SISDEN (SEMAD / GAIA) direto da API oficial
//  para a tabela public.nuden_demandas — SEM depender do robô do Sgt Anderson.
//
//  Fluxo:
//    1) login no SISDEN  → POST /eco-ui/api/auth/login  (CPF + senha)  → token
//       (failover: tenta a 1ª conta; se falhar, a 2ª, a 3ª… — ver SISDEN_ACCOUNTS)
//    2) puxa as denúncias → GET /sisden-api/api/backOffice/denuncias (Bearer token)
//    3) mapeia p/ o formato do nuden_sync e chama a RPC public.nuden_sync(jsonb)
//       (upsert por CÓDIGO = Protocolo → só NOVAS inserem; as existentes são
//        atualizadas sem apagar a baixa feita no painel.)
//
//  SEGURANÇA / credenciais: nada fica no código. Tudo vem de "secrets":
//    supabase secrets set SISDEN_ACCOUNTS='[{"cpf":"...","senha":"..."},{"cpf":"...","senha":"..."}]'
//  (ou pares SISDEN_CPF_1/SISDEN_SENHA_1, SISDEN_CPF_2/SISDEN_SENHA_2).
//  Trocar uma conta = só editar o secret; usar duas = failover automático.
//
//  DRY_RUN=true (PADRÃO SEGURO): NÃO escreve nada — só compara os protocolos
//  da API com os códigos já no banco e devolve um resumo (novas × já existentes).
//  Vire DRY_RUN=false só quando o resumo estiver validado.
//
//  ✅ MAPEAMENTO CONFIRMADO (dry-run 2026-10-31): a API devolve os campos
//  protocolo, tipo_registro, municipio, logradouro/numero/bairro/cep/
//  ponto_referencia e data_encaminhamento — todos mapeados e preenchidos
//  (366/366, endereço 290/366). Dedup confirmada (365 no banco / 1 nova).
//  OBS: natureza, cadastrado_dtad/created_at (data_gerada) e
//  informacao_complementar NÃO vêm na LISTA — só no DETALHE da denúncia;
//  ficam null p/ as novas e serão preenchidos na Fase 1b (fetch do detalhe).
// ══════════════════════════════════════════════════════════════════════

import { createClient } from "jsr:@supabase/supabase-js@2";

// ─── Config (tudo por env/secret; defaults seguros) ────────────────────
const SISDEN_BASE   = Deno.env.get("SISDEN_BASE")      ?? "https://ecosistemas.meioambiente.mg.gov.br";
const ID_SUPRAM     = Deno.env.get("SISDEN_ID_SUPRAM") ?? "221";          // SUPRAM da 3ª Cia (visto na API)
const STATUS        = Deno.env.get("SISDEN_STATUS")    ?? "Encaminhada";  // pendentes
const PAGE_SIZE     = Number(Deno.env.get("SISDEN_PAGE_SIZE") ?? "100");
const MAX_PAGES     = Number(Deno.env.get("SISDEN_MAX_PAGES") ?? "200");  // trava de segurança
const PRAZO_DIAS    = Number(Deno.env.get("SISDEN_PRAZO_DIAS") ?? "90");  // fallback p/ vencimento
// Fase 1b: buscar o DETALHE das denúncias (natureza/data_gerada/info_complementar
// não vêm na lista). Ligado por padrão; cap de segurança no nº de detalhes por run.
const DETALHE_ON    = (Deno.env.get("SISDEN_DETALHE") ?? "true").toLowerCase() !== "false";
const DETALHE_MAX   = Number(Deno.env.get("SISDEN_DETALHE_MAX") ?? "50");
// PADRÃO = dry-run. Só escreve quando explicitamente DRY_RUN=false.
const DRY_RUN       = (Deno.env.get("DRY_RUN") ?? "true").toLowerCase() !== "false";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ─── Contas do robô (failover) ─────────────────────────────────────────
type Conta = { cpf: string; senha: string };
function carregarContas(): Conta[] {
  const raw = Deno.env.get("SISDEN_ACCOUNTS");
  if (raw) {
    try {
      const arr = JSON.parse(raw);
      if (Array.isArray(arr)) return arr.filter((a) => a?.cpf && a?.senha);
    } catch { /* cai no formato de pares abaixo */ }
  }
  // formato alternativo: SISDEN_CPF_1/SISDEN_SENHA_1, _2, _3...
  const contas: Conta[] = [];
  for (let i = 1; i <= 5; i++) {
    const cpf = Deno.env.get(`SISDEN_CPF_${i}`);
    const senha = Deno.env.get(`SISDEN_SENHA_${i}`);
    if (cpf && senha) contas.push({ cpf, senha });
  }
  return contas;
}

// extrai o token de vários formatos possíveis de resposta do login
function extrairToken(j: unknown): string | null {
  if (!j || typeof j !== "object") return null;
  const o = j as Record<string, any>;
  return (
    o.token ?? o.accessToken ?? o.access_token ?? o.jwt ??
    o.data?.token ?? o.data?.accessToken ?? o.data?.access_token ??
    null
  );
}

// extrai o array de denúncias e o total de vários formatos de envelope
function extrairLista(j: unknown): { itens: any[]; total: number | null } {
  if (Array.isArray(j)) return { itens: j, total: j.length };
  const o = (j ?? {}) as Record<string, any>;
  const itens = o.content ?? o.data ?? o.items ?? o.rows ?? o.denuncias ?? [];
  const total = o.totalElements ?? o.total ?? o.totalCount ?? o.count ?? null;
  return { itens: Array.isArray(itens) ? itens : [], total };
}

// ─── Login com failover ────────────────────────────────────────────────
async function login(conta: Conta): Promise<string | null> {
  const url = `${SISDEN_BASE}/eco-ui/api/auth/login`;
  const cpfDig = conta.cpf.replace(/\D/g, "");          // só dígitos
  const cpfMask = conta.cpf;                             // como veio (pode ter máscara)
  const tag = `...${cpfDig.slice(-3)}`;
  // TODO(confirmar): corpo do login. Tentamos os formatos mais prováveis até um dar certo;
  // o log abaixo mostra qual funcionou (aí travamos só esse no código).
  const candidatos: Record<string, string>[] = [
    { cpf: cpfDig,  senha: conta.senha },
    { cpf: cpfMask, senha: conta.senha },
    { login: cpfDig, senha: conta.senha },
    { usuario: cpfDig, senha: conta.senha },
    { cpf: cpfDig,  password: conta.senha },
    { username: cpfDig, password: conta.senha },
  ];
  for (let i = 0; i < candidatos.length; i++) {
    const r = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify(candidatos[i]),
    }).catch(() => null);
    if (!r) continue;
    if (!r.ok) { console.warn(`[login] ${tag} formato#${i} → HTTP ${r.status}`); continue; }
    const j = await r.json().catch(() => null);
    const tk = extrairToken(j);
    if (tk) { console.log(`[login] ok ${tag} com formato#${i} (${Object.keys(candidatos[i]).join("+")})`); return tk; }
    console.warn(`[login] ${tag} formato#${i}: 200 mas sem token; chaves:`, Object.keys(j ?? {}));
  }
  return null;
}

async function loginComFailover(contas: Conta[]): Promise<string> {
  for (const c of contas) {
    const tk = await login(c).catch(() => null);
    if (tk) return tk;
  }
  throw new Error("Nenhuma conta do SISDEN conseguiu logar (verifique os secrets SISDEN_ACCOUNTS).");
}

// ─── Puxa todas as denúncias (paginado) ────────────────────────────────
async function puxarDenuncias(token: string): Promise<any[]> {
  const todas: any[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const url = `${SISDEN_BASE}/sisden-api/api/backOffice/denuncias`
      + `?page=${page}&pageSize=${PAGE_SIZE}`
      + `&status=${encodeURIComponent(STATUS)}&idSupram=${ID_SUPRAM}&isTecnico=true`;
    const r = await fetch(url, {
      headers: { "Authorization": `Bearer ${token}`, "Accept": "application/json" },
    });
    if (!r.ok) throw new Error(`[denuncias] HTTP ${r.status} na página ${page}`);
    const { itens } = extrairLista(await r.json());
    if (page === 1 && itens[0]) console.log("[denuncias] campos do item:", Object.keys(itens[0]));
    if (itens.length === 0) break;
    todas.push(...itens);
    if (itens.length < PAGE_SIZE) break; // última página
  }
  console.log(`[denuncias] total puxado: ${todas.length}`);
  return todas;
}

// ─── Fase 1b: DETALHE de 1 denúncia ────────────────────────────────────
// Confirmado ao vivo (2026-10-31) abrindo a denúncia no SISDEN:
//   endpoint  = GET /sisden-api/api/backOffice/denuncias/{PROTOCOLO}  (protocolo
//               com pontos, NÃO o id interno nem base64)
//   data_gerada         = det.created_at  (cadastrado_dtad é flag "F", não data!)
//   info_complementar   = det.informacao_complementar | descricao_complementar
//   natureza            = det.atividades_denuncias[].atividade_id → cruza com a
//                         tabela /api/atividades (id → {tematica, descricao}).
let _detLogou = false;
async function buscarDetalhe(token: string, item: any): Promise<any | null> {
  const proto = item?.protocolo ?? item?.codigo;
  if (!proto) return null;
  const url = `${SISDEN_BASE}/sisden-api/api/backOffice/denuncias/${encodeURIComponent(String(proto))}`;
  const r = await fetch(url, {
    headers: { "Authorization": `Bearer ${token}`, "Accept": "application/json" },
  }).catch(() => null);
  if (!r || !r.ok) { console.warn(`[detalhe] HTTP ${r?.status ?? "ERR"} p/ protocolo ${proto}`); return null; }
  const j = await r.json().catch(() => null);
  const det = (j && typeof j === "object" && !Array.isArray(j)) ? (j.data ?? j.denuncia ?? j) : null;
  if (det && !_detLogou) { console.log("[detalhe] campos do item:", Object.keys(det)); _detLogou = true; }
  return det;
}

// tabela de atividades (id → nome legível) — p/ traduzir a natureza. Puxa 1x por run.
async function carregarAtividades(token: string): Promise<Map<number, string>> {
  const m = new Map<number, string>();
  try {
    const r = await fetch(`${SISDEN_BASE}/sisden-api/api/atividades`, {
      headers: { "Authorization": `Bearer ${token}`, "Accept": "application/json" },
    });
    if (!r.ok) { console.warn(`[atividades] HTTP ${r.status}`); return m; }
    const j = await r.json();
    const arr = Array.isArray(j) ? j : (j.data ?? j.content ?? []);
    for (const a of arr) {
      if (a?.id == null) continue;
      const nome = a.descricao ? (a.tematica ? `${a.tematica} - ${a.descricao}` : String(a.descricao)) : (a.codigo ?? null);
      if (nome) m.set(Number(a.id), nome);
    }
    console.log(`[atividades] carregadas: ${m.size}`);
  } catch (e) { console.warn("[atividades] erro:", e); }
  return m;
}

// monta a natureza a partir das atividades da denúncia (ids → nomes, dedup, join)
function naturezaDeDetalhe(det: any, ativ: Map<number, string>): string | null {
  let ad = det?.atividades_denuncias;
  if (typeof ad === "string") { try { ad = JSON.parse(ad); } catch { ad = null; } }
  if (!Array.isArray(ad) || ad.length === 0) return null;
  const nomes: string[] = [];
  for (const a of ad) {
    const id = Number(a?.atividade_id ?? a?.id);
    if (!id) continue;
    nomes.push(ativ.get(id) ?? `#${id}`);
  }
  return nomes.length ? [...new Set(nomes)].join("; ") : null;
}

// funde os 3 campos de detalhe na linha, sem sobrescrever o que a lista já trouxe
function enriquecerComDetalhe(linha: any, det: any, ativ: Map<number, string>) {
  if (!det) return linha;
  return {
    ...linha,
    natureza: linha.natureza ?? naturezaDeDetalhe(det, ativ),
    data_gerada: linha.data_gerada ?? soData(pick(det, "created_at")),
    info_complementares: linha.info_complementares ?? pick(det, "informacao_complementar", "informacoes_complementares", "descricao_complementar"),
  };
}

// ─── Mapeia 1 denúncia do SISDEN → linha do nuden_sync ─────────────────
// Campos confirmados na lista (dry-run 2026-10-31). natureza / data_gerada
// (cadastrado_dtad|created_at) / informacao_complementar vêm só no DETALHE
// da denúncia → null aqui, preenchidos na Fase 1b. O pick() abaixo já aponta
// pro nome real de cada campo, então quando o detalhe for anexado eles entram.
function pick(o: any, ...keys: string[]) {
  for (const k of keys) if (o?.[k] != null && o[k] !== "") return o[k];
  return null;
}
// município pode vir como string OU objeto {nome/...}
function nomeMunicipio(d: any): string | null {
  const m = d?.municipio;
  if (!m) return null;
  if (typeof m === "string") return m;
  if (typeof m === "object") return m.nome ?? m.nomeMunicipio ?? m.descricao ?? m.municipio ?? null;
  return null;
}
// compõe o endereço a partir das partes da API
function montarEndereco(d: any): string | null {
  const partes = [d?.logradouro, d?.numero, d?.bairro]
    .map((x) => (x == null ? "" : String(x).trim())).filter(Boolean);
  let end = partes.join(", ");
  if (d?.cep) end += (end ? " - CEP " : "CEP ") + d.cep;
  if (d?.ponto_referencia) end += (end ? " (ref.: " : "(ref.: ") + String(d.ponto_referencia).trim() + ")";
  return end || null;
}
function soData(v: any): string | null {
  if (!v) return null;
  const s = String(v);
  const m = s.match(/(\d{4})-(\d{2})-(\d{2})/) || s.match(/(\d{2})\/(\d{2})\/(\d{4})/);
  if (!m) return null;
  return m[0].includes("/") ? `${m[3]}-${m[2]}-${m[1]}` : `${m[1]}-${m[2]}-${m[3]}`;
}
function addDias(iso: string | null, dias: number): string | null {
  if (!iso) return null;
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + dias);
  return d.toISOString().slice(0, 10);
}
function mapear(d: any) {
  // campos reais da API /backOffice/denuncias (confirmados 2026-10-30/31)
  // data_gerada = created_at; na LISTA vem null (só no detalhe) → Fase 1b preenche.
  const data_gerada = soData(pick(d, "created_at"));
  const data_envio  = soData(pick(d, "data_encaminhamento"));
  // a lista não traz vencimento → calcula (envio||gerada + PRAZO_DIAS); igual ao countdown da tela
  const data_vencimento = addDias(data_envio ?? data_gerada, PRAZO_DIAS);
  return {
    codigo: pick(d, "protocolo", "codigo"),
    tipo_demanda: pick(d, "tipo_registro") ?? "DENÚNCIA",
    data_gerada,
    // ⚠️ natureza NÃO vem na lista (só no detalhe). Fica null aqui; a Fase 1b
    // (buscarDetalhe + enriquecerComDetalhe, no handler) preenche as NOVAS.
    natureza: pick(d, "natureza", "tematica", "naturezaInfracao"),
    municipio: nomeMunicipio(d),
    endereco: montarEndereco(d),
    fracao_responsavel: null,           // nuden_sync resolve o grupamento pelo município
    data_envio,
    data_vencimento,
    status_prazo: null,                 // o painel calcula o rótulo de prazo pelo vencimento
    info_complementares: pick(d, "informacao_complementar", "informacoes_complementares"),
    fonte_aba: "sisden",                // proveniência: API oficial (não a planilha)
    raw: d,                             // item original (auditoria / ajuste de mapeamento)
  };
}

// ─── Handler ───────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  const t0 = Date.now();
  try {
    const contas = carregarContas();
    if (contas.length === 0) {
      return json(500, { erro: "Nenhuma conta configurada (SISDEN_ACCOUNTS ou SISDEN_CPF_n/SISDEN_SENHA_n)." });
    }

    const token = await loginComFailover(contas);
    const brutas = await puxarDenuncias(token);
    const linhas = brutas.map(mapear).filter((l) => l.codigo); // ignora sem protocolo
    const protocolos = linhas.map((l) => String(l.codigo));

    const sb = createClient(SUPABASE_URL, SERVICE_KEY);

    // compara com o que já existe (sempre — é o "gate" de dedup)
    const existentes = new Set<string>();
    for (let i = 0; i < protocolos.length; i += 500) {
      const lote = protocolos.slice(i, i + 500);
      const { data, error } = await sb
        .from("nuden_demandas").select("codigo").in("codigo", lote);
      if (error) throw new Error(`select nuden_demandas: ${error.message}`);
      for (const row of data ?? []) existentes.add(row.codigo);
    }
    const novas = protocolos.filter((p) => !existentes.has(p));

    // ── Fase 1b: completa natureza/data_gerada/info_complementar via DETALHE ──
    // índice protocolo -> item cru (o detalhe é buscado pelo próprio protocolo)
    const porProtocolo = new Map<string, any>();
    for (const d of brutas) { const p = pick(d, "protocolo", "codigo"); if (p) porProtocolo.set(String(p), d); }
    let detalhe: any = { ativo: DETALHE_ON };
    if (DETALHE_ON) {
      // prod: todas as NOVAS (até o cap). dry-run sem novas: 1 amostra, só p/ validar o endpoint.
      const alvos = novas.length ? novas
                  : (DRY_RUN && brutas.length ? [String(pick(brutas[0], "protocolo", "codigo"))] : []);
      const limitados = alvos.slice(0, DETALHE_MAX);
      const ativ = limitados.length ? await carregarAtividades(token) : new Map<number, string>();
      const presDet = { natureza: 0, data_gerada: 0, info_complementares: 0 } as Record<string, number>;
      let ok = 0, falhou = 0;
      for (const p of limitados) {
        const item = porProtocolo.get(p);
        if (!item) continue;
        const det = await buscarDetalhe(token, item).catch(() => null);
        if (!det) { falhou++; continue; }
        ok++;
        const idx = linhas.findIndex((l: any) => String(l.codigo) === p);
        if (idx >= 0) {
          linhas[idx] = enriquecerComDetalhe(linhas[idx], det, ativ);  // funde p/ a escrita real
          for (const c of Object.keys(presDet)) if (linhas[idx][c] != null && linhas[idx][c] !== "") presDet[c]++;
        }
      }
      detalhe = { ativo: true, atividades: ativ.size, tentados: limitados.length, ok, falhou, preenchidos_detalhe: presDet };
    }

    // conferência de preenchimento (presença dos campos, SEM expor valores/PII)
    const campos = ["codigo","tipo_demanda","data_gerada","natureza","municipio",
                    "endereco","data_envio","data_vencimento","info_complementares"] as const;
    const presenca: Record<string, number> = {};
    for (const c of campos) presenca[c] = linhas.filter((l: any) => l[c] != null && l[c] !== "").length;

    const resumo = {
      dry_run: DRY_RUN,
      puxadas: brutas.length,
      mapeadas: linhas.length,
      ja_no_banco: existentes.size,
      novas: novas.length,
      exemplos_novas: novas.slice(0, 5),
      preenchidos: presenca,        // quantas das 'mapeadas' têm cada campo (confere o mapeamento)
      detalhe,                      // Fase 1b: endpoint do detalhe + quantos campos preencheu
      ms: Date.now() - t0,
    };

    if (DRY_RUN) {
      // NÃO escreve nada — só o diagnóstico
      console.log("[DRY-RUN]", resumo);
      return json(200, { ...resumo, aviso: "DRY_RUN ativo — nada foi gravado." });
    }

    // escrita real: delega ao nuden_sync (upsert por código, preserva baixa)
    const { data, error } = await sb.rpc("nuden_sync", { linhas });
    if (error) throw new Error(`nuden_sync: ${error.message}`);
    console.log("[SYNC] resultado nuden_sync:", data);
    return json(200, { ...resumo, nuden_sync: data });
  } catch (e) {
    console.error("[sisden-sync] erro:", e);
    return json(500, { erro: String(e?.message ?? e) });
  }
});

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body, null, 2), {
    status, headers: { "Content-Type": "application/json" },
  });
}

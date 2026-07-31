# Edge Functions de anexos — `upload-anexo` e `get-anexo`

Os arquivos ficam **privados** no Drive (conta de serviço). Ninguém abre o Drive
diretamente:

- **`upload-anexo`** envia o arquivo, e agora **assina um link durável** (`link`)
  que aponta para a `get-anexo`. Devolve `{ file_id, web_view_link, link }`; o
  painel guarda o `link` no registro (`denuncias.anexos[].link`).
- **`get-anexo`** é a **porteira**: recebe `?t=<token assinado>`, valida o HMAC e a
  expiração, e faz **proxy dos bytes** do Drive usando a conta de serviço. O
  arquivo nunca é tornado público; o link funciona no painel e dentro do PDF
  encaminhado (por isso o token tem validade longa — ~1 ano por padrão).

O segredo de assinatura (`ANEXO_SIGN_SECRET`) só existe no servidor — o frontend
nunca assina nada, apenas usa o `link` já pronto que veio do upload.

## 1) Criar a conta de serviço (uma vez)
1. Google Cloud Console → **APIs & Services → Enable APIs** → habilite **Google Drive API**.
2. **IAM & Admin → Service Accounts → Create** → crie uma conta (ex.: `anexos-painel`).
3. Na conta criada → **Keys → Add key → JSON** → baixe o arquivo JSON.
4. No **Google Drive** da conta `3ciapmmamb.p3`: crie a pasta (ex.: `Anexos Painel`),
   clique em **Compartilhar** e adicione o `client_email` da conta de serviço como **Editor**.
   Copie o **ID da pasta** (o trecho da URL depois de `/folders/`).

## 2) Configurar os segredos no Supabase
No projeto Supabase → **Edge Functions → Secrets** (ou via CLI):
```bash
supabase secrets set GOOGLE_SA_JSON='<conteúdo inteiro do JSON da conta de serviço>'
supabase secrets set DRIVE_FOLDER_ID='<id da pasta do Drive>'
# Segredo p/ assinar os links de acesso (qualquer string longa e aleatória):
supabase secrets set ANEXO_SIGN_SECRET='<ex.: saída de `openssl rand -hex 32`>'
# Opcional: validade do link em dias (padrão 400 ≈ 13 meses):
supabase secrets set ANEXO_LINK_DIAS='400'
```
`SUPABASE_URL` já é injetado automaticamente nas Edge Functions — a `upload-anexo`
usa isso para montar a URL da `get-anexo`.

## ⚠️ Desligar "Verify JWT" nas DUAS funções (obrigatório para o navegador)
Por padrão o Supabase exige JWT em toda chamada, e o preflight CORS (OPTIONS) do
navegador não envia token → dá erro de CORS ("preflight ... does not have HTTP ok
status"). Além disso a `get-anexo` é aberta como link direto (do PDF), sem token
de sessão. Solução: **Edge Functions → (upload-anexo e get-anexo) → Settings →
desligar "Verify JWT"** em CADA uma.

As funções ficam públicas, mas a `get-anexo` só serve arquivos com **token HMAC
válido** (não dá pra adivinhar/forjar acesso a outro `file_id`), e a `upload-anexo`
pode ser protegida depois com um header `x-app-key` próprio.

## 3) Publicar as funções
```bash
supabase functions new upload-anexo      # cria a pasta
# cole o código da seção 4 em supabase/functions/upload-anexo/index.ts
supabase functions deploy upload-anexo

supabase functions new get-anexo
# cole o código da seção 5 em supabase/functions/get-anexo/index.ts
supabase functions deploy get-anexo
```

## 4) Código — `supabase/functions/upload-anexo/index.ts`
```ts
// Deno / Supabase Edge Function
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function b64urlFromBytes(bytes: Uint8Array): string {
  let s = ""; for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64url(str: string): string { return b64urlFromBytes(new TextEncoder().encode(str)); }
function pemToBuf(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64); const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}
async function getAccessToken(sa: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/drive",
    aud: "https://oauth2.googleapis.com/token",
    iat: now, exp: now + 3600,
  };
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claim))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8", pemToBuf(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${b64urlFromBytes(new Uint8Array(sig))}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const j = await res.json();
  if (!j.access_token) throw new Error("token: " + JSON.stringify(j));
  return j.access_token;
}

// Assina { id, exp } com HMAC-SHA256 e devolve o token "<payload>.<assinatura>".
async function hmacSign(msg: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return b64urlFromBytes(new Uint8Array(sig));
}
async function montarLinkDuravel(fileId: string): Promise<string | null> {
  const secret = Deno.env.get("ANEXO_SIGN_SECRET");
  const base = Deno.env.get("SUPABASE_URL");
  if (!secret || !base) return null; // sem segredo/URL → cai no web_view_link no front
  const dias = parseInt(Deno.env.get("ANEXO_LINK_DIAS") || "400", 10);
  const exp = Math.floor(Date.now() / 1000) + dias * 86400;
  const payload = b64url(JSON.stringify({ id: fileId, exp }));
  const token = `${payload}.${await hmacSign(payload, secret)}`;
  return `${base}/functions/v1/get-anexo?t=${token}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { nome, mime, conteudo_base64 } = await req.json();
    if (!nome || !conteudo_base64) throw new Error("nome e conteudo_base64 são obrigatórios");

    const sa = JSON.parse(Deno.env.get("GOOGLE_SA_JSON")!);
    const folder = Deno.env.get("DRIVE_FOLDER_ID")!;
    const token = await getAccessToken(sa);

    const boundary = "b" + crypto.randomUUID().replace(/-/g, "");
    const metadata = { name: nome, parents: [folder] };
    const body =
      `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n` +
      JSON.stringify(metadata) +
      `\r\n--${boundary}\r\nContent-Type: ${mime || "application/octet-stream"}\r\n` +
      `Content-Transfer-Encoding: base64\r\n\r\n` +
      conteudo_base64 +
      `\r\n--${boundary}--`;

    const up = await fetch(
      "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink&supportsAllDrives=true",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": `multipart/related; boundary=${boundary}`,
        },
        body,
      },
    );
    const file = await up.json();
    if (!up.ok) throw new Error("drive: " + JSON.stringify(file));

    const link = await montarLinkDuravel(file.id);
    return new Response(
      JSON.stringify({ file_id: file.id, web_view_link: file.webViewLink, link }),
      { headers: { ...CORS, "Content-Type": "application/json" } },
    );
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e.message || e) }), {
      status: 400, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
```

## 5) Código — `supabase/functions/get-anexo/index.ts`
Porteira: valida o token HMAC (`?t=`), confere a expiração e faz **proxy** dos bytes
do Drive. O arquivo continua privado; abre inline no navegador (PDF/imagem) ou baixa.

```ts
// Deno / Supabase Edge Function — get-anexo
function b64urlFromBytes(bytes: Uint8Array): string {
  let s = ""; for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64url(str: string): string { return b64urlFromBytes(new TextEncoder().encode(str)); }
function b64urlDecode(str: string): string {
  const b64 = str.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((str.length + 3) % 4);
  return atob(b64);
}
function pemToBuf(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64); const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}
async function hmacSign(msg: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return b64urlFromBytes(new Uint8Array(sig));
}
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
async function getAccessToken(sa: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.` +
    b64url(JSON.stringify({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/drive.readonly",
      aud: "https://oauth2.googleapis.com/token",
      iat: now, exp: now + 3600,
    }));
  const key = await crypto.subtle.importKey(
    "pkcs8", pemToBuf(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${b64urlFromBytes(new Uint8Array(sig))}`;
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const j = await res.json();
  if (!j.access_token) throw new Error("token: " + JSON.stringify(j));
  return j.access_token;
}

Deno.serve(async (req) => {
  try {
    const t = new URL(req.url).searchParams.get("t") || "";
    const [payload, sig] = t.split(".");
    if (!payload || !sig) return new Response("Link inválido.", { status: 400 });

    const secret = Deno.env.get("ANEXO_SIGN_SECRET")!;
    const esperado = await hmacSign(payload, secret);
    if (!safeEqual(sig, esperado)) return new Response("Assinatura inválida.", { status: 403 });

    const { id, exp } = JSON.parse(b64urlDecode(payload));
    if (exp && Math.floor(Date.now() / 1000) > exp)
      return new Response("Link expirado.", { status: 410 });

    const sa = JSON.parse(Deno.env.get("GOOGLE_SA_JSON")!);
    const at = await getAccessToken(sa);
    const H = { Authorization: `Bearer ${at}` };

    // Metadados (nome + mime) para servir com Content-Type/nome corretos.
    const metaRes = await fetch(
      `https://www.googleapis.com/drive/v3/files/${id}?fields=name,mimeType&supportsAllDrives=true`,
      { headers: H },
    );
    if (!metaRes.ok) return new Response("Arquivo não encontrado.", { status: 404 });
    const meta = await metaRes.json();

    const dl = await fetch(
      `https://www.googleapis.com/drive/v3/files/${id}?alt=media&supportsAllDrives=true`,
      { headers: H },
    );
    if (!dl.ok || !dl.body) return new Response("Falha ao ler o arquivo.", { status: 502 });

    const nomeAscii = (meta.name || "anexo").replace(/[^\x20-\x7E]/g, "_").replace(/"/g, "");
    return new Response(dl.body, {
      headers: {
        "Content-Type": meta.mimeType || "application/octet-stream",
        "Content-Disposition": `inline; filename="${nomeAscii}"; filename*=UTF-8''${encodeURIComponent(meta.name || "anexo")}`,
        "Cache-Control": "private, max-age=300",
      },
    });
  } catch (e) {
    return new Response("Erro: " + String((e as any).message || e), { status: 500 });
  }
});
```

## Observação
O front (`nova-denuncia.html`) envia `{ nome, mime, conteudo_base64 }` para
`/functions/v1/upload-anexo` e guarda o `{ file_id, web_view_link, link }` de volta
no registro (`denuncias.anexos`). O painel (`denuncias.html`) usa `a.link ||
a.web_view_link` tanto no detalhe quanto no PDF, então:
- **com `get-anexo` publicada:** o link do PDF abre o anexo de qualquer lugar,
  sem login, com o arquivo privado no Drive;
- **sem as funções publicadas:** o upload falha e o registro é salvo sem anexo —
  nada trava. Anexos antigos sem `link` caem no `web_view_link` (só abre p/ quem
  tem permissão no Drive).

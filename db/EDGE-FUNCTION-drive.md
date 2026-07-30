# Edge Function `upload-anexo` — envio de anexos ao Google Drive

Mantém os arquivos **privados** no Drive (conta de serviço) e devolve `file_id` +
`web_view_link` para o registro. O painel guarda só esses dados — o acesso é
liberado depois por link temporário (próxima etapa).

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
```

## 3) Publicar a função
```bash
supabase functions new upload-anexo      # cria a pasta
# cole o código abaixo em supabase/functions/upload-anexo/index.ts
supabase functions deploy upload-anexo
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

    return new Response(
      JSON.stringify({ file_id: file.id, web_view_link: file.webViewLink }),
      { headers: { ...CORS, "Content-Type": "application/json" } },
    );
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e.message || e) }), {
      status: 400, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
```

## Observação
O front (`nova-denuncia.html`) já envia `{ nome, mime, conteudo_base64 }` para
`/functions/v1/upload-anexo` e usa o `{ file_id, web_view_link }` de volta.
Sem a função publicada, o anexo apenas falha — o registro continua funcionando.

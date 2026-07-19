/**
 * ══════════════════════════════════════════════════════════════════
 *  SUPABASE AUTH — 3ª CIA PM MAmb
 *  Autenticação e gestão de usuários 100% via Supabase.
 *  Substitui a dependência da aba "MILITARES" do Google Sheets.
 *
 *  Tabela esperada no Supabase: public.militares
 *  Colunas:
 *    id              UUID (PK, gerado automaticamente)
 *    matricula       TEXT  UNIQUE NOT NULL  (ex: "146.322-3")
 *    matricula_clean TEXT  GENERATED/STORED (somente dígitos, 7 chars)
 *    posto_graduacao TEXT  (ex: "3º Sgt PM")
 *    nome_completo   TEXT  NOT NULL
 *    nome_guerra     TEXT
 *    email           TEXT
 *    senha_hash      TEXT  NOT NULL   (bcrypt-like via sha256 no frontend)
 *    primeiro_acesso BOOLEAN DEFAULT true
 *    ativo           BOOLEAN DEFAULT true
 *    nivel_acesso    TEXT  CHECK IN ('admin_geral','admin','admin_pelotao','operacional')
 *    funcao          TEXT
 *    grupamento_id   TEXT  (FK para tabela grupos, opcional)
 *    created_at      TIMESTAMPTZ DEFAULT now()
 *    updated_at      TIMESTAMPTZ DEFAULT now()
 *
 *  RLS (Row Level Security) recomendado:
 *    - SELECT: qualquer usuário autenticado (via JWT Supabase ou anon com validação no frontend)
 *    - INSERT/UPDATE/DELETE: somente admin_geral via service_role key no backend
 *    Obs: como o sistema usa chave anon no frontend, a validação de nível de acesso
 *    é feita aqui no JS. Para produção, implemente RLS no Supabase.
 * ══════════════════════════════════════════════════════════════════
 */

/* ─── Configuração ─────────────────────────────────────────────── */
const SB_AUTH_URL = 'https://zrnbebjszwkmquzthjfa.supabase.co';
const SB_AUTH_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpybmJlYmpzendrbXF1enRoamZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkzOTA4MzEsImV4cCI6MjA5NDk2NjgzMX0.di9t2SOCTLZ2uPFOnTOiy6srvt7GC5cdqenZZScXve4';
const SB_TABLE    = 'militares';
const SENHA_PADRAO = 'Mudar@123';

/* Níveis de acesso em ordem crescente de permissão */
const NIVEIS = ['operacional', 'admin_gp', 'admin_pelotao', 'admin', 'admin_geral'];

/* Admin Gerais iniciais (nunca podem ser rebaixados abaixo de admin_geral
   a menos que haja outro admin_geral) */
const ADMIN_GERAIS_FIXOS = ['1463223', '1384841']; // matricula_clean

/* ─── Hash simples (SHA-256 via WebCrypto) ─────────────────────── */
async function hashSenha(senha) {
  const enc  = new TextEncoder();
  const buf  = await crypto.subtle.digest('SHA-256', enc.encode(senha));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2,'0')).join('');
}

/* ─── Utilitários Supabase REST ─────────────────────────────────── */
const _sbHeaders = {
  'apikey': SB_AUTH_KEY,
  'Authorization': `Bearer ${SB_AUTH_KEY}`,
  'Content-Type': 'application/json',
  'Prefer': 'return=representation'
};

async function _sbGet(params = '') {
  const sep = params ? `${params}&` : '';
  const url = `${SB_AUTH_URL}/rest/v1/${SB_TABLE}?${sep}limit=2000&order=nome_completo`;
  const res = await fetch(url, { headers: _sbHeaders });
  if (!res.ok) throw new Error(`[sbGet] ${res.status}: ${await res.text()}`);
  return res.json();
}

async function _sbGetOne(params = '') {
  const url = `${SB_AUTH_URL}/rest/v1/${SB_TABLE}?${params}&limit=1`;
  const res = await fetch(url, { headers: { ..._sbHeaders, 'Prefer': 'return=representation' } });
  if (!res.ok) throw new Error(`[sbGetOne] ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows[0] || null;
}

async function _sbInsert(body) {
  const res = await fetch(`${SB_AUTH_URL}/rest/v1/${SB_TABLE}`, {
    method: 'POST', headers: _sbHeaders, body: JSON.stringify(body)
  });
  if (!res.ok) throw new Error(`[sbInsert] ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return Array.isArray(rows) ? rows[0] : rows;
}

async function _sbPatch(filter, body) {
  const res = await fetch(`${SB_AUTH_URL}/rest/v1/${SB_TABLE}?${filter}`, {
    method: 'PATCH', headers: _sbHeaders, body: JSON.stringify({ ...body, updated_at: new Date().toISOString() })
  });
  if (!res.ok) throw new Error(`[sbPatch] ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return Array.isArray(rows) ? rows[0] : rows;
}

async function _sbDelete(filter) {
  const res = await fetch(`${SB_AUTH_URL}/rest/v1/${SB_TABLE}?${filter}`, {
    method: 'DELETE', headers: _sbHeaders
  });
  if (!res.ok) throw new Error(`[sbDelete] ${res.status}: ${await res.text()}`);
  return true;
}

/* ─── Helpers ────────────────────────────────────────────────────── */
function _limparMatricula(m) {
  return String(m || '').replace(/\D/g, '').padStart(7, '0');
}

function _formatarMatricula(clean) {
  clean = String(clean || '').replace(/\D/g, '');
  while (clean.length < 7) clean = '0' + clean;
  if (clean.length === 7) return `${clean.slice(0,3)}.${clean.slice(3,6)}-${clean.slice(6)}`;
  return clean;
}

function _nivelNum(nivel) {
  const i = NIVEIS.indexOf(nivel);
  return i === -1 ? 0 : i;
}

/* Verifica se o usuário atual (sessão) pode gerenciar o alvo */
function _podeManejar(sessao, alvo) {
  const meuNivel  = _nivelNum(sessao?.nivel_acesso);
  const alvNivel  = _nivelNum(alvo?.nivel_acesso);
  return meuNivel > alvNivel || sessao?.id === alvo?.id;
}

/* ─── SESSÃO ─────────────────────────────────────────────────────── */
const _SESSAO_KEY = 'poe_sessao_v2';

function sessaoSalvar(user) {
  const data = { ...user, ts: Date.now() };
  sessionStorage.setItem(_SESSAO_KEY, JSON.stringify(data));
  /* Propositalmente NÃO grava em localStorage: a sessão deve expirar ao
     fechar o navegador, exigindo login novamente — não apenas ao fechar a aba. */
}

function sessaoLer() {
  const raw = sessionStorage.getItem(_SESSAO_KEY);
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

function sessaoLimpar() {
  sessionStorage.removeItem(_SESSAO_KEY);
  localStorage.removeItem(_SESSAO_KEY);
  // Compatibilidade com a sessão antiga
  sessionStorage.removeItem('poe_sessao');
  localStorage.removeItem('poe_sessao');
}

/* ─── AUTENTICAÇÃO ───────────────────────────────────────────────── */

/**
 * Login: verifica matricula + senha contra o Supabase.
 * Retorna { ok, user, primeiroAcesso, erro }
 */
async function auth_login(matricula, senha) {
  try {
    const clean = _limparMatricula(matricula);
    const user = await _sbGetOne(`matricula_clean=eq.${clean}&ativo=eq.true`);

    if (!user) return { ok: false, erro: 'Usuário não encontrado ou inativo.' };

    const senhaHash = await hashSenha(senha);
    if (user.senha_hash !== senhaHash) {
      return { ok: false, erro: 'Senha incorreta.' };
    }

    const sessao = {
      id:             user.id,
      matricula:      user.matricula,
      matricula_clean: user.matricula_clean,
      nome:           user.nome_completo,
      guerra:         user.nome_guerra,
      pg:             user.posto_graduacao,
      nivel_acesso:   user.nivel_acesso,
      funcao:         user.funcao,
      grupamento_id:  user.grupamento_id,
      primeiro_acesso: user.primeiro_acesso,
    };

    sessaoSalvar(sessao);
    return { ok: true, user: sessao, primeiroAcesso: user.primeiro_acesso };
  } catch (e) {
    console.error('auth_login:', e);
    return { ok: false, erro: `Erro ao conectar: ${e.message}` };
  }
}

/**
 * Troca de senha (primeiro acesso ou reset voluntário).
 * Retorna { ok, erro }
 */
async function auth_trocarSenha(id, novaSenha) {
  try {
    if (!novaSenha || novaSenha.length < 6) {
      return { ok: false, erro: 'A senha deve ter pelo menos 6 caracteres.' };
    }
    if (novaSenha === SENHA_PADRAO) {
      return { ok: false, erro: 'A nova senha não pode ser igual à senha padrão.' };
    }
    const hash = await hashSenha(novaSenha);
    await _sbPatch(`id=eq.${id}`, { senha_hash: hash, primeiro_acesso: false });

    // Atualiza sessão atual se for o mesmo usuário
    const s = sessaoLer();
    if (s && s.id === id) {
      s.primeiro_acesso = false;
      sessaoSalvar(s);
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, erro: e.message };
  }
}

/* ─── CRUD DE USUÁRIOS ───────────────────────────────────────────── */

/** Lista todos os militares */
async function auth_listarUsuarios() {
  return _sbGet();
}

/** Cria novo militar */
async function auth_criarUsuario({ matricula, posto_graduacao, nome_completo, nome_guerra, funcao, grupamento_id, nivel_acesso }, sessao) {
  try {
    if (_nivelNum(sessao?.nivel_acesso) < _nivelNum('admin')) {
      return { ok: false, erro: 'Permissão insuficiente para criar usuários.' };
    }
    if (!matricula || !nome_completo) {
      return { ok: false, erro: 'Matrícula e nome são obrigatórios.' };
    }
    const clean = _limparMatricula(matricula);
    const existe = await _sbGetOne(`matricula_clean=eq.${clean}`);
    if (existe) return { ok: false, erro: 'Matrícula já cadastrada.', dup: true };

    const hash = await hashSenha(SENHA_PADRAO);
    const novo = await _sbInsert({
      matricula:       _formatarMatricula(clean),
      matricula_clean: clean,
      posto_graduacao: posto_graduacao || null,
      nome_completo,
      nome_guerra:     nome_guerra || null,
      funcao:          funcao || null,
      grupamento_id:   grupamento_id || null,
      nivel_acesso:    nivel_acesso || 'operacional',
      senha_hash:      hash,
      primeiro_acesso: true,
      ativo:           true,
    });
    return { ok: true, user: novo };
  } catch (e) {
    return { ok: false, erro: e.message };
  }
}

/** Atualiza dados do militar */
async function auth_atualizarUsuario(id, dados, sessao) {
  try {
    const alvo = await _sbGetOne(`id=eq.${id}`);
    if (!alvo) return { ok: false, erro: 'Usuário não encontrado.' };

    // Restrição: não pode rebaixar admin_geral se for o único
    if (dados.nivel_acesso && dados.nivel_acesso !== 'admin_geral' && alvo.nivel_acesso === 'admin_geral') {
      const outrosAG = (await _sbGet(`nivel_acesso=eq.admin_geral&id=neq.${id}&ativo=eq.true`)).length;
      if (outrosAG === 0) return { ok: false, erro: 'Não é possível rebaixar o único Admin Geral ativo.' };
    }

    // Somente admin_geral pode promover a admin_geral
    if (dados.nivel_acesso === 'admin_geral' && _nivelNum(sessao?.nivel_acesso) < _nivelNum('admin_geral')) {
      return { ok: false, erro: 'Apenas Admin Geral pode promover outros Admin Gerais.' };
    }

    // Não pode editar usuário de nível superior (exceto admin_geral pode editar outros admin_geral)
    const meuNivelNum = _nivelNum(sessao?.nivel_acesso);
    const alvNivelNum = _nivelNum(alvo.nivel_acesso);
    const ambosAdminGeral = sessao?.nivel_acesso === 'admin_geral' && alvo.nivel_acesso === 'admin_geral';
    if (sessao?.id !== id && !ambosAdminGeral && alvNivelNum >= meuNivelNum) {
      return { ok: false, erro: 'Você não pode editar um usuário de nível igual ou superior ao seu.' };
    }

    const update = {};
    if (dados.posto_graduacao !== undefined) update.posto_graduacao = dados.posto_graduacao;
    if (dados.nome_completo   !== undefined) update.nome_completo   = dados.nome_completo;
    if (dados.nome_guerra     !== undefined) update.nome_guerra     = dados.nome_guerra;
    if (dados.funcao          !== undefined) update.funcao          = dados.funcao;
    if (dados.grupamento_id   !== undefined) update.grupamento_id   = dados.grupamento_id;
    if (dados.nivel_acesso    !== undefined) update.nivel_acesso    = dados.nivel_acesso;
    if (dados.ativo           !== undefined) update.ativo           = dados.ativo;

    const updated = await _sbPatch(`id=eq.${id}`, update);
    return { ok: true, user: updated };
  } catch (e) {
    return { ok: false, erro: e.message };
  }
}

/** Reset de senha para padrão */
async function auth_resetarSenha(id, sessao) {
  try {
    const alvo = await _sbGetOne(`id=eq.${id}`);
    if (!alvo) return { ok: false, erro: 'Usuário não encontrado.' };
    const ambosAG = sessao?.nivel_acesso === 'admin_geral' && alvo.nivel_acesso === 'admin_geral';
    if (sessao?.id !== id && !ambosAG && _nivelNum(sessao?.nivel_acesso) <= _nivelNum(alvo.nivel_acesso)) {
      return { ok: false, erro: 'Permissão insuficiente para resetar esta senha.' };
    }
    const hash = await hashSenha(SENHA_PADRAO);
    await _sbPatch(`id=eq.${id}`, { senha_hash: hash, primeiro_acesso: true });
    return { ok: true };
  } catch (e) {
    return { ok: false, erro: e.message };
  }
}

/** Altera nível de acesso */
async function auth_alterarNivel(id, novoNivel, sessao) {
  return auth_atualizarUsuario(id, { nivel_acesso: novoNivel }, sessao);
}

/** Ativa ou desativa usuário */
async function auth_alterarAtivo(id, ativo, sessao) {
  try {
    const alvo = await _sbGetOne(`id=eq.${id}`);
    if (!alvo) return { ok: false, erro: 'Usuário não encontrado.' };

    if (!ativo && alvo.nivel_acesso === 'admin_geral') {
      const outrosAG = (await _sbGet(`nivel_acesso=eq.admin_geral&id=neq.${id}&ativo=eq.true`)).length;
      if (outrosAG === 0) return { ok: false, erro: 'Não é possível desativar o único Admin Geral ativo.' };
    }

    await _sbPatch(`id=eq.${id}`, { ativo });
    return { ok: true };
  } catch (e) {
    return { ok: false, erro: e.message };
  }
}

/** Exclui usuário permanentemente */
async function auth_excluirUsuario(id, sessao) {
  try {
    const alvo = await _sbGetOne(`id=eq.${id}`);
    if (!alvo) return { ok: false, erro: 'Usuário não encontrado.' };
    if (sessao?.id === id) return { ok: false, erro: 'Você não pode excluir sua própria conta.' };

    if (alvo.nivel_acesso === 'admin_geral') {
      const outrosAG = (await _sbGet(`nivel_acesso=eq.admin_geral&id=neq.${id}&ativo=eq.true`)).length;
      if (outrosAG === 0) return { ok: false, erro: 'Não é possível excluir o único Admin Geral.' };
    }

    const ambosAGExcl = sessao?.nivel_acesso === 'admin_geral' && alvo.nivel_acesso === 'admin_geral';
    if (!ambosAGExcl && _nivelNum(alvo.nivel_acesso) >= _nivelNum(sessao?.nivel_acesso)) {
      return { ok: false, erro: 'Você não pode excluir um usuário de nível igual ou superior.' };
    }

    await _sbDelete(`id=eq.${id}`);
    return { ok: true };
  } catch (e) {
    return { ok: false, erro: e.message };
  }
}

/* ─── VERIFICAÇÃO DE PERMISSÕES ──────────────────────────────────── */

/** Retorna true se o usuário tem o nível mínimo exigido */
function auth_temPermissao(sessao, nivelMinimo) {
  return _nivelNum(sessao?.nivel_acesso) >= _nivelNum(nivelMinimo);
}

/** Extrai o número do pelotão de uma string de grupamento_id */
function _pelotaoNum(gid) {
  const m = (gid || '').match(/(\d+)\s*PEL/i);
  return m ? parseInt(m[1]) : null;
}

/** Verifica se pode ver dados de um determinado grupamento */
function auth_podeVerGrupamento(sessao, grupamento_id) {
  if (!sessao) return false;
  const nivel = sessao.nivel_acesso;
  if (nivel === 'admin_geral' || nivel === 'admin') return true;
  if (nivel === 'admin_pelotao') {
    // Compara pelo número do pelotão, não pelo grupamento exato
    const meuPel = _pelotaoNum(sessao.grupamento_id);
    if (meuPel === null) return sessao.grupamento_id === grupamento_id; // fallback
    return _pelotaoNum(grupamento_id) === meuPel;
  }
  if (nivel === 'admin_gp') {
    // Escopo isolado: só o próprio grupamento (não o pelotão inteiro)
    return sessao.grupamento_id === grupamento_id;
  }
  return false; // operacional não acessa painel admin
}

/* ─── MIGRAÇÃO: importar dados da planilha (uso único) ──────────── */

/**
 * Importa um array de usuários (lidos da planilha) para o Supabase.
 * Não sobrescreve usuários já existentes (verifica matricula_clean).
 * Use apenas uma vez durante a migração inicial.
 * Retorna { inseridos, ignorados, erros }
 */
async function auth_migrarDaPlanilha(rows) {
  let inseridos = 0, ignorados = 0, erros = [];

  for (const row of rows) {
    try {
      const clean = _limparMatricula(row.matricula);
      const existe = await _sbGetOne(`matricula_clean=eq.${clean}`);
      if (existe) { ignorados++; continue; }

      const senhaOriginal = row.senha || SENHA_PADRAO;
      const hash = await hashSenha(senhaOriginal);

      // Mapeamento de perfil antigo → novo nivel_acesso
      let nivel = 'operacional';
      const perfilRaw = (row.perfil || '').toLowerCase();
      if (perfilRaw === 'admin') nivel = 'admin';

      // Admin Gerais fixos
      if (ADMIN_GERAIS_FIXOS.includes(clean)) nivel = 'admin_geral';

      await _sbInsert({
        matricula:       _formatarMatricula(clean),
        matricula_clean: clean,
        posto_graduacao: row.pg || null,
        nome_completo:   row.nome,
        nome_guerra:     row.guerra || null,
        funcao:          row.funcao || null,
        grupamento_id:   row.lotacao || null,
        nivel_acesso:    nivel,
        senha_hash:      hash,
        primeiro_acesso: row.primeiroAcesso !== false,
        ativo:           row.ativo !== false,
      });
      inseridos++;
    } catch (e) {
      erros.push({ matricula: row.matricula, erro: e.message });
    }
  }
  return { inseridos, ignorados, erros };
}

/* ─── SQL DE CRIAÇÃO DA TABELA ───────────────────────────────────── */
/**
 * Execute este SQL no SQL Editor do Supabase:
 *
 * CREATE TABLE IF NOT EXISTS public.militares (
 *   id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 *   matricula       TEXT UNIQUE NOT NULL,
 *   matricula_clean TEXT GENERATED ALWAYS AS (regexp_replace(matricula, '[^0-9]', '', 'g')) STORED,
 *   posto_graduacao TEXT,
 *   nome_completo   TEXT NOT NULL,
 *   nome_guerra     TEXT,
 *   email           TEXT,
 *   senha_hash      TEXT NOT NULL,
 *   primeiro_acesso BOOLEAN NOT NULL DEFAULT true,
 *   ativo           BOOLEAN NOT NULL DEFAULT true,
 *   nivel_acesso    TEXT NOT NULL DEFAULT 'operacional'
 *                   CHECK (nivel_acesso IN ('admin_geral','admin','admin_pelotao','operacional')),
 *   funcao          TEXT,
 *   grupamento_id   TEXT,
 *   created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
 *   updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
 * );
 *
 * -- Índices úteis
 * CREATE INDEX IF NOT EXISTS idx_militares_clean ON public.militares(matricula_clean);
 * CREATE INDEX IF NOT EXISTS idx_militares_nivel ON public.militares(nivel_acesso);
 * CREATE INDEX IF NOT EXISTS idx_militares_ativo  ON public.militares(ativo);
 *
 * -- Trigger para atualizar updated_at automaticamente
 * CREATE OR REPLACE FUNCTION update_updated_at()
 * RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;
 *
 * CREATE TRIGGER trg_militares_updated_at
 *   BEFORE UPDATE ON public.militares
 *   FOR EACH ROW EXECUTE FUNCTION update_updated_at();
 *
 * -- RLS (recomendado para produção)
 * ALTER TABLE public.militares ENABLE ROW LEVEL SECURITY;
 * -- Permitir leitura para anon (necessário para login via frontend)
 * CREATE POLICY "militares_select" ON public.militares FOR SELECT USING (true);
 * -- Escrita somente via service_role (backend seguro)
 * CREATE POLICY "militares_insert" ON public.militares FOR INSERT WITH CHECK (false);
 * CREATE POLICY "militares_update" ON public.militares FOR UPDATE USING (false);
 * CREATE POLICY "militares_delete" ON public.militares FOR DELETE USING (false);
 *
 * -- Para permitir escrita pelo frontend (dev/staging sem backend):
 * -- Substitua as políticas acima por:
 * -- CREATE POLICY "allow_all" ON public.militares FOR ALL USING (true) WITH CHECK (true);
 */

/* ─── CACHE DE REFERÊNCIAS (militares, frações, operações, etc.) ────
   Evita buscar tudo de novo do Apps Script/Sheets toda vez que a pessoa
   troca de página — guarda por 5 minutos no sessionStorage (some quando
   fecha a aba). Se algo for cadastrado/alterado via Administração, chama
   auth_limparCacheReferencias() pra forçar buscar de novo na hora. ────── */
const AUTH_REFERENCIAS_CACHE_KEY = 'poe_referencias_cache_v1';
const AUTH_REFERENCIAS_CACHE_MS = 5 * 60 * 1000; // 5 minutos

async function auth_fetchReferencias(scriptUrl) {
  try {
    const bruto = sessionStorage.getItem(AUTH_REFERENCIAS_CACHE_KEY);
    if (bruto) {
      const cache = JSON.parse(bruto);
      if (cache.scriptUrl === scriptUrl && (Date.now() - cache.buscadoEm) < AUTH_REFERENCIAS_CACHE_MS) {
        return cache.dados;
      }
    }
  } catch (e) { /* cache corrompido — ignora e busca de novo */ }

  const res = await fetch(scriptUrl + '?action=referencias');
  const dados = await res.json();
  try {
    sessionStorage.setItem(AUTH_REFERENCIAS_CACHE_KEY, JSON.stringify({
      scriptUrl, dados, buscadoEm: Date.now(),
    }));
  } catch (e) { /* sessionStorage cheio/indisponível — segue sem cachear */ }
  return dados;
}

function auth_limparCacheReferencias() {
  try { sessionStorage.removeItem(AUTH_REFERENCIAS_CACHE_KEY); } catch (e) {}
}

/* ─── Exportações globais ────────────────────────────────────────── */
window.SbAuth = {
  login:            auth_login,
  trocarSenha:      auth_trocarSenha,
  listarUsuarios:   auth_listarUsuarios,
  criarUsuario:     auth_criarUsuario,
  atualizarUsuario: auth_atualizarUsuario,
  resetarSenha:     auth_resetarSenha,
  alterarNivel:     auth_alterarNivel,
  alterarAtivo:     auth_alterarAtivo,
  excluirUsuario:   auth_excluirUsuario,
  temPermissao:     auth_temPermissao,
  podeVerGrupamento: auth_podeVerGrupamento,
  migrarDaPlanilha: auth_migrarDaPlanilha,
  fetchReferencias: auth_fetchReferencias,
  limparCacheReferencias: auth_limparCacheReferencias,
  sessaoLer,
  sessaoSalvar,
  sessaoLimpar,
  formatarMatricula: _formatarMatricula,
  limparMatricula:   _limparMatricula,
  NIVEIS,
  SENHA_PADRAO,
  hashSenha,
};

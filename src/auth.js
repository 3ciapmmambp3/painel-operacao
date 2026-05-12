/* =====================================================
   AUTH.JS — Gerenciamento de usuários (localStorage)
   Trocar por Supabase quando pronto para produção
   ===================================================== */

const DB_KEY = 'poe_usuarios';
const SESS_KEY = 'poe_sessao';

/* Wrapper seguro — fallback em memória se storage bloqueado (ex: Edge Tracking Prevention) */
const _mem = {};
function _storageSet(key, val) {
  try { localStorage.setItem(key, val); } catch(e) {}
  _mem[key] = val;
}
function _storageGet(key) {
  try {
    const v = localStorage.getItem(key);
    if (v !== null) { _mem[key] = v; return v; }
  } catch(e) {}
  return _mem[key] || null;
}
function _storageDel(key) {
  try { localStorage.removeItem(key); } catch(e) {}
  delete _mem[key];
}
const SENHA_PADRAO = 'Mudar@123';

/* ── Usuários iniciais ── */
const USUARIOS_INICIAIS = [
  {
    id: '0',
    numeroPolicia: '000.000-1',
    numeroClean: '0000001',
    nome: 'Administrador Padrão',
    perfil: 'admin',
    senha: 'Mudar@123',
    primeiroAcesso: true,
    ativo: true,
    criadoEm: '2026-01-01T00:00:00.000Z'
  },
  {
    id: '1',
    numeroPolicia: '146.322-3',
    numeroClean: '1463223',
    nome: 'THIAGO JARDIM DE CASTRO',
    pg: '3 SGT PM',
    guerra: 'CASTRO',
    funcao: 'AUX P3',
    lotacao: '1 GP / 4 PEL / 3 CIA PM MAMB / TEOFILO OTONI',
    perfil: 'admin',
    senha: 'Mudar@123',
    primeiroAcesso: true,
    ativo: true,
    criadoEm: '2026-01-01T00:00:00.000Z'
  },
  {
    id: '2',
    numeroPolicia: '138.484-1',
    numeroClean: '1384841',
    nome: 'RAFAEL ESTEVAM',
    pg: '1 SGT PM',
    guerra: 'ESTEVAM',
    funcao: 'AUX P3',
    lotacao: 'ADM',
    perfil: 'operacional',
    senha: 'Mudar@123',
    primeiroAcesso: true,
    ativo: true,
    criadoEm: '2026-01-01T00:00:00.000Z'
  }
];

/* Versão do banco — ao incrementar, força reset para pegar novos usuários iniciais */
const DB_VERSION = '2';

/* ══ BANCO LOCAL ══ */
function getUsuarios() {
  const raw = _storageGet(DB_KEY);
  const ver = _storageGet(DB_KEY + '_ver');
  let lista;

  if (!raw) {
    /* Primeira vez: cria banco com usuários iniciais */
    lista = [...USUARIOS_INICIAIS.map(u => ({...u}))];
    _storageSet(DB_KEY, JSON.stringify(lista));
    _storageSet(DB_KEY + '_ver', DB_VERSION);
    return lista;
  }

  /* Banco já existe — carrega sem sobrescrever dados do usuário */
  lista = JSON.parse(raw);

  /* Apenas garante que novos usuários iniciais sejam adicionados se não existirem */
  let changed = false;
  USUARIOS_INICIAIS.forEach(u => {
    if (!lista.find(x => x.numeroClean === u.numeroClean)) {
      lista.unshift({...u});
      changed = true;
    }
  });

  /* Atualiza versão sem mexer nos dados existentes */
  if (ver !== DB_VERSION || changed) {
    _storageSet(DB_KEY, JSON.stringify(lista));
    _storageSet(DB_KEY + '_ver', DB_VERSION);
  }

  lista = JSON.parse(raw);
  /* Garante admin padrão sempre presente */
  const adminPadrao = USUARIOS_INICIAIS[0];
  if (!lista.find(u => u.numeroClean === adminPadrao.numeroClean)) {
    lista.unshift({...adminPadrao});
    _storageSet(DB_KEY, JSON.stringify(lista));
  }
  return lista;
}

function saveUsuarios(lista) {
  _storageSet(DB_KEY, JSON.stringify(lista));
}

function cleanNP(np) {
  return (np || '').replace(/[^0-9]/g, '');
}

/* ══ AUTENTICAÇÃO ══ */
function auth_login(numeroPolicia, senha) {
  const usuarios = getUsuarios();
  const clean = cleanNP(numeroPolicia);
  const user = usuarios.find(u => u.numeroClean === clean && u.ativo);
  if (!user) return { ok: false, erro: 'Número de polícia não encontrado.' };
  if (user.senha !== senha) return { ok: false, erro: 'Senha incorreta.' };
  const sessao = { id: user.id, numeroPolicia: user.numeroPolicia, nome: user.nome, perfil: user.perfil, primeiroAcesso: user.primeiroAcesso };
  _storageSet(SESS_KEY, JSON.stringify(sessao));
  return { ok: true, user: sessao };
}

function auth_logout() {
  _storageDel(SESS_KEY);
  window.location.href = 'index.html';
}

function auth_getSessao() {
  const raw = _storageGet(SESS_KEY);
  return raw ? JSON.parse(raw) : null;
}

function auth_requerLogin() {
  const s = auth_getSessao();
  if (!s) { window.location.href = 'index.html'; return null; }
  return s;
}

function auth_requerAdmin() {
  const s = auth_requerLogin();
  if (!s) return null;
  /* Verifica o perfil TANTO na sessão quanto no banco local */
  const usuarios = JSON.parse(_storageGet('poe_usuarios') || '[]');
  const userDB = usuarios.find(u => u.id === s.id);
  const perfilReal = userDB ? userDB.perfil : s.perfil;
  if (perfilReal !== 'admin') {
    const _msgDiv = document.createElement('div');
    _msgDiv.style.cssText = 'display:flex;align-items:center;justify-content:center;height:100vh;background:#1a1a1a;flex-direction:column;gap:16px;';
    _msgDiv.innerHTML = '<div style="color:#ef5350;font-size:48px;">🔒</div><div style="color:#ef5350;font-size:18px;font-weight:700;">ACESSO RESTRITO</div><div style="color:#999;font-size:13px;">Apenas administradores podem acessar esta área.</div>';
    const _btn = document.createElement('button');
    _btn.textContent = '← Voltar ao Painel';
    _btn.style.cssText = 'margin-top:12px;background:#9b8a5c;color:#1a1000;border:none;padding:10px 24px;border-radius:6px;font-size:13px;font-weight:700;cursor:pointer;';
    _btn.onclick = function(){ window.location.href = 'painel.html'; };
    _msgDiv.appendChild(_btn);
    document.body.innerHTML = '';
    document.body.appendChild(_msgDiv);
    return null;
  }
  return s;
}

/* ══ SENHA ══ */
function auth_alterarSenha(userId, senhaAtual, novaSenha) {
  const usuarios = getUsuarios();
  const idx = usuarios.findIndex(u => u.id === userId);
  if (idx === -1) return { ok: false, erro: 'Usuário não encontrado.' };
  if (usuarios[idx].senha !== senhaAtual) return { ok: false, erro: 'Senha atual incorreta.' };
  if (novaSenha.length < 6) return { ok: false, erro: 'A nova senha deve ter pelo menos 6 caracteres.' };
  usuarios[idx].senha = novaSenha;
  usuarios[idx].primeiroAcesso = false;
  saveUsuarios(usuarios);
  /* Atualiza sessão */
  const s = auth_getSessao();
  if (s) { s.primeiroAcesso = false; _storageSet(SESS_KEY, JSON.stringify(s)); }
  return { ok: true };
}

function auth_atualizarNome(userId, novoNome) {
  const usuarios = getUsuarios();
  const idx = usuarios.findIndex(u => u.id === userId);
  if (idx === -1) return { ok: false, erro: 'Usuário não encontrado.' };
  usuarios[idx].nome = novoNome;
  saveUsuarios(usuarios);
  const s = auth_getSessao();
  if (s) { s.nome = novoNome; _storageSet(SESS_KEY, JSON.stringify(s)); }
  return { ok: true };
}

/* ══ GESTÃO DE USUÁRIOS (admin) ══ */
function auth_listarUsuarios() {
  return getUsuarios();
}

function auth_criarUsuario(numeroPolicia, nome, perfil) {
  const usuarios = getUsuarios();
  const clean = cleanNP(numeroPolicia);
  if (usuarios.find(u => u.numeroClean === clean)) return { ok: false, erro: 'Número de polícia já cadastrado.' };
  const novo = {
    id: Date.now().toString(),
    numeroPolicia: formatNP(clean),
    numeroClean: clean,
    nome,
    perfil,
    senha: SENHA_PADRAO,
    primeiroAcesso: true,
    ativo: true,
    criadoEm: new Date().toISOString()
  };
  usuarios.push(novo);
  saveUsuarios(usuarios);
  return { ok: true, user: novo };
}

function auth_alterarPerfil(userId, novoPerfil) {
  const usuarios = getUsuarios();
  /* Garante que sempre haverá ao menos 1 admin */
  if (novoPerfil === 'operacional') {
    const admins = usuarios.filter(u => u.perfil === 'admin' && u.ativo && u.id !== userId);
    if (admins.length === 0) return { ok: false, erro: 'Não é possível rebaixar: precisa haver pelo menos um administrador.' };
  }
  const idx = usuarios.findIndex(u => u.id === userId);
  if (idx === -1) return { ok: false, erro: 'Usuário não encontrado.' };
  usuarios[idx].perfil = novoPerfil;
  saveUsuarios(usuarios);
  return { ok: true };
}

function auth_resetarSenha(userId) {
  const usuarios = getUsuarios();
  const idx = usuarios.findIndex(u => u.id === userId);
  if (idx === -1) return { ok: false, erro: 'Usuário não encontrado.' };
  usuarios[idx].senha = SENHA_PADRAO;
  usuarios[idx].primeiroAcesso = true;
  saveUsuarios(usuarios);
  return { ok: true };
}

function auth_excluirUsuario(userId) {
  const usuarios = getUsuarios();
  const user = usuarios.find(u => u.id === userId);
  if (!user) return { ok: false, erro: 'Usuário não encontrado.' };
  if (user.perfil === 'admin') {
    const admins = usuarios.filter(u => u.perfil === 'admin' && u.ativo && u.id !== userId);
    if (admins.length === 0) return { ok: false, erro: 'Não é possível excluir: precisa haver pelo menos um administrador.' };
  }
  const idx = usuarios.findIndex(u => u.id === userId);
  usuarios.splice(idx, 1);
  saveUsuarios(usuarios);
  return { ok: true };
}

/* ── Formata número de polícia ── */
function formatNP(clean) {
  clean = String(clean || '').replace(/[^0-9]/g,'');
  while(clean.length < 7) clean = '0' + clean;
  if(clean.length === 7) return clean.slice(0,3)+'.'+clean.slice(3,6)+'-'+clean.slice(6);
  return clean;
}

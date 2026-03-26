require('dotenv').config();

// SECURITY: Fail fast if SESSION_SECRET is not set — weak fallback is a security risk
if (!process.env.SESSION_SECRET) {
  console.error('FATAL: SESSION_SECRET environment variable must be set. Refusing to start with a weak fallback.');
  process.exit(1);
}

const express = require('express');
const Database = require('better-sqlite3');
const { Marked } = require('marked');
const { markedHighlight } = require('marked-highlight');
const hljs = require('highlight.js');
const path = require('path');
const os = require('os');
const fs = require('fs');
const { execFile, execFileSync } = require('child_process');
const { promisify } = require('util');
const execFileAsync = promisify(execFile);
const crypto = require('crypto');
const { createChatModule } = require('./lib/db/chat');
const { createFunnelDashboardService } = require('./lib/funnel/dashboard');
const { createOpenClawClient } = require('./lib/openclaw');
const {
  ALLOWED_CATEGORIES,
  DECISION_SCHEMA_VERSION,
  arraysMatchExactly,
  buildInternalMessage,
  getAllowedActionsForItem,
  getCanonicalActions,
  getInitialActionStatus,
  getSessionKey,
  getStoredStatusForDecision,
  isAllowedDecision,
  normalizeCategory,
  usesCanonicalRouting,
} = require('./lib/review-routing');
const OpenAI = require('openai');
const multer = require('multer');
const csrf = require('csurf');
const xss = require('xss');

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 25 * 1024 * 1024 } });

// Image upload multer instance (disk storage, 10MB limit, images only)
const ALLOWED_IMAGE_MIMES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);
const ALLOWED_IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp']);

// TTS cache directory
const ttsCacheDir = path.join(__dirname, 'tts-cache');
if (!fs.existsSync(ttsCacheDir)) fs.mkdirSync(ttsCacheDir);
const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
const MIN_TTS_CHARS = 500;

const app = express();
const PORT = process.env.PORT || 3457;
const OPENCLAW_TOKEN = process.env.OPENCLAW_TOKEN || '840913d59243741296520ed68d2cea56b49934b9c84ff738';
const OPENCLAW_BASE_URL = process.env.OPENCLAW_BASE_URL || 'http://127.0.0.1:18789/v1';
const OPENCLAW_AGENT_ID = process.env.OPENCLAW_AGENT_ID || 'main';
const CHAT_MODEL = process.env.CHAT_MODEL || `openclaw/${OPENCLAW_AGENT_ID}`;

// --- SSE live-refresh ---
const sseClients = new Set();

function broadcastSSE(event, data) {
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of sseClients) {
    res.write(msg);
  }
}

// --- Database setup ---
const dataDir = path.join(__dirname, 'data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir);

// Uploads directory — created on startup
const uploadsDir = path.join(dataDir, 'uploads');
if (!fs.existsSync(uploadsDir)) fs.mkdirSync(uploadsDir, { recursive: true });

const db = new Database(path.join(dataDir, 'reviews.db'));
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
  CREATE TABLE IF NOT EXISTS items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    slug TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    markdown TEXT NOT NULL,
    rendered_html TEXT NOT NULL,
    category TEXT DEFAULT 'general',
    status TEXT DEFAULT 'pending',
    decision TEXT,
    actions TEXT,
    feedback TEXT,
    content_hash TEXT,
    mindwtr_task_id TEXT,
    mindwtr_project_id TEXT,
    on_approve TEXT,
    session_key TEXT,
    workspace_dir TEXT,
    source_path TEXT,
    decision_schema_version INTEGER DEFAULT 1,
    action_status TEXT DEFAULT NULL,
    action_message TEXT,
    action_updated_at TEXT,
    tts_status TEXT DEFAULT NULL,
    context_status TEXT DEFAULT NULL,
    context_summary TEXT,
    approval_status TEXT DEFAULT NULL,
    approval_message TEXT,
    approval_exit_code INTEGER,
    approval_updated_at TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
  )
`);

// Migrate: add columns if missing (for existing DBs)
try { db.exec('ALTER TABLE items ADD COLUMN decision TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN actions TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN content_hash TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN mindwtr_task_id TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN mindwtr_project_id TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN on_approve TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN session_key TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN workspace_dir TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN source_path TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN decision_schema_version INTEGER DEFAULT 1'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN action_status TEXT DEFAULT NULL'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN action_message TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN action_updated_at TEXT'); } catch(e) {}
try { db.exec('CREATE INDEX IF NOT EXISTS idx_items_content_hash ON items(content_hash)'); } catch(e) {}
try { db.exec('CREATE INDEX IF NOT EXISTS idx_items_session_key ON items(session_key)'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN tts_status TEXT DEFAULT NULL'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN context_status TEXT DEFAULT NULL'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN context_summary TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN approval_status TEXT DEFAULT NULL'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN approval_message TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN approval_exit_code INTEGER'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN approval_updated_at TEXT'); } catch(e) {}

// --- Annotations table ---
db.exec(`
  CREATE TABLE IF NOT EXISTS annotations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    slug TEXT NOT NULL,
    quote TEXT,
    anchor_type TEXT NOT NULL DEFAULT 'text',
    anchor_ref TEXT,
    comment TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (slug) REFERENCES items(slug)
  )
`);
try { db.exec('CREATE INDEX IF NOT EXISTS idx_annotations_slug ON annotations(slug)'); } catch(e) {}

// C4: Durable decision outbox — notifications survive OpenClaw downtime
db.exec(`
  CREATE TABLE IF NOT EXISTS decision_outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    slug TEXT NOT NULL,
    payload TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    sent_at TEXT,
    created_at TEXT DEFAULT (datetime('now'))
  )
`);
try { db.exec('CREATE INDEX IF NOT EXISTS idx_decision_outbox_pending ON decision_outbox(sent_at, created_at)'); } catch(e) {}

// Backfill content_hash for legacy rows so dedupe works against old data too.
try {
  const legacyRows = db.prepare('SELECT id, title, markdown FROM items WHERE content_hash IS NULL').all();
  const updateContentHash = db.prepare('UPDATE items SET content_hash = ? WHERE id = ?');
  const tx = db.transaction((rows) => {
    for (const row of rows) {
      const hash = crypto.createHash('sha256').update(`${row.title}\n---\n${row.markdown || ''}`, 'utf8').digest('hex');
      updateContentHash.run(hash, row.id);
    }
  });
  tx(legacyRows);
} catch (e) {
  console.error('Failed to backfill content hashes:', e.message);
}

// --- Marked setup ---
const marked = new Marked(
  markedHighlight({
    langPrefix: 'hljs language-',
    highlight(code, lang) {
      if (lang === 'mermaid') return code;
      if (lang && hljs.getLanguage(lang)) {
        return hljs.highlight(code, { language: lang }).value;
      }
      return hljs.highlightAuto(code).value;
    }
  })
);
const _renderer = new marked.Renderer();
_renderer.code = function({ text, lang }) {
  if (lang === 'mermaid') {
    return `<div class="mermaid">${text}</div>`;
  }
  const escaped = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return `<pre><code class="hljs language-${lang || ''}">${escaped}</code></pre>`;
};
marked.setOptions({ gfm: true, breaks: true, renderer: _renderer });

// --- Middleware ---
const session = require('express-session');

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true }));
const publicStatic = express.static(path.join(__dirname, 'public'), { index: false, redirect: false });
app.use((req, res, next) => {
  if (req.path === '/funnel' || req.path === '/funnel/' || req.path === '/funnel/index.html') {
    return next();
  }
  return publicStatic(req, res, next);
});

// --- Chat module ---
const chatModule = createChatModule({
  dataDir: path.join(__dirname, 'data'),
  openclawToken: OPENCLAW_TOKEN,
  openclawBaseUrl: OPENCLAW_BASE_URL,
  openclawAgentId: OPENCLAW_AGENT_ID,
  openaiApiKey: process.env.OPENAI_API_KEY || '',
  chatModel: CHAT_MODEL,
});
const openclawClient = createOpenClawClient({
  token: OPENCLAW_TOKEN,
  baseUrl: OPENCLAW_BASE_URL,
  agentId: OPENCLAW_AGENT_ID,
  model: CHAT_MODEL,
});
app.use('/tts-cache', express.static(path.join(__dirname, 'tts-cache')));
app.use('/audio', express.static(path.join(__dirname, 'data', 'audio')));
app.use('/uploads', express.static(uploadsDir));

app.use(session({
  secret: process.env.SESSION_SECRET, // Required — startup fails if not set
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 30 * 24 * 60 * 60 * 1000 } // 30 days
}));

// Auth: cookie session + Basic Auth fallback (for API calls from scripts)
function auth(req, res, next) {
  const user = process.env.REVIEW_USER;
  const pass = process.env.REVIEW_PASSWORD;
  if (!user || !pass) return next();

  // Already logged in via session
  if (req.session && req.session.authenticated) return next();

  // Basic Auth (for API/curl calls)
  const header = req.headers.authorization;
  if (header && header.startsWith('Basic ')) {
    const [u, p] = Buffer.from(header.split(' ')[1], 'base64').toString().split(':');
    if (u === user && p === pass) return next();
  }

  // Login page routes bypass auth
  if (req.path === '/login') return next();

  // Redirect to login
  return res.redirect('/login');
}

app.use(auth);

function getReviewBaseUrl(req) {
  if (process.env.TURF_REVIEW_BASE_URL) {
    return process.env.TURF_REVIEW_BASE_URL.replace(/\/+$/, '');
  }

  const forwardedProto = req.get('x-forwarded-proto');
  const protocol = forwardedProto ? forwardedProto.split(',')[0].trim() : req.protocol;
  return `${protocol}://${req.get('host')}`;
}

// CSRF protection for form submissions (excludes API routes used by scripts/curl with Basic Auth)
const csrfProtection = csrf({ cookie: false }); // use session-based CSRF tokens

// CSRF token injection for EJS views
app.use((req, res, next) => {
  // Skip CSRF for API routes (API uses Basic Auth), login POST, and safe HTTP methods
  if (req.path.startsWith('/api/') || req.path === '/login') return next();
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) {
    // For GET requests, generate token for forms but don't validate
    csrfProtection(req, res, (err) => {
      // Ignore CSRF errors on GET — just make token available if session exists
      if (err) {
        res.locals.csrfToken = '';
        return next();
      }
      res.locals.csrfToken = req.csrfToken();
      next();
    });
    return;
  }
  // For POST/PUT/DELETE — enforce CSRF validation
  csrfProtection(req, res, (err) => {
    if (err) return next(err);
    res.locals.csrfToken = req.csrfToken();
    next();
  });
});

// Login page
app.get('/login', (req, res) => {
  const error = req.query.error ? 'Invalid username or password' : null;
  res.render('login', { error });
});

app.post('/login', (req, res) => {
  const { username, password } = req.body;
  if (username === process.env.REVIEW_USER && password === process.env.REVIEW_PASSWORD) {
    req.session.authenticated = true;
    return res.redirect(req.query.next || '/');
  }
  return res.redirect('/login?error=1');
});

app.get('/logout', (req, res) => {
  req.session.destroy();
  res.redirect('/login');
});

// --- Helpers ---
function slugify(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

function createContentHash(title, markdown) {
  return crypto.createHash('sha256').update(`${title}\n---\n${markdown || ''}`, 'utf8').digest('hex');
}

function normalizeEventText(text) {
  return (text || '').replace(/\s+/g, ' ').trim();
}

function notifyBenji(payload) {
  return new Promise((resolve, reject) => {
    const { decision, title, slug, feedback, taskId, projectId, sessionKey, actionStatus } = payload;
    const parts = [
      'REVIEW DECIDED',
      `decision="${normalizeEventText(decision)}"`,
      `title="${normalizeEventText(title)}"`,
      `slug="${normalizeEventText(slug)}"`,
    ];
    if (sessionKey) parts.push(`sessionKey="${normalizeEventText(sessionKey)}"`);
    if (actionStatus) parts.push(`actionStatus="${normalizeEventText(actionStatus)}"`);
    if (feedback && normalizeEventText(feedback)) {
      parts.push(`feedback="${normalizeEventText(feedback)}"`);
    }
    if (taskId) parts.push(`taskId="${normalizeEventText(taskId)}"`);
    if (projectId) parts.push(`projectId="${normalizeEventText(projectId)}"`);

    const text = parts.join(' | ');
    execFile('/opt/homebrew/bin/openclaw', ['system', 'event', '--text', text, '--mode', 'now'], {
      env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' }
    }, (err) => {
      if (err) return reject(err);
      resolve();
    });
  });
}

function sanitizeRenderedHtml(rawHtml) {
  return xss(rawHtml, {
    whiteList: {
      a: ['href', 'title', 'target'],
      b: [], strong: [], i: [], em: [], s: [], del: [],
      p: [], br: [], hr: [],
      h1: [], h2: [], h3: [], h4: [], h5: [], h6: [],
      ul: [], ol: [], li: [],
      blockquote: [],
      pre: ['class'], code: ['class'],
      table: [], thead: [], tbody: [], tr: [], th: ['scope'], td: [],
      img: ['src', 'alt', 'title'],
      span: ['class'], div: ['class'],
    },
    stripIgnoreTag: true,
  });
}

function renderSourceDocument({ markdown, html }) {
  const sourceMarkdown = markdown || '';
  const rawHtml = html || marked.parse(sourceMarkdown);
  return {
    markdown: sourceMarkdown,
    rendered_html: sanitizeRenderedHtml(rawHtml),
  };
}

function assertAbsolutePath(value, label) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`${label} is required`);
  }
  if (!path.isAbsolute(value)) {
    throw new Error(`${label} must be an absolute path`);
  }
  return path.resolve(value);
}

function assertPathInside(parentDir, childPath, childLabel) {
  const relative = path.relative(parentDir, childPath);
  if (!relative || relative === '') return;
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`${childLabel} must be inside workspaceDir`);
  }
}

function resolveGitTrackedSource(workspaceDir, sourcePath) {
  const resolvedWorkspaceDir = assertAbsolutePath(workspaceDir, 'workspaceDir');
  const resolvedSourcePath = assertAbsolutePath(sourcePath, 'sourcePath');
  assertPathInside(resolvedWorkspaceDir, resolvedSourcePath, 'sourcePath');

  let gitRoot;
  try {
    gitRoot = execFileSync('git', ['-C', resolvedWorkspaceDir, 'rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  } catch (_error) {
    throw new Error('workspaceDir must be inside a git repository');
  }

  const relativeToGitRoot = path.relative(gitRoot, resolvedSourcePath);
  if (relativeToGitRoot.startsWith('..') || path.isAbsolute(relativeToGitRoot)) {
    throw new Error('sourcePath must be inside the git repository for workspaceDir');
  }

  try {
    execFileSync('git', ['-C', gitRoot, 'ls-files', '--error-unmatch', relativeToGitRoot], {
      stdio: ['ignore', 'ignore', 'pipe'],
    });
  } catch (_error) {
    throw new Error('sourcePath must point to a git-tracked file');
  }

  return {
    gitRoot,
    workspaceDir: resolvedWorkspaceDir,
    sourcePath: resolvedSourcePath,
    relativeToGitRoot,
  };
}

function readSourceDocument(sourcePath) {
  return fs.readFileSync(sourcePath, 'utf8');
}

function buildGitReviewUrl(slug) {
  return `/review/${slug}`;
}

// --- Read Aloud TTS (Edge TTS) ---
function stripMarkdownToPlain(text) {
  return (text || '')
    .replace(/<[^>]*>/g, '')
    .replace(/#{1,6}\s*/g, '')
    .replace(/\*{1,3}([^*]+)\*{1,3}/g, '$1')
    .replace(/`{1,3}[^`]*`{1,3}/g, '')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/!\[.*?\]\(.*?\)/g, '')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/^\s*\d+\.\s+/gm, '')
    .replace(/^\s*>\s*/gm, '')
    .replace(/---+/g, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

const activeTtsJobs = new Set();
const activeContextJobs = new Set();

function chunkTextForSpeech(text, chunkSize = 4000) {
  const chunks = [];
  let remaining = (text || '').trim();
  while (remaining.length > 0) {
    if (remaining.length <= chunkSize) {
      chunks.push(remaining);
      break;
    }

    let cutPoint = remaining.lastIndexOf('. ', chunkSize);
    if (cutPoint < chunkSize * 0.5) cutPoint = remaining.lastIndexOf(' ', chunkSize);
    if (cutPoint < 1) cutPoint = chunkSize;

    chunks.push(remaining.substring(0, cutPoint + 1));
    remaining = remaining.substring(cutPoint + 1).trimStart();
  }
  return chunks;
}

function safeUnlink(filePath) {
  if (!filePath) return;
  try {
    fs.unlinkSync(filePath);
  } catch (err) {
    if (err.code !== 'ENOENT') {
      console.warn(`[fs] Failed to remove ${filePath}: ${err.message}`);
    }
  }
}

async function synthesizeSpeechToFile({ text, slug, prefix, outputPath }) {
  const chunks = chunkTextForSpeech(text);
  const chunkFiles = [];
  const tempTextFiles = [];

  try {
    for (let i = 0; i < chunks.length; i += 1) {
      const tmpFile = path.join(os.tmpdir(), `${prefix}-${slug}-${Date.now()}-${i}.txt`);
      const chunkOut = path.join(os.tmpdir(), `${prefix}-${slug}-${Date.now()}-${i}.mp3`);
      tempTextFiles.push(tmpFile);
      fs.writeFileSync(tmpFile, chunks[i], 'utf8');

      await execFileAsync('/opt/homebrew/bin/edge-tts', [
        '-v', 'en-GB-RyanNeural',
        '-f', tmpFile,
        '--write-media', chunkOut,
      ], {
        timeout: 120000,
        stdio: 'ignore',
      });

      chunkFiles.push(chunkOut);
      safeUnlink(tmpFile);
    }

    if (chunkFiles.length === 0) {
      throw new Error('No audio chunks were generated');
    }

    safeUnlink(outputPath);

    if (chunkFiles.length === 1) {
      fs.renameSync(chunkFiles[0], outputPath);
    } else {
      const listFile = path.join(os.tmpdir(), `${prefix}-${slug}-${Date.now()}-list.txt`);
      fs.writeFileSync(listFile, chunkFiles.map((file) => `file '${file.replace(/'/g, "'\\''")}'`).join('\n'), 'utf8');
      try {
        await execFileAsync('/opt/homebrew/bin/ffmpeg', [
          '-y',
          '-f', 'concat',
          '-safe', '0',
          '-i', listFile,
          '-c', 'copy',
          outputPath,
        ], {
          timeout: 60000,
          stdio: 'ignore',
        });
      } finally {
        safeUnlink(listFile);
      }
    }
  } finally {
    tempTextFiles.forEach(safeUnlink);
    chunkFiles.forEach((file) => {
      if (file !== outputPath) safeUnlink(file);
    });
  }

  if (!fs.existsSync(outputPath)) {
    throw new Error(`Expected audio output missing at ${outputPath}`);
  }
}

function reconcileInterruptedAudioJobs() {
  const rows = db.prepare(`
    SELECT slug, tts_status, context_status
    FROM items
    WHERE tts_status = 'generating' OR context_status = 'generating'
  `).all();

  for (const row of rows) {
    const ttsPath = path.join(ttsCacheDir, `${row.slug}.mp3`);
    const contextPath = path.join(__dirname, 'data', 'audio', `${row.slug}.mp3`);

    if (row.tts_status === 'generating') {
      db.prepare('UPDATE items SET tts_status = ? WHERE slug = ?')
        .run(fs.existsSync(ttsPath) ? 'ready' : 'failed', row.slug);
    }

    if (row.context_status === 'generating') {
      db.prepare('UPDATE items SET context_status = ? WHERE slug = ?')
        .run(fs.existsSync(contextPath) ? 'ready' : 'failed', row.slug);
    }
  }
}

function resolveAudioStatus(item, kind) {
  if (!item) return item;

  const statusKey = kind === 'tts' ? 'tts_status' : 'context_status';
  const activeJobs = kind === 'tts' ? activeTtsJobs : activeContextJobs;
  const outputPath = kind === 'tts'
    ? path.join(ttsCacheDir, `${item.slug}.mp3`)
    : path.join(__dirname, 'data', 'audio', `${item.slug}.mp3`);

  if (item[statusKey] !== 'generating') return item;

  if (fs.existsSync(outputPath)) {
    db.prepare(`UPDATE items SET ${statusKey} = 'ready' WHERE slug = ?`).run(item.slug);
    return { ...item, [statusKey]: 'ready' };
  }

  if (!activeJobs.has(item.slug)) {
    db.prepare(`UPDATE items SET ${statusKey} = 'failed' WHERE slug = ?`).run(item.slug);
    return { ...item, [statusKey]: 'failed' };
  }

  return item;
}

function updateActionState(slug, status, message = null, exitCode = null) {
  db.prepare(`
    UPDATE items
    SET action_status = @status,
        action_message = @message,
        action_updated_at = datetime('now'),
        approval_status = @status,
        approval_message = @message,
        approval_exit_code = @exit_code,
        approval_updated_at = datetime('now')
    WHERE slug = @slug
  `).run({
    slug,
    status,
    message,
    exit_code: exitCode,
  });
}

function generateReadAloudTTS(slug) {
  const item = db.prepare('SELECT * FROM items WHERE slug = ?').get(slug);
  if (!item) {
    console.error(`[tts] Item not found: ${slug}`);
    return;
  }

  const plainText = stripMarkdownToPlain(item.markdown || item.rendered_html);
  if (!plainText) {
    db.prepare("UPDATE items SET tts_status = 'failed' WHERE slug = ?").run(slug);
    return;
  }

  if (plainText.length < MIN_TTS_CHARS) {
    db.prepare("UPDATE items SET tts_status = 'skipped' WHERE slug = ?").run(slug);
    safeUnlink(path.join(ttsCacheDir, `${slug}.mp3`));
    console.log(`[tts] Skipped short item for ${slug} (${plainText.length} chars)`);
    return;
  }

  const cachePath = path.join(ttsCacheDir, `${slug}.mp3`);
  const chunks = chunkTextForSpeech(plainText);

  console.log(`[tts] Generating ${chunks.length} chunk(s) for ${slug} (${plainText.length} chars)`);

  activeTtsJobs.add(slug);
  setImmediate(async () => {
    try {
      await synthesizeSpeechToFile({ text: plainText, slug, prefix: 'tts', outputPath: cachePath });
      db.prepare("UPDATE items SET tts_status = 'ready' WHERE slug = ?").run(slug);
      console.log(`[tts] Ready: ${slug} (${chunks.length} chunks merged)`);
    } catch (err) {
      db.prepare("UPDATE items SET tts_status = 'failed' WHERE slug = ?").run(slug);
      console.error(`[tts] Error for ${slug}:`, err.message);
    } finally {
      activeTtsJobs.delete(slug);
    }
  });
}

// --- Context Voice Memo (AI summary → Edge TTS) ---
function generateContextMemo(slug) {
  const item = db.prepare('SELECT * FROM items WHERE slug = ?').get(slug);
  if (!item) {
    console.error(`[context] Item not found: ${slug}`);
    return;
  }

  const plainText = stripMarkdownToPlain(item.markdown || item.rendered_html);
  if (!plainText) {
    db.prepare("UPDATE items SET context_status = 'failed' WHERE slug = ?").run(slug);
    return;
  }

  const audioDir = path.join(__dirname, 'data', 'audio');
  if (!fs.existsSync(audioDir)) fs.mkdirSync(audioDir, { recursive: true });
  const audioPath = path.join(audioDir, `${slug}.mp3`);

  activeContextJobs.add(slug);
  setImmediate(async () => {
    try {
      // Step 1: Generate summary via OpenAI
      const completion = await openai.chat.completions.create({
        model: 'gpt-5-mini',
        messages: [
          {
            role: 'system',
            content: 'You are generating a brief spoken audio summary for a business review document. Summarize what this document is about, what decision is needed, and key points — in a conversational tone as if briefing someone. Keep it under 100 words.'
          },
          { role: 'user', content: plainText.substring(0, 12000) }
        ],
        // max_completion_tokens removed — gpt-5-mini rejects it via SDK v6.25 (maps to max_tokens internally)
      });

      const summary = completion.choices[0].message.content.trim();
      if (!summary) {
        db.prepare("UPDATE items SET context_status = 'failed' WHERE slug = ?").run(slug);
        return;
      }

      // Store the summary text
      db.prepare("UPDATE items SET context_summary = ? WHERE slug = ?").run(summary, slug);
      const chunks = chunkTextForSpeech(summary);

      console.log(`[context] Generating TTS for ${slug} (${summary.length} chars)`);

      await synthesizeSpeechToFile({ text: summary, slug, prefix: 'ctx', outputPath: audioPath });
      db.prepare("UPDATE items SET context_status = 'ready' WHERE slug = ?").run(slug);
      console.log(`[context] Ready: ${slug}`);
    } catch (err) {
      db.prepare("UPDATE items SET context_status = 'failed' WHERE slug = ?").run(slug);
      console.error(`[context] Error for ${slug}:`, err.message);
    } finally {
      activeContextJobs.delete(slug);
    }
  });
}

function getActions(item) {
  const actions = getAllowedActionsForItem(item);
  if (actions.length) return actions;

  const canonical = getCanonicalActions(item?.category);
  return canonical ? [...canonical] : [];
}

function buildReviewUrl(baseUrl, slug) {
  return new URL(`/review/${slug}`, baseUrl).toString();
}

async function appendSessionNote(item, kind, payload) {
  if (!openclawClient || !item) return null;
  const sessionKey = item.session_key || getSessionKey(item.slug);
  const notePayload = (payload && typeof payload === 'object' && !Array.isArray(payload))
    ? {
        responseInstruction: 'Reply only with an internal Turf Review message. Do not produce any user-facing text.',
        ...payload,
      }
    : payload;
  const content = buildInternalMessage(kind, notePayload);
  return openclawClient.appendInternalMessage({ sessionKey, content });
}

async function seedSessionForItem(item, reviewUrl, reason = 'bootstrap') {
  const sourceMapping = {
    workspaceDir: item.workspace_dir,
    sourcePath: item.source_path,
  };

  return appendSessionNote(item, reason, {
    instruction: 'Read the full document now and build a working understanding before Jimmy opens chat. Produce only an internal Turf Review note with your private digest of the document, key intent, risks, and any ambiguities. Do not send any user-facing text until Jimmy chats with this review or triggers a decision.',
    bootstrapChecklist: [
      'Read the full document body in this bootstrap payload.',
      'Summarize the document intent and the main points privately.',
      'Note likely review risks, execution concerns, or ambiguities privately.',
      'Keep the result internal-only; do not speak to Jimmy yet.',
    ],
    title: item.title,
    slug: item.slug,
    category: item.category,
    reviewUrl,
    source: sourceMapping,
    document: item.markdown || item.rendered_html,
  });
}

async function mirrorAnnotationToSession(item, annotation, reviewUrl) {
  return appendSessionNote(item, 'annotation', {
    reviewUrl,
    annotation: {
      id: annotation.id,
      createdAt: annotation.created_at,
      anchorType: annotation.anchor_type,
      anchorRef: annotation.anchor_ref,
      quote: annotation.quote,
      comment: annotation.comment,
    },
  });
}

function parseInternalResultText(text) {
  const normalized = String(text || '').trim();
  const match = normalized.match(/^\[TURF_REVIEW_INTERNAL\][^\n]*\n?([\s\S]*)$/);
  const payload = match ? match[1].trim() : normalized;
  if (!payload) return null;
  try {
    return JSON.parse(payload);
  } catch (_error) {
    return null;
  }
}

async function runStructuredSessionAction(item, kind, payload) {
  const instructionsByKind = {
    execute: 'If you can complete the work from the linked workspace and source context, do so. If not, return blocked with a concise reason that Jimmy needs to resolve.',
    edit: 'Revise the linked source file using the review feedback and annotations. Return the full replacement file contents in updatedSource.',
    rework: 'Revise the linked source file using the review feedback and annotations. Return the full replacement file contents in updatedSource.',
  };

  const completion = await appendSessionNote(item, kind, {
    instructions: instructionsByKind[kind] || 'Handle the requested action using the linked review context.',
    contract: payload,
    responseFormat: {
      instruction: 'Reply with an internal message only. The response body after the first newline must be valid JSON.',
      schema: {
        status: 'succeeded | blocked | failed',
        summary: 'short human-readable summary',
        updatedSource: 'optional full replacement file contents',
        commitMessage: 'optional git commit message',
      },
    },
  });

  const parsed = parseInternalResultText(completion?.text || '');
  if (parsed) return parsed;

  return {
    status: 'blocked',
    summary: 'OpenClaw did not return a structured internal result',
  };
}

function gitCommitIfNeeded(workspaceDir, sourcePath, commitMessage) {
  const relativePath = path.relative(workspaceDir, sourcePath);
  execFileSync('git', ['-C', workspaceDir, 'add', relativePath], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });

  let hasChanges = true;
  try {
    execFileSync('git', ['-C', workspaceDir, 'diff', '--cached', '--quiet', '--', relativePath], {
      stdio: 'ignore',
    });
    hasChanges = false;
  } catch (error) {
    if (typeof error.status === 'number' && error.status === 1) {
      hasChanges = true;
    } else {
      throw error;
    }
  }

  if (!hasChanges) return false;

  execFileSync('git', ['-C', workspaceDir, 'commit', '-m', commitMessage || `Update ${path.basename(sourcePath)} from Turf Review`], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  return true;
}

function republishItemFromSource(item) {
  const sourceText = readSourceDocument(item.source_path);
  const ext = path.extname(item.source_path).toLowerCase();
  const rendered = renderSourceDocument({
    markdown: ext === '.html' || ext === '.htm' ? '' : sourceText,
    html: ext === '.html' || ext === '.htm' ? sourceText : null,
  });
  const contentHash = createContentHash(item.title, rendered.markdown || sourceText);

  db.prepare(`
    UPDATE items
    SET markdown = @markdown,
        rendered_html = @rendered_html,
        content_hash = @content_hash,
        status = 'pending',
        decision = NULL,
        feedback = NULL,
        actions = @actions,
        action_status = NULL,
        action_message = NULL,
        action_updated_at = NULL,
        approval_status = NULL,
        approval_message = NULL,
        approval_exit_code = NULL,
        approval_updated_at = NULL,
        decision_schema_version = @decision_schema_version,
        updated_at = datetime('now')
    WHERE slug = @slug
  `).run({
    slug: item.slug,
    markdown: rendered.markdown,
    rendered_html: rendered.rendered_html,
    content_hash: contentHash,
    actions: JSON.stringify(getCanonicalActions(item.category)),
    decision_schema_version: DECISION_SCHEMA_VERSION,
  });

  const refreshed = stmts.getBySlug.get(item.slug);
  const plainText = stripMarkdownToPlain(refreshed.markdown || refreshed.rendered_html);
  if (plainText.length >= MIN_TTS_CHARS) {
    db.prepare(`UPDATE items SET tts_status = 'generating' WHERE slug = ?`).run(item.slug);
    generateReadAloudTTS(item.slug);
  } else {
    db.prepare(`UPDATE items SET tts_status = 'skipped' WHERE slug = ?`).run(item.slug);
  }

  db.prepare(`UPDATE items SET context_status = 'generating' WHERE slug = ?`).run(item.slug);
  generateContextMemo(item.slug);

  return refreshed;
}

// --- Prepared statements ---
const stmts = {
  insert: db.prepare(`
    INSERT INTO items (
      slug, title, markdown, rendered_html, category, actions, content_hash,
      mindwtr_task_id, mindwtr_project_id, on_approve, session_key, workspace_dir,
      source_path, decision_schema_version
    )
    VALUES (
      @slug, @title, @markdown, @rendered_html, @category, @actions, @content_hash,
      @mindwtr_task_id, @mindwtr_project_id, @on_approve, @session_key, @workspace_dir,
      @source_path, @decision_schema_version
    )
  `),
  getByContentHash: db.prepare('SELECT slug FROM items WHERE content_hash = ? ORDER BY created_at ASC LIMIT 1'),
  getBySlug: db.prepare('SELECT * FROM items WHERE slug = ?'),
  listAll: db.prepare(`
    SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
           session_key, workspace_dir, source_path, decision_schema_version,
           action_status, action_message, approval_status, approval_message, approval_exit_code,
           LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
           created_at, updated_at
    FROM items
    ORDER BY created_at DESC
  `),
  listByStatus: db.prepare(`
    SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
           session_key, workspace_dir, source_path, decision_schema_version,
           action_status, action_message, approval_status, approval_message, approval_exit_code,
           LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
           created_at, updated_at
    FROM items
    WHERE status = ?
    ORDER BY created_at DESC
  `),
  listByCategory: db.prepare(`
    SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
           session_key, workspace_dir, source_path, decision_schema_version,
           action_status, action_message, approval_status, approval_message, approval_exit_code,
           LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
           created_at, updated_at
    FROM items
    WHERE category = ?
    ORDER BY created_at DESC
  `),
  listByStatusAndCategory: db.prepare(`
    SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
           session_key, workspace_dir, source_path, decision_schema_version,
           action_status, action_message, approval_status, approval_message, approval_exit_code,
           LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
           created_at, updated_at
    FROM items
    WHERE status = ? AND category = ?
    ORDER BY created_at DESC
  `),
  decide: db.prepare(`
    UPDATE items
    SET status = @status,
        decision = @decision,
        feedback = @feedback,
        action_status = @action_status,
        action_message = @action_message,
        action_updated_at = datetime('now'),
        approval_status = @action_status,
        approval_message = @action_message,
        approval_exit_code = NULL,
        approval_updated_at = datetime('now'),
        updated_at = datetime('now')
    WHERE slug = @slug
  `),
  dismiss: db.prepare(`UPDATE items SET status = 'dismissed', decision = 'Dismissed', updated_at = datetime('now') WHERE slug = @slug`),
  enqueueOutbox: db.prepare(`INSERT INTO decision_outbox (slug, payload) VALUES (@slug, @payload)`),
  listPendingOutbox: db.prepare(`SELECT id, payload FROM decision_outbox WHERE sent_at IS NULL ORDER BY created_at ASC, id ASC LIMIT @limit`),
  markOutboxSent: db.prepare(`UPDATE decision_outbox SET attempts = attempts + 1, last_error = NULL, sent_at = datetime('now') WHERE id = @id`),
  markOutboxFailed: db.prepare(`UPDATE decision_outbox SET attempts = attempts + 1, last_error = @last_error WHERE id = @id`),
};

const funnelDashboard = createFunnelDashboardService({ reviewDb: db });

// --- SSE endpoint (auth-protected) ---
app.get('/api/events', auth, (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });
  res.write(':ok\n\n');
  sseClients.add(res);
  req.on('close', () => sseClients.delete(res));
});

app.get('/api/funnel/health', (_req, res) => {
  res.json({
    ok: true,
    service: 'turfterrace-funnel',
    generatedAt: new Date().toISOString(),
  });
});

app.get('/api/funnel/dashboard', async (req, res) => {
  const reviewBaseUrl = getReviewBaseUrl(req);
  const fresh = req.query.fresh === '1';

  try {
    const payload = await funnelDashboard.getDashboardData({
      force: fresh,
      reviewBaseUrl,
    });
    res.json(payload);
  } catch (error) {
    const cachedPayload = funnelDashboard.getCachedPayload(reviewBaseUrl);
    const detail = error instanceof Error ? error.message : 'Unknown error';

    if (cachedPayload) {
      return res.json({
        ...cachedPayload,
        warnings: [...cachedPayload.warnings, `Live refresh failed. Showing cached data instead: ${detail}`],
      });
    }

    res.status(503).json({
      error: 'Dashboard data unavailable',
      detail,
    });
  }
});

function listAnnotationsForSlug(slug) {
  return db.prepare('SELECT * FROM annotations WHERE slug = ? ORDER BY created_at ASC').all(slug);
}

async function createOmniFocusInboxItem(item, reviewUrl, feedback, annotations) {
  const noteParts = [
    `Review: ${reviewUrl}`,
    `Source: ${item.source_path}`,
  ];

  if (feedback) {
    noteParts.push(`Feedback:\n${feedback}`);
  }

  if (annotations.length > 0) {
    noteParts.push(`Annotations:\n${annotations.map((annotation) => {
      if (annotation.anchor_type === 'image') {
        return `- [image ${annotation.anchor_ref || ''}] ${annotation.comment}`;
      }
      return `- "${annotation.quote || ''}" -> ${annotation.comment}`;
    }).join('\n')}`);
  }

  await execFileAsync('/Users/username/.bun/bin/of', [
    'task',
    'create',
    item.title,
    '--note',
    noteParts.join('\n\n'),
  ], {
    env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' },
    timeout: 30000,
  });
}

async function routeDecisionAction(item, { decision, feedback, annotations, reviewUrl }) {
  const freshItem = stmts.getBySlug.get(item.slug) || item;

  await appendSessionNote(freshItem, 'decision', {
    decision,
    feedback,
    reviewUrl,
    source: {
      workspaceDir: freshItem.workspace_dir,
      sourcePath: freshItem.source_path,
    },
    annotations,
  });

  switch (decision) {
    case 'Kill':
      updateActionState(item.slug, 'succeeded', 'Killed and archived.');
      return;
    case 'Noted':
      updateActionState(item.slug, 'succeeded', 'Noted and archived.');
      return;
    case 'Park':
      updateActionState(item.slug, 'succeeded', 'Parked.');
      return;
    case 'Send':
      updateActionState(item.slug, 'succeeded', 'Queued for downstream outreach send handling.');
      return;
    case 'Inbox':
      updateActionState(item.slug, 'running', 'Creating OmniFocus inbox item...');
      await createOmniFocusInboxItem(freshItem, reviewUrl, feedback, annotations);
      updateActionState(item.slug, 'succeeded', 'OmniFocus inbox item created.');
      return;
    case 'Execute': {
      updateActionState(item.slug, 'running', 'Executing from the linked workspace...');
      const result = await runStructuredSessionAction(freshItem, 'execute', {
        title: freshItem.title,
        category: freshItem.category,
        reviewUrl,
        workspaceDir: freshItem.workspace_dir,
        sourcePath: freshItem.source_path,
        feedback,
        annotations,
        document: freshItem.markdown || freshItem.rendered_html,
      });
      updateActionState(item.slug, result.status || 'blocked', result.summary || 'Execution did not report a result.');
      if ((result.status || 'blocked') !== 'succeeded') {
        await notifyBenji({
          decision,
          title: freshItem.title,
          slug: freshItem.slug,
          feedback,
          sessionKey: freshItem.session_key || getSessionKey(freshItem.slug),
          actionStatus: result.status || 'blocked',
        });
      }
      return;
    }
    case 'Edit':
    case 'Rework': {
      updateActionState(item.slug, 'running', `${decision} is applying changes to the source file...`);
      const sourceBefore = readSourceDocument(freshItem.source_path);
      const result = await runStructuredSessionAction(freshItem, decision.toLowerCase(), {
        title: freshItem.title,
        category: freshItem.category,
        reviewUrl,
        workspaceDir: freshItem.workspace_dir,
        sourcePath: freshItem.source_path,
        feedback,
        annotations,
        document: sourceBefore,
      });

      if ((result.status || 'blocked') !== 'succeeded' || typeof result.updatedSource !== 'string') {
        updateActionState(item.slug, result.status || 'blocked', result.summary || `${decision} did not produce updated source content.`);
        if ((result.status || 'blocked') !== 'succeeded') {
          await notifyBenji({
            decision,
            title: freshItem.title,
            slug: freshItem.slug,
            feedback,
            sessionKey: freshItem.session_key || getSessionKey(freshItem.slug),
            actionStatus: result.status || 'blocked',
          });
        }
        return;
      }

      fs.writeFileSync(freshItem.source_path, result.updatedSource, 'utf8');
      gitCommitIfNeeded(
        freshItem.workspace_dir,
        freshItem.source_path,
        result.commitMessage || `Turf Review ${decision.toLowerCase()}: ${freshItem.title}`
      );

      const republished = republishItemFromSource(freshItem);
      await seedSessionForItem(republished, reviewUrl, 'refresh');
      broadcastSSE('republished', { slug: republished.slug, title: republished.title });
      return;
    }
    default:
      updateActionState(item.slug, 'failed', `Unsupported decision: ${decision}`);
  }
}

// --- API Routes ---

// Publish a new review item (markdown or raw HTML)
app.post('/api/publish', (req, res) => {
  try {
    const {
      title,
      markdown,
      html,
      slug: rawSlug,
      category,
      actions,
      taskId,
      projectId,
      onApprove,
      workspaceDir,
      sourcePath,
    } = req.body;

    if (!title || (!markdown && !html)) {
      return res.status(400).json({ error: 'title and (markdown or html) are required' });
    }

    const normalizedCategory = normalizeCategory(category);
    if (!ALLOWED_CATEGORIES.has(normalizedCategory)) {
      return res.status(400).json({ error: 'Invalid category. Allowed: kitchenlux, outreach, admin, general' });
    }

    const canonicalActions = getCanonicalActions(normalizedCategory);
    if (actions && !arraysMatchExactly(actions, canonicalActions)) {
      return res.status(400).json({
        error: `actions must exactly match the canonical set for ${normalizedCategory}: ${canonicalActions.join(', ')}`,
      });
    }

    let resolvedSource;
    try {
      resolvedSource = resolveGitTrackedSource(workspaceDir, sourcePath);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }

    const content_hash = createContentHash(title, markdown || html || '');
    const existing = stmts.getByContentHash.get(content_hash);
    if (existing) {
      return res.status(200).json({ slug: existing.slug, url: `/review/${existing.slug}`, deduped: true });
    }

    const slug = rawSlug ? slugify(rawSlug) : slugify(title) + '-' + Date.now().toString(36);
    const rendered = renderSourceDocument({ markdown, html });
    const actionsJson = JSON.stringify(canonicalActions);
    const sessionKey = getSessionKey(slug);

    stmts.insert.run({
      slug,
      title,
      markdown: rendered.markdown,
      rendered_html: rendered.rendered_html,
      category: normalizedCategory,
      actions: actionsJson,
      content_hash,
      mindwtr_task_id: taskId || null,
      mindwtr_project_id: projectId || null,
      on_approve: onApprove || null,
      session_key: sessionKey,
      workspace_dir: resolvedSource.workspaceDir,
      source_path: resolvedSource.sourcePath,
      decision_schema_version: DECISION_SCHEMA_VERSION,
    });

    const plainText = stripMarkdownToPlain(rendered.markdown || rendered.rendered_html);
    if (plainText.length >= MIN_TTS_CHARS) {
      db.prepare(`UPDATE items SET tts_status = 'generating' WHERE slug = ?`).run(slug);
      generateReadAloudTTS(slug);
    } else {
      db.prepare(`UPDATE items SET tts_status = 'skipped' WHERE slug = ?`).run(slug);
    }

    // Auto-generate context voice memo (AI summary → Edge TTS, async)
    db.prepare(`UPDATE items SET context_status = 'generating' WHERE slug = ?`).run(slug);
    generateContextMemo(slug);

    // Broadcast live-refresh event to all connected dashboards
    broadcastSSE('new-item', { slug, title, category: normalizedCategory });

    const reviewBaseUrl = getReviewBaseUrl(req);
    const reviewUrl = buildReviewUrl(reviewBaseUrl, slug);
    const item = stmts.getBySlug.get(slug);

    setImmediate(async () => {
      try {
        await seedSessionForItem(item, reviewUrl);
      } catch (error) {
        console.error(`[publish] Failed to seed session for ${slug}: ${error.message}`);
      }
    });

    res.status(201).json({
      slug,
      url: `/review/${slug}`,
      deduped: false,
      sessionKey,
      actions: canonicalActions,
    });
  } catch (err) {
    if (err.message.includes('UNIQUE constraint')) {
      return res.status(409).json({ error: 'Slug already exists' });
    }
    res.status(500).json({ error: err.message });
  }
});

// List items
app.get('/api/items', (req, res) => {
  const { status, category } = req.query;
  let items;
  if (status && category) {
    items = stmts.listByStatusAndCategory.all(status, category);
  } else if (status) {
    items = stmts.listByStatus.all(status);
  } else if (category) {
    items = stmts.listByCategory.all(category);
  } else {
    items = stmts.listAll.all();
  }
  res.json(items);
});

// Get single item
app.get('/api/items/:slug', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });
  res.json(item);
});

// Decide — unified action endpoint
app.post('/api/items/:slug/decide', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });

  const { decision, feedback } = req.body;
  if (!decision) return res.status(400).json({ error: 'decision is required' });
  if (!isAllowedDecision(item, decision)) {
    return res.status(400).json({
      error: `Invalid decision for ${item.category}. Allowed: ${getActions(item).join(', ')}`,
    });
  }

  const resolvedFeedback = typeof feedback === 'string' ? feedback : (item.feedback || null);
  const annotations = listAnnotationsForSlug(req.params.slug);
  const actionStatus = getInitialActionStatus(decision);
  const reviewUrl = buildReviewUrl(getReviewBaseUrl(req), req.params.slug);
  const payload = {
    decision,
    title: item.title,
    slug: req.params.slug,
    feedback: resolvedFeedback,
    taskId: item.mindwtr_task_id,
    projectId: item.mindwtr_project_id,
    onApprove: item.on_approve,
    sessionKey: item.session_key || getSessionKey(item.slug),
    workspaceDir: item.workspace_dir,
    sourcePath: item.source_path,
    annotations,
    actionStatus,
  };

  // Transactional: update item + enqueue notification
  const txDecide = db.transaction(() => {
    stmts.decide.run({
      slug: req.params.slug,
      status: getStoredStatusForDecision(decision),
      decision,
      feedback: resolvedFeedback,
      action_status: actionStatus,
      action_message: actionStatus === 'queued' ? `Queued ${decision} action.` : `${decision} saved.`,
    });
    stmts.enqueueOutbox.run({ slug: req.params.slug, payload: JSON.stringify(payload) });
  });
  txDecide();

  // Broadcast live-refresh event for decision
  broadcastSSE('decision', {
    slug: req.params.slug,
    decision,
    title: item.title,
    status: getStoredStatusForDecision(decision),
  });

  // Fire async drain (best-effort immediate delivery for system event notification)
  void drainDecisionOutbox();

  res.json({
    status: getStoredStatusForDecision(decision),
    decision,
    slug: req.params.slug,
    queued: actionStatus === 'queued',
    processed: actionStatus !== 'queued',
    sessionKey: payload.sessionKey,
    action: {
      status: actionStatus,
      message: actionStatus === 'queued' ? `Queued ${decision} action.` : `${decision} saved.`,
    },
  });

  // Fire-and-forget after the response is on the wire so Jimmy's tap stays snappy.
  setImmediate(async () => {
    try {
      if (actionStatus === 'queued') {
        updateActionState(req.params.slug, 'running', `Running ${decision} action...`);
      }
      await routeDecisionAction(item, {
        decision,
        feedback: resolvedFeedback,
        annotations,
        reviewUrl,
      });
      const latest = stmts.getBySlug.get(req.params.slug);
      broadcastSSE('approval', {
        slug: req.params.slug,
        status: latest?.action_status || null,
      });
    } catch (error) {
      console.error(`[decision-router] ${req.params.slug}: ${error.message}`);
      updateActionState(req.params.slug, 'failed', error.message || 'Decision routing failed.');
      broadcastSSE('approval', {
        slug: req.params.slug,
        status: 'failed',
      });
    }
  });
});

// POST /api/items/:slug/dismiss — one-click remove from queue
app.post('/api/items/:slug/dismiss', (req, res) => {
  try {
    const result = stmts.dismiss.run({ slug: req.params.slug });
    if (result.changes === 0) return res.status(404).json({ error: 'Item not found' });
    res.json({ ok: true, slug: req.params.slug, status: 'dismissed' });
  } catch (err) {
    console.error('Dismiss error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Deprecated compatibility endpoints
app.post('/api/items/:slug/approve', (req, res) => {
  return res.status(410).json({
    error: 'Legacy approve endpoint removed. Use POST /api/items/:slug/decide with a canonical category decision.',
  });
});
app.post('/api/items/:slug/reject', (req, res) => {
  return res.status(410).json({
    error: 'Legacy reject endpoint removed. Use POST /api/items/:slug/decide with a canonical category decision.',
  });
});

// Transcribe audio via OpenAI Whisper API
app.post('/api/transcribe', upload.single('audio'), async (req, res) => {
  try {
    if (!req.file) return res.status(400).json({ error: 'No audio file' });

    const audioFile = new File([req.file.buffer], 'audio.webm', { type: req.file.mimetype });

    const transcription = await openai.audio.transcriptions.create({
      model: 'whisper-1',
      file: audioFile,
      language: 'en',
    });

    res.json({ text: transcription.text });
  } catch (err) {
    console.error('Transcription error:', err.message);
    res.status(500).json({ error: 'Transcription failed: ' + err.message });
  }
});

// --- Image upload endpoints ---

// Multer instance for image uploads (memory storage, 10MB per file)
const imageUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024, files: 20 },
  fileFilter: (req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase();
    if (ALLOWED_IMAGE_MIMES.has(file.mimetype) || ALLOWED_IMAGE_EXTS.has(ext)) {
      cb(null, true);
    } else {
      cb(new Error(`Unsupported file type: ${file.mimetype}`));
    }
  },
});

function saveUploadedImage(buffer, originalName) {
  const ext = path.extname(originalName).toLowerCase() || '.png';
  const safeName = crypto.randomUUID() + ext;
  const dest = path.join(uploadsDir, safeName);
  fs.writeFileSync(dest, buffer);
  return { filename: safeName, url: `/uploads/${safeName}` };
}

// POST /api/upload — multipart form upload (one or many files)
app.post('/api/upload', imageUpload.array('file', 20), (req, res) => {
  try {
    if (!req.files || req.files.length === 0) {
      return res.status(400).json({ error: 'No files provided. Use field name "file".' });
    }
    const results = req.files.map((f) => saveUploadedImage(f.buffer, f.originalname));
    // Single file → unwrap for convenience; multiple → return array
    if (results.length === 1) {
      return res.status(201).json(results[0]);
    }
    return res.status(201).json({ files: results });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /api/upload-base64 — programmatic upload (scripts, publish-review.sh)
// Body: { "filename": "name.png", "data": "<base64 string>" }
app.post('/api/upload-base64', (req, res) => {
  try {
    const { filename, data } = req.body;
    if (!filename || !data) {
      return res.status(400).json({ error: 'filename and data (base64) are required' });
    }
    const ext = path.extname(filename).toLowerCase();
    if (!ALLOWED_IMAGE_EXTS.has(ext)) {
      return res.status(400).json({ error: `Unsupported extension: ${ext}. Allowed: png, jpg, jpeg, gif, webp` });
    }
    // Strip optional data: URI prefix
    const base64Data = data.replace(/^data:[^;]+;base64,/, '');
    const buffer = Buffer.from(base64Data, 'base64');
    if (buffer.length > 10 * 1024 * 1024) {
      return res.status(400).json({ error: 'File exceeds 10MB limit' });
    }
    const result = saveUploadedImage(buffer, filename);
    return res.status(201).json(result);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// --- Annotation endpoints ---
app.post('/api/items/:slug/annotate', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });

  const { quote, anchor_type, anchor_ref, comment } = req.body;
  if (!comment || !comment.trim()) {
    return res.status(400).json({ error: 'comment is required' });
  }

  const type = anchor_type === 'image' ? 'image' : 'text';
  const result = db.prepare(`
    INSERT INTO annotations (slug, quote, anchor_type, anchor_ref, comment)
    VALUES (?, ?, ?, ?, ?)
  `).run(req.params.slug, quote || null, type, anchor_ref || null, comment.trim());

  const annotation = db.prepare('SELECT * FROM annotations WHERE id = ?').get(result.lastInsertRowid);
  res.status(201).json(annotation);

  setImmediate(async () => {
    try {
      await mirrorAnnotationToSession(item, annotation, buildReviewUrl(getReviewBaseUrl(req), req.params.slug));
    } catch (error) {
      console.error(`[annotation] Failed to mirror ${req.params.slug}/${annotation.id}: ${error.message}`);
    }
  });
});

app.get('/api/items/:slug/annotations', (req, res) => {
  res.json(listAnnotationsForSlug(req.params.slug));
});

app.delete('/api/items/:slug/annotations/:id', (req, res) => {
  const result = db.prepare('DELETE FROM annotations WHERE id = ? AND slug = ?').run(req.params.id, req.params.slug);
  if (result.changes === 0) return res.status(404).json({ error: 'Annotation not found' });
  res.json({ deleted: true });
});

// --- Regenerate context audio ---
app.post('/api/items/:slug/context/regenerate', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });
  db.prepare("UPDATE items SET context_status = 'generating' WHERE slug = ?").run(req.params.slug);
  generateContextMemo(req.params.slug);
  res.json({ status: 'regenerating' });
});

app.get('/api/items/:slug/approval', (req, res) => {
  const rawItem = stmts.getBySlug.get(req.params.slug);
  if (!rawItem) return res.status(404).json({ error: 'Not found' });

  const item = resolveAudioStatus(resolveAudioStatus(rawItem, 'tts'), 'context');
  res.json({
    status: item.action_status || item.approval_status || null,
    message: item.action_message || item.approval_message || null,
    exitCode: item.approval_exit_code ?? null,
    updatedAt: item.action_updated_at || item.approval_updated_at || null,
  });
});

// --- Read Aloud TTS status ---
app.get('/api/items/:slug/tts', (req, res) => {
  const rawItem = stmts.getBySlug.get(req.params.slug);
  const item = resolveAudioStatus(rawItem, 'tts');
  if (!item) return res.status(404).json({ error: 'Not found' });
  res.json({
    status: item.tts_status || null,
    url: item.tts_status === 'ready' ? `/tts-cache/${req.params.slug}.mp3` : null,
  });
});

// --- Context voice memo status ---
app.get('/api/items/:slug/context', (req, res) => {
  const rawItem = stmts.getBySlug.get(req.params.slug);
  const item = resolveAudioStatus(rawItem, 'context');
  if (!item) return res.status(404).json({ error: 'Not found' });
  res.json({
    status: item.context_status || null,
    url: item.context_status === 'ready' ? `/audio/${req.params.slug}.mp3` : null,
    summary: item.context_summary || null,
  });
});

// --- Web Routes ---

app.get('/funnel/index.html', (_req, res) => {
  res.redirect('/funnel');
});

app.get(['/funnel', '/funnel/'], (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.sendFile(path.join(__dirname, 'public', 'funnel', 'index.html'));
});

// Dashboard
app.get('/', (req, res) => {
  const requestedTab = typeof req.query.tab === 'string' ? req.query.tab : 'pending';
  const tab = ['pending', 'parked', 'decided'].includes(requestedTab) ? requestedTab : 'pending';
  let items;
  if (tab === 'decided') {
    items = db.prepare(`
      SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
             session_key, workspace_dir, source_path, decision_schema_version,
             action_status, action_message, approval_status, approval_message, approval_exit_code,
             LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
             created_at, updated_at
      FROM items
      WHERE status NOT IN ('pending', 'parked')
      ORDER BY updated_at DESC, created_at DESC
    `).all();
  } else {
    items = stmts.listByStatus.all(tab);
  }
  const counts = {
    pending: stmts.listByStatus.all('pending').length,
    parked: stmts.listByStatus.all('parked').length,
    decided: db.prepare(`SELECT COUNT(*) AS count FROM items WHERE status NOT IN ('pending', 'parked')`).get().count,
  };
  res.render('dashboard', { items, tab, counts });
});

// Review page
app.get('/review/:slug', (req, res) => {
  const rawItem = stmts.getBySlug.get(req.params.slug);
  const item = resolveAudioStatus(resolveAudioStatus(rawItem, 'tts'), 'context');
  if (!item) return res.status(404).send('Not found');
  const actions = getActions(item);
  const returnTab = ['decided', 'parked'].includes(req.query.fromTab) ? req.query.fromTab : 'pending';

  // Chat integration
  let chatToken = '';
  if (chatModule) {
    chatToken = chatModule.generateChatToken(req.params.slug);
  }

  res.render('review', { item, actions, returnTab, chatToken });
});

// --- Decision outbox drain (C4: durable notifications) ---
let drainingOutbox = false;

async function drainDecisionOutbox(limit = 25) {
  if (drainingOutbox) return;
  drainingOutbox = true;
  try {
    const rows = stmts.listPendingOutbox.all({ limit });
    for (const row of rows) {
      try {
        await notifyBenji(JSON.parse(row.payload));
        stmts.markOutboxSent.run({ id: row.id });
      } catch (err) {
        stmts.markOutboxFailed.run({ id: row.id, last_error: String(err?.message || err).slice(0, 500) });
      }
    }
  } finally {
    drainingOutbox = false;
  }
}

// Retry unsent decisions every 15 seconds
setInterval(() => {
  void drainDecisionOutbox();
}, 15000);

reconcileInterruptedAudioJobs();

// --- Global JSON error handler for /api/ routes ---
app.use((err, req, res, _next) => {
  console.error(`[${req.method} ${req.url}] Error:`, err.message || err);
  const status = err.status || 500;
  if (req.path.startsWith('/api/')) {
    res.status(status).json({ error: err.message || 'Internal server error' });
  } else {
    res.status(status).send(`<pre>${err.message || 'Internal server error'}</pre>`);
  }
});

// --- Start ---
const server = app.listen(PORT, () => {
  console.log(`Turf Review running at http://localhost:${PORT}`);
  // Drain any decisions that were queued while OpenClaw was down
  void drainDecisionOutbox();
});

// Attach WebSocket server for chat
if (chatModule) {
  chatModule.attachToServer(server, (slug) => stmts.getBySlug.get(slug));
  console.log('Chat WebSocket attached');
}

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
const PROCESS_APPROVAL_SCRIPT = path.join(__dirname, 'process-approval.sh');
const MIN_TTS_CHARS = 500;

const app = express();
const PORT = process.env.PORT || 3457;

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
try { db.exec('CREATE INDEX IF NOT EXISTS idx_items_content_hash ON items(content_hash)'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN tts_status TEXT DEFAULT NULL'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN context_status TEXT DEFAULT NULL'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN context_summary TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN approval_status TEXT DEFAULT NULL'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN approval_message TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN approval_exit_code INTEGER'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN approval_updated_at TEXT'); } catch(e) {}

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
      if (lang && hljs.getLanguage(lang)) {
        return hljs.highlight(code, { language: lang }).value;
      }
      return hljs.highlightAuto(code).value;
    }
  })
);
marked.setOptions({ gfm: true, breaks: true });

// --- Middleware ---
const session = require('express-session');

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));
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
    const { decision, title, slug, feedback, taskId, projectId } = payload;
    const parts = [
      'REVIEW DECIDED',
      `decision="${normalizeEventText(decision)}"`,
      `title="${normalizeEventText(title)}"`,
      `slug="${normalizeEventText(slug)}"`,
    ];
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

function updateApprovalState(slug, status, message = null, exitCode = null) {
  db.prepare(`
    UPDATE items
    SET approval_status = @status,
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
  if (item.actions) {
    try { return JSON.parse(item.actions); } catch(e) {}
  }
  // Legacy items without actions get a fallback — but new publishes are blocked without them
  return ['Approve', 'Reject'];
}

// --- Prepared statements ---
const stmts = {
  insert: db.prepare(`
    INSERT INTO items (slug, title, markdown, rendered_html, category, actions, content_hash, mindwtr_task_id, mindwtr_project_id, on_approve)
    VALUES (@slug, @title, @markdown, @rendered_html, @category, @actions, @content_hash, @mindwtr_task_id, @mindwtr_project_id, @on_approve)
  `),
  getByContentHash: db.prepare('SELECT slug FROM items WHERE content_hash = ? ORDER BY created_at ASC LIMIT 1'),
  getBySlug: db.prepare('SELECT * FROM items WHERE slug = ?'),
  listAll: db.prepare(`
    SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
           approval_status, approval_message, approval_exit_code,
           LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
           created_at, updated_at
    FROM items
    ORDER BY created_at DESC
  `),
  listByStatus: db.prepare(`
    SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
           approval_status, approval_message, approval_exit_code,
           LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
           created_at, updated_at
    FROM items
    WHERE status = ?
    ORDER BY created_at DESC
  `),
  listByCategory: db.prepare(`
    SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
           approval_status, approval_message, approval_exit_code,
           LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
           created_at, updated_at
    FROM items
    WHERE category = ?
    ORDER BY created_at DESC
  `),
  listByStatusAndCategory: db.prepare(`
    SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
           approval_status, approval_message, approval_exit_code,
           LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
           created_at, updated_at
    FROM items
    WHERE status = ? AND category = ?
    ORDER BY created_at DESC
  `),
  decide: db.prepare(`UPDATE items SET status = 'decided', decision = @decision, feedback = @feedback, updated_at = datetime('now') WHERE slug = @slug`),
  enqueueOutbox: db.prepare(`INSERT INTO decision_outbox (slug, payload) VALUES (@slug, @payload)`),
  listPendingOutbox: db.prepare(`SELECT id, payload FROM decision_outbox WHERE sent_at IS NULL ORDER BY created_at ASC, id ASC LIMIT @limit`),
  markOutboxSent: db.prepare(`UPDATE decision_outbox SET attempts = attempts + 1, last_error = NULL, sent_at = datetime('now') WHERE id = @id`),
  markOutboxFailed: db.prepare(`UPDATE decision_outbox SET attempts = attempts + 1, last_error = @last_error WHERE id = @id`),
};

const ALLOWED_CATEGORIES = new Set(['kitchenlux', 'outreach', 'admin', 'general']);
const REQUIRE_TASK_LINK = process.env.REVIEW_REQUIRE_TASK_LINK !== '0';

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

// --- API Routes ---

// Publish a new review item (markdown or raw HTML)
// actions: REQUIRED array of button labels (at least 2). No defaults.
app.post('/api/publish', (req, res) => {
  try {
    const { title, markdown, html, slug: rawSlug, category, actions, taskId, projectId, onApprove } = req.body;
    if (!title || (!markdown && !html)) {
      return res.status(400).json({ error: 'title and (markdown or html) are required' });
    }
    if (!actions || !Array.isArray(actions) || actions.length < 2 || !actions.every(a => typeof a === 'string')) {
      return res.status(400).json({ error: 'actions is required: provide a JSON array of at least 2 string button labels. No defaults — every review item must have explicit, contextual actions.' });
    }

    const normalizedCategory = String(category || 'general').toLowerCase().trim();
    if (!ALLOWED_CATEGORIES.has(normalizedCategory)) {
      return res.status(400).json({ error: 'Invalid category. Allowed: kitchenlux, outreach, admin, general' });
    }

    // Deterministic processing rule:
    // Every published review must be linked to a Mindwtr task so decisions
    // always flow through process-approval.sh without manual fallback.
    if (REQUIRE_TASK_LINK && !taskId) {
      return res.status(400).json({
        error: 'taskId is required on every publish. Link the review to a Mindwtr task.',
      });
    }

    // Backward compatibility when strict task-linking is explicitly disabled.
    if (!REQUIRE_TASK_LINK && normalizedCategory !== 'general' && !taskId && !projectId) {
      return res.status(400).json({ error: 'taskId or projectId is required when category is not general' });
    }

    const source_markdown = markdown || '';
    const content_hash = createContentHash(title, source_markdown);
    const existing = stmts.getByContentHash.get(content_hash);
    if (existing) {
      return res.status(200).json({ slug: existing.slug, url: `/review/${existing.slug}`, deduped: true });
    }

    const slug = rawSlug ? slugify(rawSlug) : slugify(title) + '-' + Date.now().toString(36);
    // Sanitize rendered HTML before storage to prevent XSS
    const rawHtml = html || marked.parse(markdown);
    const rendered_html = xss(rawHtml, {
      whiteList: {
        // Allow standard markdown output tags
        a: ['href', 'title', 'target'],
        b: [], strong: [], i: [], em: [], s: [], del: [],
        p: [], br: [], hr: [],
        h1: [], h2: [], h3: [], h4: [], h5: [], h6: [],
        ul: [], ol: [], li: [],
        blockquote: [],
        pre: ['class'], code: ['class'], // for highlight.js
        table: [], thead: [], tbody: [], tr: [], th: ['scope'], td: [],
        img: ['src', 'alt', 'title'],
        span: ['class'], div: ['class'],
      },
      stripIgnoreTag: true,
    });
    const actionsJson = actions ? JSON.stringify(actions) : null;

    stmts.insert.run({
      slug,
      title,
      markdown: source_markdown,
      rendered_html,
      category: normalizedCategory,
      actions: actionsJson,
      content_hash,
      mindwtr_task_id: taskId || null,
      mindwtr_project_id: projectId || null,
      on_approve: onApprove || null,
    });

    const plainText = stripMarkdownToPlain(source_markdown || rendered_html);
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

    res.status(201).json({ slug, url: `/review/${slug}`, deduped: false });
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
// POST /api/items/:slug/decide { decision: "Approve" | "Simply Business" | etc, feedback?: "..." }
app.post('/api/items/:slug/decide', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });

  const { decision, feedback } = req.body;
  if (!decision) return res.status(400).json({ error: 'decision is required' });

  const resolvedFeedback = typeof feedback === 'string' ? feedback : (item.feedback || null);
  const payload = {
    decision,
    title: item.title,
    slug: req.params.slug,
    feedback: resolvedFeedback,
    taskId: item.mindwtr_task_id,
    projectId: item.mindwtr_project_id,
    onApprove: item.on_approve,
  };

  // Transactional: update item + enqueue notification
  const txDecide = db.transaction(() => {
    stmts.decide.run({ decision, feedback: resolvedFeedback, slug: req.params.slug });
    stmts.enqueueOutbox.run({ slug: req.params.slug, payload: JSON.stringify(payload) });
    updateApprovalState(req.params.slug, 'queued', 'Decision saved. Processing linked task...');
  });
  txDecide();

  // Broadcast live-refresh event for decision
  broadcastSSE('decision', { slug: req.params.slug, decision, title: item.title });

  // Fire async drain (best-effort immediate delivery for system event notification)
  void drainDecisionOutbox();

  res.json({
    status: 'decided',
    decision,
    slug: req.params.slug,
    queued: true,
    processed: false,
    approval: {
      status: 'queued',
      message: 'Decision saved. Processing linked task...',
    },
  });

  // Fire-and-forget after the response is on the wire so Jimmy's tap stays snappy.
  setImmediate(() => {
    updateApprovalState(req.params.slug, 'processing', 'Processing linked task...');
    execFile('/bin/bash', [PROCESS_APPROVAL_SCRIPT, req.params.slug], {
      env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' },
    }, (err, stdout, stderr) => {
      const output = [stdout, stderr]
        .filter(Boolean)
        .join('\n')
        .trim();
      const exitCode = err && Number.isInteger(err.code) ? err.code : 0;

      if (output) {
        console.log(`[process-approval] ${req.params.slug}\n${output}`);
      }

      if (!err) {
        updateApprovalState(req.params.slug, 'succeeded', 'Linked task processed.');
        broadcastSSE('approval', { slug: req.params.slug, status: 'succeeded' });
        return;
      }

      if (exitCode === 2) {
        updateApprovalState(
          req.params.slug,
          'manual_required',
          'Manual task follow-up required. Benji has been alerted.',
          2
        );
        broadcastSSE('approval', { slug: req.params.slug, status: 'manual_required', exitCode });
        return;
      }

      console.error(`[process-approval] Error for ${req.params.slug}: ${err.message}`);
      updateApprovalState(
        req.params.slug,
        'failed',
        'Decision saved, but linked task processing failed. Benji should check the logs.',
        exitCode || 1
      );
      broadcastSSE('approval', { slug: req.params.slug, status: 'failed', exitCode: exitCode || 1 });
    });
  });
});

// Legacy endpoints (redirect to decide)
app.post('/api/items/:slug/approve', (req, res) => {
  req.body.decision = 'Approve';
  return app._router.handle({ ...req, url: `/api/items/${req.params.slug}/decide`, method: 'POST' }, res, () => {});
});
app.post('/api/items/:slug/reject', (req, res) => {
  req.body.decision = 'Reject';
  return app._router.handle({ ...req, url: `/api/items/${req.params.slug}/decide`, method: 'POST' }, res, () => {});
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
    status: item.approval_status || null,
    message: item.approval_message || null,
    exitCode: item.approval_exit_code ?? null,
    updatedAt: item.approval_updated_at || null,
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

// Dashboard
app.get('/', (req, res) => {
  const requestedTab = typeof req.query.tab === 'string' ? req.query.tab : 'pending';
  const tab = requestedTab === 'decided' ? 'decided' : 'pending';
  const items = stmts.listByStatus.all(tab);
  const counts = {
    pending: stmts.listByStatus.all('pending').length,
    decided: stmts.listByStatus.all('decided').length,
  };
  res.render('dashboard', { items, tab, counts });
});

// Review page
app.get('/review/:slug', (req, res) => {
  const rawItem = stmts.getBySlug.get(req.params.slug);
  const item = resolveAudioStatus(resolveAudioStatus(rawItem, 'tts'), 'context');
  if (!item) return res.status(404).send('Not found');
  const actions = getActions(item);
  const returnTab = req.query.fromTab === 'decided' ? 'decided' : 'pending';
  res.render('review', { item, actions, returnTab });
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

// --- Start ---
app.listen(PORT, () => {
  console.log(`Turf Review running at http://localhost:${PORT}`);
  // Drain any decisions that were queued while OpenClaw was down
  void drainDecisionOutbox();
});

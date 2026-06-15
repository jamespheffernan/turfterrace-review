require('dotenv').config();

const { loadConfig } = require('./lib/config');

let config;
try {
  config = loadConfig(process.env, __dirname);
} catch (error) {
  console.error(`FATAL: ${error.message}`);
  process.exit(1);
}

const express = require('express');
const path = require('path');
const os = require('os');
const fs = require('fs');
const { execFile, execFileSync } = require('child_process');
const { promisify } = require('util');
const execFileAsync = promisify(execFile);
const crypto = require('crypto');
const { createContentHash, createReviewDatabase, ensureDir } = require('./lib/db');
const { createChatRouter } = require('./lib/chat/routes');
const { createFunnelDashboardService } = require('./lib/funnel/dashboard');
const { createOpenClawClient } = require('./lib/openclaw');
const { renderSourceDocument, stripMarkdownToPlain } = require('./lib/reviews/render');
const { createDecisionOrchestrator } = require('./lib/reviews/orchestrator');
const { createReviewStatements } = require('./lib/reviews/repository');
const {
  listReviewTargetsForItem,
  normalizeTargetVerdict,
  rejectedTargetFeedback,
} = require('./lib/reviews/review-targets');
const { normalizeSessionKey } = require('./lib/reviews/decision-contract');
const { readSourceDocument, resolveGitTrackedSource } = require('./lib/reviews/source-paths');
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

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 25 * 1024 * 1024 } });

// Image upload multer instance (disk storage, 10MB limit, images only)
const ALLOWED_IMAGE_MIMES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);
const ALLOWED_IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp']);

// TTS cache directory
const ttsCacheDir = config.paths.ttsCacheDir;
ensureDir(ttsCacheDir);
const openai = new OpenAI({ apiKey: config.openai.apiKey });
const MIN_TTS_CHARS = 500;

// Stable asset cache-buster. Computed once at boot from the package.json
// version + the lstat mtime of public/styles.css and public/chat.js so that
// the rendered HTML is byte-stable across requests but invalidates whenever
// either the version bumps or a static asset changes on disk.
// Replaces the previous `Date.now()` cache-busters in views/layout-start.ejs
// and views/review.ejs, which made every rendered page byte-different and
// defeated any HTML response cache.
const ASSET_VERSION = (() => {
  try {
    const pkg = require('./package.json');
    const cssM = fs.statSync(path.join(config.paths.publicDir, 'styles.css')).mtimeMs;
    const chatJsM = fs.statSync(path.join(config.paths.publicDir, 'chat.js')).mtimeMs;
    const chatCssM = fs.statSync(path.join(config.paths.publicDir, 'chat.css')).mtimeMs;
    const seed = `${pkg.version || '0.0.0'}-${cssM}-${chatJsM}-${chatCssM}`;
    return crypto.createHash('sha1').update(seed).digest('hex').slice(0, 12);
  } catch (_err) {
    return Math.floor(Date.now() / 1000).toString(36);
  }
})();

const app = express();
const PORT = config.port;

// --- SSE live-refresh ---
const sseClients = new Set();

function broadcastSSE(event, data) {
  // Slug-scoped events imply the cached HTML for that slug is stale.
  // Catches every orchestrator-side write that ends with broadcastSSE
  // ('review-processed', 'approval', 'republished', 'new-item', etc.)
  // without having to thread invalidation through orchestrator.js.
  if (data && typeof data.slug === 'string' && data.slug.length) {
    invalidateReviewCache(data.slug);
  }
  const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of sseClients) {
    res.write(msg);
  }
}

// ---- Slug-keyed HTML response cache for GET /review/:slug (loop 10) ----
//
// Bounded LRU keyed by `${slug}|${returnTab}`. Cached body bytes are the
// rendered review.ejs output. Cache is read-through on miss and invalidated
// by invalidateReviewCache(slug) from every write path that mutates the
// underlying items/annotations/decision_requests rows for that slug.
//
// CSRF token is set on res.locals but NEVER emitted into review.ejs (verified
// by `grep -nE 'csrfToken' views/review.ejs`), so cached bodies are
// independent of session/user. If review.ejs ever starts rendering csrfToken,
// extend the cache key to include req.session.id and bump REVIEW_HTML_CACHE_VERSION.
const REVIEW_HTML_CACHE_MAX = Number(process.env.REVIEW_HTML_CACHE_MAX || 256);
const reviewHtmlCache = (() => {
  const map = new Map();
  return {
    get(key) {
      if (!map.has(key)) return undefined;
      const v = map.get(key);
      // Move-to-end for LRU.
      map.delete(key);
      map.set(key, v);
      return v;
    },
    set(key, value) {
      if (map.has(key)) map.delete(key);
      map.set(key, value);
      while (map.size > REVIEW_HTML_CACHE_MAX) {
        const oldest = map.keys().next().value;
        map.delete(oldest);
      }
    },
    delete(key) { return map.delete(key); },
    clear() { map.clear(); },
    size() { return map.size; },
    keys() { return Array.from(map.keys()); },
  };
})();

function invalidateReviewCache(slug) {
  if (!slug) return;
  // Each slug may be cached under multiple returnTab variants.
  const prefix = `${slug}|`;
  const stale = [];
  for (const key of reviewHtmlCache.keys()) {
    if (key.startsWith(prefix)) stale.push(key);
  }
  for (const key of stale) reviewHtmlCache.delete(key);
}

// --- Database setup ---
const dataDir = config.paths.dataDir;
ensureDir(dataDir);

// Uploads directory — created on startup
const uploadsDir = config.paths.uploadsDir;
ensureDir(uploadsDir);
ensureDir(config.paths.audioDir);

const db = createReviewDatabase({ dataDir });
const ACTION_RETRY_DELAY_SECONDS = Number(process.env.TURF_REVIEW_ACTION_RETRY_SECONDS || 60);
const ACTION_MAX_ATTEMPTS = Number(process.env.TURF_REVIEW_ACTION_MAX_ATTEMPTS || 3);
const WEB_ONLY_MODE = process.env.TURF_REVIEW_WEB_ONLY === '1';
const DISABLE_MEDIA_JOBS = process.env.TURF_REVIEW_DISABLE_MEDIA_JOBS === '1';

function resolvePublishSource(workspaceDir, sourcePath) {
  if (!WEB_ONLY_MODE) {
    return resolveGitTrackedSource(workspaceDir, sourcePath);
  }

  if (typeof workspaceDir !== 'string' || !workspaceDir.trim()) {
    throw new Error('workspaceDir is required');
  }
  if (typeof sourcePath !== 'string' || !sourcePath.trim()) {
    throw new Error('sourcePath is required');
  }
  if (!path.isAbsolute(workspaceDir)) {
    throw new Error('workspaceDir must be an absolute path');
  }
  if (!path.isAbsolute(sourcePath)) {
    throw new Error('sourcePath must be an absolute path');
  }
  return {
    gitRoot: workspaceDir,
    workspaceDir: path.resolve(workspaceDir),
    sourcePath: path.resolve(sourcePath),
    relativeToGitRoot: path.relative(path.resolve(workspaceDir), path.resolve(sourcePath)),
  };
}

// --- Middleware ---
const session = require('express-session');

app.set('view engine', 'ejs');
app.set('views', config.paths.viewsDir);
// Cache compiled EJS templates. Express only enables this automatically
// when NODE_ENV=production. Templates are compiled once per file lifetime
// and reloaded only on process restart.
app.enable('view cache');
// Disable weak-etag generation (hashes every response body on a hot path).
// Authenticated review pages always include per-request dynamic content
// so etag-based 304s are effectively never taken. Disabling saved ~57%
// p50 / 63% p95 in paired A/B benchmarks (loop 9 trial 04).
app.disable('etag');
// Trim a tiny header that no client uses.
app.disable('x-powered-by');
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true }));
const publicStatic = express.static(config.paths.publicDir, { index: false, redirect: false });
app.use((req, res, next) => {
  if (req.path === '/funnel' || req.path === '/funnel/' || req.path === '/funnel/index.html') {
    return next();
  }
  return publicStatic(req, res, next);
});

const openclawClient = config.openclaw.token ? createOpenClawClient({
  token: config.openclaw.token,
  baseUrl: config.openclaw.baseUrl,
  agentId: config.openclaw.agentId,
  model: config.openclaw.chatModel,
}) : null;
app.use('/tts-cache', express.static(config.paths.ttsCacheDir));
app.use('/audio', express.static(config.paths.audioDir));
app.use('/uploads', express.static(uploadsDir));

app.use(session({
  secret: config.auth.sessionSecret,
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 30 * 24 * 60 * 60 * 1000 } // 30 days
}));

// Auth: cookie session + Basic Auth fallback (for API calls from scripts)
function auth(req, res, next) {
  const user = config.auth.reviewUser;
  const pass = config.auth.reviewPassword;
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

// Expose ASSET_VERSION to every rendered template (loop 10).
app.use((req, res, next) => {
  res.locals.assetVersion = ASSET_VERSION;
  next();
});

function getReviewBaseUrl(req) {
  if (config.reviewBaseUrl) {
    return config.reviewBaseUrl.replace(/\/+$/, '');
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
  if (username === config.auth.reviewUser && password === config.auth.reviewPassword) {
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

// --- Read Aloud TTS (Edge TTS) ---
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
    const contextPath = path.join(config.paths.audioDir, `${row.slug}.mp3`);

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
    : path.join(config.paths.audioDir, `${item.slug}.mp3`);

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
  invalidateReviewCache(slug);
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
    invalidateReviewCache(slug);
    return;
  }

  if (plainText.length < MIN_TTS_CHARS) {
    db.prepare("UPDATE items SET tts_status = 'skipped' WHERE slug = ?").run(slug);
    invalidateReviewCache(slug);
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
      invalidateReviewCache(slug);
      console.log(`[tts] Ready: ${slug} (${chunks.length} chunks merged)`);
    } catch (err) {
      db.prepare("UPDATE items SET tts_status = 'failed' WHERE slug = ?").run(slug);
      invalidateReviewCache(slug);
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
    invalidateReviewCache(slug);
    return;
  }

  const audioDir = config.paths.audioDir;
  ensureDir(audioDir);
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
        invalidateReviewCache(slug);
        return;
      }

      // Store the summary text
      db.prepare("UPDATE items SET context_summary = ? WHERE slug = ?").run(summary, slug);
      invalidateReviewCache(slug);
      const chunks = chunkTextForSpeech(summary);

      console.log(`[context] Generating TTS for ${slug} (${summary.length} chars)`);

      await synthesizeSpeechToFile({ text: summary, slug, prefix: 'ctx', outputPath: audioPath });
      db.prepare("UPDATE items SET context_status = 'ready' WHERE slug = ?").run(slug);
      invalidateReviewCache(slug);
      console.log(`[context] Ready: ${slug}`);
    } catch (err) {
      db.prepare("UPDATE items SET context_status = 'failed' WHERE slug = ?").run(slug);
      invalidateReviewCache(slug);
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

function serializeOnApprove(onApprove) {
  if (!onApprove) return null;
  if (typeof onApprove === 'string') return onApprove;
  if (typeof onApprove === 'object' && !Array.isArray(onApprove)) return JSON.stringify(onApprove);
  return String(onApprove);
}

function parsePublishObject(value) {
  if (!value) return {};
  if (typeof value === 'object' && !Array.isArray(value)) return value;
  if (typeof value !== 'string') return {};
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (_error) {
    return {};
  }
}

function originSessionKeyFromMarkdown(markdown) {
  const source = String(markdown || '');
  const marker = source.match(/<!--\s*turf-review-origin-session:\s*([^>]+?)\s*-->/i)
    || source.match(/^\s*turf-review-origin-session:\s*(.+)$/im);
  return normalizeSessionKey(marker?.[1]);
}

function resolveOriginSessionKey({ originSessionKey, sourceSessionKey, draftSessionKey, markdown, onApprove }) {
  const payload = parsePublishObject(onApprove);
  return normalizeSessionKey(
    originSessionKey
      || sourceSessionKey
      || draftSessionKey
      || payload.originSessionKey
      || payload.sourceSessionKey
      || payload.draftSessionKey
      || originSessionKeyFromMarkdown(markdown)
  );
}

async function appendSessionNote(item, kind, payload, options = {}) {
  if (!openclawClient || !item) return null;
  const sessionKey = normalizeSessionKey(options.sessionKey) || item.session_key || getSessionKey(item.slug);
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
  const compactAnnotation = compactAnnotationForHandoff(annotation);
  return appendSessionNote(item, 'annotation', {
    reviewUrl,
    annotation: {
      id: compactAnnotation.id,
      createdAt: compactAnnotation.created_at,
      anchorType: compactAnnotation.anchor_type,
      anchorRef: compactAnnotation.anchor_ref,
      quote: compactAnnotation.quote,
      comment: compactAnnotation.comment,
      imageMime: compactAnnotation.image_mime,
      imageAttached: compactAnnotation.image_attached === true,
    },
  });
}

function parseInternalResultText(text) {
  const normalized = String(text || '').trim();
  if (!normalized) return null;

  const prefix = '[TURF_REVIEW_INTERNAL]';
  let payload = normalized;
  if (normalized.startsWith(prefix)) {
    payload = normalized.slice(prefix.length).trim();
    if (!payload.startsWith('{')) {
      const jsonStart = payload.indexOf('{');
      const newlineIndex = payload.indexOf('\n');
      payload = jsonStart >= 0 ? payload.slice(jsonStart).trim() : (newlineIndex >= 0 ? payload.slice(newlineIndex + 1).trim() : '');
    }
  }

  try {
    return JSON.parse(payload);
  } catch (_error) {
    const jsonStart = payload.indexOf('{');
    const jsonEnd = payload.lastIndexOf('}');
    if (jsonStart >= 0 && jsonEnd > jsonStart) {
      try {
        return JSON.parse(payload.slice(jsonStart, jsonEnd + 1));
      } catch (_innerError) {
        return null;
      }
    }
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

  invalidateReviewCache(item.slug);
  return refreshed;
}

// --- Prepared statements ---
const stmts = createReviewStatements(db);
const decisionOrchestrator = createDecisionOrchestrator({
  config,
  db,
  stmts,
  openclawClient,
  appendSessionNote,
  seedSessionForItem,
  broadcastSSE,
});

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

function annotationHasImageData(annotation) {
  return typeof annotation.image_data === 'string' && annotation.image_data.length > 0;
}

function compactAnnotationForHandoff(annotation) {
  if (!annotationHasImageData(annotation)) return annotation;
  const { image_data: _imageData, ...compact } = annotation;
  return {
    ...compact,
    image_attached: true,
  };
}

function listAnnotationsForSlug(slug, options = {}) {
  const annotations = db.prepare('SELECT * FROM annotations WHERE slug = ? ORDER BY created_at ASC').all(slug);
  return options.includeImageData ? annotations : annotations.map(compactAnnotationForHandoff);
}

function listReviewTargetsForSlug(slug) {
  const item = stmts.getBySlug.get(slug);
  if (!item) return { slug, targets: [], summary: { total: 0, approved: 0, rejected: 0, undecided: 0, decided: 0, complete: true } };
  return listReviewTargetsForItem(stmts, item);
}

const POSITIVE_TARGET_DECISIONS = new Set(['Approve', 'Execute', 'Send']);
const REWORK_TARGET_DECISIONS = new Set(['Rework', 'Edit']);

app.use(createChatRouter({
  getItem: (slug) => stmts.getBySlug.get(slug),
  listAnnotations: listAnnotationsForSlug,
  listReviewTargets: listReviewTargetsForSlug,
  openclaw: openclawClient,
}));

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

let drainingActions = false;
let actionDrainScheduled = false;

function scheduleActionDrain() {
  if (actionDrainScheduled) return;
  actionDrainScheduled = true;
  setImmediate(async () => {
    actionDrainScheduled = false;
    await drainDecisionActions();
  });
}

function safeParseActionPayload(row) {
  try {
    return JSON.parse(row.payload);
  } catch (error) {
    throw new Error(`Decision action ${row.id} has invalid payload: ${error.message}`);
  }
}

function normalizeActionTerminalStatus(status) {
  const normalized = String(status || '').trim();
  if (['succeeded', 'blocked', 'failed'].includes(normalized)) return normalized;
  return 'blocked';
}

async function drainDecisionActions(limit = 5) {
  if (drainingActions) return;
  drainingActions = true;
  try {
    stmts.recoverStaleActions.run({ minutes: 15 });
    const rows = stmts.listRunnableActions.all({ limit });
    for (const row of rows) {
      const claim = stmts.markActionRunning.run({ id: row.id });
      if (claim.changes === 0) continue;

      const attemptsAfterClaim = row.attempts + 1;
      let payload;
      try {
        payload = safeParseActionPayload(row);
        const item = stmts.getBySlug.get(row.slug);
        if (!item) {
          updateActionState(row.slug, 'failed', 'Review item disappeared before action could run.');
          stmts.markActionDone.run({
            id: row.id,
            status: 'failed',
            last_error: 'Review item disappeared before action could run.',
          });
          continue;
        }

        updateActionState(row.slug, 'running', `Running ${payload.decision || row.decision} action...`);
        await routeDecisionAction(item, {
          decision: payload.decision || row.decision,
          feedback: payload.feedback,
          annotations: payload.annotations || [],
          reviewUrl: payload.reviewUrl,
        });

        const latest = stmts.getBySlug.get(row.slug);
        const finalStatus = normalizeActionTerminalStatus(latest?.action_status);
        const finalMessage = latest?.action_message || latest?.approval_message || null;
        stmts.markActionDone.run({
          id: row.id,
          status: finalStatus,
          last_error: finalStatus === 'succeeded' ? null : finalMessage,
        });
        invalidateReviewCache(row.slug);
        broadcastSSE('approval', {
          slug: row.slug,
          status: finalStatus,
        });
      } catch (error) {
        const message = error.message || 'Decision action failed.';
        const willRetry = attemptsAfterClaim < row.max_attempts;
        const displayMessage = willRetry
          ? `${message} Retrying automatically.`
          : message;
        stmts.markActionFailed.run({
          id: row.id,
          last_error: message,
          retry_modifier: `+${ACTION_RETRY_DELAY_SECONDS} seconds`,
        });
        updateActionState(row.slug, 'failed', displayMessage);
        invalidateReviewCache(row.slug);
        console.error(`[decision-action] ${row.slug}/${row.id}: ${message}`);
        broadcastSSE('approval', {
          slug: row.slug,
          status: 'failed',
        });
      }
    }
  } finally {
    drainingActions = false;
  }
}

if (!WEB_ONLY_MODE) {
  setInterval(() => {
    void drainDecisionActions();
    void decisionOrchestrator.drainDecisionRequests();
  }, 15000);
  scheduleActionDrain();
  decisionOrchestrator.scheduleDrain();
} else {
  console.log('[decision-action] Web-only mode enabled; leaving queued actions for the Mac-side worker.');
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
      originSessionKey,
      sourceSessionKey,
      draftSessionKey,
    } = req.body;

    if (!title || (!markdown && !html)) {
      return res.status(400).json({ error: 'title and (markdown or html) are required' });
    }

    const normalizedCategory = normalizeCategory(category);
    if (!ALLOWED_CATEGORIES.has(normalizedCategory)) {
      return res.status(400).json({ error: `Invalid category. Allowed: ${Array.from(ALLOWED_CATEGORIES).join(', ')}` });
    }

    const canonicalActions = getCanonicalActions(normalizedCategory);
    if (actions && !arraysMatchExactly(actions, canonicalActions)) {
      return res.status(400).json({
        error: `actions must exactly match the canonical set for ${normalizedCategory}: ${canonicalActions.join(', ')}`,
      });
    }

    let resolvedSource;
    try {
      resolvedSource = resolvePublishSource(workspaceDir, sourcePath);
    } catch (error) {
      return res.status(400).json({ error: error.message });
    }

    const serializedOnApprove = serializeOnApprove(onApprove);
    const resolvedOriginSessionKey = resolveOriginSessionKey({
      originSessionKey,
      sourceSessionKey,
      draftSessionKey,
      markdown: markdown || html || '',
      onApprove: serializedOnApprove,
    });
    const content_hash = createContentHash(title, markdown || html || '');
    const existing = stmts.getByContentHash.get(content_hash);
    if (existing) {
      if (resolvedOriginSessionKey) {
        stmts.setItemOriginSession.run({
          slug: existing.slug,
          origin_session_key: resolvedOriginSessionKey,
        });
      }
      return res.status(200).json({
        slug: existing.slug,
        url: `/review/${existing.slug}`,
        deduped: true,
        originSessionKey: resolvedOriginSessionKey,
      });
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
      on_approve: serializedOnApprove,
      session_key: sessionKey,
      workspace_dir: resolvedSource.workspaceDir,
      source_path: resolvedSource.sourcePath,
      decision_schema_version: DECISION_SCHEMA_VERSION,
      parent_slug: null,
      supersedes_slug: null,
      created_by_request_id: null,
    });
    if (resolvedOriginSessionKey) {
      stmts.setItemOriginSession.run({
        slug,
        origin_session_key: resolvedOriginSessionKey,
      });
    }

    const plainText = stripMarkdownToPlain(rendered.markdown || rendered.rendered_html);
    if (DISABLE_MEDIA_JOBS) {
      db.prepare(`UPDATE items SET tts_status = 'skipped', context_status = 'skipped' WHERE slug = ?`).run(slug);
    } else {
      if (plainText.length >= MIN_TTS_CHARS) {
        db.prepare(`UPDATE items SET tts_status = 'generating' WHERE slug = ?`).run(slug);
        generateReadAloudTTS(slug);
      } else {
        db.prepare(`UPDATE items SET tts_status = 'skipped' WHERE slug = ?`).run(slug);
      }

      // Auto-generate context voice memo (AI summary → Edge TTS, async)
      db.prepare(`UPDATE items SET context_status = 'generating' WHERE slug = ?`).run(slug);
      generateContextMemo(slug);
    }

    // Broadcast live-refresh event to all connected dashboards
    broadcastSSE('new-item', { slug, title, category: normalizedCategory });

    const reviewBaseUrl = getReviewBaseUrl(req);
    const reviewUrl = buildReviewUrl(reviewBaseUrl, slug);
    const item = stmts.getBySlug.get(slug);
    decisionOrchestrator.recordIntentForItem(item, serializedOnApprove);
    const reviewTargets = listReviewTargetsForItem(stmts, item);

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
      originSessionKey: resolvedOriginSessionKey,
      actions: canonicalActions,
      reviewTargets: reviewTargets.summary,
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

app.get('/api/items/:slug/targets', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });
  res.json(listReviewTargetsForItem(stmts, item));
});

app.patch('/api/items/:slug/targets/:targetKey', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });

  listReviewTargetsForItem(stmts, item);
  const target = stmts.getReviewTargetForSlug.get({
    slug: req.params.slug,
    target_key: req.params.targetKey,
  });
  if (!target) return res.status(404).json({ error: 'Review target not found' });

  const verdict = normalizeTargetVerdict(req.body?.verdict);
  if (!verdict) {
    return res.status(400).json({ error: 'verdict must be approved, rejected, or unset' });
  }

  if (verdict === 'unset') {
    stmts.clearReviewTargetJudgment.run({
      slug: req.params.slug,
      target_key: req.params.targetKey,
    });
  } else {
    const feedback = typeof req.body?.feedback === 'string' ? req.body.feedback.trim() : '';
    stmts.upsertReviewTargetJudgment.run({
      slug: req.params.slug,
      target_key: req.params.targetKey,
      verdict,
      feedback: feedback || null,
      actor: 'jimmy',
    });
  }

  invalidateReviewCache(req.params.slug);
  const response = listReviewTargetsForItem(stmts, item);
  res.json({
    slug: req.params.slug,
    target: response.targets.find((candidate) => candidate.key === req.params.targetKey),
    summary: response.summary,
  });
});

// Decide — unified action endpoint
app.post('/api/items/:slug/decide', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });
  if (item.status !== 'pending') {
    return res.status(409).json({
      error: `Review is already ${item.status}; use a follow-up review or retry the downstream action instead.`,
    });
  }

  const { decision, feedback } = req.body;
  if (!decision) return res.status(400).json({ error: 'decision is required' });
  if (!isAllowedDecision(item, decision)) {
    return res.status(400).json({
      error: `Invalid decision for ${item.category}. Allowed: ${getActions(item).join(', ')}`,
    });
  }

  const reviewTargets = listReviewTargetsForItem(stmts, item);
  const targetFeedback = rejectedTargetFeedback(reviewTargets.targets);
  if (POSITIVE_TARGET_DECISIONS.has(decision) && reviewTargets.summary.total > 0 && !reviewTargets.summary.complete) {
    return res.status(409).json({
      error: `Decide every review target before submitting ${decision}.`,
      reviewTargets: reviewTargets.summary,
    });
  }
  if (REWORK_TARGET_DECISIONS.has(decision) && !String(feedback || '').trim() && !targetFeedback) {
    return res.status(400).json({ error: `${decision} requires feedback.` });
  }

  const resolvedFeedback = String(feedback || '').trim() || targetFeedback || item.feedback || null;
  const annotations = listAnnotationsForSlug(req.params.slug);
  const reviewUrl = buildReviewUrl(getReviewBaseUrl(req), req.params.slug);
  const result = decisionOrchestrator.handleDecision(item, {
    decision,
    feedback: resolvedFeedback,
    annotations,
    reviewTargets: reviewTargets.targets,
    reviewUrl,
  });
  invalidateReviewCache(req.params.slug);
  // Decision may also create follow-up reviews (separate slugs).
  for (const followup of result.followups || []) invalidateReviewCache(followup.slug);

  res.json({
    status: result.status,
    decision,
    slug: req.params.slug,
    queued: result.requests.some((request) => request.status === 'queued'),
    processed: true,
    sessionKey: item.session_key || getSessionKey(item.slug),
    action: {
      status: result.requests.length ? 'queued' : 'succeeded',
      message: result.requests.length
        ? `Created ${result.requests.length} downstream request(s).`
        : `${decision} saved.`,
    },
    requests: result.requests.map((request) => ({
      id: request.id,
      kind: request.kind,
      status: request.status,
      summary: request.summary,
    })),
    reviewTargets: reviewTargets.summary,
    followups: result.followups.map((followup) => ({
      slug: followup.slug,
      title: followup.title,
      url: `/review/${followup.slug}`,
    })),
  });
});

app.get('/api/items/:slug/actions', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });
  res.json({
    slug: req.params.slug,
    requests: stmts.listDecisionRequestsForSlug.all(req.params.slug),
    legacyActions: stmts.listActionsForSlug.all(req.params.slug),
  });
});

app.post('/api/items/:slug/action/retry', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });

  const latestRequest = stmts.listDecisionRequestsForSlug.all(req.params.slug)[0];
  if (!latestRequest) {
    const latestAction = stmts.getLatestActionForSlug.get(req.params.slug);
    if (!latestAction) {
      return res.status(404).json({ error: 'No decision action exists for this review.' });
    }

    if (latestAction.status === 'running' || latestAction.status === 'queued') {
      return res.status(409).json({ error: `Action is already ${latestAction.status}.` });
    }

    stmts.requeueAction.run({ id: latestAction.id });
    updateActionState(req.params.slug, 'queued', `Queued ${latestAction.decision} action for retry.`);
    invalidateReviewCache(req.params.slug);
    scheduleActionDrain();
    return res.json({
      ok: true,
      slug: req.params.slug,
      action: {
        id: latestAction.id,
        status: 'queued',
        decision: latestAction.decision,
      },
    });
  }

  if (latestRequest.status === 'running' || latestRequest.status === 'queued') {
    return res.status(409).json({ error: `Request is already ${latestRequest.status}.` });
  }

  decisionOrchestrator.requeueRequest(latestRequest.id);
  decisionOrchestrator.updateItemActionSummary(req.params.slug);
  invalidateReviewCache(req.params.slug);
  res.json({
    ok: true,
    slug: req.params.slug,
    request: {
      id: latestRequest.id,
      status: 'queued',
      kind: latestRequest.kind,
    },
  });
});

app.get('/api/actions', (req, res) => {
  const status = typeof req.query.status === 'string' ? req.query.status : 'failed';
  const limit = Math.min(Number(req.query.limit || 50) || 50, 200);
  res.json({
    status,
    requests: stmts.listDecisionRequestsByStatus.all({ status, limit }),
    legacyActions: stmts.listActionsByStatus.all({ status, limit }),
  });
});

app.post('/api/worker/decision-requests/claim', (req, res) => {
  const claimed = decisionOrchestrator.claimExternalRequest({
    includeWaitingExternal: req.body?.includeWaitingExternal !== false,
  });

  if (!claimed) {
    return res.json({ ok: true, job: null });
  }

  const item = stmts.getBySlug.get(claimed.request.slug);
  if (!item) {
    void decisionOrchestrator.completeExternalRequest(claimed.request.id, {
      status: 'failed',
      error: `Review item disappeared before Mac worker claim: ${claimed.request.slug}`,
    }).catch((error) => console.error(`[worker] failed to mark orphaned request ${claimed.request.id}: ${error.message}`));
    return res.json({ ok: true, job: null });
  }

  const reviewBaseUrl = getReviewBaseUrl(req);
  res.json({
    ok: true,
    job: {
      mode: claimed.mode,
      request: claimed.request,
      item,
      annotations: listAnnotationsForSlug(item.slug),
      reviewTargets: listReviewTargetsForSlug(item.slug).targets,
      reviewUrl: buildReviewUrl(reviewBaseUrl, item.slug),
    },
  });
});

app.post('/api/worker/decision-requests/:id/complete', async (req, res, next) => {
  try {
    const result = await decisionOrchestrator.completeExternalRequest(req.params.id, req.body || {});
    invalidateReviewCache(result.slug);
    if (result.replacement?.slug) invalidateReviewCache(result.replacement.slug);
    if (result.followup?.slug) invalidateReviewCache(result.followup.slug);
    res.json({ ok: true, result });
  } catch (error) {
    next(error);
  }
});

app.post('/api/worker/notifications/claim', (_req, res) => {
  const notification = decisionOrchestrator.claimNotification();
  res.json({
    ok: true,
    notification,
  });
});

app.post('/api/worker/notifications/:id/complete', (req, res, next) => {
  try {
    const result = decisionOrchestrator.completeNotification(req.params.id, req.body || {});
    res.json({ ok: true, result });
  } catch (error) {
    next(error);
  }
});

// POST /api/items/:slug/dismiss — one-click remove from queue
app.post('/api/items/:slug/dismiss', (req, res) => {
  try {
    const result = stmts.dismiss.run({ slug: req.params.slug });
    if (result.changes === 0) return res.status(404).json({ error: 'Item not found' });
    invalidateReviewCache(req.params.slug);
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

const MAX_ANNOTATION_IMAGE_DATA_CHARS = Number(process.env.TURF_REVIEW_MAX_ANNOTATION_IMAGE_DATA_CHARS || 1_500_000);
const ALLOWED_ANNOTATION_IMAGE_MIMES = new Set(['image/png', 'image/jpeg', 'image/webp']);

function normalizeAnnotationImagePayload({ anchorType, imageData, imageMime }) {
  const data = typeof imageData === 'string' ? imageData.trim() : '';
  if (!data) return { imageData: null, imageMime: null };

  if (anchorType !== 'image') {
    return { error: 'image_data requires anchor_type image' };
  }

  if (data.length > MAX_ANNOTATION_IMAGE_DATA_CHARS) {
    return { error: 'image_data is too large' };
  }

  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(data)) {
    return { error: 'image_data must be base64 encoded' };
  }

  const mime = String(imageMime || 'image/png').trim().toLowerCase();
  if (!ALLOWED_ANNOTATION_IMAGE_MIMES.has(mime)) {
    return { error: 'image_mime must be image/png, image/jpeg, or image/webp' };
  }

  return { imageData: data, imageMime: mime };
}

// --- Annotation endpoints ---
app.post('/api/items/:slug/annotate', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });

  const { quote, anchor_type, anchor_ref, comment, image_data, image_mime } = req.body;
  if (!comment || !comment.trim()) {
    return res.status(400).json({ error: 'comment is required' });
  }

  const type = anchor_type === 'image' ? 'image' : 'text';
  const imagePayload = normalizeAnnotationImagePayload({
    anchorType: type,
    imageData: image_data,
    imageMime: image_mime,
  });
  if (imagePayload.error) {
    return res.status(400).json({ error: imagePayload.error });
  }
  const result = db.prepare(`
    INSERT INTO annotations (slug, quote, anchor_type, anchor_ref, comment, image_data, image_mime)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `).run(
    req.params.slug,
    quote || null,
    type,
    anchor_ref || null,
    comment.trim(),
    imagePayload.imageData,
    imagePayload.imageMime
  );

  const annotation = db.prepare('SELECT * FROM annotations WHERE id = ?').get(result.lastInsertRowid);
  invalidateReviewCache(req.params.slug);
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
  res.json(listAnnotationsForSlug(req.params.slug, { includeImageData: true }));
});

app.delete('/api/items/:slug/annotations/:id', (req, res) => {
  const result = db.prepare('DELETE FROM annotations WHERE id = ? AND slug = ?').run(req.params.id, req.params.slug);
  if (result.changes === 0) return res.status(404).json({ error: 'Annotation not found' });
  invalidateReviewCache(req.params.slug);
  res.json({ deleted: true });
});

// --- Regenerate context audio ---
app.post('/api/items/:slug/context/regenerate', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).json({ error: 'Not found' });
  db.prepare("UPDATE items SET context_status = 'generating' WHERE slug = ?").run(req.params.slug);
  invalidateReviewCache(req.params.slug);
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
  res.sendFile(path.join(config.paths.publicDir, 'funnel', 'index.html'));
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
             parent_slug, supersedes_slug, created_by_request_id,
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
  const slug = req.params.slug;
  const returnTab = ['decided', 'parked'].includes(req.query.fromTab) ? req.query.fromTab : 'pending';

  // ---- HTML response cache (loop 10) ----
  // Slug-keyed, bounded LRU. Cached HTML is per-slug and per-returnTab
  // (returnTab changes the back-button href). The CSRF token is NOT
  // emitted into review.ejs HTML (verified by grep), so the cached body
  // is identical for every authenticated user requesting the same slug
  // with the same fromTab tab. Cache is invalidated on every write to
  // items/annotations/decision_requests for this slug; see
  // invalidateReviewCache() below.
  const cacheKey = `${slug}|${returnTab}`;
  const cached = reviewHtmlCache.get(cacheKey);
  if (cached !== undefined) {
    res.set('content-type', 'text/html; charset=utf-8');
    res.set('x-review-cache', 'hit');
    return res.send(cached);
  }

  const rawItem = stmts.getBySlugForReviewPage.get(slug);
  if (!rawItem) return res.status(404).send('Not found');
  // Normalize has_markdown to a falsy/truthy primitive so existing
  // template checks like `if (!item.markdown && ...)` keep working.
  rawItem.markdown = rawItem.has_markdown ? '1' : '';
  const item = resolveAudioStatus(resolveAudioStatus(rawItem, 'tts'), 'context');
  const actions = getActions(item);
  const decisionRequests = stmts.listDecisionRequestsForSlug.all(slug);

  res.render('review', { item, actions, returnTab, hasChat: true, decisionRequests }, (err, html) => {
    if (err) {
      res.set('x-review-cache', 'miss-error');
      return res.status(500).send(err.message);
    }
    reviewHtmlCache.set(cacheKey, html);
    res.set('content-type', 'text/html; charset=utf-8');
    res.set('x-review-cache', 'miss');
    res.send(html);
  });
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

// Retry unsent decisions every 15 seconds when this node has local Benji/OpenClaw access.
if (!WEB_ONLY_MODE) {
  setInterval(() => {
    void drainDecisionOutbox();
  }, 15000);
}

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
const listenArgs = config.host ? [PORT, config.host] : [PORT];
const server = app.listen(...listenArgs, () => {
  const displayHost = config.host || 'localhost';
  console.log(`Turf Review running at http://${displayHost}:${PORT}`);
  if (!WEB_ONLY_MODE) {
    // Drain any decisions that were queued while downstream systems were down.
    void drainDecisionOutbox();
    void decisionOrchestrator.drainDecisionRequests();
  }
  // Pre-render top pending slugs so the first hit on each is already a cache
  // hit. Skipped if REVIEW_HTML_CACHE_WARM=0 (used by paired benches that
  // want a clean cold start).
  const warmCount = Number(process.env.REVIEW_HTML_CACHE_WARM ?? 10);
  if (warmCount > 0) setImmediate(() => warmReviewHtmlCache(warmCount));
});

function warmReviewHtmlCache(limit) {
  let rows = [];
  try {
    rows = stmts.listByStatus.all('pending').slice(0, limit);
  } catch (err) {
    console.error('[review-cache] warm listByStatus failed:', err.message);
    return;
  }
  if (!rows.length) return;
  const renderOne = (slug) => new Promise((resolve) => {
    try {
      const rawItem = stmts.getBySlugForReviewPage.get(slug);
      if (!rawItem) return resolve(false);
      rawItem.markdown = rawItem.has_markdown ? '1' : '';
      const item = resolveAudioStatus(resolveAudioStatus(rawItem, 'tts'), 'context');
      const actions = getActions(item);
      const decisionRequests = stmts.listDecisionRequestsForSlug.all(slug);
      // app.render() uses res.locals defaults; supply assetVersion explicitly.
      const renderOpts = {
        item,
        actions,
        returnTab: 'pending',
        hasChat: true,
        decisionRequests,
        assetVersion: ASSET_VERSION,
      };
      app.render('review', renderOpts, (err, html) => {
        if (err) {
          console.error(`[review-cache] warm render failed for ${slug}:`, err.message);
          return resolve(false);
        }
        reviewHtmlCache.set(`${slug}|pending`, html);
        resolve(true);
      });
    } catch (err) {
      console.error(`[review-cache] warm exception for ${slug}:`, err.message);
      resolve(false);
    }
  });
  (async () => {
    let warmed = 0;
    for (const row of rows) {
      const ok = await renderOne(row.slug);
      if (ok) warmed += 1;
    }
    console.log(`[review-cache] warmed ${warmed}/${rows.length} pending slugs at startup`);
  })();
}

server.on('error', (error) => {
  console.error(`[server] Failed to listen on port ${PORT}: ${error.message}`);
  process.exit(1);
});

require('dotenv').config();

const express = require('express');
const Database = require('better-sqlite3');
const { Marked } = require('marked');
const { markedHighlight } = require('marked-highlight');
const hljs = require('highlight.js');
const path = require('path');
const fs = require('fs');
const { execFile } = require('child_process');
const OpenAI = require('openai');
const multer = require('multer');

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 25 * 1024 * 1024 } });
const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

const app = express();
const PORT = process.env.PORT || 3457;

// --- Database setup ---
const dataDir = path.join(__dirname, 'data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir);

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
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
  )
`);

// Migrate: add columns if missing (for existing DBs)
try { db.exec('ALTER TABLE items ADD COLUMN decision TEXT'); } catch(e) {}
try { db.exec('ALTER TABLE items ADD COLUMN actions TEXT'); } catch(e) {}

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

app.use(session({
  secret: process.env.SESSION_SECRET || 'turf-review-' + (process.env.REVIEW_PASSWORD || 'secret'),
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

function notifyBenji(decision, title, slug, feedback) {
  const feedbackSnippet = feedback ? ` — Feedback: "${feedback.slice(0, 200)}"` : '';
  const text = `[Turf Review] Jimmy chose "${decision}" on "${title}"${feedbackSnippet}. Slug: ${slug}`;
  execFile('/opt/homebrew/bin/openclaw', ['system', 'event', '--text', text, '--mode', 'now'], (err) => {
    if (err) console.error('Failed to notify Benji:', err.message);
  });
}

function getActions(item) {
  if (item.actions) {
    try { return JSON.parse(item.actions); } catch(e) {}
  }
  return ['Approve', 'Reject'];
}

// --- Prepared statements ---
const stmts = {
  insert: db.prepare(`
    INSERT INTO items (slug, title, markdown, rendered_html, category, actions)
    VALUES (@slug, @title, @markdown, @rendered_html, @category, @actions)
  `),
  getBySlug: db.prepare('SELECT * FROM items WHERE slug = ?'),
  listAll: db.prepare('SELECT id, slug, title, category, status, decision, actions, feedback, created_at, updated_at FROM items ORDER BY created_at DESC'),
  listByStatus: db.prepare('SELECT id, slug, title, category, status, decision, actions, feedback, created_at, updated_at FROM items WHERE status = ? ORDER BY created_at DESC'),
  listByCategory: db.prepare('SELECT id, slug, title, category, status, decision, actions, feedback, created_at, updated_at FROM items WHERE category = ? ORDER BY created_at DESC'),
  listByStatusAndCategory: db.prepare('SELECT id, slug, title, category, status, decision, actions, feedback, created_at, updated_at FROM items WHERE status = ? AND category = ? ORDER BY created_at DESC'),
  decide: db.prepare(`UPDATE items SET status = 'decided', decision = @decision, feedback = @feedback, updated_at = datetime('now') WHERE slug = @slug`),
};

// --- API Routes ---

// Publish a new review item (markdown or raw HTML)
// actions: optional array of button labels. Default: ["Approve", "Reject"]
app.post('/api/publish', (req, res) => {
  try {
    const { title, markdown, html, slug: rawSlug, category, actions, taskId, projectId } = req.body;
    if (!title || (!markdown && !html)) {
      return res.status(400).json({ error: 'title and (markdown or html) are required' });
    }

    const slug = rawSlug ? slugify(rawSlug) : slugify(title) + '-' + Date.now().toString(36);
    const rendered_html = html || marked.parse(markdown);
    const source_markdown = markdown || '';
    const actionsJson = actions ? JSON.stringify(actions) : null;

    stmts.insert.run({
      slug,
      title,
      markdown: source_markdown,
      rendered_html,
      category: category || 'general',
      actions: actionsJson,
    });

    // Store Mindwtr linkage if provided
    if (taskId || projectId) {
      db.prepare('UPDATE items SET mindwtr_task_id = ?, mindwtr_project_id = ? WHERE slug = ?')
        .run(taskId || null, projectId || null, slug);
    }

    res.status(201).json({ slug, url: `/review/${slug}` });
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

  stmts.decide.run({ decision, feedback: feedback || item.feedback || null, slug: req.params.slug });
  const taskRef = item.mindwtr_task_id ? ` Task: ${item.mindwtr_task_id}` : '';
  const projRef = item.mindwtr_project_id ? ` Project: ${item.mindwtr_project_id}` : '';
  notifyBenji(decision, item.title, req.params.slug, feedback ? feedback + taskRef + projRef : taskRef + projRef || feedback);
  res.json({ status: 'decided', decision, slug: req.params.slug });
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

// Transcribe audio via OpenAI Whisper
app.post('/api/transcribe', upload.single('audio'), async (req, res) => {
  try {
    if (!req.file) return res.status(400).json({ error: 'No audio file' });

    // Whisper needs a file-like object with a name
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

// --- Web Routes ---

// Dashboard
app.get('/', (req, res) => {
  const tab = req.query.tab || 'pending';
  let items;
  if (tab === 'all') {
    items = stmts.listAll.all();
  } else {
    items = stmts.listByStatus.all(tab);
  }
  const counts = {
    pending: stmts.listByStatus.all('pending').length,
    decided: stmts.listByStatus.all('decided').length,
    all: stmts.listAll.all().length,
  };
  res.render('dashboard', { items, tab, counts });
});

// Review page
app.get('/review/:slug', (req, res) => {
  const item = stmts.getBySlug.get(req.params.slug);
  if (!item) return res.status(404).send('Not found');
  const actions = getActions(item);
  res.render('review', { item, actions });
});

// --- Start ---
app.listen(PORT, () => {
  console.log(`Turf Review running at http://localhost:${PORT}`);
});

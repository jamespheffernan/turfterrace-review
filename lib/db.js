const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const Database = require('better-sqlite3');

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function tryExec(db, sql) {
  try {
    db.exec(sql);
  } catch (_error) {
    // Migration column/index already exists.
  }
}

function createContentHash(title, markdown) {
  return crypto.createHash('sha256').update(`${title}\n---\n${markdown || ''}`, 'utf8').digest('hex');
}

function backfillContentHashes(db) {
  try {
    const legacyRows = db.prepare('SELECT id, title, markdown FROM items WHERE content_hash IS NULL').all();
    const updateContentHash = db.prepare('UPDATE items SET content_hash = ? WHERE id = ?');
    const tx = db.transaction((rows) => {
      for (const row of rows) {
        updateContentHash.run(createContentHash(row.title, row.markdown || ''), row.id);
      }
    });
    tx(legacyRows);
  } catch (error) {
    console.error('Failed to backfill content hashes:', error.message);
  }
}

function setupReviewSchema(db) {
  db.pragma('journal_mode = WAL');
  db.pragma('busy_timeout = 5000');
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
      artifact_type TEXT NOT NULL DEFAULT 'markdown',
      artifact_html TEXT,
      mindwtr_task_id TEXT,
      mindwtr_project_id TEXT,
      on_approve TEXT,
      session_key TEXT,
      origin_session_key TEXT,
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
      parent_slug TEXT,
      supersedes_slug TEXT,
      created_by_request_id INTEGER,
      workflow_state TEXT,
      public_verification_status TEXT,
      public_verification_message TEXT,
      public_verification_checked_at TEXT,
      migration_marker TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now'))
    )
  `);

  [
    'ALTER TABLE items ADD COLUMN decision TEXT',
    'ALTER TABLE items ADD COLUMN actions TEXT',
    'ALTER TABLE items ADD COLUMN content_hash TEXT',
    "ALTER TABLE items ADD COLUMN artifact_type TEXT NOT NULL DEFAULT 'markdown'",
    'ALTER TABLE items ADD COLUMN artifact_html TEXT',
    'ALTER TABLE items ADD COLUMN mindwtr_task_id TEXT',
    'ALTER TABLE items ADD COLUMN mindwtr_project_id TEXT',
    'ALTER TABLE items ADD COLUMN on_approve TEXT',
    'ALTER TABLE items ADD COLUMN session_key TEXT',
    'ALTER TABLE items ADD COLUMN origin_session_key TEXT',
    'ALTER TABLE items ADD COLUMN workspace_dir TEXT',
    'ALTER TABLE items ADD COLUMN source_path TEXT',
    'ALTER TABLE items ADD COLUMN decision_schema_version INTEGER DEFAULT 1',
    'ALTER TABLE items ADD COLUMN action_status TEXT DEFAULT NULL',
    'ALTER TABLE items ADD COLUMN action_message TEXT',
    'ALTER TABLE items ADD COLUMN action_updated_at TEXT',
    'ALTER TABLE items ADD COLUMN tts_status TEXT DEFAULT NULL',
    'ALTER TABLE items ADD COLUMN context_status TEXT DEFAULT NULL',
    'ALTER TABLE items ADD COLUMN context_summary TEXT',
    'ALTER TABLE items ADD COLUMN approval_status TEXT DEFAULT NULL',
    'ALTER TABLE items ADD COLUMN approval_message TEXT',
    'ALTER TABLE items ADD COLUMN approval_exit_code INTEGER',
    'ALTER TABLE items ADD COLUMN approval_updated_at TEXT',
    'ALTER TABLE items ADD COLUMN parent_slug TEXT',
    'ALTER TABLE items ADD COLUMN supersedes_slug TEXT',
    'ALTER TABLE items ADD COLUMN created_by_request_id INTEGER',
    'ALTER TABLE items ADD COLUMN workflow_state TEXT',
    'ALTER TABLE items ADD COLUMN public_verification_status TEXT',
    'ALTER TABLE items ADD COLUMN public_verification_message TEXT',
    'ALTER TABLE items ADD COLUMN public_verification_checked_at TEXT',
    'ALTER TABLE items ADD COLUMN migration_marker TEXT',
    'CREATE INDEX IF NOT EXISTS idx_items_content_hash ON items(content_hash)',
    'CREATE INDEX IF NOT EXISTS idx_items_session_key ON items(session_key)',
    'CREATE INDEX IF NOT EXISTS idx_items_origin_session_key ON items(origin_session_key)',
    'CREATE INDEX IF NOT EXISTS idx_items_parent_slug ON items(parent_slug)',
  ].forEach((sql) => tryExec(db, sql));

  db.exec(`
    CREATE TABLE IF NOT EXISTS review_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL,
      event_type TEXT NOT NULL,
      actor TEXT NOT NULL DEFAULT 'system',
      source TEXT NOT NULL DEFAULT 'kernel',
      transition TEXT,
      payload_json TEXT NOT NULL DEFAULT '{}',
      proof_ref TEXT,
      provenance TEXT NOT NULL DEFAULT 'live',
      created_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (slug) REFERENCES items(slug)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_review_events_slug_created ON review_events(slug, created_at, id)');
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_review_events_type ON review_events(event_type, created_at)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS annotations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL,
      quote TEXT,
      anchor_type TEXT NOT NULL DEFAULT 'text',
      anchor_ref TEXT,
      comment TEXT NOT NULL,
      image_data TEXT,
      image_mime TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (slug) REFERENCES items(slug)
    )
  `);
  [
    'ALTER TABLE annotations ADD COLUMN image_data TEXT',
    'ALTER TABLE annotations ADD COLUMN image_mime TEXT',
  ].forEach((sql) => tryExec(db, sql));
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_annotations_slug ON annotations(slug)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS review_targets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL,
      target_key TEXT NOT NULL,
      label TEXT NOT NULL,
      source_type TEXT NOT NULL DEFAULT 'approval_list',
      anchor_ref TEXT,
      ordinal INTEGER NOT NULL DEFAULT 0,
      active INTEGER NOT NULL DEFAULT 1,
      text_hash TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now')),
      UNIQUE(slug, target_key),
      FOREIGN KEY (slug) REFERENCES items(slug)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_review_targets_slug_active ON review_targets(slug, active, ordinal)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS review_target_judgments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL,
      target_key TEXT NOT NULL,
      verdict TEXT NOT NULL,
      feedback TEXT,
      actor TEXT NOT NULL DEFAULT 'jimmy',
      decided_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now')),
      UNIQUE(slug, target_key),
      FOREIGN KEY (slug, target_key) REFERENCES review_targets(slug, target_key)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_review_target_judgments_slug ON review_target_judgments(slug, updated_at)');

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
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_decision_outbox_pending ON decision_outbox(sent_at, created_at)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS decision_actions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL,
      decision TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'queued',
      payload TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      max_attempts INTEGER NOT NULL DEFAULT 3,
      last_error TEXT,
      next_attempt_at TEXT,
      claimed_at TEXT,
      completed_at TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (slug) REFERENCES items(slug)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_decision_actions_slug ON decision_actions(slug, created_at)');
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_decision_actions_runnable ON decision_actions(status, next_attempt_at, created_at)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS review_intents (
      slug TEXT PRIMARY KEY,
      kind TEXT NOT NULL DEFAULT 'general_review',
      summary TEXT,
      needed_from_jimmy TEXT,
      on_approval_kind TEXT,
      on_approval_payload TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (slug) REFERENCES items(slug)
    )
  `);

  db.exec(`
    CREATE TABLE IF NOT EXISTS decisions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL,
      decision TEXT NOT NULL,
      feedback TEXT,
      actor TEXT NOT NULL DEFAULT 'jimmy',
      status TEXT NOT NULL DEFAULT 'recorded',
      created_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (slug) REFERENCES items(slug)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_decisions_slug_created ON decisions(slug, created_at)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS decision_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      decision_id INTEGER,
      slug TEXT NOT NULL,
      parent_request_id INTEGER,
      kind TEXT NOT NULL,
      summary TEXT NOT NULL,
      sensitivity TEXT NOT NULL DEFAULT 'normal',
      status TEXT NOT NULL DEFAULT 'queued',
      payload TEXT NOT NULL DEFAULT '{}',
      proof_json TEXT,
      confirmation_slug TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      max_attempts INTEGER NOT NULL DEFAULT 3,
      last_error TEXT,
      next_attempt_at TEXT,
      claimed_at TEXT,
      completed_at TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (decision_id) REFERENCES decisions(id),
      FOREIGN KEY (slug) REFERENCES items(slug),
      FOREIGN KEY (parent_request_id) REFERENCES decision_requests(id)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_decision_requests_slug ON decision_requests(slug, created_at)');
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_decision_requests_status ON decision_requests(status, next_attempt_at, created_at)');
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_decision_requests_confirmation_slug ON decision_requests(confirmation_slug)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS action_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request_id INTEGER NOT NULL,
      attempt INTEGER NOT NULL,
      status TEXT NOT NULL,
      error TEXT,
      proof_json TEXT,
      started_at TEXT DEFAULT (datetime('now')),
      completed_at TEXT,
      FOREIGN KEY (request_id) REFERENCES decision_requests(id)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_action_runs_request ON action_runs(request_id, started_at)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS outcome_proofs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request_id INTEGER NOT NULL,
      proof_type TEXT NOT NULL,
      external_id TEXT,
      payload_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (request_id) REFERENCES decision_requests(id)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_outcome_proofs_request ON outcome_proofs(request_id, created_at)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS notifications (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request_id INTEGER,
      channel TEXT NOT NULL,
      audience TEXT NOT NULL,
      kind TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'queued',
      payload_json TEXT NOT NULL DEFAULT '{}',
      last_error TEXT,
      sent_at TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      updated_at TEXT DEFAULT (datetime('now')),
      FOREIGN KEY (request_id) REFERENCES decision_requests(id)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_notifications_status ON notifications(status, created_at)');
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_notifications_request ON notifications(request_id)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS push_devices (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_token TEXT NOT NULL,
      platform TEXT NOT NULL CHECK (platform IN ('ios', 'macos')),
      environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
      bundle_id TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
      invalidated_at TEXT,
      last_registered_at TEXT NOT NULL DEFAULT (datetime('now')),
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(device_token, environment, bundle_id)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_push_devices_active ON push_devices(active, id)');

  db.exec(`
    CREATE TABLE IF NOT EXISTS push_deliveries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      review_slug TEXT NOT NULL,
      device_id INTEGER NOT NULL,
      apns_id TEXT NOT NULL,
      response_apns_id TEXT,
      status TEXT NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'sending', 'sent', 'failed')),
      attempts INTEGER NOT NULL DEFAULT 0,
      next_attempt_at TEXT,
      claimed_at TEXT,
      sent_at TEXT,
      last_error TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      FOREIGN KEY (review_slug) REFERENCES items(slug),
      FOREIGN KEY (device_id) REFERENCES push_devices(id),
      UNIQUE(review_slug, device_id),
      UNIQUE(apns_id)
    )
  `);
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_push_deliveries_ready ON push_deliveries(status, next_attempt_at, created_at)');
  tryExec(db, 'CREATE INDEX IF NOT EXISTS idx_push_deliveries_review ON push_deliveries(review_slug, device_id)');

  backfillContentHashes(db);
}

function createReviewDatabase({ dataDir, filename = 'reviews.db' } = {}) {
  if (!dataDir) throw new Error('dataDir is required');
  ensureDir(dataDir);

  const db = new Database(path.join(dataDir, filename));
  setupReviewSchema(db);
  return db;
}

module.exports = {
  createContentHash,
  createReviewDatabase,
  ensureDir,
  setupReviewSchema,
};

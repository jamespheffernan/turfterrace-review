const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

const { createContentHash, createReviewDatabase } = require('../lib/db');
const { createReviewStatements } = require('../lib/reviews/repository');
const { applyKernelMigration, auditKernelMigration } = require('../lib/reviews/kernel/migrations');
const { DECISION_SCHEMA_VERSION, getCanonicalActions, getSessionKey } = require('../lib/review-routing');

function createStore(t) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-migration-'));
  const db = createReviewDatabase({ dataDir });
  const stmts = createReviewStatements(db);
  t.after(() => {
    db.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  });
  return { db, stmts };
}

function insertItem(stmts, overrides = {}) {
  const slug = overrides.slug || 'tracked-plan';
  const title = overrides.title || 'Tracked plan';
  const markdown = overrides.markdown || '# Tracked plan';
  stmts.insert.run({
    slug,
    title,
    markdown,
    rendered_html: '<h1>Tracked plan</h1>',
    artifact_type: overrides.artifact_type || 'markdown',
    artifact_html: overrides.artifact_html || null,
    category: overrides.category || 'general',
    actions: JSON.stringify(getCanonicalActions(overrides.category || 'general')),
    content_hash: createContentHash(title, markdown),
    mindwtr_task_id: null,
    mindwtr_project_id: null,
    on_approve: null,
    session_key: getSessionKey(slug),
    workspace_dir: overrides.workspace_dir || null,
    source_path: overrides.source_path || null,
    decision_schema_version: overrides.decision_schema_version || DECISION_SCHEMA_VERSION,
    parent_slug: null,
    supersedes_slug: null,
    created_by_request_id: null,
  });
}

test('migration audit classifies executable and legacy readonly items without writes', (t) => {
  const { db, stmts } = createStore(t);
  insertItem(stmts, {
    slug: 'tracked-plan',
    workspace_dir: '/repo',
    source_path: '/repo/docs/plan.md',
  });
  insertItem(stmts, {
    slug: 'legacy-plan',
    decision_schema_version: 1,
  });

  const beforeEvents = db.prepare('SELECT COUNT(*) AS count FROM review_events').get().count;
  const report = auditKernelMigration({ db, stmts });
  const afterEvents = db.prepare('SELECT COUNT(*) AS count FROM review_events').get().count;

  assert.equal(report.total, 2);
  assert.equal(report.items.find((item) => item.slug === 'tracked-plan').proposedAction, 'migrate_executable');
  assert.equal(report.items.find((item) => item.slug === 'legacy-plan').proposedAction, 'legacy_readonly');
  assert.equal(beforeEvents, afterEvents);
});

test('migration apply writes migrated events and is idempotent', (t) => {
  const { db, stmts } = createStore(t);
  insertItem(stmts, {
    slug: 'tracked-plan',
    workspace_dir: '/repo',
    source_path: '/repo/docs/plan.md',
  });

  const first = applyKernelMigration({ db, stmts, backupPath: '/tmp/reviews.db.backup' });
  const second = applyKernelMigration({ db, stmts, backupPath: '/tmp/reviews.db.backup' });
  const item = stmts.getBySlug.get('tracked-plan');
  const events = stmts.listReviewEventsForSlug.all('tracked-plan');

  assert.equal(first.applied, true);
  assert.equal(second.applied, true);
  assert.match(item.migration_marker, /^kernel-v1:/);
  assert.equal(events.length, 1);
  assert.equal(events[0].provenance, 'migrated');
});

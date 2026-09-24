const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

const { createContentHash, createReviewDatabase } = require('../lib/db');
const { createReviewStatements } = require('../lib/reviews/repository');
const {
  appendReviewEvent,
  listReviewEvents,
  replayWorkflowState,
} = require('../lib/reviews/kernel/lifecycle');
const { DECISION_SCHEMA_VERSION, getCanonicalActions, getSessionKey } = require('../lib/review-routing');

function createStore(t) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-lifecycle-'));
  const db = createReviewDatabase({ dataDir });
  const stmts = createReviewStatements(db);
  t.after(() => {
    db.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  });
  return { db, stmts };
}

function insertItem(stmts) {
  stmts.insert.run({
    slug: 'kernel-plan',
    title: 'Kernel plan',
    markdown: '# Kernel plan',
    rendered_html: '<h1>Kernel plan</h1>',
    artifact_type: 'markdown',
    artifact_html: null,
    category: 'general',
    actions: JSON.stringify(getCanonicalActions('general')),
    content_hash: createContentHash('Kernel plan', '# Kernel plan'),
    mindwtr_task_id: null,
    mindwtr_project_id: null,
    on_approve: null,
    session_key: getSessionKey('kernel-plan'),
    workspace_dir: null,
    source_path: null,
    decision_schema_version: DECISION_SCHEMA_VERSION,
    parent_slug: null,
    supersedes_slug: null,
    created_by_request_id: null,
  });
  return stmts.getBySlug.get('kernel-plan');
}

test('review events append and replay workflow state', (t) => {
  const { stmts } = createStore(t);
  const item = insertItem(stmts);

  appendReviewEvent(stmts, item.slug, {
    eventType: 'publish_intent',
    actor: 'operator',
    source: 'api',
    transition: 'publish_intent',
    payload: { title: item.title },
  });
  appendReviewEvent(stmts, item.slug, {
    eventType: 'public_verified',
    actor: 'system',
    source: 'publish',
    transition: 'public_verified',
    provenance: 'live',
  });
  appendReviewEvent(stmts, item.slug, {
    eventType: 'action_recorded',
    actor: 'jimmy',
    source: 'web',
    transition: 'action_recorded',
    payload: { action: 'Execute' },
  });

  const events = listReviewEvents(stmts, item.slug);
  assert.equal(events.length, 3);
  assert.equal(events[1].provenance, 'live');
  assert.deepEqual(JSON.parse(events[2].payload_json), { action: 'Execute' });
  assert.equal(replayWorkflowState(events).state, 'action_recorded');
});

test('SQLite is configured for concurrent server and worker writes', (t) => {
  const { db } = createStore(t);
  assert.equal(db.pragma('journal_mode', { simple: true }).toLowerCase(), 'wal');
  assert.ok(Number(db.pragma('busy_timeout', { simple: true })) >= 5000);
});

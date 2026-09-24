const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

const { createContentHash, createReviewDatabase } = require('../lib/db');
const { createReviewStatements } = require('../lib/reviews/repository');
const { DECISION_SCHEMA_VERSION, getSessionKey } = require('../lib/review-routing');

function createTestStore() {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-actions-'));
  const db = createReviewDatabase({ dataDir });
  const stmts = createReviewStatements(db);

  stmts.insert.run({
    slug: 'sample-action',
    title: 'Sample Action',
    markdown: '# Sample',
    rendered_html: '<h1>Sample</h1>',
    artifact_type: 'markdown',
    artifact_html: null,
    category: 'general',
    actions: JSON.stringify(['Noted', 'Execute', 'Inbox', 'Rework', 'Kill']),
    content_hash: createContentHash('Sample Action', '# Sample'),
    mindwtr_task_id: null,
    mindwtr_project_id: null,
    on_approve: null,
    session_key: getSessionKey('sample-action'),
    workspace_dir: dataDir,
    source_path: path.join(dataDir, 'sample.md'),
    decision_schema_version: DECISION_SCHEMA_VERSION,
    parent_slug: null,
    supersedes_slug: null,
    created_by_request_id: null,
  });

  return { db, stmts, dataDir };
}

test('decision action queue records, claims, and completes work durably', (t) => {
  const { db, stmts, dataDir } = createTestStore();
  t.after(() => {
    db.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  });

  stmts.enqueueAction.run({
    slug: 'sample-action',
    decision: 'Execute',
    payload: JSON.stringify({ decision: 'Execute', slug: 'sample-action' }),
    max_attempts: 3,
  });

  const runnable = stmts.listRunnableActions.all({ limit: 10 });
  assert.equal(runnable.length, 1);
  assert.equal(runnable[0].status, 'queued');
  assert.equal(stmts.listActionsByStatus.all({ status: 'queued', limit: 10 }).length, 1);

  const claim = stmts.markActionRunning.run({ id: runnable[0].id });
  assert.equal(claim.changes, 1);

  stmts.markActionDone.run({
    id: runnable[0].id,
    status: 'succeeded',
    last_error: null,
  });

  const latest = stmts.getLatestActionForSlug.get('sample-action');
  assert.equal(latest.status, 'succeeded');
  assert.equal(latest.attempts, 1);
  assert.equal(latest.completed_at !== null, true);
});

test('failed decision actions can be requeued explicitly', (t) => {
  const { db, stmts, dataDir } = createTestStore();
  t.after(() => {
    db.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  });

  stmts.enqueueAction.run({
    slug: 'sample-action',
    decision: 'Execute',
    payload: JSON.stringify({ decision: 'Execute', slug: 'sample-action' }),
    max_attempts: 3,
  });

  const action = stmts.listRunnableActions.all({ limit: 1 })[0];
  stmts.markActionRunning.run({ id: action.id });
  stmts.markActionFailed.run({
    id: action.id,
    last_error: 'OpenClaw unavailable',
    retry_modifier: '+60 seconds',
  });

  let latest = stmts.getLatestActionForSlug.get('sample-action');
  assert.equal(latest.status, 'failed');
  assert.equal(latest.last_error, 'OpenClaw unavailable');

  stmts.requeueAction.run({ id: action.id });
  latest = stmts.getLatestActionForSlug.get('sample-action');
  assert.equal(latest.status, 'queued');
  assert.equal(latest.attempts, 0);
  assert.equal(latest.last_error, null);
});

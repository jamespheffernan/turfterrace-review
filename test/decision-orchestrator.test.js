const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

const { createContentHash, createReviewDatabase } = require('../lib/db');
const { createDecisionOrchestrator } = require('../lib/reviews/orchestrator');
const { createReviewStatements } = require('../lib/reviews/repository');
const { DECISION_SCHEMA_VERSION, getCanonicalActions, getSessionKey } = require('../lib/review-routing');

function createStore(t) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-orchestrator-'));
  const db = createReviewDatabase({ dataDir });
  const stmts = createReviewStatements(db);

  t.after(() => {
    db.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  });

  return { db, stmts, dataDir };
}

function insertReview(stmts, overrides = {}) {
  const slug = overrides.slug || 'parent-review';
  const title = overrides.title || 'Parent Review';
  const markdown = overrides.markdown || '# Parent Review';
  const category = overrides.category || 'general';

  stmts.insert.run({
    slug,
    title,
    markdown,
    rendered_html: overrides.rendered_html || '<h1>Parent Review</h1>',
    category,
    actions: JSON.stringify(getCanonicalActions(category)),
    content_hash: createContentHash(title, markdown),
    mindwtr_task_id: null,
    mindwtr_project_id: null,
    on_approve: overrides.on_approve || null,
    session_key: getSessionKey(slug),
    workspace_dir: null,
    source_path: null,
    decision_schema_version: DECISION_SCHEMA_VERSION,
    parent_slug: overrides.parent_slug || null,
    supersedes_slug: null,
    created_by_request_id: overrides.created_by_request_id || null,
  });

  return stmts.getBySlug.get(slug);
}

function createOrchestrator(db, stmts) {
  return createDecisionOrchestrator({
    config: {
      reviewBaseUrl: 'https://review.turfterrace.com',
      openclaw: { bin: '/opt/homebrew/bin/openclaw', telegramTarget: '8339963854', telegramReplyTo: '' },
      integrations: {},
    },
    db,
    stmts,
    openclawClient: null,
    appendSessionNote: async () => null,
    seedSessionForItem: async () => null,
    broadcastSSE: () => {},
  });
}

test('confirmation follow-up resolves the source request and creates child work', (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const orchestrator = createOrchestrator(db, stmts);
  const item = insertReview(stmts);
  orchestrator.recordIntentForItem(item);

  const first = orchestrator.handleDecision(item, {
    decision: 'Execute',
    feedback: 'send this email tomorrow',
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/parent-review',
  });

  assert.equal(first.followups.length, 1);
  const sourceRequest = stmts.listDecisionRequestsForSlug.all(item.slug)[0];
  assert.equal(sourceRequest.status, 'needs_confirmation');

  const followup = stmts.getBySlug.get(first.followups[0].slug);
  const second = orchestrator.handleDecision(followup, {
    decision: 'Approve',
    feedback: '',
    annotations: [],
    reviewUrl: `https://review.turfterrace.com/review/${followup.slug}`,
  });

  assert.equal(second.requests.length, 1);
  assert.equal(second.requests[0].kind, 'send_message');

  const resolvedSource = stmts.getDecisionRequestById.get(sourceRequest.id);
  assert.equal(resolvedSource.status, 'succeeded');
  assert.match(resolvedSource.proof_json, /continued_to_downstream_request/);

  const childRequest = stmts.listDecisionRequestsForSlug.all(followup.slug)[0];
  assert.equal(childRequest.parent_request_id, sourceRequest.id);
  assert.equal(childRequest.status, 'queued');
});

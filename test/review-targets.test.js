const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

const { createContentHash, createReviewDatabase } = require('../lib/db');
const { createReviewStatements } = require('../lib/reviews/repository');
const {
  extractReviewTargets,
  listReviewTargetsForItem,
  normalizeTargetVerdict,
} = require('../lib/reviews/review-targets');
const { DECISION_SCHEMA_VERSION, getCanonicalActions, getSessionKey } = require('../lib/review-routing');

function createStore(t) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-targets-'));
  const db = createReviewDatabase({ dataDir });
  const stmts = createReviewStatements(db);

  t.after(() => {
    db.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  });

  return { db, stmts };
}

function insertReview(stmts, overrides = {}) {
  const title = overrides.title || 'Target review';
  const markdown = overrides.markdown || '# Target review';
  const category = overrides.category || 'general';
  const slug = overrides.slug || 'target-review';

  stmts.insert.run({
    slug,
    title,
    markdown,
    rendered_html: overrides.rendered_html || '<h1>Target review</h1>',
    category,
    actions: JSON.stringify(getCanonicalActions(category)),
    content_hash: createContentHash(title, markdown),
    mindwtr_task_id: null,
    mindwtr_project_id: null,
    on_approve: null,
    session_key: getSessionKey(slug),
    workspace_dir: null,
    source_path: null,
    decision_schema_version: DECISION_SCHEMA_VERSION,
    parent_slug: null,
    supersedes_slug: null,
    created_by_request_id: null,
  });

  return stmts.getBySlug.get(slug);
}

test('extractReviewTargets finds task list items and approval section bullets', () => {
  const targets = extractReviewTargets([
    '# Packet',
    '',
    '- ordinary bullet',
    '',
    '## Approval list',
    '- First candidate',
    '- [ ] Second candidate',
    '',
    '## Notes',
    '- not a target',
  ].join('\n'));

  assert.equal(targets.length, 2);
  assert.equal(targets[0].label, 'First candidate');
  assert.equal(targets[0].source_type, 'approval_list');
  assert.equal(targets[1].label, 'Second candidate');
  assert.equal(targets[1].source_type, 'task_list');
  assert.match(targets[1].target_key, /^task:approval-list:002:/);
});

test('listReviewTargetsForItem syncs targets idempotently and preserves judgments', (t) => {
  const { stmts } = createStore(t);
  const item = insertReview(stmts, {
    markdown: [
      '# Target review',
      '',
      '## Approval checklist',
      '- [ ] Keep this candidate',
      '- [ ] Reject this candidate',
    ].join('\n'),
  });

  const first = listReviewTargetsForItem(stmts, item);
  assert.equal(first.summary.total, 2);
  assert.equal(first.summary.undecided, 2);

  stmts.upsertReviewTargetJudgment.run({
    slug: item.slug,
    target_key: first.targets[1].key,
    verdict: 'rejected',
    feedback: 'Missing proof.',
    actor: 'jimmy',
  });

  const second = listReviewTargetsForItem(stmts, item);
  assert.equal(second.summary.total, 2);
  assert.equal(second.summary.rejected, 1);
  assert.equal(second.targets[1].feedback, 'Missing proof.');

  const third = listReviewTargetsForItem(stmts, item);
  assert.equal(third.summary.total, 2);
  assert.deepEqual(third.targets.map((target) => target.key), second.targets.map((target) => target.key));
});

test('changed target labels create new active keys without deleting old judgments', (t) => {
  const { db, stmts } = createStore(t);
  const item = insertReview(stmts, {
    markdown: [
      '# Target review',
      '',
      '## Approval checklist',
      '- [ ] Original candidate',
    ].join('\n'),
  });

  const first = listReviewTargetsForItem(stmts, item);
  stmts.upsertReviewTargetJudgment.run({
    slug: item.slug,
    target_key: first.targets[0].key,
    verdict: 'approved',
    feedback: null,
    actor: 'jimmy',
  });

  db.prepare('UPDATE items SET markdown = ? WHERE slug = ?').run([
    '# Target review',
    '',
    '## Approval checklist',
    '- [ ] Replacement candidate',
  ].join('\n'), item.slug);

  const updatedItem = stmts.getBySlug.get(item.slug);
  const second = listReviewTargetsForItem(stmts, updatedItem);
  assert.equal(second.summary.total, 1);
  assert.equal(second.targets[0].label, 'Replacement candidate');
  assert.notEqual(second.targets[0].key, first.targets[0].key);
  assert.equal(db.prepare('SELECT COUNT(*) AS count FROM review_target_judgments WHERE slug = ?').get(item.slug).count, 1);
});

test('normalizeTargetVerdict maps yes no and clear inputs', () => {
  assert.equal(normalizeTargetVerdict('yes'), 'approved');
  assert.equal(normalizeTargetVerdict(' rejected '), 'rejected');
  assert.equal(normalizeTargetVerdict('clear'), 'unset');
  assert.equal(normalizeTargetVerdict(''), null);
  assert.equal(normalizeTargetVerdict('maybe'), null);
});

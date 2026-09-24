const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

const { createContentHash, createReviewDatabase } = require('../lib/db');
const { createReviewStatements } = require('../lib/reviews/repository');
const {
  compactReviewTarget,
  describeReviewTargetDecision,
  extractReviewTargets,
  listReviewTargetsForItem,
  normalizeTargetVerdict,
  summarizeReviewTargets,
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

test('review items expose their actual choices instead of a binary judgment', () => {
  const scopeDecision = describeReviewTargetDecision(
    'Decide whether the 12 uncertain candidates should be included, excluded, or merged into an owner project.'
  );
  assert.equal(scopeDecision.kind, 'choice');
  assert.deepEqual(scopeDecision.options.map((option) => option.label), ['Include', 'Exclude', 'Merge']);

  const sourceDecision = describeReviewTargetDecision(
    'For Breathe Clock, identify the canonical source among ~/Breathe Clock, turfterrace-review/BreatheClock, and clawd/projects/breathe-clock-live.'
  );
  assert.equal(sourceDecision.kind, 'choice');
  assert.deepEqual(sourceDecision.options.map((option) => option.label), [
    '~/Breathe Clock',
    'turfterrace-review/BreatheClock',
    'clawd/projects/breathe-clock-live',
  ]);

  assert.equal(describeReviewTargetDecision('Approve the proposed scope.').kind, 'approval');

  const summary = summarizeReviewTargets([
    { verdict: `choice:${scopeDecision.options[0].value}` },
    { verdict: 'unset' },
  ]);
  assert.equal(summary.decided, 1);
  assert.equal(summary.undecided, 1);
  assert.equal(summary.complete, false);
});

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
    artifact_type: overrides.artifact_type || 'markdown',
    artifact_html: overrides.artifact_html || null,
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

test('extractReviewTargets supports items to review heading', () => {
  const targets = extractReviewTargets([
    '# Packet',
    '',
    '## Items to review',
    '- [ ] First decision',
    '- [x] Already checked still needs a verdict',
    '- Plain approval bullet',
  ].join('\n'));

  assert.equal(targets.length, 3);
  assert.deepEqual(targets.map((target) => target.label), [
    'First decision',
    'Already checked still needs a verdict',
    'Plain approval bullet',
  ]);
});

test('extractReviewTargets ignores task lists outside designated target sections', () => {
  const targets = extractReviewTargets([
    '# Plan',
    '',
    '## Requirements',
    '- [ ] This is implementation work, not a review target',
    '',
    '## Acceptance Examples',
    '- [ ] This should not become a target either',
    '',
    '## Definition of Done',
    '- [ ] Tests pass',
    '',
    '## Items to review',
    '- [ ] Only this belongs to Jimmy',
  ].join('\n'));

  assert.equal(targets.length, 1);
  assert.equal(targets[0].label, 'Only this belongs to Jimmy');
});

test('extractReviewTargets lets explicit manifest targets override markdown shorthand', () => {
  const targets = extractReviewTargets([
    '# Plan',
    '',
    '## Items to review',
    '- [ ] Markdown fallback',
  ].join('\n'), {
    targets: [
      { id: 'keep-provenance', label: 'Keep source provenance mandatory' },
    ],
  });

  assert.equal(targets.length, 1);
  assert.equal(targets[0].target_key, 'manifest:keep-provenance');
  assert.equal(targets[0].source_type, 'manifest');
  assert.equal(targets[0].label, 'Keep source provenance mandatory');
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

test('read-only target rendering does not deactivate active targets', (t) => {
  const { db, stmts } = createStore(t);
  const item = insertReview(stmts, {
    markdown: [
      '# Target review',
      '',
      '## Items to review',
      '- [ ] Keep this item',
    ].join('\n'),
  });

  const synced = listReviewTargetsForItem(stmts, item);
  assert.equal(synced.summary.total, 1);

  const rows = stmts.listReviewTargetsForSlug.all(item.slug).map(compactReviewTarget);
  const summary = summarizeReviewTargets(rows);
  assert.equal(summary.total, 1);

  const active = db.prepare('SELECT COUNT(*) AS count FROM review_targets WHERE slug = ? AND active = 1').get(item.slug);
  assert.equal(active.count, 1);
});

test('normalizeTargetVerdict maps yes no and clear inputs', () => {
  assert.equal(normalizeTargetVerdict('yes'), 'approved');
  assert.equal(normalizeTargetVerdict(' rejected '), 'rejected');
  assert.equal(normalizeTargetVerdict('clear'), 'unset');
  assert.equal(normalizeTargetVerdict(''), null);
  assert.equal(normalizeTargetVerdict('maybe'), null);
});

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildReviewIntent,
  decomposeDecision,
  extractOutboundPlan,
  feedbackRequests,
} = require('../lib/reviews/decision-contract');

test('outbound approval requires recipients, send timing, and copy', () => {
  const item = {
    slug: 'outbound',
    title: 'Outbound',
    category: 'outreach',
    markdown: [
      '**Target send date:** 2026-05-07',
      '',
      '## Draft for Jane',
      '**To:** jane@example.com',
      '**Subject:** Hello',
      '',
      'Body copy that is long enough to count as real approved copy. It includes the complete outbound note, the ask, context, and closing language so the system can treat the review as approving a real sendable artifact rather than a placeholder.',
    ].join('\n'),
  };

  const plan = extractOutboundPlan(item);
  assert.equal(plan.complete, true);
  assert.equal(plan.recipientCount, 1);
  assert.equal(plan.sendDate, '2026-05-07');

  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Send',
    feedback: '',
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/outbound',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'outreach_approval');
  assert.equal(requests[0].sensitivity, 'approved_sensitive');
});

test('outbound approval with a missing send plan becomes a clarification request', () => {
  const item = {
    slug: 'outbound-missing',
    title: 'Outbound Missing',
    category: 'outreach',
    markdown: '**To:** jane@example.com\n\n**Subject:** Hello\n\nShort body',
  };

  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Send',
    feedback: '',
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/outbound-missing',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'decision_clarification');
  assert.equal(requests[0].status, 'blocked_decision');
  assert.deepEqual(requests[0].payload.missing, ['send timing', 'exact copy/template']);
});

test('mixed feedback decomposes non-sensitive tasks and sensitive confirmations separately', () => {
  const requests = feedbackRequests('Make me an OmniFocus task to follow up, and send this email tomorrow');
  assert.equal(requests.length, 2);
  assert.equal(requests[0].kind, 'create_omnifocus_task');
  assert.equal(requests[0].status, 'queued');
  assert.equal(requests[1].kind, 'sensitive_confirmation');
  assert.equal(requests[1].status, 'needs_confirmation');
});

test('rework requires feedback and otherwise becomes a decision blocker', () => {
  const item = { slug: 'plan', title: 'Plan', category: 'general', markdown: '# Plan' };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Rework',
    feedback: '',
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/plan',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'decision_clarification');
  assert.equal(requests[0].status, 'blocked_decision');
});

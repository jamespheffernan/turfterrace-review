const test = require('node:test');
const assert = require('node:assert/strict');

const {
  getAdapterDescriptor,
  planDecisionRequests,
} = require('../lib/reviews/kernel/adapter-descriptors');
const { buildReviewIntent } = require('../lib/reviews/decision-contract');

test('adapter descriptors declare proof, blocker, and idempotency contracts', () => {
  const descriptor = getAdapterDescriptor('agent_build');

  assert.equal(descriptor.kind, 'agent_build');
  assert.equal(descriptor.sideEffects, false);
  assert.equal(descriptor.executor, 'openclaw-build');
  assert.ok(descriptor.proofSchema.required.includes('summary'));
  assert.ok(descriptor.blockerSchema.required.includes('reason'));
  assert.equal(descriptor.idempotencyScope, 'action_event');
});

test('descriptor planner remains pure while producing normalized requests', () => {
  const item = {
    slug: 'software-plan',
    title: 'Software build plan',
    category: 'general',
    markdown: [
      '# Software build plan',
      '',
      '## Implementation',
      '',
      '- Change `server.js`.',
      '- Add tests.',
    ].join('\n'),
  };
  const intent = buildReviewIntent({ item });
  const result = planDecisionRequests({
    item,
    intent,
    decision: 'Execute',
    feedback: 'Build it.',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/software-plan',
  });

  assert.equal(result.requests.length, 1);
  assert.equal(result.requests[0].kind, 'agent_build');
  assert.equal(result.requests[0].descriptor.kind, 'agent_build');
  assert.equal(result.requests[0].descriptor.sideEffects, false);
});

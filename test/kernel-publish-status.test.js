const test = require('node:test');
const assert = require('node:assert/strict');

const { buildPublishStatus } = require('../lib/reviews/kernel/publish-status');

test('publish status exposes source, targets, action ids, requests, and proof summary', () => {
  const status = buildPublishStatus({
    item: {
      slug: 'status-plan',
      title: 'Status plan',
      category: 'general',
      status: 'pending',
      workflow_state: 'public_verified',
      public_verification_status: 'verified',
      source_path: '/repo/docs/status-plan.md',
      workspace_dir: '/repo',
      artifact_type: 'markdown',
    },
    reviewTargets: {
      summary: { total: 2, approved: 1, rejected: 0, undecided: 1, complete: false },
      targets: [],
    },
    requests: [{
      id: 7,
      kind: 'agent_build',
      status: 'queued',
      proof_json: null,
    }],
    events: [{ event_type: 'public_verified' }],
  });

  assert.equal(status.slug, 'status-plan');
  assert.equal(status.publicVerification.status, 'verified');
  assert.equal(status.targets.total, 2);
  assert.equal(status.actions[1].id, 'general.execute');
  assert.equal(status.requests.total, 1);
  assert.equal(status.proof.proven, 0);
});

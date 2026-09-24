const test = require('node:test');
const assert = require('node:assert/strict');

const {
  actionIdFor,
  getActionPolicy,
  resolveActionInput,
} = require('../lib/reviews/kernel/action-policy');
const { DECISION_SCHEMA_VERSION } = require('../lib/review-routing');

test('action policy exposes stable ids alongside display labels', () => {
  const actions = getActionPolicy('general');

  assert.deepEqual(actions.map((action) => action.id), [
    'general.noted',
    'general.execute',
    'general.inbox',
    'general.rework',
    'general.kill',
  ]);
  assert.deepEqual(actions.map((action) => action.label), ['Noted', 'Execute', 'Inbox', 'Rework', 'Kill']);
  assert.equal(actionIdFor('confirmation', 'No further action'), 'confirmation.no-further-action');
});

test('server action ids resolve to labels and stale labels are rejected when id is supplied', () => {
  const item = {
    category: 'general',
    decision_schema_version: DECISION_SCHEMA_VERSION,
  };

  assert.deepEqual(resolveActionInput(item, { actionId: 'general.execute' }), {
    actionId: 'general.execute',
    label: 'Execute',
  });
  assert.throws(
    () => resolveActionInput(item, { actionId: 'general.execute', decision: 'Inbox' }),
    /does not match/,
  );
  assert.throws(
    () => resolveActionInput(item, { actionId: 'general.archive' }),
    /Invalid action id/,
  );
});

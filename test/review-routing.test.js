const test = require('node:test');
const assert = require('node:assert/strict');

const {
  DECISION_SCHEMA_VERSION,
  getAllowedActionsForItem,
  getCanonicalActions,
  getInitialActionStatus,
  getSessionKey,
  getStoredStatusForDecision,
  usesCanonicalRouting,
} = require('../lib/review-routing');

test('category-derived actions are stable', () => {
  assert.deepEqual(getCanonicalActions('outreach'), ['Send', 'Edit', 'Kill']);
  assert.deepEqual(getCanonicalActions('kitchenlux'), ['Execute', 'Inbox', 'Rework', 'Park', 'Kill']);
  assert.deepEqual(getCanonicalActions('general'), ['Noted', 'Execute', 'Inbox', 'Rework', 'Kill']);
  assert.deepEqual(getCanonicalActions('admin'), ['Noted', 'Execute', 'Inbox', 'Rework', 'Kill']);
});

test('canonical routing wins when schema version is current', () => {
  const item = {
    category: 'outreach',
    decision_schema_version: DECISION_SCHEMA_VERSION,
    actions: JSON.stringify(['Approve', 'Reject']),
  };

  assert.equal(usesCanonicalRouting(item), true);
  assert.deepEqual(getAllowedActionsForItem(item), ['Send', 'Edit', 'Kill']);
});

test('decision status mapping matches routed outcomes', () => {
  assert.equal(getStoredStatusForDecision('Park'), 'parked');
  assert.equal(getStoredStatusForDecision('Kill'), 'archived');
  assert.equal(getStoredStatusForDecision('Noted'), 'archived');
  assert.equal(getStoredStatusForDecision('Execute'), 'decided');
  assert.equal(getInitialActionStatus('Execute'), 'queued');
  assert.equal(getInitialActionStatus('Kill'), 'succeeded');
  assert.equal(getSessionKey('abc123'), 'review:abc123');
});

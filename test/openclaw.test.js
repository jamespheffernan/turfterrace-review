const test = require('node:test');
const assert = require('node:assert/strict');

const {
  extractText,
  formatHistoryTimestamp,
  normalizeGatewayBaseUrl,
  normalizeOpenClawModel,
} = require('../lib/openclaw');
const { isInternalMessageText } = require('../lib/review-routing');

test('normalizeGatewayBaseUrl strips trailing /v1', () => {
  assert.equal(normalizeGatewayBaseUrl('http://127.0.0.1:18789/v1'), 'http://127.0.0.1:18789');
  assert.equal(normalizeGatewayBaseUrl('http://127.0.0.1:18789/v1/'), 'http://127.0.0.1:18789');
  assert.equal(normalizeGatewayBaseUrl('http://127.0.0.1:18789'), 'http://127.0.0.1:18789');
});

test('extractText handles OpenClaw history payload shapes', () => {
  assert.equal(extractText('hello'), 'hello');
  assert.equal(extractText([{ type: 'text', text: 'hel' }, { type: 'text', text: 'lo' }]), 'hello');
  assert.equal(extractText({ text: 'hello' }), 'hello');
});

test('formatHistoryTimestamp emits sqlite-like strings', () => {
  assert.equal(formatHistoryTimestamp(0), '1970-01-01 00:00:00');
});

test('normalizeOpenClawModel forces gateway-safe aliases', () => {
  assert.equal(normalizeOpenClawModel('', 'main'), 'openclaw/main');
  assert.equal(normalizeOpenClawModel('anthropic/claude-sonnet-4-6', 'main'), 'openclaw/main');
  assert.equal(normalizeOpenClawModel('openclaw', 'main'), 'openclaw');
  assert.equal(normalizeOpenClawModel('openclaw/research', 'main'), 'openclaw/research');
});

test('isInternalMessageText catches both bracketed and bare internal notes', () => {
  assert.equal(isInternalMessageText('[TURF_REVIEW_INTERNAL] bootstrap\n{"ok":true}'), true);
  assert.equal(isInternalMessageText('TURF REVIEW INTERNAL DIGEST — Example\nHidden note'), true);
  assert.equal(isInternalMessageText('Normal assistant reply'), false);
});

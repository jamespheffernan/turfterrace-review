const test = require('node:test');
const assert = require('node:assert/strict');

const {
  createOpenClawClient,
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

test('OpenClaw completion request uses review session key header', async (t) => {
  const originalFetch = global.fetch;
  const calls = [];

  global.fetch = async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify({
      choices: [{ message: { content: 'Visible reply' } }],
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  };

  t.after(() => {
    global.fetch = originalFetch;
  });

  const client = createOpenClawClient({
    token: 'test-token',
    baseUrl: 'http://127.0.0.1:18789/v1',
    agentId: 'main',
    model: 'openclaw/main',
  });

  const result = await client.complete({
    sessionKey: 'review:test-slug',
    messages: [{ role: 'user', content: 'Hello' }],
  });

  assert.equal(result.text, 'Visible reply');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'http://127.0.0.1:18789/v1/chat/completions');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.headers.Authorization, 'Bearer test-token');
  assert.equal(calls[0].options.headers['x-openclaw-agent-id'], 'main');
  assert.equal(calls[0].options.headers['x-openclaw-session-key'], 'review:test-slug');

  const body = JSON.parse(calls[0].options.body);
  assert.equal(body.model, 'openclaw/main');
  assert.equal(body.stream, false);
  assert.deepEqual(body.messages, [{ role: 'user', content: 'Hello' }]);
});

test('OpenClaw completion fetch errors include session and cause', async (t) => {
  const originalFetch = global.fetch;

  global.fetch = async () => {
    const error = new TypeError('fetch failed');
    error.cause = new Error('connect ECONNREFUSED 127.0.0.1:18789');
    throw error;
  };

  t.after(() => {
    global.fetch = originalFetch;
  });

  const client = createOpenClawClient({
    token: 'test-token',
    baseUrl: 'http://127.0.0.1:18789/v1',
    agentId: 'main',
    model: 'openclaw/main',
  });

  await assert.rejects(
    client.complete({
      sessionKey: 'review:test-slug',
      messages: [{ role: 'user', content: 'Hello' }],
    }),
    /OpenClaw completion session=review:test-slug fetch failed.*connect ECONNREFUSED/
  );
});

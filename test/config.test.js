const test = require('node:test');
const assert = require('node:assert/strict');

const { loadConfig } = require('../lib/config');

function baseEnv(overrides = {}) {
  return {
    SESSION_SECRET: 'test-secret',
    ...overrides,
  };
}

test('OpenClaw token accepts the gateway token environment variable', () => {
  const config = loadConfig(baseEnv({
    OPENCLAW_GATEWAY_TOKEN: 'gateway-token',
  }), process.cwd());

  assert.equal(config.openclaw.token, 'gateway-token');
});

test('OpenClaw token prefers the explicit Turf Review token', () => {
  const config = loadConfig(baseEnv({
    OPENCLAW_TOKEN: 'review-token',
    OPENCLAW_GATEWAY_TOKEN: 'gateway-token',
  }), process.cwd());

  assert.equal(config.openclaw.token, 'review-token');
});

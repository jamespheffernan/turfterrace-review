const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');

const { createContentHash, createReviewDatabase } = require('../lib/db');
const { createPushNotificationService, normalizeDeviceRegistration } = require('../lib/push-notifications');
const { createReviewStatements } = require('../lib/reviews/repository');

function createStore(t) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-push-'));
  const db = createReviewDatabase({ dataDir });
  const stmts = createReviewStatements(db);
  t.after(() => {
    db.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  });
  return { db, stmts };
}

function insertReview(stmts, slug = 'new-review') {
  const title = 'A genuinely new review';
  const markdown = '# Review';
  stmts.insert.run({
    slug,
    title,
    markdown,
    rendered_html: '<h1>Review</h1>',
    artifact_type: 'markdown',
    artifact_html: null,
    category: 'general',
    actions: '[]',
    content_hash: createContentHash(title, markdown),
    mindwtr_task_id: null,
    mindwtr_project_id: null,
    on_approve: null,
    session_key: `review:${slug}`,
    workspace_dir: '/tmp',
    source_path: '/tmp/review.md',
    decision_schema_version: 3,
    parent_slug: null,
    supersedes_slug: null,
    created_by_request_id: null,
  });
}

function configuredEnvironment() {
  return {
    TURF_REVIEW_APNS_TEAM_ID: 'TEAM123',
    TURF_REVIEW_APNS_KEY_ID: 'KEY123',
    TURF_REVIEW_APNS_PRIVATE_KEY: 'unused-by-injected-transport',
  };
}

test('push delivery is unique per new review and device across retries', async (t) => {
  const { db, stmts } = createStore(t);
  insertReview(stmts);
  const requests = [];
  let attempt = 0;
  const transport = {
    async send(request) {
      requests.push(request);
      attempt += 1;
      if (attempt === 1) throw new Error('temporary APNs transport failure');
      return { status: 200, apnsId: request.apnsId };
    },
    invalidateProviderToken() {},
    close() {},
  };
  const service = createPushNotificationService({
    db,
    baseUrl: 'https://review.turfterrace.com',
    env: configuredEnvironment(),
    transport,
    logger: { error() {}, warn() {} },
  });
  t.after(() => service.close());

  const registration = {
    token: 'ab'.repeat(32),
    platform: 'ios',
    environment: 'development',
    bundleId: 'com.jamesheffernan.turfreviewnative',
  };
  assert.equal(service.registerDevice(registration).created, true);
  assert.equal(service.registerDevice(registration).created, false);
  assert.equal(service.enqueueReview('new-review'), 1);
  assert.equal(service.enqueueReview('new-review'), 0);

  await service.drain();
  const retry = db.prepare('SELECT * FROM push_deliveries').get();
  assert.equal(retry.status, 'queued');
  assert.equal(retry.attempts, 1);
  db.prepare('UPDATE push_deliveries SET next_attempt_at = NULL').run();

  await service.drain();
  const sent = db.prepare('SELECT * FROM push_deliveries').get();
  assert.equal(sent.status, 'sent');
  assert.equal(sent.attempts, 2);
  assert.equal(requests.length, 2);
  assert.equal(requests[0].apnsId, requests[1].apnsId);
  assert.equal(requests[0].collapseId, requests[1].collapseId);
  assert.equal(requests[1].payload.reviewURL, 'https://review.turfterrace.com/review/new-review');
});

test('push registration accepts only Turf Review bundle and platform pairs', () => {
  assert.throws(
    () => normalizeDeviceRegistration({
      token: 'ab'.repeat(32),
      platform: 'ios',
      environment: 'production',
      bundleId: 'com.example.other-app',
    }),
    /not a supported Turf Review notification target/,
  );
});

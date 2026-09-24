const assert = require('node:assert/strict');
const test = require('node:test');

const {
  buildNativeReviewURL,
  shouldOpenReviewInNativeApp,
} = require('../lib/reviews/app-links');

test('native review URLs encode the slug as one path segment', () => {
  assert.equal(
    buildNativeReviewURL('launch plan'),
    'turf-review://review/launch%20plan',
  );
});

test('Mac browsers hand review links to the native app', () => {
  assert.equal(shouldOpenReviewInNativeApp({ userAgent: 'Mozilla/5.0 (Macintosh)', webOverride: undefined }), true);
  assert.equal(shouldOpenReviewInNativeApp({ userAgent: 'Mozilla/5.0 (Windows NT 10.0)', webOverride: undefined }), false);
});

test('iOS handoff stays gated until the matching app release is installed', () => {
  assert.equal(shouldOpenReviewInNativeApp({ userAgent: 'Mozilla/5.0 (iPhone)', webOverride: undefined }), false);
  assert.equal(shouldOpenReviewInNativeApp({ userAgent: 'Mozilla/5.0 (iPad)', webOverride: undefined, iosEnabled: true }), true);
  assert.equal(shouldOpenReviewInNativeApp({ userAgent: 'Mozilla/5.0 (Macintosh; Mobile)', webOverride: undefined }), false);
});

test('web override keeps the review in the browser', () => {
  assert.equal(shouldOpenReviewInNativeApp({ userAgent: 'Mozilla/5.0 (Macintosh)', webOverride: '1' }), false);
});

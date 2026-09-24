const fs = require('fs');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

const webTargetUI = fs.readFileSync(path.join(__dirname, '..', 'public', 'review-targets.js'), 'utf8');
const nativeTargetPanel = fs.readFileSync(
  path.join(__dirname, '..', 'TurfReviewNative', 'TurfReviewNative', 'Views', 'ReviewTargetsPanel.swift'),
  'utf8'
);
const nativeDocumentView = fs.readFileSync(
  path.join(__dirname, '..', 'TurfReviewNative', 'TurfReviewNative', 'Support', 'HTMLDocumentView.swift'),
  'utf8'
);

test('web review-item controls use the real decision choices', () => {
  assert.match(webTargetUI, /data-verdict="approved">Approve<\/button>/);
  assert.match(webTargetUI, /data-verdict="rejected">Reject<\/button>/);
  assert.match(webTargetUI, /data-verdict="unset"[^>]*>Reset<\/button>/);
  assert.match(webTargetUI, /verdict === 'unset' \? '' : '<button[^']*review-target-action--reset/);
  assert.match(webTargetUI, /Reason for rejection/);
  assert.match(webTargetUI, /target\.decisionKind === 'choice'/);
  assert.match(webTargetUI, /'choice:' \+ option\.value/);
  assert.doesNotMatch(webTargetUI, /data-verdict="approved">Yes<\/button>|data-verdict="rejected">No<\/button>/);
});

test('native review-item controls use approval or explicit choice semantics', () => {
  assert.match(nativeTargetPanel, /Label\("Approve", systemImage: "checkmark"\)/);
  assert.match(nativeTargetPanel, /Label\("Reject", systemImage: "xmark"\)/);
  assert.match(nativeTargetPanel, /return "Approved"/);
  assert.match(nativeTargetPanel, /return "Rejected"/);
  assert.match(nativeTargetPanel, /if target\.isChoice, let options = target\.options/);
  assert.ok(nativeTargetPanel.includes('verdict: "choice:\\(value)"'));
  assert.doesNotMatch(nativeTargetPanel, /Label\("Yes"|Label\("No"/);

  assert.match(nativeDocumentView, /"approved", "Approve"/);
  assert.match(nativeDocumentView, /"rejected", "Reject"/);
  assert.match(nativeDocumentView, /"unset", "Reset"/);
  assert.match(nativeDocumentView, /turf-native-target-button-unset/);
  assert.match(nativeDocumentView, /target\.decisionKind === "choice"/);
  assert.doesNotMatch(nativeDocumentView, /"approved", "Yes"|"rejected", "No"/);
});

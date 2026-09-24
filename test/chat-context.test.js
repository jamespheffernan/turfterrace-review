const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildReviewChatMessages,
  buildReviewContextPacket,
  truncateDocument,
} = require('../lib/chat/openclaw-context');
const { filterVisibleMessages } = require('../lib/chat/repository');
const { DECISION_SCHEMA_VERSION } = require('../lib/review-routing');

function sampleItem(overrides = {}) {
  return {
    slug: 'sample-review',
    title: 'Sample Review',
    category: 'outreach',
    status: 'pending',
    decision: null,
    feedback: 'Tighten the ending.',
    markdown: '# Sample\n\nBody copy.',
    rendered_html: '<h1>Sample</h1>',
    session_key: null,
    workspace_dir: '/tmp/workspace',
    source_path: '/tmp/workspace/sample.md',
    decision_schema_version: DECISION_SCHEMA_VERSION,
    ...overrides,
  };
}

test('review context packet includes stable review session and canonical context', () => {
  const packet = buildReviewContextPacket({
    item: sampleItem(),
    annotations: [{
      id: 7,
      anchor_type: 'text',
      anchor_ref: 'char:12',
      quote: 'Body copy',
      comment: 'Needs proof.',
      created_at: '2026-04-28 10:00:00',
    }],
  });

  assert.equal(packet.kind, 'turf_review_context');
  assert.equal(packet.sessionKey, 'review:sample-review');
  assert.equal(packet.slug, 'sample-review');
  assert.equal(packet.title, 'Sample Review');
  assert.deepEqual(packet.allowedActions, ['Send', 'Edit', 'Kill']);
  assert.deepEqual(packet.actions.map((action) => action.id), ['outreach.send', 'outreach.edit', 'outreach.kill']);
  assert.deepEqual(packet.source, {
    workspaceDir: '/tmp/workspace',
    sourcePath: '/tmp/workspace/sample.md',
  });
  assert.equal(packet.document.text, '# Sample\n\nBody copy.');
  assert.equal(packet.document.truncated, false);
  assert.equal(packet.annotations[0].comment, 'Needs proof.');
});

test('review context packet marks image annotations without carrying raw image data', () => {
  const packet = buildReviewContextPacket({
    item: sampleItem(),
    annotations: [{
      id: 8,
      anchor_type: 'image',
      anchor_ref: 'apple-pencil-sketch',
      quote: null,
      comment: 'Apple Pencil sketch: Tighten the intro.',
      image_data: 'raw-base64-payload',
      image_mime: 'image/png',
      created_at: '2026-06-12 10:00:00',
    }],
  });

  assert.equal(packet.annotations[0].imageAttached, true);
  assert.equal(packet.annotations[0].imageMime, 'image/png');
  assert.equal(packet.annotations[0].imageData, undefined);
  assert.equal(JSON.stringify(packet).includes('raw-base64-payload'), false);
});

test('review context packet carries compact review target judgments', () => {
  const packet = buildReviewContextPacket({
    item: sampleItem(),
    annotations: [],
    reviewTargets: [{
      key: 'task:approval-list:001:abc',
      label: 'Approve candidate A',
      sourceType: 'task_list',
      anchorRef: 'target:task:approval-list:001:abc',
      ordinal: 1,
      verdict: 'rejected',
      feedback: 'Needs a source link.',
      decidedAt: '2026-06-12 15:00:00',
    }],
  });

  assert.deepEqual(packet.reviewTargets, [{
    key: 'task:approval-list:001:abc',
    label: 'Approve candidate A',
    anchorRef: 'target:task:approval-list:001:abc',
    sourceType: 'task_list',
    ordinal: 1,
    verdict: 'rejected',
    feedback: 'Needs a source link.',
    decided: true,
    decidedAt: '2026-06-12 15:00:00',
  }]);
});

test('review chat messages carry context as developer message and user text separately', () => {
  const request = buildReviewChatMessages({
    item: sampleItem(),
    annotations: [],
    reviewTargets: [{ key: 'task:approval-list:001:abc', label: 'Candidate', verdict: 'approved' }],
    userMessage: 'What is the biggest risk?',
  });

  assert.equal(request.sessionKey, 'review:sample-review');
  assert.equal(request.messages.length, 2);
  assert.equal(request.messages[0].role, 'developer');
  assert.match(request.messages[0].content, /"slug": "sample-review"/);
  assert.match(request.messages[0].content, /"reviewTargets"/);
  assert.match(request.messages[0].content, /Do not expose hidden bootstrap notes/);
  assert.deepEqual(request.messages[1], {
    role: 'user',
    content: 'What is the biggest risk?',
  });
});

test('document context truncates large documents deterministically', () => {
  const truncated = truncateDocument('abcdef', 3);
  assert.deepEqual(truncated, {
    text: 'abc',
    truncated: true,
    originalLength: 6,
  });
});

test('chat history falls back empty when OpenClaw history scope is unavailable', async () => {
  const { loadVisibleHistory } = require('../lib/chat/repository');
  const messages = await loadVisibleHistory({
    async getHistory() {
      throw new Error('OpenClaw request failed (403): {"ok":false,"error":{"message":"missing scope: operator.read"}}');
    },
  }, 'review:example');

  assert.deepEqual(messages, []);
});

test('visible chat history filters internal and non-chat messages', () => {
  const visible = filterVisibleMessages([
    { role: 'developer', content: 'hidden context' },
    { role: 'assistant', content: '[TURF_REVIEW_INTERNAL] bootstrap\n{}' },
    { role: 'assistant', content: 'Visible answer' },
    { role: 'user', content: 'Visible question' },
    { role: 'tool', content: 'tool output' },
    { role: 'assistant', content: '' },
  ]);

  assert.deepEqual(visible, [
    { role: 'assistant', content: 'Visible answer' },
    { role: 'user', content: 'Visible question' },
  ]);
});

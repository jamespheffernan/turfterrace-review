const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

const { createContentHash, createReviewDatabase } = require('../lib/db');
const { createDecisionOrchestrator } = require('../lib/reviews/orchestrator');
const { createReviewStatements } = require('../lib/reviews/repository');
const { DECISION_SCHEMA_VERSION, getCanonicalActions, getSessionKey } = require('../lib/review-routing');
const { executeDecisionJob, outcomeFromAgentResult } = require('../scripts/mac-worker');

function createStore(t) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-orchestrator-'));
  const db = createReviewDatabase({ dataDir });
  const stmts = createReviewStatements(db);

  t.after(() => {
    db.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  });

  return { db, stmts, dataDir };
}

function insertReview(stmts, overrides = {}) {
  const slug = overrides.slug || 'parent-review';
  const title = overrides.title || 'Parent Review';
  const markdown = overrides.markdown || '# Parent Review';
  const category = overrides.category || 'general';

  stmts.insert.run({
    slug,
    title,
    markdown,
    rendered_html: overrides.rendered_html || '<h1>Parent Review</h1>',
    artifact_type: overrides.artifact_type || 'markdown',
    artifact_html: overrides.artifact_html || null,
    category,
    actions: JSON.stringify(getCanonicalActions(category)),
    content_hash: createContentHash(title, markdown),
    mindwtr_task_id: null,
    mindwtr_project_id: null,
    on_approve: overrides.on_approve || null,
    session_key: overrides.session_key || getSessionKey(slug),
    workspace_dir: overrides.workspace_dir || null,
    source_path: overrides.source_path || null,
    decision_schema_version: DECISION_SCHEMA_VERSION,
    parent_slug: overrides.parent_slug || null,
    supersedes_slug: null,
    created_by_request_id: overrides.created_by_request_id || null,
  });
  if (overrides.origin_session_key) {
    stmts.setItemOriginSession.run({
      slug,
      origin_session_key: overrides.origin_session_key,
    });
  }

  return stmts.getBySlug.get(slug);
}

function createOrchestrator(db, stmts, overrides = {}) {
  return createDecisionOrchestrator({
    config: {
      reviewBaseUrl: 'https://review.turfterrace.com',
      openclaw: {
        bin: '/opt/homebrew/bin/openclaw',
        notificationChannel: 'discord',
        notificationAccount: 'default',
        notificationTarget: 'channel:1509121052834529330',
        notificationThreadId: '',
        telegramTarget: '8339963854',
        telegramReplyTo: '',
      },
      integrations: {},
    },
    db,
    stmts,
    openclawClient: null,
    appendSessionNote: async () => null,
    seedSessionForItem: async () => null,
    broadcastSSE: () => {},
    ...overrides,
  });
}

test('confirmation follow-up resolves the source request and creates child work', (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const orchestrator = createOrchestrator(db, stmts);
  const item = insertReview(stmts);
  orchestrator.recordIntentForItem(item);

  const first = orchestrator.handleDecision(item, {
    decision: 'Execute',
    feedback: 'send this email tomorrow',
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/parent-review',
  });

  assert.equal(first.followups.length, 1);
  const sourceRequest = stmts.listDecisionRequestsForSlug.all(item.slug)[0];
  assert.equal(sourceRequest.status, 'needs_confirmation');

  const followup = stmts.getBySlug.get(first.followups[0].slug);
  const second = orchestrator.handleDecision(followup, {
    decision: 'Approve',
    feedback: '',
    annotations: [],
    reviewUrl: `https://review.turfterrace.com/review/${followup.slug}`,
  });

  assert.equal(second.requests.length, 1);
  assert.equal(second.requests[0].kind, 'send_message');

  const resolvedSource = stmts.getDecisionRequestById.get(sourceRequest.id);
  assert.equal(resolvedSource.status, 'succeeded');
  assert.match(resolvedSource.proof_json, /continued_to_downstream_request/);

  const childRequest = stmts.listDecisionRequestsForSlug.all(followup.slug)[0];
  assert.equal(childRequest.parent_request_id, sourceRequest.id);
  assert.equal(childRequest.status, 'queued');
});

test('confirmation follow-up approval resumes the source request exactly once', (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const orchestrator = createOrchestrator(db, stmts);
  const item = insertReview(stmts);
  orchestrator.recordIntentForItem(item);

  const first = orchestrator.handleDecision(item, {
    decision: 'Execute',
    feedback: 'send this email tomorrow',
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/parent-review',
  });

  const sourceRequest = stmts.listDecisionRequestsForSlug.all(item.slug)[0];
  const followup = stmts.getBySlug.get(first.followups[0].slug);
  orchestrator.handleDecision(followup, {
    decision: 'Approve',
    feedback: '',
    annotations: [],
    reviewUrl: `https://review.turfterrace.com/review/${followup.slug}`,
  });
  const duplicate = orchestrator.handleDecision(followup, {
    decision: 'Approve',
    feedback: '',
    annotations: [],
    reviewUrl: `https://review.turfterrace.com/review/${followup.slug}`,
  });

  assert.equal(duplicate.requests.length, 0);
  const children = stmts.listDecisionRequestsForSlug.all(followup.slug)
    .filter((request) => request.parent_request_id === sourceRequest.id);
  assert.equal(children.length, 1);
});

test('approved software build plan creates build-mode agent request', async (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const item = insertReview(stmts, {
    slug: 'software-build-plan',
    title: 'Software build plan',
    markdown: [
      '# Software build plan',
      '',
      '## Implementation',
      '',
      '- Change `server.js` and `lib/reviews/decision-contract.js`.',
      '- Add tests for decision requests.',
      '',
      '## Acceptance criteria',
      '',
      '- `npm test` passes.',
    ].join('\n'),
  });
  const calls = [];
  const orchestrator = createOrchestrator(db, stmts, {
    openclawClient: {},
    appendSessionNote: async (_item, kind, payload) => {
      calls.push({ kind, payload });
      return {
        text: `[TURF_REVIEW_INTERNAL] ${JSON.stringify({
          status: 'succeeded',
          summary: 'Build completed.',
          proof: { tests: 'passed' },
        })}`,
      };
    },
  });
  orchestrator.recordIntentForItem(item);

  const result = orchestrator.handleDecision(item, {
    decision: 'Execute',
    feedback: 'Build it.',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/software-build-plan',
  });

  assert.equal(result.requests.length, 1);
  assert.equal(result.requests[0].kind, 'agent_build');
  assert.equal(result.requests[0].status, 'queued');

  await orchestrator.drainDecisionRequests(1);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].kind, 'build');
  assert.match(calls[0].payload.instructions, /approved software build plan/);
  assert.equal(calls[0].payload.request.kind, 'agent_build');

  const request = stmts.getDecisionRequestById.get(result.requests[0].id);
  assert.equal(request.status, 'succeeded');
  assert.match(request.proof_json, /Build completed/);
});

test('approved software build plan is delivered to drafting origin session', async (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const originSessionKey = 'agent:main:review:drafted-software-plan';
  const item = insertReview(stmts, {
    slug: 'origin-software-build-plan',
    title: 'Origin software build plan',
    markdown: [
      '# Origin software build plan',
      '',
      '## Implementation',
      '',
      '- Change `server.js` and `scripts/mac-worker.js`.',
      '- Add tests for the origin session handoff.',
      '',
      '## Acceptance criteria',
      '',
      '- `npm test` passes.',
    ].join('\n'),
    origin_session_key: originSessionKey,
  });
  const calls = [];
  const orchestrator = createOrchestrator(db, stmts, {
    openclawClient: {},
    appendSessionNote: async (_item, kind, payload, options) => {
      calls.push({ kind, payload, options });
      return {
        text: `[TURF_REVIEW_INTERNAL] ${JSON.stringify({
          status: 'succeeded',
          summary: 'Build completed in the origin session.',
          proof: { tests: 'passed' },
        })}`,
      };
    },
  });
  orchestrator.recordIntentForItem(item);

  const result = orchestrator.handleDecision(item, {
    decision: 'Execute',
    feedback: 'Build it.',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/origin-software-build-plan',
  });

  assert.equal(result.requests.length, 1);
  assert.equal(result.requests[0].kind, 'agent_build');
  assert.equal(result.requests[0].payload.originSessionKey, originSessionKey);

  await orchestrator.drainDecisionRequests(1);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].kind, 'build');
  assert.equal(calls[0].options.sessionKey, originSessionKey);
  assert.equal(calls[0].payload.targetSessionKey, originSessionKey);
  assert.equal(calls[0].payload.reviewSessionKey, getSessionKey(item.slug));
  assert.equal(calls[0].payload.request.payload.originSessionKey, originSessionKey);
  assert.match(calls[0].payload.instructions, /consented to execute/);

  const request = stmts.getDecisionRequestById.get(result.requests[0].id);
  assert.equal(request.status, 'succeeded');
  assert.match(request.proof_json, /origin session/);
});

test('codex implementation child requests run as build work in origin session', async (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const originSessionKey = 'agent:main:review:implementation-origin-plan';
  const item = insertReview(stmts, {
    slug: 'implementation-origin-plan',
    title: 'Implementation origin plan',
    markdown: '# Implementation origin plan',
    origin_session_key: originSessionKey,
  });
  const decision = stmts.insertDecision.run({
    slug: item.slug,
    decision: 'Execute',
    feedback: 'Build the child item.',
    actor: 'jimmy',
    status: 'recorded',
  });
  const request = stmts.insertDecisionRequest.run({
    decision_id: decision.lastInsertRowid,
    slug: item.slug,
    parent_request_id: null,
    kind: 'codex_implementation',
    summary: 'Add benchmark artifact generation',
    sensitivity: 'internal',
    status: 'queued',
    payload: JSON.stringify({
      originSessionKey,
      workspaceDir: '/tmp/example-workspace',
      tasks: ['Create benchmark artifact', 'Run focused tests'],
    }),
    max_attempts: 3,
  });
  const calls = [];
  const orchestrator = createOrchestrator(db, stmts, {
    openclawClient: {},
    appendSessionNote: async (_item, kind, payload, options) => {
      calls.push({ kind, payload, options });
      return {
        text: `[TURF_REVIEW_INTERNAL] ${JSON.stringify({
          status: 'succeeded',
          summary: 'Child implementation completed.',
          proof: { tests: 'passed' },
        })}`,
      };
    },
  });

  await orchestrator.drainDecisionRequests(1);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].kind, 'build');
  assert.equal(calls[0].options.sessionKey, originSessionKey);
  assert.equal(calls[0].payload.targetSessionKey, originSessionKey);
  assert.equal(calls[0].payload.request.kind, 'codex_implementation');
  assert.match(calls[0].payload.instructions, /approved Codex implementation request/);
  assert.match(calls[0].payload.instructions, /not as a memory search/);

  const completed = stmts.getDecisionRequestById.get(request.lastInsertRowid);
  assert.equal(completed.status, 'succeeded');
  assert.match(completed.proof_json, /Child implementation completed/);
});

test('killed origin plan records non-consent in drafting session', async (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const originSessionKey = 'agent:main:review:drafted-software-plan';
  const item = insertReview(stmts, {
    slug: 'killed-origin-plan',
    title: 'Killed origin plan',
    markdown: '# Killed origin plan',
    origin_session_key: originSessionKey,
  });
  const calls = [];
  const orchestrator = createOrchestrator(db, stmts, {
    openclawClient: {},
    appendSessionNote: async (_item, kind, payload, options) => {
      calls.push({ kind, payload, options });
      return { text: '[TURF_REVIEW_INTERNAL] {"status":"succeeded","summary":"Recorded."}' };
    },
  });
  orchestrator.recordIntentForItem(item);

  const result = orchestrator.handleDecision(item, {
    decision: 'Kill',
    feedback: 'Do not build this version.',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/killed-origin-plan',
  });

  assert.equal(result.requests.length, 1);
  assert.equal(result.requests[0].kind, 'origin_decision_notice');
  assert.equal(result.requests[0].payload.consent, false);

  await orchestrator.drainDecisionRequests(1);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].kind, 'decision');
  assert.equal(calls[0].options.sessionKey, originSessionKey);
  assert.equal(calls[0].payload.decision.consent, false);
  assert.match(calls[0].payload.instructions, /did not consent/);

  const request = stmts.getDecisionRequestById.get(result.requests[0].id);
  assert.equal(request.status, 'succeeded');
  assert.match(request.proof_json, /drafted-software-plan/);
});

test('Mac worker can claim and complete a decision request remotely', async (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const orchestrator = createOrchestrator(db, stmts);
  const item = insertReview(stmts);
  const decision = stmts.insertDecision.run({
    slug: item.slug,
    decision: 'Inbox',
    feedback: null,
    actor: 'jimmy',
    status: 'recorded',
  });
  const inserted = stmts.insertDecisionRequest.run({
    decision_id: decision.lastInsertRowid,
    slug: item.slug,
    parent_request_id: null,
    kind: 'create_omnifocus_task',
    summary: 'Create a follow-up task',
    sensitivity: 'normal',
    status: 'queued',
    payload: JSON.stringify({ slug: item.slug, title: 'Create a follow-up task' }),
    max_attempts: 3,
  });

  const claimed = orchestrator.claimExternalRequest();
  assert.equal(claimed.mode, 'request');
  assert.equal(claimed.request.id, inserted.lastInsertRowid);
  assert.equal(claimed.request.status, 'running');
  assert.equal(claimed.request.attempts, 1);
  assert.equal(stmts.listDecisionRequestsByStatus.all({ status: 'running', limit: 10 }).length, 1);

  await orchestrator.completeExternalRequest(inserted.lastInsertRowid, {
    status: 'succeeded',
    proofType: 'omnifocus_task',
    externalId: 'task-123',
    proof: { task: { id: 'task-123' } },
  });

  const row = stmts.getDecisionRequestById.get(inserted.lastInsertRowid);
  assert.equal(row.status, 'succeeded');
  assert.equal(JSON.parse(row.proof_json).task.id, 'task-123');
  assert.equal(stmts.listOutcomeProofsForRequest.all(inserted.lastInsertRowid).length, 1);
  assert.equal(stmts.listDecisionRequestsForSlug.all(item.slug)[0].status, 'succeeded');
});

test('Mac worker can claim and defer a waiting external request', async (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const orchestrator = createOrchestrator(db, stmts);
  const item = insertReview(stmts, { slug: 'outreach-review', category: 'outreach' });
  const decision = stmts.insertDecision.run({
    slug: item.slug,
    decision: 'Send',
    feedback: null,
    actor: 'jimmy',
    status: 'recorded',
  });
  const inserted = stmts.insertDecisionRequest.run({
    decision_id: decision.lastInsertRowid,
    slug: item.slug,
    parent_request_id: null,
    kind: 'outreach_approval',
    summary: 'Check outbound queue',
    sensitivity: 'approved_sensitive',
    status: 'waiting_external',
    payload: JSON.stringify({ slug: item.slug }),
    max_attempts: 3,
  });

  const claimed = orchestrator.claimExternalRequest();
  assert.equal(claimed.mode, 'waiting_external');
  assert.equal(claimed.request.id, inserted.lastInsertRowid);
  assert.equal(claimed.request.status, 'running');
  assert.equal(claimed.request.attempts, 0);

  await orchestrator.completeExternalRequest(inserted.lastInsertRowid, {
    status: 'waiting_external',
    proofType: 'outreach_send_queue',
    externalId: 'queue-1',
    proof: { queueItemIds: ['queue-1'] },
    nextAttemptSeconds: 60,
  });

  const row = stmts.getDecisionRequestById.get(inserted.lastInsertRowid);
  assert.equal(row.status, 'waiting_external');
  assert.match(row.proof_json, /queue-1/);
  assert.equal(typeof row.next_attempt_at, 'string');
});

test('agent child schedule_discussion creates a clarification follow-up, not generic agent work', async (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const item = insertReview(stmts, {
    slug: 'gwp-packaging-enquiry-reply-draft-movjji7o',
    title: 'GWP packaging enquiry reply draft',
  });
  const decision = stmts.insertDecision.run({
    slug: item.slug,
    decision: 'Rework',
    feedback: 'Needs more precise packaging language.',
    actor: 'jimmy',
    status: 'recorded',
  });
  const source = stmts.insertDecisionRequest.run({
    decision_id: decision.lastInsertRowid,
    slug: item.slug,
    parent_request_id: null,
    kind: 'agent_rework',
    summary: 'Rework the packaging enquiry reply draft',
    sensitivity: 'normal',
    status: 'queued',
    payload: JSON.stringify({ slug: item.slug, title: item.title }),
    max_attempts: 3,
  });
  const orchestrator = createOrchestrator(db, stmts, {
    openclawClient: {},
    appendSessionNote: async () => ({
      text: `[TURF_REVIEW_INTERNAL]\n${JSON.stringify({
        status: 'succeeded',
        summary: 'Created a calendar scheduling child request.',
        childRequests: [{
          kind: 'schedule_discussion',
          summary: 'Schedule time with Jimmy to review the packaging enquiry reply draft',
          payload: {
            topic: 'Packaging enquiry',
            context: 'The GWP reply draft needs review time with Jimmy.',
            desiredOutcome: 'Agree the reply direction before sending.',
          },
          sensitivity: 'internal',
        }],
      })}`,
    }),
  });

  await orchestrator.drainDecisionRequests(1);

  const child = stmts.listDecisionRequestsForSlug.all(item.slug)
    .find((row) => row.parent_request_id === source.lastInsertRowid);
  assert.ok(child);
  assert.equal(child.kind, 'decision_clarification');
  assert.equal(child.status, 'blocked_decision');
  assert.equal(child.sensitivity, 'internal');
  assert.notEqual(child.kind, 'create_omnifocus_task');

  const payload = JSON.parse(child.payload);
  assert.equal(payload.requestedKind, 'create_calendar_event');
  assert.equal(payload.originalKind, 'schedule_discussion');
  assert.deepEqual(payload.missing, ['exact start time', 'exact end time or duration']);
  assert.ok(child.confirmation_slug);

  const followup = stmts.getBySlug.get(child.confirmation_slug);
  assert.equal(followup.category, 'clarification');
  assert.equal(followup.parent_slug, item.slug);

  const notification = db.prepare('SELECT * FROM notifications WHERE request_id = ?').get(child.id);
  assert.equal(notification.kind, 'decision_clarification');
  assert.equal(notification.status, 'queued');
  assert.equal(notification.channel, 'discord');
  assert.equal(JSON.parse(notification.payload_json).target, 'channel:1509121052834529330');
});

test('agent result parser accepts current and legacy internal JSON formats', async (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const variants = [
    `[TURF_REVIEW_INTERNAL] ${JSON.stringify({ status: 'succeeded', summary: 'Same-line JSON parsed.' })}`,
    `[TURF_REVIEW_INTERNAL] followup\n${JSON.stringify({ status: 'succeeded', summary: 'Legacy label JSON parsed.' })}`,
    `[TURF_REVIEW_INTERNAL] monitor ${JSON.stringify({ status: 'succeeded', summary: 'Same-line label JSON parsed.' })}`,
  ];

  for (const [index, text] of variants.entries()) {
    const { db, stmts } = createStore(t);
    const item = insertReview(stmts, {
      slug: `agent-result-format-${index}`,
      title: `Agent result format ${index}`,
    });
    const decision = stmts.insertDecision.run({
      slug: item.slug,
      decision: 'Rework',
      feedback: 'Run the agent follow-up.',
      actor: 'jimmy',
      status: 'recorded',
    });
    const inserted = stmts.insertDecisionRequest.run({
      decision_id: decision.lastInsertRowid,
      slug: item.slug,
      parent_request_id: null,
      kind: 'agent_followup',
      summary: 'Run the agent follow-up',
      sensitivity: 'normal',
      status: 'queued',
      payload: JSON.stringify({ slug: item.slug, title: item.title }),
      max_attempts: 3,
    });
    const orchestrator = createOrchestrator(db, stmts, {
      openclawClient: {},
      appendSessionNote: async () => ({ text }),
    });

    await orchestrator.drainDecisionRequests(1);

    const row = stmts.getDecisionRequestById.get(inserted.lastInsertRowid);
    assert.equal(row.status, 'succeeded');
    assert.match(row.proof_json, /JSON parsed/);
  }
});

test('worker completion child schedule_discussion creates clarification review immediately', async (t) => {
  const previousWebOnly = process.env.TURF_REVIEW_WEB_ONLY;
  process.env.TURF_REVIEW_WEB_ONLY = '1';
  t.after(() => {
    if (previousWebOnly === undefined) delete process.env.TURF_REVIEW_WEB_ONLY;
    else process.env.TURF_REVIEW_WEB_ONLY = previousWebOnly;
  });

  const { db, stmts } = createStore(t);
  const orchestrator = createOrchestrator(db, stmts);
  const item = insertReview(stmts);
  const decision = stmts.insertDecision.run({
    slug: item.slug,
    decision: 'Execute',
    feedback: null,
    actor: 'jimmy',
    status: 'recorded',
  });
  const inserted = stmts.insertDecisionRequest.run({
    decision_id: decision.lastInsertRowid,
    slug: item.slug,
    parent_request_id: null,
    kind: 'agent_followup',
    summary: 'Handle GWP reply',
    sensitivity: 'normal',
    status: 'queued',
    payload: JSON.stringify({ slug: item.slug, title: item.title }),
    max_attempts: 3,
  });

  const claimed = orchestrator.claimExternalRequest();
  assert.equal(claimed.request.id, inserted.lastInsertRowid);
  await orchestrator.completeExternalRequest(inserted.lastInsertRowid, {
    status: 'succeeded',
    proofType: 'agent_report',
    proof: { summary: 'Worker returned a child request.' },
    childRequests: [{
      kind: 'schedule_review',
      summary: 'Schedule review time with Jimmy',
      payload: { topic: 'GWP reply' },
    }],
  });

  const child = stmts.listDecisionRequestsForSlug.all(item.slug)
    .find((row) => row.parent_request_id === inserted.lastInsertRowid);
  assert.ok(child);
  assert.equal(child.kind, 'decision_clarification');
  assert.equal(child.status, 'blocked_decision');
  assert.equal(JSON.parse(child.payload).requestedKind, 'create_calendar_event');
  assert.ok(stmts.getBySlug.get(child.confirmation_slug));

  const notification = db.prepare('SELECT * FROM notifications WHERE request_id = ?').get(child.id);
  assert.equal(notification.status, 'queued');
  assert.equal(notification.channel, 'discord');
});

test('Mac worker turns agent schedule_discussion child output into a calendar clarification', () => {
  const outcome = outcomeFromAgentResult({
    status: 'succeeded',
    summary: 'Need review time before redrafting.',
    proof: { system: 'agent' },
    childRequests: [{
      kind: 'schedule_discussion',
      summary: 'Schedule time with Jimmy to review the packaging enquiry reply draft',
      payload: {
        topic: 'Packaging enquiry',
        context: 'The reply draft needs a review slot.',
      },
      sensitivity: 'internal',
    }],
  }, {
    id: 98,
    kind: 'agent_rework',
    summary: 'Rework GWP reply',
  }, {
    slug: 'gwp-packaging-enquiry-reply-draft-movjji7o',
  });

  assert.equal(outcome.status, 'blocked_decision');
  assert.equal(outcome.followup.requestedKind, 'create_calendar_event');
  assert.equal(outcome.followup.payload.originalKind, 'schedule_discussion');
  assert.deepEqual(outcome.followup.missing, ['exact start time', 'exact end time or duration']);
});

test('Mac worker blocks schedule_discussion jobs before generic agent dispatch', async () => {
  const outcome = await executeDecisionJob({
    mode: 'request',
    request: {
      id: 99,
      kind: 'schedule_discussion',
      summary: 'Schedule time with Jimmy to review the packaging enquiry reply draft',
      payload: JSON.stringify({
        topic: 'Packaging enquiry',
        context: 'The reply draft needs a review slot.',
        desiredOutcome: 'Pick a time and discuss changes.',
      }),
    },
    item: {
      slug: 'gwp-packaging-enquiry-reply-draft-movjji7o',
      title: 'GWP packaging enquiry reply draft',
      category: 'general',
    },
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/gwp-packaging-enquiry-reply-draft-movjji7o',
  });

  assert.equal(outcome.status, 'blocked_decision');
  assert.equal(outcome.followup.requestedKind, 'create_calendar_event');
  assert.deepEqual(outcome.followup.missing, ['exact start time', 'exact end time or duration']);
});

test('Mac worker can run deferred non-outreach jobs after waiting period', async () => {
  const outcome = await executeDecisionJob({
    mode: 'waiting_external',
    request: {
      id: 100,
      kind: 'schedule_discussion',
      summary: 'Schedule time with Jimmy to review a deferred reply',
      payload: JSON.stringify({
        topic: 'Deferred scheduling',
        context: 'The deferred request is ready to run again.',
      }),
    },
    item: {
      slug: 'deferred-scheduling-review',
      title: 'Deferred scheduling review',
      category: 'general',
    },
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/deferred-scheduling-review',
  });

  assert.equal(outcome.status, 'blocked_decision');
  assert.equal(outcome.followup.requestedKind, 'create_calendar_event');
});

test('Mac worker sends approved build work to origin session key', async (t) => {
  const previousToken = process.env.OPENCLAW_TOKEN;
  const previousBaseUrl = process.env.OPENCLAW_BASE_URL;
  const received = [];
  const server = http.createServer(async (req, res) => {
    let body = '';
    req.setEncoding('utf8');
    for await (const chunk of req) body += chunk;
    received.push({
      url: req.url,
      sessionKey: req.headers['x-openclaw-session-key'],
      body: JSON.parse(body || '{}'),
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      choices: [{
        message: {
          content: `[TURF_REVIEW_INTERNAL] ${JSON.stringify({
            status: 'succeeded',
            summary: 'Worker build completed.',
            proof: { tests: 'passed' },
          })}`,
        },
      }],
    }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await new Promise((resolve) => server.close(resolve));
    if (previousToken === undefined) delete process.env.OPENCLAW_TOKEN;
    else process.env.OPENCLAW_TOKEN = previousToken;
    if (previousBaseUrl === undefined) delete process.env.OPENCLAW_BASE_URL;
    else process.env.OPENCLAW_BASE_URL = previousBaseUrl;
  });

  const address = server.address();
  process.env.OPENCLAW_TOKEN = 'test-token';
  process.env.OPENCLAW_BASE_URL = `http://127.0.0.1:${address.port}/v1`;
  const originSessionKey = 'agent:main:review:drafted-worker-plan';

  const outcome = await executeDecisionJob({
    mode: 'request',
    request: {
      id: 101,
      kind: 'agent_build',
      summary: 'Build approved plan',
      payload: JSON.stringify({
        slug: 'worker-origin-build-plan',
        title: 'Worker origin build plan',
        decision: 'Execute',
        originSessionKey,
      }),
    },
    item: {
      slug: 'worker-origin-build-plan',
      title: 'Worker origin build plan',
      category: 'general',
      session_key: getSessionKey('worker-origin-build-plan'),
      origin_session_key: originSessionKey,
      markdown: '# Worker origin build plan',
    },
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/worker-origin-build-plan',
  });

  assert.equal(outcome.status, 'succeeded');
  assert.equal(received.length, 1);
  assert.equal(received[0].url, '/v1/chat/completions');
  assert.equal(received[0].sessionKey, originSessionKey);

  const content = received[0].body.messages[1].content;
  const payload = JSON.parse(content.slice(content.indexOf('\n') + 1));
  assert.equal(payload.targetSessionKey, originSessionKey);
  assert.equal(payload.reviewSessionKey, getSessionKey('worker-origin-build-plan'));
  assert.match(payload.instructions, /consented to execute/);
});

test('Mac worker treats codex implementation requests as origin-session build work', async (t) => {
  const previousToken = process.env.OPENCLAW_TOKEN;
  const previousBaseUrl = process.env.OPENCLAW_BASE_URL;
  const received = [];
  const server = http.createServer(async (req, res) => {
    let body = '';
    req.setEncoding('utf8');
    for await (const chunk of req) body += chunk;
    received.push({
      url: req.url,
      sessionKey: req.headers['x-openclaw-session-key'],
      body: JSON.parse(body || '{}'),
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      choices: [{
        message: {
          content: `[TURF_REVIEW_INTERNAL] ${JSON.stringify({
            status: 'succeeded',
            summary: 'Codex implementation completed.',
            proof: { artifact: 'created' },
          })}`,
        },
      }],
    }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await new Promise((resolve) => server.close(resolve));
    if (previousToken === undefined) delete process.env.OPENCLAW_TOKEN;
    else process.env.OPENCLAW_TOKEN = previousToken;
    if (previousBaseUrl === undefined) delete process.env.OPENCLAW_BASE_URL;
    else process.env.OPENCLAW_BASE_URL = previousBaseUrl;
  });

  const address = server.address();
  process.env.OPENCLAW_TOKEN = 'test-token';
  process.env.OPENCLAW_BASE_URL = `http://127.0.0.1:${address.port}/v1`;
  const originSessionKey = 'agent:main:review:omnifocus-origin-plan';

  const outcome = await executeDecisionJob({
    mode: 'request',
    request: {
      id: 102,
      kind: 'codex_implementation',
      summary: 'Add benchmark artifact generation',
      payload: JSON.stringify({
        slug: 'omnifocus-private-write-path-research-plan-mqcj426x',
        title: 'OmniFocus private write path research plan',
        originSessionKey,
        workspaceDir: '/Users/username/GitHub/Vocal Review',
        tasks: ['Create benchmark artifact', 'Run focused tests'],
      }),
    },
    item: {
      slug: 'omnifocus-private-write-path-research-plan-mqcj426x',
      title: 'OmniFocus private write path research plan',
      category: 'general',
      session_key: getSessionKey('omnifocus-private-write-path-research-plan-mqcj426x'),
      origin_session_key: originSessionKey,
      markdown: '# OmniFocus private write path research plan',
    },
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/omnifocus-private-write-path-research-plan-mqcj426x',
  });

  assert.equal(outcome.status, 'succeeded');
  assert.equal(received.length, 1);
  assert.equal(received[0].url, '/v1/chat/completions');
  assert.equal(received[0].sessionKey, originSessionKey);

  const content = received[0].body.messages[1].content;
  assert.match(content, /^\[TURF_REVIEW_INTERNAL\] build\n/);
  const payload = JSON.parse(content.slice(content.indexOf('\n') + 1));
  assert.equal(payload.targetSessionKey, originSessionKey);
  assert.equal(payload.reviewSessionKey, getSessionKey('omnifocus-private-write-path-research-plan-mqcj426x'));
  assert.equal(payload.request.kind, 'codex_implementation');
  assert.match(payload.instructions, /approved Codex implementation request/);
  assert.match(payload.instructions, /not as a memory search/);
});

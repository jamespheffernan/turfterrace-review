const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildReviewIntent,
  decomposeDecision,
  extractOutboundPlan,
  feedbackRequests,
  isSoftwareBuildPlan,
  normalizeDecisionRequest,
  normalizeSessionKey,
} = require('../lib/reviews/decision-contract');

test('outbound approval requires recipients, send timing, and copy', () => {
  const item = {
    slug: 'outbound',
    title: 'Outbound',
    category: 'outreach',
    markdown: [
      '**Target send date:** 2026-05-07',
      '',
      '## Draft for Jane',
      '**To:** jane@example.com',
      '**Subject:** Hello',
      '',
      'Body copy that is long enough to count as real approved copy. It includes the complete outbound note, the ask, context, and closing language so the system can treat the review as approving a real sendable artifact rather than a placeholder.',
    ].join('\n'),
  };

  const plan = extractOutboundPlan(item);
  assert.equal(plan.complete, true);
  assert.equal(plan.recipientCount, 1);
  assert.equal(plan.sendDate, '2026-05-07');

  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Send',
    feedback: '',
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/outbound',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'outreach_approval');
  assert.equal(requests[0].sensitivity, 'approved_sensitive');
});

test('outbound approval with a missing send plan becomes a clarification request', () => {
  const item = {
    slug: 'outbound-missing',
    title: 'Outbound Missing',
    category: 'outreach',
    markdown: '**To:** jane@example.com\n\n**Subject:** Hello\n\nShort body',
  };

  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Send',
    feedback: '',
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/outbound-missing',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'decision_clarification');
  assert.equal(requests[0].status, 'blocked_decision');
  assert.deepEqual(requests[0].payload.missing, ['send timing', 'exact copy/template']);
});

test('mixed feedback decomposes non-sensitive tasks and sensitive confirmations separately', () => {
  const requests = feedbackRequests('Make me an OmniFocus task to follow up, and send this email tomorrow');
  assert.equal(requests.length, 2);
  assert.equal(requests[0].kind, 'create_omnifocus_task');
  assert.equal(requests[0].status, 'queued');
  assert.equal(requests[1].kind, 'sensitive_confirmation');
  assert.equal(requests[1].status, 'needs_confirmation');
});

test('rework requires feedback and otherwise becomes a decision blocker', () => {
  const item = { slug: 'plan', title: 'Plan', category: 'general', markdown: '# Plan' };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Rework',
    feedback: '',
    annotations: [],
    reviewUrl: 'https://review.turfterrace.com/review/plan',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'decision_clarification');
  assert.equal(requests[0].status, 'blocked_decision');
});

test('rework can use rejected review target feedback', () => {
  const item = { slug: 'plan-targets', title: 'Plan targets', category: 'general', markdown: '# Plan' };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Rework',
    feedback: '',
    annotations: [],
    reviewTargets: [{
      key: 'task:approval-list:001:abc',
      label: 'Candidate A',
      verdict: 'rejected',
      feedback: 'Needs stronger evidence.',
    }],
    reviewUrl: 'https://review.turfterrace.com/review/plan-targets',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'agent_rework');
  assert.match(requests[0].payload.feedback, /Candidate A: Needs stronger evidence/);
  assert.equal(requests[0].payload.reviewTargets[0].verdict, 'rejected');
});

test('execute payload carries compact review target judgments', () => {
  const item = { slug: 'execute-targets', title: 'Execute targets', category: 'general', markdown: '# Plan' };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Execute',
    feedback: 'Ship the approved rows.',
    annotations: [],
    reviewTargets: [{
      key: 'task:approval-list:001:abc',
      label: 'Candidate A',
      verdict: 'approved',
      feedback: null,
    }],
    reviewUrl: 'https://review.turfterrace.com/review/execute-targets',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].payload.reviewTargets[0].label, 'Candidate A');
  assert.equal(requests[0].payload.reviewTargets[0].verdict, 'approved');
});

test('execute of a software implementation plan queues agent build work', () => {
  const item = {
    slug: 'review-target-approvals-plan',
    title: 'Review target approvals implementation plan',
    category: 'general',
    markdown: [
      '# Review target approvals implementation plan',
      '',
      '## Implementation',
      '',
      '- Change `lib/reviews/review-targets.js` and `server.js`.',
      '- Add tests for the API route and native client.',
      '',
      '## Acceptance criteria',
      '',
      '- `npm test` passes.',
    ].join('\n'),
    workspace_dir: '/repo',
    source_path: '/repo/docs/plans/review-target-approvals-plan.md',
  };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Execute',
    feedback: 'Ship the plan.',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/review-target-approvals-plan',
  });

  assert.equal(isSoftwareBuildPlan(item), true);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'agent_build');
  assert.equal(requests[0].summary, 'Build approved software plan: Review target approvals implementation plan');
  assert.equal(requests[0].payload.planKind, 'software_build_plan');
  assert.equal(requests[0].payload.workspaceDir, '/repo');
  assert.equal(requests[0].payload.sourcePath, '/repo/docs/plans/review-target-approvals-plan.md');
  assert.match(requests[0].payload.outcomeContract, /changed source/);
});

test('approved software build plan carries origin session consent', () => {
  const item = {
    slug: 'origin-software-build-plan',
    title: 'Origin software build plan',
    category: 'general',
    markdown: [
      '# Origin software build plan',
      '',
      '## Implementation',
      '',
      '- Change `server.js` and `scripts/mac-worker.js`.',
      '- Add tests for origin session routing.',
      '',
      '## Acceptance criteria',
      '',
      '- `npm test` passes.',
    ].join('\n'),
    origin_session_key: 'agent:main:review:drafted-plan-session',
  };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Execute',
    feedback: 'Ship it.',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/origin-software-build-plan',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'agent_build');
  assert.equal(requests[0].payload.originSessionKey, 'agent:main:review:drafted-plan-session');
  assert.equal(requests[0].payload.decision, 'Execute');
});

test('rejected origin plan records non-consent in drafting session', () => {
  const item = {
    slug: 'rejected-origin-plan',
    title: 'Rejected origin plan',
    category: 'general',
    markdown: '# Rejected origin plan',
    origin_session_key: 'agent:main:review:drafted-plan-session',
  };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Kill',
    feedback: 'Do not build this version.',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/rejected-origin-plan',
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'origin_decision_notice');
  assert.equal(requests[0].payload.consent, false);
  assert.equal(requests[0].payload.originSessionKey, 'agent:main:review:drafted-plan-session');
  assert.match(requests[0].payload.instruction, /do not execute/i);
});

test('session keys are normalized before routing', () => {
  assert.equal(normalizeSessionKey('  agent:main:review:plan  '), 'agent:main:review:plan');
  assert.equal(normalizeSessionKey(''), null);
  assert.equal(normalizeSessionKey('x'.repeat(241)), null);
});

test('hyphenated runtime plan source paths are detected as software build plans', () => {
  const item = {
    slug: 'runtime-plan',
    title: 'Vocal Review Provider-Swappable Backend Runtime Plan',
    category: 'general',
    markdown: [
      '# Vocal Review Provider-Swappable Backend Runtime Plan',
      '',
      '## Implementation',
      '',
      '- Add provider runtime routing.',
      '- Verify backend profile persistence.',
    ].join('\n'),
    source_path: '/Users/username/GitHub/Vocal Review/docs/plans/2026-06-13-001-refactor-provider-swappable-backend-runtime-plan.md',
  };

  assert.equal(isSoftwareBuildPlan(item), true);
});

test('backend fix readouts can trigger software build work', () => {
  const item = {
    slug: 'backend-fix-required',
    title: 'OpenRouter Replay Readout: Backend Fix Required',
    category: 'general',
    markdown: [
      '# OpenRouter Replay Readout: Backend Fix Required',
      '',
      'Backend fixes required before rerun: enforce RuntimeProfile timeouts, add per-call OpenRouter reasoning/token policy, normalize provider schemas, decode OpenRouter response variants, normalize unique external ids back to local refs, and keep replay running with provider-error rows.',
    ].join('\n'),
  };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Execute',
    feedback: '',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/backend-fix-required',
  });

  assert.equal(isSoftwareBuildPlan(item), true);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'agent_build');
});

test('execute of a non-software plan still queues a generic agent follow-up', () => {
  const item = {
    slug: 'google-workspace-email-plan',
    title: 'Google Workspace primary email plan',
    category: 'general',
    markdown: [
      '# Google Workspace primary email plan',
      '',
      'Choose the primary inbox, migration timing, and communication order.',
    ].join('\n'),
  };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Execute',
    feedback: 'Do it.',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/google-workspace-email-plan',
  });

  assert.equal(isSoftwareBuildPlan(item), false);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'agent_followup');
});

test('explicit onApprove metadata can request agent build work', () => {
  const item = {
    slug: 'explicit-build',
    title: 'Explicit build approval',
    category: 'general',
    markdown: '# Explicit build approval',
    on_approve: JSON.stringify({
      kind: 'agent_build',
      summary: 'Build the approved dashboard workflow',
      instruction: 'Use the linked repository and verify the dashboard smoke path.',
      sensitivity: 'normal',
    }),
  };
  const intent = buildReviewIntent({ item });
  const requests = decomposeDecision({
    item,
    intent,
    decision: 'Execute',
    feedback: '',
    annotations: [],
    reviewTargets: [],
    reviewUrl: 'https://review.turfterrace.com/review/explicit-build',
  });

  assert.equal(intent.on_approval_kind, 'agent_build');
  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'agent_build');
  assert.equal(requests[0].summary, 'Build the approved dashboard workflow');
  assert.equal(requests[0].payload.instruction, 'Use the linked repository and verify the dashboard smoke path.');
  assert.equal(requests[0].payload.approvedByReview, 'explicit-build');
});

test('schedule discussion requests without an exact slot become calendar clarifications', () => {
  const request = normalizeDecisionRequest({
    kind: 'schedule_discussion',
    summary: 'Schedule time with Jimmy to review the packaging enquiry',
    sensitivity: 'internal',
    payload: {
      topic: 'Packaging enquiry',
      context: 'GWP reply draft needs review time',
      desiredOutcome: 'Pick the calendar slot',
    },
  });

  assert.equal(request.kind, 'decision_clarification');
  assert.equal(request.status, 'blocked_decision');
  assert.equal(request.sensitivity, 'internal');
  assert.equal(request.payload.requestedKind, 'create_calendar_event');
  assert.equal(request.payload.originalKind, 'schedule_discussion');
  assert.deepEqual(request.payload.missing, ['exact start time', 'exact end time or duration']);
});

test('schedule review requests with start and end become calendar events', () => {
  const request = normalizeDecisionRequest({
    kind: 'schedule_review',
    summary: 'Schedule review time',
    payload: {
      title: 'Review packaging enquiry',
      start: 'Friday, May 15, 2026 15:00',
      end: 'Friday, May 15, 2026 15:30',
    },
  });

  assert.equal(request.kind, 'create_calendar_event');
  assert.equal(request.status, 'queued');
  assert.equal(request.payload.title, 'Review packaging enquiry');
});

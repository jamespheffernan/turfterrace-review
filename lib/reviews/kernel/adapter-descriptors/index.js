const { decomposeDecision, normalizeDecisionRequest } = require('../../decision-contract');

const BASE_PROOF_SCHEMA = Object.freeze({
  type: 'object',
  required: ['summary'],
});

const BASE_BLOCKER_SCHEMA = Object.freeze({
  type: 'object',
  required: ['reason'],
});

const DESCRIPTORS = Object.freeze({
  agent_build: {
    kind: 'agent_build',
    executor: 'openclaw-build',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'normal',
    aggregation: 'required',
    proofSchema: BASE_PROOF_SCHEMA,
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
  codex_implementation: {
    kind: 'codex_implementation',
    executor: 'openclaw-build',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'normal',
    aggregation: 'required',
    proofSchema: BASE_PROOF_SCHEMA,
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
  agent_followup: {
    kind: 'agent_followup',
    executor: 'openclaw-followup',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'normal',
    aggregation: 'required',
    proofSchema: BASE_PROOF_SCHEMA,
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
  agent_rework: {
    kind: 'agent_rework',
    executor: 'openclaw-rework',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'normal',
    aggregation: 'required',
    proofSchema: BASE_PROOF_SCHEMA,
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
  create_omnifocus_task: {
    kind: 'create_omnifocus_task',
    executor: 'omnifocus',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'normal',
    aggregation: 'required',
    proofSchema: Object.freeze({ type: 'object', required: ['task'] }),
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
  create_calendar_event: {
    kind: 'create_calendar_event',
    executor: 'calendar',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'sensitive',
    aggregation: 'required',
    proofSchema: Object.freeze({ type: 'object', required: ['eventId'] }),
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
  outreach_approval: {
    kind: 'outreach_approval',
    executor: 'outreach',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'approved_sensitive',
    aggregation: 'required',
    proofSchema: Object.freeze({ type: 'object', required: ['queueItemIds'] }),
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
  send_message: {
    kind: 'send_message',
    executor: 'outreach',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'approved_sensitive',
    aggregation: 'required',
    proofSchema: Object.freeze({ type: 'object', required: ['messageId'] }),
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
  decision_clarification: {
    kind: 'decision_clarification',
    executor: 'clarification-review',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'normal',
    aggregation: 'blocks_parent',
    proofSchema: Object.freeze({ type: 'object', required: ['resolvedByReview'] }),
    blockerSchema: Object.freeze({ type: 'object', required: ['missing'] }),
  },
  sensitive_confirmation: {
    kind: 'sensitive_confirmation',
    executor: 'confirmation-review',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'sensitive',
    aggregation: 'blocks_parent',
    proofSchema: Object.freeze({ type: 'object', required: ['resolvedByReview'] }),
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
  origin_decision_notice: {
    kind: 'origin_decision_notice',
    executor: 'origin-session',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'internal',
    aggregation: 'optional_notice',
    proofSchema: Object.freeze({ type: 'object', required: ['targetSessionKey'] }),
    blockerSchema: BASE_BLOCKER_SCHEMA,
  },
});

function fallbackDescriptor(kind) {
  return {
    kind,
    executor: 'openclaw-followup',
    sideEffects: false,
    idempotencyScope: 'action_event',
    sensitivity: 'normal',
    aggregation: 'required',
    proofSchema: BASE_PROOF_SCHEMA,
    blockerSchema: BASE_BLOCKER_SCHEMA,
  };
}

function getAdapterDescriptor(kind) {
  const normalized = String(kind || '').trim() || 'agent_followup';
  return DESCRIPTORS[normalized] || fallbackDescriptor(normalized);
}

function planDecisionRequests(input) {
  const requests = decomposeDecision(input).map((request) => normalizeDecisionRequest(request));
  return {
    requests: requests.map((request) => ({
      ...request,
      descriptor: getAdapterDescriptor(request.kind),
    })),
  };
}

module.exports = {
  getAdapterDescriptor,
  planDecisionRequests,
};

const crypto = require('crypto');

const NO_ACTION_DECISIONS = new Set(['Noted', 'Park', 'No further action']);
const REWORK_DECISIONS = new Set(['Rework', 'Edit']);
const KILL_DECISIONS = new Set(['Kill']);
const SCHEDULING_REQUEST_KINDS = new Set([
  'schedule_discussion',
  'schedule_review',
  'schedule_meeting',
  'schedule_time',
]);
const SOFTWARE_PLAN_TITLE_PATTERNS = [
  /\bsoftware\s+build\s+plan\b/i,
  /\bbuild\s+plan\b/i,
  /\bimplementation\s+plan\b/i,
  /\bengineering\s+plan\b/i,
  /\btechnical\s+plan\b/i,
  /\bfeature\s+plan\b/i,
  /\bruntime\s+plan\b/i,
  /\brebuild\s+brief\b/i,
  /\brefactor\s+plan\b/i,
  /\bbackend\s+fix(?:es)?\s+required\b/i,
  /\bfix(?:es)?\s+required\b/i,
];
const SOFTWARE_PLAN_BODY_PATTERNS = [
  /\bacceptance\s+criteria\b/i,
  /\bimplementation\b/i,
  /\bfix(?:es)?\s+required\b/i,
  /\bbefore\s+rerun\b/i,
  /\bfiles?\s+to\s+(?:change|touch|edit)\b/i,
  /\bcode\s+path\b/i,
  /\btest(?:s|ing)?\b/i,
  /\bapi\b/i,
  /\bbackend\b/i,
  /\bruntime\b/i,
  /\bprovider\b/i,
  /\bschema\b/i,
  /\bdatabase\b/i,
  /\bmigration\b/i,
  /\bcomponent\b/i,
  /\broute\b/i,
  /\bendpoints?\b/i,
  /\bworker\b/i,
  /\bnpm\s+(?:test|run)\b/i,
  /\bnode\s+--test\b/i,
  /\bxcodebuild\b/i,
  /\bpytest\b/i,
  /\bvitest\b/i,
  /```(?:js|jsx|ts|tsx|swift|py|python|rb|go|sql|sh|bash|json|ya?ml)\b/i,
  /\b[\w./-]+\.(?:js|jsx|ts|tsx|swift|py|rb|go|sql|json|ya?ml)\b/i,
];

function normalizeText(value) {
  return String(value || '').replace(/\s+/g, ' ').trim();
}

function normalizeSessionKey(value) {
  const text = normalizeText(value);
  if (!text || text.length > 240) return null;
  return text;
}

function safeJsonParse(value, fallback = null) {
  if (!value || typeof value !== 'string') return fallback;
  try {
    return JSON.parse(value);
  } catch (_error) {
    return fallback;
  }
}

function coerceObject(value) {
  if (value && typeof value === 'object' && !Array.isArray(value)) return value;
  if (typeof value !== 'string') return null;
  return safeJsonParse(value, null);
}

function normalizeApprovalPayload(value) {
  const objectPayload = coerceObject(value);
  if (objectPayload) return objectPayload;

  const instruction = normalizeText(value);
  return instruction ? { instruction } : {};
}

function stableRequestKey(parts) {
  return crypto.createHash('sha256').update(parts.map((part) => String(part || '')).join('|')).digest('hex');
}

function splitFeedback(feedback) {
  const text = normalizeText(feedback);
  if (!text) return [];
  return text
    .split(/\s*(?:\n+|;\s+|,\s+and\s+|\s+and\s+then\s+|\s+then\s+)\s*/i)
    .map(normalizeText)
    .filter(Boolean);
}

function extractRecipients(markdown) {
  const recipients = [];
  const re = /\*\*To:\*\*\s*(.+)/g;
  let match;
  while ((match = re.exec(markdown || ''))) {
    const recipient = normalizeText(match[1]);
    if (recipient) recipients.push(recipient);
  }
  return recipients;
}

function extractSendDate(markdown) {
  const source = markdown || '';
  const patterns = [
    /\*\*Target send date:\*\*\s*([^\n]+)/i,
    /\*\*Send date:\*\*\s*([^\n]+)/i,
    /If approved:\s*(?:send|schedule)[^\n]*\b(?:on|for)\s+([A-Za-z]{3,9}\s+\d{1,2}(?:,\s*\d{4})?|\d{4}-\d{2}-\d{2})/i,
  ];
  for (const pattern of patterns) {
    const match = source.match(pattern);
    if (match) return normalizeText(match[1]);
  }
  return null;
}

function extractOutboundPlan(item) {
  const markdown = item?.markdown || '';
  const recipients = extractRecipients(markdown);
  const sendDate = extractSendDate(markdown);
  const hasCopy = /\*\*Subject:\*\*/i.test(markdown) && markdown.length > 200;
  const literalCopy = /\b(literal|verbatim|do not rewrite|without rewriting)\b/i.test(markdown);
  const followUpsIncluded = /\bfollow[- ]?up\b/i.test(markdown);

  return {
    recipients,
    recipientCount: recipients.length,
    sendDate,
    hasCopy,
    literalCopy,
    followUpsIncluded,
    complete: recipients.length > 0 && Boolean(sendDate) && hasCopy,
  };
}

function buildReviewIntent({ item, onApprove }) {
  const category = String(item?.category || 'general');
  const outboundPlan = extractOutboundPlan(item);
  const approvalPayload = normalizeApprovalPayload(onApprove || item?.on_approve || null);
  const approvalKind = normalizeText(approvalPayload.kind || approvalPayload.requestedKind);

  if (category === 'outreach') {
    return {
      kind: 'outbound_approval',
      summary: 'Approve outbound copy, shown recipients, and the stated send plan.',
      needed_from_jimmy: 'Approve or reject the outbound send plan.',
      on_approval_kind: 'outreach_approval',
      on_approval_payload: JSON.stringify({
        sendPlan: outboundPlan,
        onApprove: onApprove || item?.on_approve || null,
      }),
    };
  }

  if (category === 'confirmation') {
    const payload = safeJsonParse(item?.on_approve, {});
    return {
      kind: 'sensitive_confirmation',
      summary: payload?.summary || 'Confirm a sensitive downstream action.',
      needed_from_jimmy: 'Approve this sensitive action before it runs.',
      on_approval_kind: payload?.kind || 'agent_followup',
      on_approval_payload: JSON.stringify(payload || {}),
    };
  }

  if (category === 'clarification') {
    const payload = safeJsonParse(item?.on_approve, {});
    return {
      kind: 'decision_clarification',
      summary: payload?.summary || 'Clarify the requested next action.',
      needed_from_jimmy: 'Add the missing detail Benji needs to proceed.',
      on_approval_kind: payload?.kind || 'agent_followup',
      on_approval_payload: JSON.stringify(payload || {}),
    };
  }

  return {
    kind: approvalKind ? 'approval_action' : 'general_review',
    summary: approvalPayload.summary || approvalPayload.instruction || 'Review the artifact and decide the next step.',
    needed_from_jimmy: approvalPayload.needed_from_jimmy || approvalPayload.instruction || 'Review and respond.',
    on_approval_kind: approvalKind || null,
    on_approval_payload: Object.keys(approvalPayload).length ? JSON.stringify(approvalPayload) : null,
  };
}

function makeRequest(kind, summary, payload = {}, overrides = {}) {
  return {
    kind,
    summary: normalizeText(summary) || kind,
    sensitivity: overrides.sensitivity || 'normal',
    status: overrides.status || 'queued',
    payload: {
      ...payload,
      idempotencyKey: payload.idempotencyKey || stableRequestKey([
        kind,
        summary,
        payload.slug,
        payload.decision,
        payload.feedback,
      ]),
    },
    maxAttempts: overrides.maxAttempts || 3,
  };
}

function calendarSlotMissing(payload = {}) {
  const missing = [];
  if (!normalizeText(payload.start)) missing.push('exact start time');
  if (!normalizeText(payload.end) && !normalizeText(payload.duration)) {
    missing.push('exact end time or duration');
  } else if (!normalizeText(payload.end)) {
    missing.push('exact end time');
  }
  return missing;
}

function normalizeDecisionRequest(request = {}) {
  const payload = request.payload && typeof request.payload === 'object' ? { ...request.payload } : {};
  const kind = normalizeText(request.kind || payload.kind || payload.requestedKind || 'agent_followup');
  const summary = normalizeText(request.summary || payload.summary || 'Agent-created follow-up request');
  const status = request.status || 'queued';
  const sensitivity = request.sensitivity || 'normal';
  const isSchedulingRequest = kind === 'create_calendar_event' || SCHEDULING_REQUEST_KINDS.has(kind);

  if (!isSchedulingRequest) {
    return {
      ...request,
      kind,
      summary,
      sensitivity,
      status,
      payload,
    };
  }

  if (normalizeText(payload.start) && normalizeText(payload.end)) {
    return {
      ...request,
      kind: 'create_calendar_event',
      summary,
      sensitivity,
      status: SCHEDULING_REQUEST_KINDS.has(kind) ? 'queued' : status,
      payload,
    };
  }

  return {
    ...request,
    kind: 'decision_clarification',
    summary: summary || 'Clarify calendar scheduling request',
    sensitivity,
    status: 'blocked_decision',
    payload: {
      ...payload,
      requestedKind: 'create_calendar_event',
      originalKind: payload.originalKind || kind,
      instruction: payload.instruction || payload.context || payload.topic || summary,
      missing: Array.isArray(payload.missing) && payload.missing.length ? payload.missing : calendarSlotMissing(payload),
    },
  };
}

function classifyFeedbackSentence(sentence) {
  const text = normalizeText(sentence);
  const lower = text.toLowerCase();

  if (!text) return null;

  if (/\b(send|email|message|outreach|dm)\b/.test(lower)) {
    return makeRequest('sensitive_confirmation', `Confirm outbound message: ${text}`, {
      requestedKind: 'send_message',
      instruction: text,
    }, {
      sensitivity: 'sensitive',
      status: 'needs_confirmation',
    });
  }

  if (/\b(invite|meeting with|calendar invite)\b/.test(lower)) {
    return makeRequest('sensitive_confirmation', `Confirm calendar invite: ${text}`, {
      requestedKind: 'calendar_invite',
      instruction: text,
    }, {
      sensitivity: 'sensitive',
      status: 'needs_confirmation',
    });
  }

  if (/\b(task|omnifocus|to[- ]?do|todo|follow up|remind me|reminder)\b/.test(lower)) {
    return makeRequest('create_omnifocus_task', text, {
      title: text,
      note: '',
    });
  }

  if (/\b(schedule|calendar|time block|block time)\b/.test(lower)) {
    return makeRequest('decision_clarification', `Clarify calendar request: ${text}`, {
      requestedKind: 'create_calendar_event',
      instruction: text,
      missing: ['exact start time', 'duration or end time'],
    }, {
      status: 'blocked_decision',
    });
  }

  return null;
}

function feedbackRequests(feedback) {
  const requests = [];
  const seen = new Set();
  for (const sentence of splitFeedback(feedback)) {
    const request = classifyFeedbackSentence(sentence);
    if (!request) continue;
    const key = `${request.kind}:${request.summary}`;
    if (seen.has(key)) continue;
    seen.add(key);
    requests.push(request);
  }
  return requests;
}

function rejectedReviewTargetFeedback(reviewTargets = []) {
  return reviewTargets
    .filter((target) => target && target.verdict === 'rejected' && normalizeText(target.feedback))
    .map((target) => `${normalizeText(target.label || target.target_key || target.key)}: ${normalizeText(target.feedback)}`)
    .join('\n')
    .trim();
}

function countMatches(text, patterns) {
  return patterns.reduce((count, pattern) => count + (pattern.test(text) ? 1 : 0), 0);
}

function isSoftwareBuildPlan(item = {}) {
  const title = normalizeText(item.title);
  const sourcePath = normalizeText(item.source_path || item.sourcePath);
  const markdown = String(item.markdown || item.rendered_html || '').slice(0, 16000);
  const titleAndPath = `${title}\n${sourcePath}`;
  const normalizedTitleAndPath = titleAndPath.replace(/[-_/]+/g, ' ');
  const searchable = `${normalizedTitleAndPath}\n${markdown}`;

  if (/<!--\s*turf-review:\s*software-build-plan\s*-->/i.test(markdown)) return true;
  if (/\bturf-review:\s*software-build-plan\b/i.test(markdown)) return true;

  const hasPlanTitle = SOFTWARE_PLAN_TITLE_PATTERNS.some((pattern) => pattern.test(normalizedTitleAndPath));
  if (!hasPlanTitle) return false;

  return countMatches(searchable, SOFTWARE_PLAN_BODY_PATTERNS) >= 2;
}

function explicitExecuteRequest({ item, intent, basePayload, effectiveFeedback }) {
  const approvalPayload = safeJsonParse(intent?.on_approval_payload, {});
  const kind = normalizeText(intent?.on_approval_kind || approvalPayload.kind || approvalPayload.requestedKind);
  if (!kind) return null;

  return makeRequest(kind, approvalPayload.summary || `Execute approved action for ${item.title}`, {
    ...basePayload,
    ...approvalPayload,
    feedback: effectiveFeedback || basePayload.feedback || '',
    approvedByReview: item.slug,
  }, {
    sensitivity: approvalPayload.sensitivity || 'normal',
    maxAttempts: approvalPayload.maxAttempts || undefined,
  });
}

function softwareBuildRequest({ item, basePayload }) {
  return makeRequest('agent_build', `Build approved software plan: ${item.title}`, {
    ...basePayload,
    planKind: 'software_build_plan',
    instruction: 'Implement the approved software build plan in the linked workspace. Make the code changes, run focused verification, and return durable proof or a clear blocker.',
    outcomeContract: 'Success requires changed source, a useful artifact, child action requests, or verification proof. An agent/session reply alone is not success.',
  });
}

function originDecisionNoticeRequest({ item, basePayload, consent }) {
  if (!basePayload.originSessionKey) return null;
  return makeRequest('origin_decision_notice', `Record review decision for ${item.title}`, {
    ...basePayload,
    consent,
    instruction: consent
      ? 'Jimmy approved this plan. Record the consent and wait for the execution request.'
      : 'Jimmy did not approve this plan for execution. Record the decision and do not execute the plan.',
  }, {
    maxAttempts: 3,
  });
}

function decomposeDecision({ item, intent, decision, feedback, annotations = [], reviewTargets = [], reviewUrl }) {
  const effectiveFeedback = normalizeText(feedback) ? feedback : rejectedReviewTargetFeedback(reviewTargets);
  const intentPayload = safeJsonParse(intent?.on_approval_payload, {});
  const originSessionKey = normalizeSessionKey(
    intentPayload.originSessionKey
      || intentPayload.sourceSessionKey
      || intentPayload.draftSessionKey
      || item.origin_session_key
      || item.originSessionKey
  );
  const basePayload = {
    slug: item.slug,
    title: item.title,
    category: item.category,
    decision,
    feedback: effectiveFeedback || '',
    annotations,
    reviewTargets,
    reviewUrl,
    workspaceDir: item.workspace_dir,
    sourcePath: item.source_path,
    originSessionKey,
  };

  if (NO_ACTION_DECISIONS.has(decision) || KILL_DECISIONS.has(decision)) {
    const notice = originDecisionNoticeRequest({ item, basePayload, consent: false });
    return notice ? [notice] : [];
  }

  if (item.category === 'confirmation' && decision === 'Approve') {
    const approvalPayload = safeJsonParse(intent?.on_approval_payload, {});
    const kind = intent?.on_approval_kind || approvalPayload?.kind || approvalPayload?.requestedKind || 'agent_followup';
    return [
      makeRequest(kind, approvalPayload?.summary || `Approved sensitive action for ${item.title}`, {
        ...basePayload,
        ...approvalPayload,
        approvedByReview: item.slug,
      }, {
        sensitivity: 'approved_sensitive',
      }),
    ];
  }

  if (item.category === 'clarification' && decision === 'Execute') {
    const clarificationPayload = safeJsonParse(intent?.on_approval_payload, {});
    return [
      makeRequest(clarificationPayload?.kind || clarificationPayload?.requestedKind || 'agent_followup', effectiveFeedback || `Clarified action for ${item.title}`, {
        ...basePayload,
        ...clarificationPayload,
        clarification: effectiveFeedback || '',
        approvedByReview: item.slug,
      }),
    ];
  }

  if (REWORK_DECISIONS.has(decision)) {
    if (!normalizeText(effectiveFeedback)) {
      return [
        makeRequest('decision_clarification', 'Rework requires feedback before Benji can revise this.', {
          ...basePayload,
          missing: ['rework feedback'],
        }, {
          status: 'blocked_decision',
        }),
      ];
    }

    return [
      makeRequest('agent_rework', `Rework "${item.title}" from Jimmy feedback.`, {
        ...basePayload,
      }),
    ];
  }

  if (decision === 'Inbox') {
    return [
      makeRequest('create_omnifocus_task', `Review follow-up: ${item.title}`, {
        ...basePayload,
        title: `Review follow-up: ${item.title}`,
        note: effectiveFeedback || `Review: ${reviewUrl}`,
      }),
    ];
  }

  if (decision === 'Send') {
    const sendPlan = extractOutboundPlan(item);
    if (!sendPlan.complete) {
      return [
        makeRequest('decision_clarification', `Clarify send plan for ${item.title}`, {
          ...basePayload,
          requestedKind: 'outreach_approval',
          sendPlan,
          missing: [
            ...(!sendPlan.recipientCount ? ['recipient list'] : []),
            ...(!sendPlan.sendDate ? ['send timing'] : []),
            ...(!sendPlan.hasCopy ? ['exact copy/template'] : []),
          ],
        }, {
          status: 'blocked_decision',
        }),
      ];
    }

    return [
      makeRequest('outreach_approval', `Approve outbound send plan for ${item.title}`, {
        ...basePayload,
        sendPlan,
      }, {
        sensitivity: 'approved_sensitive',
      }),
    ];
  }

  if (decision === 'Execute') {
    const explicitRequest = explicitExecuteRequest({ item, intent, basePayload, effectiveFeedback });
    if (explicitRequest) return [explicitRequest];

    if (isSoftwareBuildPlan(item)) {
      return [softwareBuildRequest({ item, basePayload })];
    }

    const parsed = feedbackRequests(effectiveFeedback);
    if (parsed.length) {
      return parsed.map((request) => ({
        ...request,
        payload: {
          ...basePayload,
          ...request.payload,
        },
      }));
    }

    return [
      makeRequest('agent_followup', `Execute follow-up for ${item.title}`, {
        ...basePayload,
        outcomeContract: 'Return durable proof, a produced report/artifact, child action requests, or an explicit blocker. OpenClaw/session completion alone is not success.',
      }),
    ];
  }

  return [
    makeRequest('agent_followup', `Handle ${decision} for ${item.title}`, basePayload),
  ];
}

module.exports = {
  NO_ACTION_DECISIONS,
  buildReviewIntent,
  decomposeDecision,
  extractOutboundPlan,
  feedbackRequests,
  isSoftwareBuildPlan,
  normalizeSessionKey,
  normalizeText,
  safeJsonParse,
  normalizeDecisionRequest,
};

const crypto = require('crypto');

const NO_ACTION_DECISIONS = new Set(['Noted', 'Park', 'No further action']);
const REWORK_DECISIONS = new Set(['Rework', 'Edit']);
const KILL_DECISIONS = new Set(['Kill']);

function normalizeText(value) {
  return String(value || '').replace(/\s+/g, ' ').trim();
}

function safeJsonParse(value, fallback = null) {
  if (!value || typeof value !== 'string') return fallback;
  try {
    return JSON.parse(value);
  } catch (_error) {
    return fallback;
  }
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
    kind: 'general_review',
    summary: onApprove || item?.on_approve || 'Review the artifact and decide the next step.',
    needed_from_jimmy: onApprove || item?.on_approve || 'Review and respond.',
    on_approval_kind: null,
    on_approval_payload: onApprove ? JSON.stringify({ instruction: onApprove }) : null,
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

function decomposeDecision({ item, intent, decision, feedback, annotations = [], reviewUrl }) {
  const basePayload = {
    slug: item.slug,
    title: item.title,
    category: item.category,
    decision,
    feedback: feedback || '',
    annotations,
    reviewUrl,
    workspaceDir: item.workspace_dir,
    sourcePath: item.source_path,
  };

  if (NO_ACTION_DECISIONS.has(decision) || KILL_DECISIONS.has(decision)) {
    return [];
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
      makeRequest(clarificationPayload?.kind || clarificationPayload?.requestedKind || 'agent_followup', feedback || `Clarified action for ${item.title}`, {
        ...basePayload,
        ...clarificationPayload,
        clarification: feedback || '',
        approvedByReview: item.slug,
      }),
    ];
  }

  if (REWORK_DECISIONS.has(decision)) {
    if (!normalizeText(feedback)) {
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
        note: feedback || `Review: ${reviewUrl}`,
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
    const parsed = feedbackRequests(feedback);
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
  normalizeText,
  safeJsonParse,
};

const fs = require('fs');
const { execFile } = require('child_process');
const { promisify } = require('util');

const Database = require('better-sqlite3');

const { createContentHash } = require('../db');
const { renderSourceDocument } = require('./render');
const {
  DECISION_SCHEMA_VERSION,
  getCanonicalActions,
  getSessionKey,
  getStoredStatusForDecision,
} = require('../review-routing');
const {
  buildReviewIntent,
  decomposeDecision,
  normalizeDecisionRequest,
  normalizeSessionKey,
  normalizeText,
  safeJsonParse,
} = require('./decision-contract');

const execFileAsync = promisify(execFile);

function sqlDateAfter(seconds) {
  return new Date(Date.now() + seconds * 1000).toISOString().slice(0, 19).replace('T', ' ');
}

function nowSql() {
  return new Date().toISOString().slice(0, 19).replace('T', ' ');
}

function httpError(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function parseJson(value, fallback = {}) {
  if (!value) return fallback;
  if (typeof value === 'object') return value;
  return safeJsonParse(value, fallback);
}

function safeSlugPart(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 50) || 'request';
}

function createDecisionOrchestrator(options) {
  const {
    config,
    db,
    stmts,
    openclawClient,
    appendSessionNote,
    seedSessionForItem,
    broadcastSSE,
  } = options;

  const retryDelaySeconds = Number(process.env.TURF_REVIEW_ACTION_RETRY_SECONDS || 60);
  const externalRecheckSeconds = Number(process.env.TURF_REVIEW_EXTERNAL_RECHECK_SECONDS || 600);
  const maxAttempts = Number(process.env.TURF_REVIEW_ACTION_MAX_ATTEMPTS || 3);
  const webOnlyMode = process.env.TURF_REVIEW_WEB_ONLY === '1';

  function recordIntentForItem(item, onApprove = item?.on_approve) {
    const intent = buildReviewIntent({ item, onApprove });
    stmts.recordReviewIntent.run({
      slug: item.slug,
      kind: intent.kind,
      summary: intent.summary || null,
      needed_from_jimmy: intent.needed_from_jimmy || null,
      on_approval_kind: intent.on_approval_kind || null,
      on_approval_payload: intent.on_approval_payload || null,
    });
    return intent;
  }

  function getIntent(item) {
    return stmts.getReviewIntent.get(item.slug) || recordIntentForItem(item);
  }

  function updateItemActionSummary(slug) {
    const rows = stmts.listDecisionRequestsForSlug.all(slug);
    if (!rows.length) {
      updateItemActionState(slug, 'succeeded', 'Decision recorded. No downstream action required.');
      return;
    }

    const counts = rows.reduce((acc, row) => {
      acc[row.status] = (acc[row.status] || 0) + 1;
      return acc;
    }, {});

    if (counts.blocked_system || counts.failed) {
      updateItemActionState(slug, 'blocked', 'A downstream system action is blocked; the system will notify Jimmy if it stays stuck.');
      return;
    }
    if (counts.blocked_decision || counts.needs_confirmation) {
      updateItemActionState(slug, 'blocked', 'A follow-up confirmation or clarification review was created.');
      return;
    }
    if (counts.running) {
      updateItemActionState(slug, 'running', 'Downstream action processing is running.');
      return;
    }
    if (counts.queued || counts.waiting_external) {
      updateItemActionState(slug, 'queued', 'Downstream action processing is queued or waiting for an authoritative system.');
      return;
    }

    updateItemActionState(slug, 'succeeded', 'All downstream action requests reached a durable outcome.');
  }

  function updateItemActionState(slug, status, message) {
    db.prepare(`
      UPDATE items
      SET action_status = @status,
          action_message = @message,
          action_updated_at = datetime('now'),
          approval_status = @status,
          approval_message = @message,
          approval_exit_code = NULL,
          approval_updated_at = datetime('now')
      WHERE slug = @slug
    `).run({ slug, status, message });
  }

  function insertInternalReview({ title, markdown, category, onApprove, parentSlug, requestId }) {
    const slug = `${category}-${safeSlugPart(title)}-${Date.now().toString(36)}-${String(requestId || '').slice(-4)}`;
    const rendered = renderSourceDocument({ markdown, html: null });
    const actions = JSON.stringify(getCanonicalActions(category));
    const sessionKey = getSessionKey(slug);

    stmts.insert.run({
      slug,
      title,
      markdown: rendered.markdown,
      rendered_html: rendered.rendered_html,
      category,
      actions,
      content_hash: createContentHash(`${title}:${slug}`, rendered.markdown),
      mindwtr_task_id: null,
      mindwtr_project_id: null,
      on_approve: onApprove ? JSON.stringify(onApprove) : null,
      session_key: sessionKey,
      workspace_dir: null,
      source_path: null,
      decision_schema_version: DECISION_SCHEMA_VERSION,
      parent_slug: parentSlug || null,
      supersedes_slug: null,
      created_by_request_id: requestId || null,
    });

    const item = stmts.getBySlug.get(slug);
    recordIntentForItem(item, item.on_approve);
    return item;
  }

  function createFollowupReviewForRequest(requestRow, request) {
    const payload = request.payload || parseJson(requestRow.payload);
    const parentTitle = payload.title || payload.slug || requestRow.slug;
    const isSensitive = request.kind === 'sensitive_confirmation' || requestRow.status === 'needs_confirmation';
    const category = isSensitive ? 'confirmation' : 'clarification';
    const title = isSensitive
      ? `Confirm action: ${request.summary}`
      : `Clarify action: ${request.summary}`;
    const markdown = [
      `# ${title}`,
      '',
      `Original review: [${parentTitle}](${payload.reviewUrl || `/review/${requestRow.slug}`})`,
      '',
      isSensitive
        ? 'This action is sensitive, so Turf Review needs explicit approval before Benji runs it.'
        : 'Benji needs this clarified before the downstream action can continue.',
      '',
      '## Requested action',
      '',
      request.summary,
      '',
      payload.instruction ? `> ${payload.instruction}` : '',
      '',
      payload.missing?.length ? `Missing: ${payload.missing.join(', ')}` : '',
      '',
      '## Original feedback',
      '',
      payload.feedback || '(none)',
    ].filter((line) => line !== '').join('\n');

    const onApprove = {
      kind: payload.requestedKind || payload.kind || 'agent_followup',
      requestedKind: payload.requestedKind || payload.kind || 'agent_followup',
      summary: request.summary,
      instruction: payload.instruction || request.summary,
      originalPayload: payload,
      sourceRequestId: requestRow.id,
    };
    const followup = insertInternalReview({
      title,
      markdown,
      category,
      onApprove,
      parentSlug: requestRow.slug,
      requestId: requestRow.id,
    });
    stmts.updateDecisionRequestConfirmation.run({
      id: requestRow.id,
      confirmation_slug: followup.slug,
    });
    enqueueNotification({
      requestId: requestRow.id,
      kind: isSensitive ? 'sensitive_confirmation' : 'decision_clarification',
      message: `${isSensitive ? 'Confirmation' : 'Clarification'} needed in Turf Review: ${title}\n${buildReviewUrl(followup.slug)}`,
    });
    return followup;
  }

  function announceInternalReview(item, label = 'follow-up') {
    broadcastSSE('new-item', { slug: item.slug, title: item.title, category: item.category });
    setImmediate(async () => {
      try {
        await seedSessionForItem(item, buildReviewUrl(item.slug), 'bootstrap');
      } catch (error) {
        console.error(`[orchestrator] Failed to seed ${label} review ${item.slug}: ${error.message}`);
      }
    });
  }

  function buildReviewUrl(slug) {
    const base = config.reviewBaseUrl || 'https://review.turfterrace.com';
    return new URL(`/review/${slug}`, base.replace(/\/+$/, '')).toString();
  }

  function getNotificationConfig() {
    const openclaw = config.openclaw || {};
    return {
      channel: openclaw.notificationChannel || 'discord',
      account: openclaw.notificationAccount || 'default',
      target: openclaw.notificationTarget || 'channel:1509121052834529330',
      threadId: openclaw.notificationThreadId || '',
      replyTo: openclaw.notificationReplyTo || '',
    };
  }

  function enqueueNotification({ requestId = null, kind, message }) {
    const notification = getNotificationConfig();
    stmts.insertNotification.run({
      request_id: requestId,
      channel: notification.channel,
      audience: 'jimmy',
      kind,
      status: webOnlyMode ? 'queued' : 'queued',
      payload_json: JSON.stringify({ message, ...notification }),
    });
  }

  function recordProof(requestId, proofType, externalId, payload) {
    stmts.insertOutcomeProof.run({
      request_id: requestId,
      proof_type: proofType,
      external_id: externalId || null,
      payload_json: JSON.stringify(payload || {}),
    });
  }

  function insertActionRunForRequest(request, status, { error = null, proof = null } = {}) {
    const attempt = Math.max(1, Number(request?.attempts || 0));
    stmts.insertActionRun.run({
      request_id: request.id,
      attempt,
      status,
      error,
      proof_json: proof ? JSON.stringify(proof) : null,
      completed_at: nowSql(),
    });
  }

  function markRequestStatus(requestId, status, { proof = null, error = null, nextAttemptAt = null, completed = false } = {}) {
    stmts.markDecisionRequestStatus.run({
      id: requestId,
      status,
      proof_json: proof ? JSON.stringify(proof) : null,
      last_error: error,
      next_attempt_at: nextAttemptAt,
      completed_at: completed ? nowSql() : null,
    });
  }

  function getSourceRequestId(item, intent) {
    if (item?.category !== 'confirmation' && item?.category !== 'clarification') return null;
    const directPayload = parseJson(item.on_approve, {});
    const intentPayload = parseJson(intent?.on_approval_payload, {});
    return intentPayload.sourceRequestId || directPayload.sourceRequestId || null;
  }

  function resolveSourceRequest(item, intent, decision, createdRequests) {
    const sourceRequestId = getSourceRequestId(item, intent);
    if (!sourceRequestId) return;

    const source = stmts.getDecisionRequestById.get(sourceRequestId);
    if (!source) return;

    const proof = {
      resolvedByReview: item.slug,
      decision,
      childRequestIds: createdRequests.map((request) => request.id),
      outcome: createdRequests.length ? 'continued_to_downstream_request' : 'dismissed_without_action',
    };
    recordProof(sourceRequestId, 'followup_review_resolution', item.slug, proof);
    markRequestStatus(sourceRequestId, 'succeeded', { proof, completed: true });
    updateItemActionSummary(source.slug);
  }

  function handleDecision(item, { decision, feedback, annotations, reviewTargets = [], reviewUrl }) {
    const intent = getIntent(item);
    const requests = decomposeDecision({ item, intent, decision, feedback, annotations, reviewTargets, reviewUrl })
      .map((request) => normalizeDecisionRequest(request));
    const storedStatus = getStoredStatusForDecision(decision);
    let decisionId;
    const createdRequests = [];

    const tx = db.transaction(() => {
      const decisionResult = stmts.insertDecision.run({
        slug: item.slug,
        decision,
        feedback: feedback || null,
        actor: 'jimmy',
        status: 'recorded',
      });
      decisionId = decisionResult.lastInsertRowid;

      stmts.decide.run({
        slug: item.slug,
        status: storedStatus,
        decision,
        feedback: feedback || null,
        action_status: requests.length ? 'queued' : 'succeeded',
        action_message: requests.length
          ? `Recorded decision and created ${requests.length} downstream request(s).`
          : 'Decision recorded. No downstream action required.',
      });

      for (const request of requests) {
        const result = stmts.insertDecisionRequest.run({
          decision_id: decisionId,
          slug: item.slug,
          parent_request_id: request.payload?.sourceRequestId || null,
          kind: request.kind,
          summary: request.summary,
          sensitivity: request.sensitivity,
          status: request.status,
          payload: JSON.stringify(request.payload || {}),
          max_attempts: request.maxAttempts || maxAttempts,
        });
        createdRequests.push({ ...request, id: result.lastInsertRowid });
      }
    });
    tx();

    const followups = [];
    for (const request of createdRequests) {
      if (request.status === 'needs_confirmation' || request.status === 'blocked_decision') {
        const row = stmts.getDecisionRequestById.get(request.id);
        followups.push(createFollowupReviewForRequest(row, request));
      }
    }

    updateItemActionSummary(item.slug);
    resolveSourceRequest(item, intent, decision, createdRequests);
    broadcastSSE('review-processed', { slug: item.slug, decision, status: storedStatus });
    if (createdRequests.some((request) => request.status === 'queued') && !webOnlyMode) {
      scheduleDrain();
    }
    if (followups.length) {
      for (const followup of followups) {
        broadcastSSE('new-item', { slug: followup.slug, title: followup.title, category: followup.category });
        setImmediate(async () => {
          try {
            await seedSessionForItem(followup, buildReviewUrl(followup.slug), 'bootstrap');
          } catch (error) {
            console.error(`[orchestrator] Failed to seed follow-up review ${followup.slug}: ${error.message}`);
          }
        });
      }
      if (!webOnlyMode) void drainNotifications();
    }

    return {
      status: storedStatus,
      decisionId,
      requests: createdRequests,
      followups,
    };
  }

  async function createOmniFocusTask(request, payload) {
    if (!fs.existsSync(config.integrations.omnifocusBin)) {
      throw new Error(`OmniFocus CLI not found at ${config.integrations.omnifocusBin}`);
    }
    const title = normalizeText(payload.title || request.summary);
    const noteParts = [
      payload.note || '',
      payload.reviewUrl ? `Review: ${payload.reviewUrl}` : '',
      payload.feedback ? `Feedback:\n${payload.feedback}` : '',
    ].filter(Boolean);
    const args = ['task', 'create', title];
    if (noteParts.length) args.push('--note', noteParts.join('\n\n'));
    const result = await execFileAsync(config.integrations.omnifocusBin, args, {
      timeout: 45000,
      env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' },
    });
    const task = JSON.parse(result.stdout);
    if (!task?.id) throw new Error('OmniFocus task create returned no task id');
    return { proofType: 'omnifocus_task', externalId: task.id, proof: { task } };
  }

  async function createCalendarEvent(request, payload) {
    if (!payload.start || !payload.end) {
      markRequestStatus(request.id, 'blocked_decision', {
        error: 'Calendar request needs exact start and end time.',
        completed: true,
      });
      const row = stmts.getDecisionRequestById.get(request.id);
      createFollowupReviewForRequest(row, {
        id: request.id,
        kind: 'decision_clarification',
        summary: request.summary,
        payload: { ...payload, requestedKind: 'create_calendar_event', missing: ['start', 'end'] },
      });
      return null;
    }

    const script = `
      on run argv
        set calendarName to item 1 of argv
        set eventTitle to item 2 of argv
        set eventStart to date (item 3 of argv)
        set eventEnd to date (item 4 of argv)
        tell application "Calendar"
          set targetCalendar to first calendar whose name is calendarName
          set newEvent to make new event at end of events of targetCalendar with properties {summary:eventTitle, start date:eventStart, end date:eventEnd}
          return uid of newEvent
        end tell
      end run
    `;
    const result = await execFileAsync('/usr/bin/osascript', [
      '-e',
      script,
      config.integrations.calendarName,
      normalizeText(payload.title || request.summary),
      payload.start,
      payload.end,
    ], { timeout: 30000 });
    const eventId = normalizeText(result.stdout);
    if (!eventId) throw new Error('Calendar returned no event id');
    return { proofType: 'calendar_event', externalId: eventId, proof: { eventId, calendar: config.integrations.calendarName } };
  }

  function inspectOutreachState(slug) {
    if (!fs.existsSync(config.integrations.kitchenLuxCrmDb)) {
      throw new Error(`KitchenLux CRM DB not found at ${config.integrations.kitchenLuxCrmDb}`);
    }
    const crm = new Database(config.integrations.kitchenLuxCrmDb, { readonly: true });
    try {
      const queueItems = crm.prepare(`
        SELECT id, contact_id, recipient_email, subject, scheduled_for, status, state,
               sent_at, provider_message_id, provider_thread_id, blocked_reason,
               terminal_reason, error
        FROM queue_items
        WHERE review_slug = ?
        ORDER BY created_at ASC
      `).all(slug);
      const attempts = crm.prepare(`
        SELECT id, queue_item_id, recipient_email, subject, sent_at, status,
               provider_status, gmail_message_id, gmail_thread_id, error_message,
               completed_at
        FROM send_attempts
        WHERE queue_item_id IN (SELECT id FROM queue_items WHERE review_slug = ?)
        ORDER BY created_at ASC
      `).all(slug);
      return { queueItems, attempts };
    } finally {
      crm.close();
    }
  }

  async function approveOutreach(request, payload) {
    if (!fs.existsSync(config.integrations.reviewDecisionIngestScript)) {
      throw new Error(`review-decision-ingest.ts not found at ${config.integrations.reviewDecisionIngestScript}`);
    }
    const result = await execFileAsync(config.integrations.bunBin, [
      config.integrations.reviewDecisionIngestScript,
      payload.slug,
      `decision-request:${request.id}`,
    ], {
      cwd: config.integrations.clawdRoot,
      timeout: 60000,
      env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' },
    });

    const ingestPayload = safeJsonParse(result.stdout.trim(), { ok: true, raw: result.stdout.trim() });
    const state = inspectOutreachState(payload.slug);
    if (!state.queueItems.length) {
      throw new Error(`Outreach ingest produced no queue items for ${payload.slug}: ${JSON.stringify(ingestPayload)}`);
    }

    const allSent = state.queueItems.every((item) => item.sent_at || item.provider_message_id);
    const failed = state.queueItems.find((item) => {
      const status = `${item.status || ''} ${item.state || ''} ${item.terminal_reason || ''}`.toLowerCase();
      return status.includes('fail') || status.includes('blocked') || item.error || item.blocked_reason;
    });

    if (failed) {
      throw new Error(`Outreach queue item blocked: ${failed.id} ${failed.blocked_reason || failed.error || failed.terminal_reason || failed.status}`);
    }

    const proof = {
      ingest: ingestPayload,
      queueItemIds: state.queueItems.map((item) => item.id),
      sendAttemptIds: state.attempts.map((attempt) => attempt.id),
      sent: allSent,
    };

    if (allSent) {
      return { proofType: 'sent_email_log', externalId: proof.sendAttemptIds.join(','), proof };
    }

    markRequestStatus(request.id, 'waiting_external', {
      proof,
      nextAttemptAt: sqlDateAfter(externalRecheckSeconds),
    });
    recordProof(request.id, 'outreach_send_queue', proof.queueItemIds.join(','), proof);
    return null;
  }

  function targetSessionKeyForRequest(item, payload = {}) {
    return normalizeSessionKey(
      payload.originSessionKey
        || payload.sourceSessionKey
        || payload.draftSessionKey
        || item?.origin_session_key
        || item?.session_key
        || (item?.slug ? getSessionKey(item.slug) : null)
    );
  }

  function isBuildRequest(request) {
    return request?.kind === 'agent_build' || request?.kind === 'codex_implementation';
  }

  function isOriginSessionRequest(request) {
    return isBuildRequest(request)
      || request?.kind === 'agent_rework'
      || request?.kind === 'agent_followup'
      || request?.kind === 'origin_decision_notice';
  }

  function agentInstructionsForRequest(request) {
    if (isBuildRequest(request)) {
      return [
        request?.kind === 'codex_implementation'
          ? 'This is an approved Codex implementation request spawned from a Turf Review plan.'
          : 'This is an approved software build plan.',
        'Jimmy has consented to execute the plan.',
        'Implement the plan in the linked workspace and source context.',
        'Use the request payload as the execution contract, not as a memory search or planning prompt.',
        'Make concrete code changes when the workspace is available.',
        'Run focused verification and return durable proof, a produced artifact, child action requests, or a clear blocker.',
        'Do not treat an OpenClaw/session reply as completion by itself.',
      ].join(' ');
    }

    return [
      'This is a Turf Review downstream action request.',
      'Do not treat an OpenClaw/session reply as completion by itself.',
      'Return durable proof, a produced report/artifact, child action requests, or a clear blocker.',
    ].join(' ');
  }

  async function appendRequestSessionNote(item, mode, payload, request) {
    const targetSessionKey = isOriginSessionRequest(request)
      ? targetSessionKeyForRequest(item, payload)
      : item?.session_key || getSessionKey(item.slug);
    return appendSessionNote(item, mode, {
      ...payload,
      targetSessionKey,
      reviewSessionKey: item?.session_key || (item?.slug ? getSessionKey(item.slug) : null),
    }, targetSessionKey ? { sessionKey: targetSessionKey } : undefined);
  }

  async function runAgentRequest(request, payload, mode = 'followup') {
    if (!openclawClient) {
      throw new Error('OpenClaw is not configured for agent follow-up work.');
    }
    const item = stmts.getBySlug.get(request.slug);
    const completion = await appendRequestSessionNote(item, mode, {
      instructions: agentInstructionsForRequest(request),
      request: {
        id: request.id,
        kind: request.kind,
        summary: request.summary,
        payload,
      },
      responseFormat: {
        instruction: 'Reply with [TURF_REVIEW_INTERNAL] followed by one valid JSON object. No label, prose, markdown, or code fences.',
        schema: {
          status: 'succeeded | answered | blocked_system | blocked_decision | failed',
          summary: 'short summary',
          proof: 'optional proof object',
          producedArtifact: 'optional durable answer/report/artifact text',
          childRequests: 'optional array of {kind, summary, payload, sensitivity}',
          replacementReview: 'optional {title, markdown, category}',
          blocker: 'optional blocker reason',
        },
      },
    }, request);
    const parsed = parseInternalResultText(completion?.text || '');
    if (!parsed) {
      throw new Error('OpenClaw did not return a structured internal result');
    }
    return parsed;
  }

  async function sendOriginDecisionNotice(request, payload) {
    if (!openclawClient) {
      throw new Error('OpenClaw is not configured for origin decision notices.');
    }
    const item = stmts.getBySlug.get(request.slug);
    await appendRequestSessionNote(item, 'decision', {
      instructions: [
        'This is the Turf Review decision for the plan you drafted.',
        payload.consent ? 'Jimmy consented to execution.' : 'Jimmy did not consent to execution.',
        'Record this decision in session memory.',
        payload.consent ? 'Wait for the execution request before making changes.' : 'Do not execute the plan.',
      ].join(' '),
      decision: {
        reviewSlug: request.slug,
        title: payload.title || item?.title,
        decision: payload.decision,
        feedback: payload.feedback || '',
        consent: payload.consent === true,
        reviewUrl: payload.reviewUrl || null,
      },
    }, request);
    return {
      proofType: 'origin_session_notice',
      externalId: targetSessionKeyForRequest(item, payload),
      proof: {
        targetSessionKey: targetSessionKeyForRequest(item, payload),
        decision: payload.decision,
        consent: payload.consent === true,
      },
    };
  }

  function parseInternalResultText(text) {
    const normalized = String(text || '').trim();
    if (!normalized) return null;

    const prefix = '[TURF_REVIEW_INTERNAL]';
    let payload = normalized;
    if (normalized.startsWith(prefix)) {
      payload = normalized.slice(prefix.length).trim();
      if (!payload.startsWith('{')) {
        const jsonStart = payload.indexOf('{');
        const newlineIndex = payload.indexOf('\n');
        payload = jsonStart >= 0 ? payload.slice(jsonStart).trim() : (newlineIndex >= 0 ? payload.slice(newlineIndex + 1).trim() : '');
      }
    }

    let parsed = safeJsonParse(payload, null);
    if (parsed) return parsed;

    const jsonStart = payload.indexOf('{');
    const jsonEnd = payload.lastIndexOf('}');
    if (jsonStart >= 0 && jsonEnd > jsonStart) {
      parsed = safeJsonParse(payload.slice(jsonStart, jsonEnd + 1), null);
    }
    return parsed;
  }

  function insertChildRequests(parentRequest, childRequests) {
    const created = [];
    for (const child of childRequests || []) {
      const request = normalizeDecisionRequest({
        ...child,
        summary: child.summary || 'Agent-created follow-up request',
        payload: child.payload || {},
      });
      const result = stmts.insertDecisionRequest.run({
        decision_id: parentRequest.decision_id || null,
        slug: parentRequest.slug,
        parent_request_id: parentRequest.id,
        kind: request.kind,
        summary: request.summary,
        sensitivity: request.sensitivity,
        status: request.status,
        payload: JSON.stringify(request.payload || {}),
        max_attempts: request.maxAttempts || maxAttempts,
      });
      const createdRequest = { ...request, id: result.lastInsertRowid };
      if (request.status === 'blocked_decision' || request.status === 'needs_confirmation') {
        const row = stmts.getDecisionRequestById.get(result.lastInsertRowid);
        createdRequest.followup = createFollowupReviewForRequest(row, request);
      }
      created.push(createdRequest);
    }
    return created;
  }

  function createReplacementReview(parentRequest, replacement) {
    if (!replacement?.title || !replacement?.markdown) return null;
    const item = stmts.getBySlug.get(parentRequest.slug);
    const rendered = renderSourceDocument({ markdown: replacement.markdown, html: null });
    const slug = `rework-${safeSlugPart(replacement.title)}-${Date.now().toString(36)}`;
    const category = replacement.category && getCanonicalActions(replacement.category) ? replacement.category : item.category;
    stmts.insert.run({
      slug,
      title: replacement.title,
      markdown: rendered.markdown,
      rendered_html: rendered.rendered_html,
      category,
      actions: JSON.stringify(getCanonicalActions(category)),
      content_hash: createContentHash(`${replacement.title}:${slug}`, replacement.markdown),
      mindwtr_task_id: item.mindwtr_task_id || null,
      mindwtr_project_id: item.mindwtr_project_id || null,
      on_approve: item.on_approve || null,
      session_key: getSessionKey(slug),
      workspace_dir: item.workspace_dir || null,
      source_path: item.source_path || null,
      decision_schema_version: DECISION_SCHEMA_VERSION,
      parent_slug: item.slug,
      supersedes_slug: item.slug,
      created_by_request_id: parentRequest.id,
    });
    if (item.origin_session_key) {
      stmts.setItemOriginSession.run({
        slug,
        origin_session_key: item.origin_session_key,
      });
    }
    const replacementItem = stmts.getBySlug.get(slug);
    recordIntentForItem(replacementItem, replacementItem.on_approve);
    return replacementItem;
  }

  async function runOneRequest(row) {
    const normalized = normalizeDecisionRequest({ ...row, payload: parseJson(row.payload, {}) });
    const payload = normalized.payload || {};
    row = { ...row, kind: normalized.kind, summary: normalized.summary, sensitivity: normalized.sensitivity };
    let result = null;

    if (normalized.status === 'blocked_decision' || row.status === 'blocked_decision' || row.status === 'needs_confirmation') {
      markRequestStatus(row.id, 'blocked_decision', {
        error: payload.missing?.length ? `Missing: ${payload.missing.join(', ')}` : 'Decision input required.',
        completed: true,
      });
      const followup = createFollowupReviewForRequest(stmts.getDecisionRequestById.get(row.id), normalized);
      announceInternalReview(followup, 'follow-up');
      return;
    }

    switch (row.kind) {
      case 'create_omnifocus_task':
        result = await createOmniFocusTask(row, payload);
        break;
      case 'create_calendar_event':
        result = await createCalendarEvent(row, payload);
        break;
      case 'outreach_approval':
        result = await approveOutreach(row, payload);
        break;
      case 'origin_decision_notice':
        result = await sendOriginDecisionNotice(row, payload);
        break;
      case 'agent_rework': {
        const agentResult = await runAgentRequest(row, payload, 'rework');
        if (agentResult.replacementReview) {
          const replacement = createReplacementReview(row, agentResult.replacementReview);
          if (!replacement) throw new Error('Rework did not produce a replacement review item.');
          result = {
            proofType: 'replacement_review',
            externalId: replacement.slug,
            proof: { slug: replacement.slug, title: replacement.title },
          };
          broadcastSSE('new-item', { slug: replacement.slug, title: replacement.title, category: replacement.category });
          setImmediate(async () => {
            try {
              await seedSessionForItem(replacement, buildReviewUrl(replacement.slug), 'bootstrap');
            } catch (error) {
              console.error(`[orchestrator] Failed to seed replacement review ${replacement.slug}: ${error.message}`);
            }
          });
        } else if (agentResult.childRequests?.length) {
          const createdChildren = insertChildRequests(row, agentResult.childRequests);
          for (const child of createdChildren) {
            if (child.followup) announceInternalReview(child.followup, 'follow-up');
          }
          result = {
            proofType: 'agent_report',
            externalId: null,
            proof: {
              summary: agentResult.summary || null,
              childRequests: createdChildren.map(({ followup, ...child }) => child),
            },
          };
        } else {
          throw new Error(agentResult.blocker || agentResult.summary || 'Rework did not produce a replacement review.');
        }
        break;
      }
      default: {
        const agentResult = await runAgentRequest(row, payload, isBuildRequest(row) ? 'build' : 'execute');
        let createdChildren = [];
        if (agentResult.childRequests?.length) {
          createdChildren = insertChildRequests(row, agentResult.childRequests);
          for (const child of createdChildren) {
            if (child.followup) announceInternalReview(child.followup, 'follow-up');
          }
        }
        if (agentResult.proof || agentResult.producedArtifact || agentResult.status === 'answered' || agentResult.status === 'succeeded') {
          result = {
            proofType: agentResult.producedArtifact ? 'reported_artifact' : 'agent_report',
            externalId: null,
            proof: {
              summary: agentResult.summary || null,
              proof: agentResult.proof || null,
              producedArtifact: agentResult.producedArtifact || null,
              childRequests: createdChildren.length ? createdChildren.map(({ followup, ...child }) => child) : (agentResult.childRequests || []),
            },
          };
        } else if (agentResult.status === 'blocked_decision') {
          markRequestStatus(row.id, 'blocked_decision', {
            error: agentResult.blocker || agentResult.summary || 'Decision input required.',
            completed: true,
          });
          createFollowupReviewForRequest(stmts.getDecisionRequestById.get(row.id), {
            ...row,
            kind: 'decision_clarification',
            summary: agentResult.blocker || row.summary,
            payload: {
              ...payload,
              missing: [agentResult.blocker || 'clarification'],
              requestedKind: row.kind,
            },
          });
          return;
        } else {
          throw new Error(agentResult.blocker || agentResult.summary || 'Agent action did not reach a durable outcome.');
        }
      }
    }

    if (!result) return;
    recordProof(row.id, result.proofType, result.externalId, result.proof);
    markRequestStatus(row.id, 'succeeded', {
      proof: result.proof,
      completed: true,
    });
  }

  async function reconcileWaitingExternal(row) {
    const payload = parseJson(row.payload, {});
    if (row.kind !== 'outreach_approval') return;

    const state = inspectOutreachState(payload.slug);
    const allSent = state.queueItems.length > 0 && state.queueItems.every((item) => item.sent_at || item.provider_message_id);
    if (allSent) {
      const proof = {
        queueItemIds: state.queueItems.map((item) => item.id),
        sendAttemptIds: state.attempts.map((attempt) => attempt.id),
        sentAt: state.queueItems.map((item) => item.sent_at).filter(Boolean),
      };
      recordProof(row.id, 'sent_email_log', proof.sendAttemptIds.join(','), proof);
      markRequestStatus(row.id, 'succeeded', { proof, completed: true });
      return;
    }

    const failed = state.queueItems.find((item) => {
      const status = `${item.status || ''} ${item.state || ''} ${item.terminal_reason || ''}`.toLowerCase();
      return status.includes('fail') || status.includes('blocked') || item.error || item.blocked_reason;
    });
    if (failed) {
      throw new Error(`Outreach send blocked: ${failed.id} ${failed.blocked_reason || failed.error || failed.terminal_reason || failed.status}`);
    }

    markRequestStatus(row.id, 'waiting_external', {
      proof: row.proof_json ? safeJsonParse(row.proof_json, null) : null,
      nextAttemptAt: sqlDateAfter(externalRecheckSeconds),
    });
  }

  function claimExternalRequest({ includeWaitingExternal = true } = {}) {
    stmts.recoverStaleDecisionRequests.run({ minutes: 15 });

    const runnable = stmts.listRunnableDecisionRequests.all({ limit: 1 });
    for (const row of runnable) {
      const claim = stmts.markDecisionRequestRunning.run({ id: row.id });
      if (claim.changes === 0) continue;
      return {
        mode: 'request',
        request: stmts.getDecisionRequestById.get(row.id) || { ...row, attempts: row.attempts + 1, status: 'running' },
      };
    }

    if (!includeWaitingExternal) return null;

    const waiting = stmts.listWaitingExternalDecisionRequests.all({ limit: 1 });
    for (const row of waiting) {
      const claim = stmts.markWaitingDecisionRequestRunning.run({ id: row.id });
      if (claim.changes === 0) continue;
      return {
        mode: 'waiting_external',
        request: stmts.getDecisionRequestById.get(row.id) || { ...row, status: 'running' },
      };
    }

    return null;
  }

  async function completeExternalRequest(id, outcome = {}) {
    const requestId = Number(id);
    if (!Number.isInteger(requestId) || requestId <= 0) {
      throw httpError(400, 'Invalid decision request id.');
    }

    const row = stmts.getDecisionRequestById.get(requestId);
    if (!row) throw httpError(404, 'Decision request not found.');
    if (row.status !== 'running') {
      throw httpError(409, `Decision request is ${row.status}, not running.`);
    }

    const status = String(outcome.status || '').trim();
    const allowed = new Set(['succeeded', 'waiting_external', 'blocked_decision', 'blocked_system', 'failed']);
    if (!allowed.has(status)) {
      throw httpError(400, `Invalid worker completion status: ${status || '(empty)'}`);
    }

    const proof = outcome.proof && typeof outcome.proof === 'object' ? outcome.proof : null;
    const error = normalizeText(outcome.error || outcome.blocker || outcome.summary || '');
    const nextAttemptSeconds = Math.max(1, Number(outcome.nextAttemptSeconds || externalRecheckSeconds));
    let replacement = null;
    let followup = null;
    const childFollowups = [];

    const tx = db.transaction(() => {
      let proofType = normalizeText(outcome.proofType || '');
      let externalId = outcome.externalId || null;
      let effectiveProof = proof;

      if (status === 'succeeded' && outcome.replacementReview) {
        replacement = createReplacementReview(row, outcome.replacementReview);
        if (!replacement) throw new Error('Worker reported replacement review without enough replacement content.');
        proofType = proofType || 'replacement_review';
        externalId = externalId || replacement.slug;
        effectiveProof = effectiveProof || { slug: replacement.slug, title: replacement.title };
      }

      if (Array.isArray(outcome.childRequests) && outcome.childRequests.length) {
        const createdChildren = insertChildRequests(row, outcome.childRequests);
        childFollowups.push(...createdChildren.map((child) => child.followup).filter(Boolean));
      }

      if (proofType && effectiveProof) {
        recordProof(row.id, proofType, externalId, effectiveProof);
      }

      if (status === 'succeeded') {
        insertActionRunForRequest(row, 'succeeded', { proof: effectiveProof });
        markRequestStatus(row.id, 'succeeded', {
          proof: effectiveProof,
          completed: true,
        });
        return;
      }

      if (status === 'waiting_external') {
        insertActionRunForRequest(row, 'waiting_external', { proof: effectiveProof });
        markRequestStatus(row.id, 'waiting_external', {
          proof: effectiveProof,
          nextAttemptAt: sqlDateAfter(nextAttemptSeconds),
        });
        return;
      }

      if (status === 'blocked_decision') {
        const message = error || 'Decision input required.';
        insertActionRunForRequest(row, 'blocked_decision', { error: message, proof: effectiveProof });
        markRequestStatus(row.id, 'blocked_decision', {
          proof: effectiveProof,
          error: message,
          completed: true,
        });
        const payload = parseJson(row.payload, {});
        const followupPayload = outcome.followup && typeof outcome.followup === 'object' ? outcome.followup : {};
        followup = createFollowupReviewForRequest(row, {
          ...row,
          kind: 'decision_clarification',
          summary: normalizeText(followupPayload.summary || message || row.summary),
          payload: {
            ...payload,
            ...(followupPayload.payload || {}),
            missing: followupPayload.missing || payload.missing || [message],
            requestedKind: followupPayload.requestedKind || payload.requestedKind || row.kind,
          },
        });
        return;
      }

      if (status === 'blocked_system') {
        const message = error || 'Worker reported a system blocker.';
        insertActionRunForRequest(row, 'blocked_system', { error: message, proof: effectiveProof });
        markRequestStatus(row.id, 'blocked_system', {
          proof: effectiveProof,
          error: message,
          completed: true,
        });
        enqueueNotification({
          requestId: row.id,
          kind: 'system_blocker',
          message: `Turf Review system action is blocked: ${row.summary}\nReview: ${buildReviewUrl(row.slug)}\nError: ${message}`,
        });
        return;
      }

      const message = error || 'Worker reported a failed request.';
      insertActionRunForRequest(row, 'failed', { error: message, proof: effectiveProof });
      stmts.markDecisionRequestFailed.run({
        id: row.id,
        last_error: message,
        retry_modifier: `+${retryDelaySeconds} seconds`,
      });
      if (Number(row.attempts || 0) >= Number(row.max_attempts || maxAttempts)) {
        markRequestStatus(row.id, 'blocked_system', {
          proof: effectiveProof,
          error: message,
          completed: true,
        });
        enqueueNotification({
          requestId: row.id,
          kind: 'system_blocker',
          message: `Turf Review system action is stuck after ${row.attempts} attempts: ${row.summary}\nReview: ${buildReviewUrl(row.slug)}\nError: ${message}`,
        });
      }
    });

    tx();
    updateItemActionSummary(row.slug);
    broadcastSSE('approval', { slug: row.slug, status });

    if (replacement) {
      broadcastSSE('new-item', { slug: replacement.slug, title: replacement.title, category: replacement.category });
      setImmediate(async () => {
        try {
          await seedSessionForItem(replacement, buildReviewUrl(replacement.slug), 'bootstrap');
        } catch (error) {
          console.error(`[orchestrator] Failed to seed replacement review ${replacement.slug}: ${error.message}`);
        }
      });
    }

    if (followup) {
      announceInternalReview(followup, 'follow-up');
    }

    for (const childFollowup of childFollowups) {
      announceInternalReview(childFollowup, 'follow-up');
    }

    return {
      id: row.id,
      slug: row.slug,
      status,
      replacement,
      followup,
      followups: [...(followup ? [followup] : []), ...childFollowups],
    };
  }

  function claimNotification() {
    stmts.recoverStaleNotifications.run({ minutes: 15 });
    const rows = stmts.listQueuedNotifications.all({ limit: 1 });
    for (const row of rows) {
      const claim = stmts.markNotificationSending.run({ id: row.id });
      if (claim.changes === 0) continue;
      return stmts.getNotificationById.get(row.id) || { ...row, status: 'sending' };
    }
    return null;
  }

  function completeNotification(id, outcome = {}) {
    const notificationId = Number(id);
    if (!Number.isInteger(notificationId) || notificationId <= 0) {
      throw httpError(400, 'Invalid notification id.');
    }
    const row = stmts.getNotificationById.get(notificationId);
    if (!row) throw httpError(404, 'Notification not found.');
    if (row.status !== 'sending') {
      throw httpError(409, `Notification is ${row.status}, not sending.`);
    }

    const status = String(outcome.status || 'sent').trim();
    if (status === 'sent' || status === 'succeeded') {
      stmts.markNotificationSent.run({ id: notificationId });
      return { id: notificationId, status: 'sent' };
    }

    if (status === 'failed') {
      stmts.markNotificationFailed.run({
        id: notificationId,
        last_error: outcome.error || 'Mac worker reported notification failure.',
      });
      return { id: notificationId, status: 'failed' };
    }

    throw httpError(400, `Invalid notification completion status: ${status}`);
  }

  async function drainDecisionRequests(limit = 5) {
    stmts.recoverStaleDecisionRequests.run({ minutes: 15 });
    const runnable = stmts.listRunnableDecisionRequests.all({ limit });
    for (const row of runnable) {
      const claim = stmts.markDecisionRequestRunning.run({ id: row.id });
      if (claim.changes === 0) continue;
      const attempt = row.attempts + 1;
      try {
        await runOneRequest({ ...row, attempts: attempt });
        stmts.insertActionRun.run({
          request_id: row.id,
          attempt,
          status: 'succeeded',
          error: null,
          proof_json: null,
          completed_at: nowSql(),
        });
      } catch (error) {
        const message = error.message || 'Decision request failed.';
        stmts.insertActionRun.run({
          request_id: row.id,
          attempt,
          status: 'failed',
          error: message,
          proof_json: null,
          completed_at: nowSql(),
        });
        stmts.markDecisionRequestFailed.run({
          id: row.id,
          last_error: message,
          retry_modifier: `+${retryDelaySeconds} seconds`,
        });
        if (attempt >= row.max_attempts) {
          markRequestStatus(row.id, 'blocked_system', {
            error: message,
            completed: true,
          });
          enqueueNotification({
            requestId: row.id,
            kind: 'system_blocker',
            message: `Turf Review system action is stuck after ${attempt} attempts: ${row.summary}\nReview: ${buildReviewUrl(row.slug)}\nError: ${message}`,
          });
        }
      } finally {
        updateItemActionSummary(row.slug);
      }
    }

    const waiting = stmts.listWaitingExternalDecisionRequests.all({ limit });
    for (const row of waiting) {
      try {
        await reconcileWaitingExternal(row);
      } catch (error) {
        markRequestStatus(row.id, 'blocked_system', {
          error: error.message || 'External reconciliation failed.',
          completed: true,
        });
        enqueueNotification({
          requestId: row.id,
          kind: 'system_blocker',
          message: `Turf Review external action is blocked: ${row.summary}\nReview: ${buildReviewUrl(row.slug)}\nError: ${error.message}`,
        });
      } finally {
        updateItemActionSummary(row.slug);
      }
    }

    await drainNotifications();
  }

  let drainScheduled = false;
  function scheduleDrain() {
    if (drainScheduled) return;
    drainScheduled = true;
    setImmediate(async () => {
      drainScheduled = false;
      try {
        await drainDecisionRequests();
      } catch (error) {
        console.error(`[orchestrator] drain failed: ${error.message}`);
      }
    });
  }

  async function drainNotifications(limit = 10) {
    if (webOnlyMode) return;
    const rows = stmts.listQueuedNotifications.all({ limit });
    for (const row of rows) {
      const payload = parseJson(row.payload_json, {});
      try {
        await sendNotification(row, payload);
        stmts.markNotificationSent.run({ id: row.id });
      } catch (error) {
        stmts.markNotificationFailed.run({
          id: row.id,
          last_error: error.message || String(error),
        });
      }
    }
  }

  function buildNotificationTarget(row, payload = {}) {
    const notification = getNotificationConfig();
    return {
      channel: payload.channel || row.channel || notification.channel,
      account: payload.account || notification.account,
      target: payload.target || notification.target,
      threadId: payload.threadId || notification.threadId,
      replyTo: payload.replyTo || notification.replyTo,
      message: payload.message || row.kind,
    };
  }

  async function sendNotification(row, payload = {}) {
    if (!fs.existsSync(config.openclaw.bin)) {
      throw new Error(`OpenClaw CLI not found at ${config.openclaw.bin}`);
    }
    const target = buildNotificationTarget(row, payload);
    if (!target.channel) throw new Error('Notification channel is not configured.');
    if (!target.target) throw new Error(`Notification target is not configured for ${target.channel}.`);
    const args = [
      'message',
      'send',
      '--channel',
      target.channel,
      '--account',
      target.account,
      '--target',
      target.target,
      '--message',
      target.message,
    ];
    if (target.threadId) {
      args.splice(args.length - 2, 0, '--thread-id', target.threadId);
    }
    if (target.replyTo) {
      args.splice(args.length - 2, 0, '--reply-to', target.replyTo);
    }
    await execFileAsync(config.openclaw.bin, args, {
      timeout: 30000,
      env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' },
    });
  }

  function requeueRequest(id) {
    stmts.requeueDecisionRequest.run({ id });
    if (!webOnlyMode) scheduleDrain();
  }

  return {
    claimExternalRequest,
    claimNotification,
    completeExternalRequest,
    completeNotification,
    drainDecisionRequests,
    drainNotifications,
    getIntent,
    handleDecision,
    recordIntentForItem,
    requeueRequest,
    scheduleDrain,
    updateItemActionSummary,
  };
}

module.exports = {
  createDecisionOrchestrator,
};

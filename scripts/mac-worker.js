#!/usr/bin/env node

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile, execFileSync } = require('child_process');
const { promisify } = require('util');

const Database = require('better-sqlite3');
const dotenv = require('dotenv');

const { createContentHash, createReviewDatabase, ensureDir } = require('../lib/db');
const { createOpenClawClient } = require('../lib/openclaw');
const { buildInternalMessage, getCanonicalActions, getSessionKey } = require('../lib/review-routing');
const {
  normalizeDecisionRequest,
  normalizeSessionKey,
  normalizeText,
  safeJsonParse,
} = require('../lib/reviews/decision-contract');

const execFileAsync = promisify(execFile);

const ROOT_DIR = path.resolve(__dirname, '..');
const HOME_DIR = os.homedir();

loadEnvFile(path.join(ROOT_DIR, '.env'));
loadEnvFile(path.join(HOME_DIR, 'clawd/.env.local'));
loadEnvFile(path.join(HOME_DIR, 'clawd/.env'));
loadOpenClawTokenFromRetiredLaunchAgent();

const LOCAL_REVIEW_DATA_DIR = process.env.TURF_REVIEW_LOCAL_DATA_DIR || path.join(ROOT_DIR, 'data');
const DEFAULT_REVIEW_BASE_URL = 'https://review.turfterrace.com';
const DEFAULT_PATH = `${HOME_DIR}/.volta/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`;

const config = {
  baseUrl: normalizeBaseUrl(process.env.TURF_REVIEW_WORKER_BASE_URL || process.env.TURF_REVIEW_BASE_URL || DEFAULT_REVIEW_BASE_URL),
  intervalMs: Math.max(1000, Number(process.env.TURF_REVIEW_WORKER_INTERVAL_MS || 15000)),
  requestTimeoutMs: Math.max(5000, Number(process.env.TURF_REVIEW_WORKER_TIMEOUT_MS || 120000)),
  externalRecheckSeconds: Math.max(60, Number(process.env.TURF_REVIEW_EXTERNAL_RECHECK_SECONDS || 600)),
  omnifocusBin: process.env.TURF_REVIEW_OMNIFOCUS_BIN || path.join(HOME_DIR, '.bun/bin/of'),
  openclawBin: process.env.OPENCLAW_BIN || '/opt/homebrew/bin/openclaw',
  notificationChannel: process.env.TURF_REVIEW_NOTIFY_CHANNEL || process.env.TURF_REVIEW_NOTIFICATION_CHANNEL || 'discord',
  notificationAccount: process.env.TURF_REVIEW_NOTIFY_ACCOUNT || process.env.TURF_REVIEW_NOTIFICATION_ACCOUNT || 'default',
  notificationTarget: process.env.TURF_REVIEW_NOTIFY_TARGET || process.env.TURF_REVIEW_NOTIFICATION_TARGET || process.env.TURF_REVIEW_DISCORD_TARGET || 'channel:1509121052834529330',
  notificationThreadId: process.env.TURF_REVIEW_NOTIFY_THREAD_ID || process.env.TURF_REVIEW_NOTIFICATION_THREAD_ID || '',
  telegramTarget: process.env.TURF_REVIEW_TELEGRAM_TARGET || '8339963854',
  telegramReplyTo: process.env.TURF_REVIEW_TELEGRAM_REPLY_TO || '',
  calendarName: process.env.TURF_REVIEW_CALENDAR_NAME || 'Calendar',
  bunBin: process.env.TURF_REVIEW_BUN_BIN || '/opt/homebrew/bin/bun',
  clawdRoot: process.env.TURF_REVIEW_CLAWD_ROOT || path.join(HOME_DIR, 'clawd'),
  reviewDecisionIngestScript: process.env.TURF_REVIEW_DECISION_INGEST_SCRIPT || path.join(HOME_DIR, 'clawd/scripts/review-decision-ingest.ts'),
  kitchenLuxCrmDb: process.env.TURF_REVIEW_KITCHENLUX_CRM_DB || path.join(HOME_DIR, 'clawd/data/kitchenlux-crm.db'),
};

function loadEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return;
  dotenv.config({ path: filePath, override: false });
}

function loadOpenClawTokenFromRetiredLaunchAgent() {
  if (process.env.OPENCLAW_TOKEN) return;
  const plistPath = path.join(HOME_DIR, 'Library/LaunchAgents/com.turf-review.plist');
  if (!fs.existsSync(plistPath)) return;
  try {
    const token = execFileSync('/usr/bin/plutil', [
      '-extract',
      'EnvironmentVariables.OPENCLAW_TOKEN',
      'raw',
      '-o',
      '-',
      plistPath,
    ], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (token) process.env.OPENCLAW_TOKEN = token;
  } catch (_error) {
    // The worker can still handle non-agent jobs without OpenClaw.
  }
}

function normalizeBaseUrl(value) {
  return String(value || DEFAULT_REVIEW_BASE_URL).replace(/\/+$/, '');
}

function parseJson(value, fallback = {}) {
  if (!value) return fallback;
  if (typeof value === 'object') return value;
  return safeJsonParse(value, fallback);
}

function authHeader() {
  const direct = String(process.env.TURF_REVIEW_AUTH || '').trim();
  if (direct.startsWith('Basic ')) return direct;
  if (direct) return `Basic ${Buffer.from(direct).toString('base64')}`;

  const user = process.env.REVIEW_USER;
  const password = process.env.REVIEW_PASSWORD;
  if (!user || !password) {
    throw new Error('TURF_REVIEW_AUTH or REVIEW_USER/REVIEW_PASSWORD is required for the Mac worker.');
  }
  return `Basic ${Buffer.from(`${user}:${password}`).toString('base64')}`;
}

async function requestJson(pathname, { method = 'GET', body = null } = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.requestTimeoutMs);
  try {
    const response = await fetch(`${config.baseUrl}${pathname}`, {
      method,
      headers: {
        Authorization: authHeader(),
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    const text = await response.text();
    const payload = text ? JSON.parse(text) : {};
    if (!response.ok) {
      throw new Error(`${method} ${pathname} failed (${response.status}): ${payload.error || text}`);
    }
    return payload;
  } finally {
    clearTimeout(timeout);
  }
}

function buildEnv(extra = {}) {
  return {
    ...process.env,
    PATH: process.env.PATH ? `${DEFAULT_PATH}:${process.env.PATH}` : DEFAULT_PATH,
    ...extra,
  };
}

function snapshotItemForLocalTools(item) {
  ensureDir(LOCAL_REVIEW_DATA_DIR);
  const db = createReviewDatabase({ dataDir: LOCAL_REVIEW_DATA_DIR });
  try {
    const category = item.category || 'general';
    const markdown = item.markdown || item.rendered_html || '';
    const renderedHtml = item.rendered_html || markdown;
    const canonicalActions = getCanonicalActions(category);
    const params = {
      slug: item.slug,
      title: item.title || item.slug,
      markdown,
      rendered_html: renderedHtml,
      category,
      status: item.status || 'processed',
      decision: item.decision || null,
      actions: item.actions || (canonicalActions ? JSON.stringify(canonicalActions) : '[]'),
      feedback: item.feedback || null,
      content_hash: item.content_hash || createContentHash(item.title || item.slug, markdown),
      mindwtr_task_id: item.mindwtr_task_id || null,
      mindwtr_project_id: item.mindwtr_project_id || null,
      on_approve: item.on_approve || null,
      session_key: item.session_key || getSessionKey(item.slug),
      origin_session_key: item.origin_session_key || null,
      workspace_dir: item.workspace_dir || null,
      source_path: item.source_path || null,
      decision_schema_version: item.decision_schema_version || 3,
      action_status: item.action_status || null,
      action_message: item.action_message || null,
      action_updated_at: item.action_updated_at || null,
      tts_status: item.tts_status || null,
      context_status: item.context_status || null,
      context_summary: item.context_summary || null,
      approval_status: item.approval_status || null,
      approval_message: item.approval_message || null,
      approval_exit_code: item.approval_exit_code || null,
      approval_updated_at: item.approval_updated_at || null,
      parent_slug: item.parent_slug || null,
      supersedes_slug: item.supersedes_slug || null,
      created_by_request_id: item.created_by_request_id || null,
      created_at: item.created_at || null,
      updated_at: item.updated_at || null,
    };

    db.prepare(`
      INSERT INTO items (
        slug, title, markdown, rendered_html, category, status, decision, actions, feedback,
        content_hash, mindwtr_task_id, mindwtr_project_id, on_approve, session_key,
        origin_session_key, workspace_dir, source_path, decision_schema_version, action_status, action_message,
        action_updated_at, tts_status, context_status, context_summary, approval_status,
        approval_message, approval_exit_code, approval_updated_at, parent_slug, supersedes_slug,
        created_by_request_id, created_at, updated_at
      )
      VALUES (
        @slug, @title, @markdown, @rendered_html, @category, @status, @decision, @actions, @feedback,
        @content_hash, @mindwtr_task_id, @mindwtr_project_id, @on_approve, @session_key,
        @origin_session_key, @workspace_dir, @source_path, @decision_schema_version, @action_status, @action_message,
        @action_updated_at, @tts_status, @context_status, @context_summary, @approval_status,
        @approval_message, @approval_exit_code, @approval_updated_at, @parent_slug, @supersedes_slug,
        @created_by_request_id, COALESCE(@created_at, datetime('now')), COALESCE(@updated_at, datetime('now'))
      )
      ON CONFLICT(slug) DO UPDATE SET
        title = excluded.title,
        markdown = excluded.markdown,
        rendered_html = excluded.rendered_html,
        category = excluded.category,
        status = excluded.status,
        decision = excluded.decision,
        actions = excluded.actions,
        feedback = excluded.feedback,
        content_hash = excluded.content_hash,
        mindwtr_task_id = excluded.mindwtr_task_id,
        mindwtr_project_id = excluded.mindwtr_project_id,
        on_approve = excluded.on_approve,
        session_key = excluded.session_key,
        origin_session_key = excluded.origin_session_key,
        workspace_dir = excluded.workspace_dir,
        source_path = excluded.source_path,
        decision_schema_version = excluded.decision_schema_version,
        action_status = excluded.action_status,
        action_message = excluded.action_message,
        action_updated_at = excluded.action_updated_at,
        approval_status = excluded.approval_status,
        approval_message = excluded.approval_message,
        approval_exit_code = excluded.approval_exit_code,
        approval_updated_at = excluded.approval_updated_at,
        parent_slug = excluded.parent_slug,
        supersedes_slug = excluded.supersedes_slug,
        created_by_request_id = excluded.created_by_request_id,
        updated_at = excluded.updated_at
    `).run(params);
  } finally {
    db.close();
  }
}

async function createOmniFocusTask(request, payload) {
  if (!fs.existsSync(config.omnifocusBin)) {
    throw new Error(`OmniFocus CLI not found at ${config.omnifocusBin}`);
  }
  const title = normalizeText(payload.title || request.summary);
  const noteParts = [
    payload.note || '',
    payload.reviewUrl ? `Review: ${payload.reviewUrl}` : '',
    payload.feedback ? `Feedback:\n${payload.feedback}` : '',
  ].filter(Boolean);
  const args = ['task', 'create', title];
  if (noteParts.length) args.push('--note', noteParts.join('\n\n'));
  const result = await execFileAsync(config.omnifocusBin, args, {
    timeout: 45000,
    env: buildEnv(),
  });
  const task = JSON.parse(result.stdout);
  if (!task?.id) throw new Error('OmniFocus task create returned no task id');
  return { status: 'succeeded', proofType: 'omnifocus_task', externalId: task.id, proof: { task } };
}

async function createCalendarEvent(request, payload) {
  if (!payload.start || !payload.end) {
    return {
      status: 'blocked_decision',
      error: 'Calendar request needs exact start and end time.',
      followup: {
        summary: request.summary,
        missing: ['start', 'end'],
        requestedKind: 'create_calendar_event',
        payload: { ...payload },
      },
    };
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
    config.calendarName,
    normalizeText(payload.title || request.summary),
    payload.start,
    payload.end,
  ], { timeout: 30000, env: buildEnv() });
  const eventId = normalizeText(result.stdout);
  if (!eventId) throw new Error('Calendar returned no event id');
  return { status: 'succeeded', proofType: 'calendar_event', externalId: eventId, proof: { eventId, calendar: config.calendarName } };
}

function inspectOutreachState(slug) {
  if (!fs.existsSync(config.kitchenLuxCrmDb)) {
    throw new Error(`KitchenLux CRM DB not found at ${config.kitchenLuxCrmDb}`);
  }
  const crm = new Database(config.kitchenLuxCrmDb, { readonly: true });
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

function failedOutreachItem(state) {
  return state.queueItems.find((item) => {
    const status = `${item.status || ''} ${item.state || ''} ${item.terminal_reason || ''}`.toLowerCase();
    return status.includes('fail') || status.includes('blocked') || item.error || item.blocked_reason;
  });
}

async function approveOutreach(request, payload, item) {
  if (!fs.existsSync(config.reviewDecisionIngestScript)) {
    throw new Error(`review-decision-ingest.ts not found at ${config.reviewDecisionIngestScript}`);
  }
  snapshotItemForLocalTools(item);
  const slug = payload.slug || item.slug;
  const result = await execFileAsync(config.bunBin, [
    config.reviewDecisionIngestScript,
    slug,
    `decision-request:${request.id}`,
  ], {
    cwd: config.clawdRoot,
    timeout: 60000,
    env: buildEnv(),
  });

  const ingestPayload = safeJsonParse(result.stdout.trim(), { ok: true, raw: result.stdout.trim() });
  const state = inspectOutreachState(slug);
  if (!state.queueItems.length) {
    throw new Error(`Outreach ingest produced no queue items for ${slug}: ${JSON.stringify(ingestPayload)}`);
  }

  const failed = failedOutreachItem(state);
  if (failed) {
    throw new Error(`Outreach queue item blocked: ${failed.id} ${failed.blocked_reason || failed.error || failed.terminal_reason || failed.status}`);
  }

  const allSent = state.queueItems.every((queueItem) => queueItem.sent_at || queueItem.provider_message_id);
  const proof = {
    ingest: ingestPayload,
    queueItemIds: state.queueItems.map((queueItem) => queueItem.id),
    sendAttemptIds: state.attempts.map((attempt) => attempt.id),
    sent: allSent,
  };

  if (allSent) {
    return { status: 'succeeded', proofType: 'sent_email_log', externalId: proof.sendAttemptIds.join(','), proof };
  }

  return {
    status: 'waiting_external',
    proofType: 'outreach_send_queue',
    externalId: proof.queueItemIds.join(','),
    proof,
    nextAttemptSeconds: config.externalRecheckSeconds,
  };
}

async function reconcileWaitingExternal(request, payload, item) {
  if (request.kind !== 'outreach_approval') {
    throw new Error(`No external reconciliation handler for ${request.kind}`);
  }
  const slug = payload.slug || item.slug;
  const state = inspectOutreachState(slug);
  const failed = failedOutreachItem(state);
  if (failed) {
    throw new Error(`Outreach send blocked: ${failed.id} ${failed.blocked_reason || failed.error || failed.terminal_reason || failed.status}`);
  }

  const allSent = state.queueItems.length > 0 && state.queueItems.every((queueItem) => queueItem.sent_at || queueItem.provider_message_id);
  const proof = {
    queueItemIds: state.queueItems.map((queueItem) => queueItem.id),
    sendAttemptIds: state.attempts.map((attempt) => attempt.id),
    sentAt: state.queueItems.map((queueItem) => queueItem.sent_at).filter(Boolean),
  };
  if (allSent) {
    return { status: 'succeeded', proofType: 'sent_email_log', externalId: proof.sendAttemptIds.join(','), proof };
  }
  return {
    status: 'waiting_external',
    proofType: 'outreach_send_queue',
    externalId: proof.queueItemIds.join(','),
    proof,
    nextAttemptSeconds: config.externalRecheckSeconds,
  };
}

function openclawClient() {
  if (!process.env.OPENCLAW_TOKEN) {
    throw new Error('OPENCLAW_TOKEN is required for agent follow-up work.');
  }
  return createOpenClawClient({
    token: process.env.OPENCLAW_TOKEN,
    baseUrl: process.env.OPENCLAW_BASE_URL || 'http://127.0.0.1:18789/v1',
    agentId: process.env.OPENCLAW_AGENT_ID || 'main',
    model: process.env.CHAT_MODEL || `openclaw/${process.env.OPENCLAW_AGENT_ID || 'main'}`,
  });
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

async function appendWorkerSessionNote(item, kind, payload, options = {}) {
  const client = openclawClient();
  const sessionKey = normalizeSessionKey(options.sessionKey) || item.session_key || getSessionKey(item.slug);
  const content = buildInternalMessage(kind, {
    responseInstruction: 'Reply only with [TURF_REVIEW_INTERNAL] followed by one valid JSON object. No label, prose, markdown, or code fences.',
    ...payload,
  });
  return client.appendInternalMessage({ sessionKey, content });
}

function agentInstructionsForRequest(request) {
  if (isBuildRequest(request)) {
    return [
      request?.kind === 'codex_implementation'
        ? 'This is an approved Codex implementation request spawned from a Turf Review plan.'
        : 'This is an approved software build plan running from the Mac-side worker.',
      'Jimmy has consented to execute the plan.',
      'Implement the plan in the linked workspace and source context.',
      'Use the request payload as the execution contract, not as a memory search or planning prompt.',
      'Make concrete code changes when the workspace is available.',
      'Run focused verification and return durable proof, a produced artifact, child action requests, or a clear blocker.',
      'Do not treat an OpenClaw/session reply as completion by itself.',
    ].join(' ');
  }

  return [
    'This is a Turf Review downstream action request running from the Mac-side worker.',
    'Do not treat an OpenClaw/session reply as completion by itself.',
    'Return durable proof, a produced report/artifact, child action requests, a replacement review, or a clear blocker.',
  ].join(' ');
}

async function runAgentRequest(request, payload, item, mode = 'execute') {
  const targetSessionKey = isOriginSessionRequest(request)
    ? targetSessionKeyForRequest(item, payload)
    : item?.session_key || getSessionKey(item.slug);
  const reviewSessionKey = item?.session_key || getSessionKey(item.slug);
  const completion = await appendWorkerSessionNote(item, mode, {
    instructions: agentInstructionsForRequest(request),
    targetSessionKey,
    reviewSessionKey,
    request: {
      id: request.id,
      kind: request.kind,
      summary: request.summary,
      payload,
    },
    item: {
      slug: item.slug,
      title: item.title,
      category: item.category,
      status: item.status,
      decision: item.decision,
      feedback: item.feedback,
      workspaceDir: item.workspace_dir,
      sourcePath: item.source_path,
      document: item.markdown || item.rendered_html,
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
  }, targetSessionKey ? { sessionKey: targetSessionKey } : undefined);
  const parsed = parseInternalResultText(completion?.text || '');
  if (!parsed) throw new Error('OpenClaw did not return a structured internal result');
  return parsed;
}

async function sendOriginDecisionNotice(request, payload, item) {
  const targetSessionKey = targetSessionKeyForRequest(item, payload);
  await appendWorkerSessionNote(item, 'decision', {
    instructions: [
      'This is the Turf Review decision for the plan you drafted.',
      payload.consent ? 'Jimmy consented to execution.' : 'Jimmy did not consent to execution.',
      'Record this decision in session memory.',
      payload.consent ? 'Wait for the execution request before making changes.' : 'Do not execute the plan.',
    ].join(' '),
    targetSessionKey,
    reviewSessionKey: item?.session_key || getSessionKey(item.slug),
    decision: {
      reviewSlug: request.slug,
      title: payload.title || item?.title,
      decision: payload.decision,
      feedback: payload.feedback || '',
      consent: payload.consent === true,
      reviewUrl: payload.reviewUrl || null,
    },
  }, targetSessionKey ? { sessionKey: targetSessionKey } : undefined);

  return {
    status: 'succeeded',
    proofType: 'origin_session_notice',
    externalId: targetSessionKey,
    proof: {
      targetSessionKey,
      decision: payload.decision,
      consent: payload.consent === true,
    },
  };
}

function outcomeFromAgentResult(agentResult, request, payload) {
  const childRequests = (agentResult.childRequests || []).map((child) => normalizeDecisionRequest(child));
  const blockingScheduleRequest = childRequests.find((child) => child.status === 'blocked_decision' && child.payload?.requestedKind === 'create_calendar_event');

  if (blockingScheduleRequest) {
    return {
      status: 'blocked_decision',
      error: blockingScheduleRequest.payload?.missing?.length
        ? `Missing: ${blockingScheduleRequest.payload.missing.join(', ')}`
        : 'Calendar request needs exact start and end time.',
      followup: {
        summary: blockingScheduleRequest.summary || request.summary,
        missing: blockingScheduleRequest.payload?.missing || ['exact start time', 'exact end time or duration'],
        requestedKind: 'create_calendar_event',
        payload: {
          ...payload,
          ...(blockingScheduleRequest.payload || {}),
        },
      },
    };
  }

  if (childRequests.length || agentResult.proof || agentResult.producedArtifact || agentResult.status === 'answered' || agentResult.status === 'succeeded') {
    return {
      status: 'succeeded',
      proofType: agentResult.producedArtifact ? 'reported_artifact' : 'agent_report',
      proof: {
        summary: agentResult.summary || null,
        proof: agentResult.proof || null,
        producedArtifact: agentResult.producedArtifact || null,
        childRequests,
      },
      childRequests,
    };
  }

  if (agentResult.status === 'blocked_decision') {
    const blocker = agentResult.blocker || agentResult.summary || 'Decision input required.';
    return {
      status: 'blocked_decision',
      error: blocker,
      followup: {
        summary: blocker || request.summary,
        missing: [blocker || 'clarification'],
        requestedKind: request.kind,
        payload,
      },
    };
  }

  if (agentResult.status === 'blocked_system') {
    return { status: 'blocked_system', error: agentResult.blocker || agentResult.summary || 'Agent reported a system blocker.' };
  }

  return { status: 'failed', error: agentResult.blocker || agentResult.summary || 'Agent action did not reach a durable outcome.' };
}

async function executeDecisionJob(job) {
  const request = job.request;
  const item = job.item;
  const rawPayload = parseJson(request.payload, {});
  const normalized = normalizeDecisionRequest({
    ...request,
    payload: {
      ...rawPayload,
      slug: rawPayload.slug || item.slug,
      reviewUrl: rawPayload.reviewUrl || job.reviewUrl,
      annotations: rawPayload.annotations || job.annotations || [],
    },
  });
  const effectiveRequest = {
    ...request,
    kind: normalized.kind,
    summary: normalized.summary,
    sensitivity: normalized.sensitivity,
  };
  const payload = normalized.payload || {};

  if (job.mode === 'waiting_external' && effectiveRequest.kind === 'outreach_approval') {
    return reconcileWaitingExternal(effectiveRequest, payload, item);
  }

  if (normalized.status === 'blocked_decision') {
    return {
      status: 'blocked_decision',
      error: payload.missing?.length ? `Missing: ${payload.missing.join(', ')}` : 'Decision input required.',
      followup: {
        summary: normalized.summary,
        missing: payload.missing || ['exact start time', 'exact end time or duration'],
        requestedKind: payload.requestedKind || 'create_calendar_event',
        payload,
      },
    };
  }

  switch (effectiveRequest.kind) {
    case 'create_omnifocus_task':
      return createOmniFocusTask(effectiveRequest, payload);
    case 'create_calendar_event':
      return createCalendarEvent(effectiveRequest, payload);
    case 'outreach_approval':
      return approveOutreach(effectiveRequest, payload, item);
    case 'origin_decision_notice':
      return sendOriginDecisionNotice(effectiveRequest, payload, item);
    case 'agent_rework': {
      const agentResult = await runAgentRequest(effectiveRequest, payload, item, 'rework');
      if (agentResult.replacementReview) {
        return {
          status: 'succeeded',
          proofType: 'replacement_review',
          proof: { title: agentResult.replacementReview.title || null },
          replacementReview: agentResult.replacementReview,
        };
      }
      return outcomeFromAgentResult(agentResult, effectiveRequest, payload);
    }
    default: {
      const agentResult = await runAgentRequest(effectiveRequest, payload, item, isBuildRequest(effectiveRequest) ? 'build' : 'execute');
      return outcomeFromAgentResult(agentResult, effectiveRequest, payload);
    }
  }
}

function buildNotificationTarget(notification, payload = {}) {
  return {
    channel: payload.channel || notification.channel || config.notificationChannel,
    account: payload.account || config.notificationAccount,
    target: payload.target || config.notificationTarget,
    threadId: payload.threadId || config.notificationThreadId,
    replyTo: payload.replyTo || '',
    message: payload.message || notification.kind,
  };
}

async function sendNotification(notification, payload = {}) {
  if (!fs.existsSync(config.openclawBin)) {
    throw new Error(`OpenClaw CLI not found at ${config.openclawBin}`);
  }
  const target = buildNotificationTarget(notification, payload);
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
  await execFileAsync(config.openclawBin, args, {
    timeout: 30000,
    env: buildEnv(),
  });
}

async function handleDecisionJob(job) {
  const request = job.request;
  let outcome;
  try {
    outcome = await executeDecisionJob(job);
  } catch (error) {
    outcome = {
      status: 'failed',
      error: error.message || String(error),
    };
  }

  await requestJson(`/api/worker/decision-requests/${request.id}/complete`, {
    method: 'POST',
    body: outcome,
  });
  console.log(`[decision] ${request.id} ${request.kind} -> ${outcome.status}`);
}

async function handleNotification(notification) {
  const payload = parseJson(notification.payload_json, {});
  try {
    await sendNotification(notification, payload);
    await requestJson(`/api/worker/notifications/${notification.id}/complete`, {
      method: 'POST',
      body: { status: 'sent' },
    });
    console.log(`[notification] ${notification.id} -> sent`);
  } catch (error) {
    await requestJson(`/api/worker/notifications/${notification.id}/complete`, {
      method: 'POST',
      body: { status: 'failed', error: error.message || String(error) },
    });
    console.log(`[notification] ${notification.id} -> failed`);
  }
}

async function runCycle() {
  let handled = 0;

  const claim = await requestJson('/api/worker/decision-requests/claim', {
    method: 'POST',
    body: { worker: os.hostname(), includeWaitingExternal: true },
  });
  if (claim.job) {
    handled += 1;
    await handleDecisionJob(claim.job);
  }

  const notificationClaim = await requestJson('/api/worker/notifications/claim', { method: 'POST' });
  if (notificationClaim.notification) {
    handled += 1;
    await handleNotification(notificationClaim.notification);
  }

  return handled;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const once = process.argv.includes('--once');
  console.log(`[worker] starting base=${config.baseUrl} once=${once}`);

  if (once) {
    const handled = await runCycle();
    console.log(`[worker] once handled=${handled}`);
    return;
  }

  let stopping = false;
  process.on('SIGTERM', () => { stopping = true; });
  process.on('SIGINT', () => { stopping = true; });

  while (!stopping) {
    try {
      await runCycle();
    } catch (error) {
      console.error(`[worker] cycle failed: ${error.message || error}`);
    }
    await sleep(config.intervalMs);
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`[worker] fatal: ${error.stack || error.message || error}`);
    process.exit(1);
  });
}

module.exports = {
  executeDecisionJob,
  outcomeFromAgentResult,
};

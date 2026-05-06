const DECISION_SCHEMA_VERSION = 3;
const INTERNAL_MESSAGE_PREFIX = '[TURF_REVIEW_INTERNAL]';
const INTERNAL_MESSAGE_BARE_PREFIX = 'TURF REVIEW INTERNAL';

const CANONICAL_ACTIONS_BY_CATEGORY = Object.freeze({
  outreach: ['Send', 'Edit', 'Kill'],
  kitchenlux: ['Execute', 'Inbox', 'Rework', 'Park', 'Kill'],
  general: ['Noted', 'Execute', 'Inbox', 'Rework', 'Kill'],
  admin: ['Noted', 'Execute', 'Inbox', 'Rework', 'Kill'],
  confirmation: ['Approve', 'Rework', 'Kill', 'No further action'],
  clarification: ['Execute', 'Rework', 'Kill', 'No further action'],
});

const ALLOWED_CATEGORIES = new Set(Object.keys(CANONICAL_ACTIONS_BY_CATEGORY));
const ROUTED_ACTIONS = new Set(['Send', 'Edit', 'Rework', 'Execute', 'Inbox', 'Approve']);
const TERMINAL_STATUSES = new Set(['archived', 'processed', 'dismissed', 'killed', 'parked']);

function normalizeCategory(value) {
  return String(value || 'general').trim().toLowerCase();
}

function isCanonicalCategory(value) {
  return ALLOWED_CATEGORIES.has(normalizeCategory(value));
}

function getCanonicalActions(category) {
  return CANONICAL_ACTIONS_BY_CATEGORY[normalizeCategory(category)] || null;
}

function cloneActions(actions) {
  return Array.isArray(actions) ? actions.map((action) => String(action)) : [];
}

function arraysMatchExactly(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right)) return false;
  if (left.length !== right.length) return false;
  return left.every((value, index) => String(value) === String(right[index]));
}

function parseActions(rawActions) {
  if (Array.isArray(rawActions)) return cloneActions(rawActions);
  if (typeof rawActions !== 'string' || !rawActions.trim()) return [];

  try {
    const parsed = JSON.parse(rawActions);
    return Array.isArray(parsed) ? cloneActions(parsed) : [];
  } catch (_error) {
    return [];
  }
}

function getDecisionSchemaVersion(item) {
  const parsed = Number(item?.decision_schema_version);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 1;
}

function usesCanonicalRouting(item) {
  if (!item) return false;
  if (getDecisionSchemaVersion(item) >= DECISION_SCHEMA_VERSION) return true;
  return Boolean(item.session_key || item.workspace_dir || item.source_path);
}

function getAllowedActionsForItem(item) {
  if (!item) return [];

  if (usesCanonicalRouting(item)) {
    return cloneActions(getCanonicalActions(item.category) || []);
  }

  return parseActions(item.actions);
}

function isAllowedDecision(item, decision) {
  return getAllowedActionsForItem(item).includes(String(decision || ''));
}

function getSessionKey(slug) {
  return `review:${slug}`;
}

function isInternalMessageText(text) {
  const normalized = String(text || '').trim();
  if (!normalized) return false;
  return normalized.startsWith(INTERNAL_MESSAGE_PREFIX) || normalized.toUpperCase().startsWith(INTERNAL_MESSAGE_BARE_PREFIX);
}

function buildInternalMessage(kind, payload) {
  const serializedPayload = typeof payload === 'string' ? payload : JSON.stringify(payload, null, 2);
  return `${INTERNAL_MESSAGE_PREFIX} ${String(kind || 'note').trim()}\n${serializedPayload}`;
}

function getStoredStatusForDecision(decision) {
  switch (decision) {
    case 'Park':
    case 'Noted':
    case 'No further action':
      return 'archived';
    case 'Kill':
      return 'killed';
    default:
      return 'processed';
  }
}

function getInitialActionStatus(decision) {
  return ROUTED_ACTIONS.has(String(decision || '')) ? 'queued' : 'succeeded';
}

function isTerminalStatus(status) {
  return TERMINAL_STATUSES.has(String(status || ''));
}

module.exports = {
  ALLOWED_CATEGORIES,
  CANONICAL_ACTIONS_BY_CATEGORY,
  DECISION_SCHEMA_VERSION,
  INTERNAL_MESSAGE_PREFIX,
  ROUTED_ACTIONS,
  arraysMatchExactly,
  buildInternalMessage,
  getAllowedActionsForItem,
  getCanonicalActions,
  getDecisionSchemaVersion,
  getInitialActionStatus,
  getSessionKey,
  getStoredStatusForDecision,
  isAllowedDecision,
  isCanonicalCategory,
  isInternalMessageText,
  isTerminalStatus,
  normalizeCategory,
  parseActions,
  usesCanonicalRouting,
};

const {
  getCanonicalActions,
  isAllowedDecision,
  normalizeCategory,
} = require('../../review-routing');

const ROUTED_LABELS = new Set(['Send', 'Edit', 'Rework', 'Execute', 'Inbox', 'Approve']);
const TERMINAL_LABELS = new Set(['Noted', 'Park', 'No further action', 'Kill']);

function slugifyAction(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function actionIdFor(category, label) {
  const normalizedCategory = normalizeCategory(category);
  const token = slugifyAction(label);
  if (!token) throw new Error('Action label is required');
  return `${normalizedCategory}.${token}`;
}

function getActionPolicy(category) {
  const normalizedCategory = normalizeCategory(category);
  return (getCanonicalActions(normalizedCategory) || []).map((label) => ({
    id: actionIdFor(normalizedCategory, label),
    label,
    routed: ROUTED_LABELS.has(label),
    terminal: TERMINAL_LABELS.has(label),
  }));
}

function findById(item, actionId) {
  const id = String(actionId || '').trim();
  if (!id) return null;
  return getActionPolicy(item?.category).find((action) => action.id === id) || null;
}

function findByLabel(item, label) {
  const text = String(label || '').trim();
  if (!text) return null;
  return getActionPolicy(item?.category).find((action) => action.label === text) || null;
}

function resolveActionInput(item, input = {}) {
  const actionId = String(input.actionId || input.action_id || '').trim();
  const decision = String(input.decision || input.action || '').trim();

  if (actionId) {
    const action = findById(item, actionId);
    if (!action) throw new Error(`Invalid action id for ${item?.category || 'general'}: ${actionId}`);
    if (decision && decision !== action.label) {
      throw new Error(`Action id ${actionId} does not match decision label ${decision}`);
    }
    return {
      actionId: action.id,
      label: action.label,
    };
  }

  if (!decision) throw new Error('decision or actionId is required');
  if (!isAllowedDecision(item, decision)) {
    throw new Error(`Invalid decision for ${item?.category || 'general'}: ${decision}`);
  }
  const action = findByLabel(item, decision);
  return {
    actionId: action ? action.id : actionIdFor(item?.category || 'general', decision),
    label: decision,
  };
}

module.exports = {
  actionIdFor,
  getActionPolicy,
  resolveActionInput,
};

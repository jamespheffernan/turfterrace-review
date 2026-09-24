const crypto = require('crypto');

const TARGET_SECTION_TOKENS = new Set([
  'items-to-review',
  'review-targets',
  'approval-list',
  'approval-checklist',
  'review-checklist',
]);
const TASK_ITEM_RE = /^(\s*)(?:[-*+]|\d+[.)])\s+\[([ xX-])\]\s+(.+)$/;
const LIST_ITEM_RE = /^(\s*)(?:[-*+]|\d+[.)])\s+(.+)$/;

function normalizeTargetText(value) {
  return String(value || '')
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[*_`>#]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function choiceActionLabel(value) {
  const clean = normalizeTargetText(value).replace(/[.?!]+$/, '');
  const firstWord = clean.split(/\s+/)[0].toLowerCase();
  const verbs = {
    included: 'Include',
    include: 'Include',
    excluded: 'Exclude',
    exclude: 'Exclude',
    merged: 'Merge',
    merge: 'Merge',
    kept: 'Keep',
    keep: 'Keep',
    removed: 'Remove',
    remove: 'Remove',
  };
  return verbs[firstWord] || clean;
}

function splitExplicitChoices(value) {
  const clean = normalizeTargetText(value).replace(/[.?!]+$/, '');
  if (!clean) return [];
  const parts = clean
    .replace(/,\s*(?:or|and)\s+/gi, ', ')
    .split(/\s*,\s*|\s+or\s+/i)
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length < 2 || parts.length > 5) return [];
  return parts.map((part) => ({
    value: hashPart(part.toLowerCase(), 12),
    label: choiceActionLabel(part),
    description: part,
  }));
}

function describeReviewTargetDecision(label) {
  const clean = normalizeTargetText(label);
  if (/^(approve|accept|authorize|confirm)\b/i.test(clean)) {
    return { kind: 'approval', options: [] };
  }

  const shouldBe = clean.match(/\bshould be\s+(.+?)[.?!]?$/i);
  const among = clean.match(/\bamong\s+(.+?)[.?!]?$/i);
  const between = clean.match(/\bbetween\s+(.+?)[.?!]?$/i);
  const options = splitExplicitChoices(shouldBe?.[1] || among?.[1] || between?.[1] || '');
  if (options.length > 1) return { kind: 'choice', options };

  return { kind: 'approval', options: [] };
}

function hashPart(value, length = 12) {
  return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex').slice(0, length);
}

function headingToken(value) {
  const normalized = normalizeTargetText(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return normalized || 'body';
}

function isApprovalHeading(value) {
  return TARGET_SECTION_TOKENS.has(headingToken(value));
}

function makeTargetKey({ sourceType, heading, ordinal, label }) {
  const source = sourceType === 'task_list' ? 'task' : 'list';
  return [
    source,
    headingToken(heading),
    String(ordinal).padStart(3, '0'),
    hashPart(normalizeTargetText(label)),
  ].join(':');
}

function makeTarget({ sourceType, heading, ordinal, label }) {
  const cleanLabel = normalizeTargetText(label);
  const targetKey = makeTargetKey({ sourceType, heading, ordinal, label: cleanLabel });
  return {
    target_key: targetKey,
    label: cleanLabel,
    source_type: sourceType,
    anchor_ref: `target:${targetKey}`,
    ordinal,
    text_hash: hashPart(cleanLabel, 32),
  };
}

function explicitManifestTarget(manifestTarget, ordinal) {
  const label = normalizeTargetText(manifestTarget?.label || manifestTarget?.title || manifestTarget?.text);
  if (!label) return null;
  const explicitId = normalizeTargetText(manifestTarget.id || manifestTarget.key || manifestTarget.target_key);
  const targetKey = explicitId
    ? `manifest:${headingToken(explicitId)}`
    : makeTargetKey({ sourceType: 'manifest', heading: 'manifest', ordinal, label });
  return {
    target_key: targetKey,
    label,
    source_type: 'manifest',
    anchor_ref: manifestTarget.anchorRef || manifestTarget.anchor_ref || `target:${targetKey}`,
    ordinal,
    text_hash: hashPart(label, 32),
  };
}

function extractReviewTargets(markdown, options = {}) {
  const explicitTargets = Array.isArray(options.targets) ? options.targets : [];
  if (explicitTargets.length) {
    return explicitTargets
      .map((target, index) => explicitManifestTarget(target, index + 1))
      .filter(Boolean);
  }

  const targets = [];
  const lines = String(markdown || '').split(/\r?\n/);
  let heading = '';
  let inTargetSection = false;
  let ordinal = 0;

  for (const line of lines) {
    const headingMatch = line.match(/^#{1,6}\s+(.+?)\s*#*\s*$/);
    if (headingMatch) {
      heading = normalizeTargetText(headingMatch[1]);
      inTargetSection = isApprovalHeading(heading);
      ordinal = 0;
      continue;
    }

    if (!inTargetSection) continue;

    const taskMatch = line.match(TASK_ITEM_RE);
    if (taskMatch) {
      const label = normalizeTargetText(taskMatch[3]);
      if (!label) continue;
      ordinal += 1;
      targets.push(makeTarget({ sourceType: 'task_list', heading, ordinal, label }));
      continue;
    }

    const listMatch = line.match(LIST_ITEM_RE);
    if (!listMatch) continue;

    const label = normalizeTargetText(listMatch[2]);
    if (!label) continue;
    ordinal += 1;
    targets.push(makeTarget({ sourceType: 'approval_list', heading, ordinal, label }));
  }

  return targets;
}

function syncReviewTargetsForItem(stmts, item) {
  if (!item?.slug) return [];
  const targets = extractReviewTargets(item.markdown || '');
  stmts.deactivateReviewTargetsForSlug.run(item.slug);
  for (const target of targets) {
    stmts.upsertReviewTarget.run({
      slug: item.slug,
      ...target,
    });
  }
  return targets;
}

function compactReviewTarget(row) {
  const decision = describeReviewTargetDecision(row.label);
  const storedVerdict = row.verdict || 'unset';
  const verdict = decision.kind === 'choice' && !storedVerdict.startsWith('choice:')
    ? 'unset'
    : storedVerdict;
  const selectedValue = verdict.startsWith('choice:') ? verdict.slice('choice:'.length) : null;
  const selectedOption = decision.options.find((option) => option.value === selectedValue) || null;
  return {
    id: row.id,
    key: row.target_key,
    label: row.label,
    sourceType: row.source_type,
    anchorRef: row.anchor_ref,
    ordinal: row.ordinal,
    verdict,
    decisionKind: decision.kind,
    options: decision.options,
    selectedOption,
    feedback: row.feedback || null,
    decided: verdict !== 'unset',
    decidedAt: row.decided_at || null,
    updatedAt: row.judgment_updated_at || row.updated_at || null,
  };
}

function summarizeReviewTargets(targets) {
  const summary = {
    total: targets.length,
    approved: 0,
    rejected: 0,
    undecided: 0,
    decided: 0,
    complete: targets.length === 0,
  };

  for (const target of targets) {
    if (target.verdict === 'approved') summary.approved += 1;
    else if (target.verdict === 'rejected') summary.rejected += 1;
    else if (target.verdict === 'unset') summary.undecided += 1;
  }

  summary.decided = summary.total - summary.undecided;
  summary.complete = summary.total === 0 || summary.undecided === 0;
  return summary;
}

function listReviewTargetsForItem(stmts, item) {
  syncReviewTargetsForItem(stmts, item);
  const targets = stmts.listReviewTargetsForSlug.all(item.slug).map(compactReviewTarget);
  return {
    slug: item.slug,
    targets,
    summary: summarizeReviewTargets(targets),
  };
}

function normalizeTargetVerdict(value) {
  const normalized = String(value || '').trim().toLowerCase();
  if (!normalized) return null;
  if (normalized === 'unset' || normalized === 'clear') return 'unset';
  if (['yes', 'approve', 'approved', 'accept', 'accepted'].includes(normalized)) return 'approved';
  if (['no', 'reject', 'rejected', 'decline', 'declined'].includes(normalized)) return 'rejected';
  return null;
}

function rejectedTargetFeedback(targets) {
  return targets
    .filter((target) => target.verdict === 'rejected' && target.feedback)
    .map((target) => `${target.label}: ${target.feedback}`)
    .join('\n')
    .trim();
}

module.exports = {
  compactReviewTarget,
  describeReviewTargetDecision,
  extractReviewTargets,
  listReviewTargetsForItem,
  normalizeTargetText,
  normalizeTargetVerdict,
  rejectedTargetFeedback,
  summarizeReviewTargets,
  syncReviewTargetsForItem,
};

const crypto = require('crypto');

const APPROVAL_HEADING_RE = /\b(approval|approve|approved|reject|yes\/no|yes-no|decide|decision|review targets?|items to review|per[- ]item|checklist)\b/i;
const TASK_ITEM_RE = /^(\s*)(?:[-*+]|\d+[.)])\s+\[([ xX-])\]\s+(.+)$/;
const LIST_ITEM_RE = /^(\s*)(?:[-*+]|\d+[.)])\s+(.+)$/;

function normalizeTargetText(value) {
  return String(value || '')
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[*_~`>#]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
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
  return APPROVAL_HEADING_RE.test(normalizeTargetText(value));
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

function extractReviewTargets(markdown) {
  const targets = [];
  const lines = String(markdown || '').split(/\r?\n/);
  let heading = '';
  let inApprovalSection = false;
  let ordinal = 0;

  for (const line of lines) {
    const headingMatch = line.match(/^#{1,6}\s+(.+?)\s*#*\s*$/);
    if (headingMatch) {
      heading = normalizeTargetText(headingMatch[1]);
      inApprovalSection = isApprovalHeading(heading);
      ordinal = 0;
      continue;
    }

    const taskMatch = line.match(TASK_ITEM_RE);
    if (taskMatch) {
      const label = normalizeTargetText(taskMatch[3]);
      if (!label) continue;
      ordinal += 1;
      targets.push(makeTarget({ sourceType: 'task_list', heading, ordinal, label }));
      continue;
    }

    if (!inApprovalSection) continue;
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
  const verdict = row.verdict || 'unset';
  return {
    id: row.id,
    key: row.target_key,
    label: row.label,
    sourceType: row.source_type,
    anchorRef: row.anchor_ref,
    ordinal: row.ordinal,
    verdict,
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
    else summary.undecided += 1;
  }

  summary.decided = summary.approved + summary.rejected;
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
  extractReviewTargets,
  listReviewTargetsForItem,
  normalizeTargetText,
  normalizeTargetVerdict,
  rejectedTargetFeedback,
  summarizeReviewTargets,
  syncReviewTargetsForItem,
};

const { openCrmDb } = require('./crm');

const CACHE_TTL_MS = 60_000;
const DASHBOARD_VERSION = 1;
const CRM_COMMAND_BASE = 'crm';

const TYPE_LABELS = {
  pm: 'Property Manager',
  influencer: 'Influencer',
};

const STATUS_LABELS = {
  new_lead: 'New Lead',
  contacted: 'Contacted',
  follow_up_due: 'Follow-up Due',
  responded: 'Responded',
  declined: 'Declined',
  parked: 'Parked',
  converted: 'Converted',
};

const STAGE_LABELS = {
  d0: 'D0',
  d3: 'D+3',
  d7: 'D+7',
  completed: 'Completed',
};

const CHANNEL_LABELS = {
  email: 'Email',
  contact_form: 'Contact Form',
  ig_dm: 'Instagram DM',
  phone: 'Phone',
};

const REGION_LABELS = {
  cotswolds: 'Cotswolds',
  lake_district: 'Lake District',
  yorkshire: 'Yorkshire',
  devon: 'Devon',
  cornwall: 'Cornwall',
  norfolk: 'Norfolk',
  suffolk: 'Suffolk',
  peak_district: 'Peak District',
  scottish_highlands: 'Scottish Highlands',
  pembrokeshire: 'Pembrokeshire',
  dorset: 'Dorset',
  somerset: 'Somerset',
  sussex: 'Sussex',
  kent: 'Kent',
  national: 'National',
  other: 'Other',
};

const RESPONSE_TYPE_LABELS = {
  positive: 'Positive',
  negative: 'Negative',
  question: 'Question',
};

const PIPELINE_STAGE_ORDER = ['new_lead', 'contacted', 'follow_up_due', 'replied', 'parked'];
const PIPELINE_STAGE_LABELS = {
  new_lead: 'New Lead',
  contacted: 'Contacted',
  follow_up_due: 'Follow-up Due',
  replied: 'Replied',
  parked: 'Parked',
};

const APPROVE_DECISIONS = new Set(['Approve', 'Send All', 'Send']);
const DAY_FORMATTER = new Intl.DateTimeFormat('en-GB', { day: 'numeric' });
const MONTH_FORMATTER = new Intl.DateTimeFormat('en-GB', { month: 'short' });
const WEEKDAY_FORMATTER = new Intl.DateTimeFormat('en-GB', { weekday: 'short' });
const MONTH_LABEL_FORMATTER = new Intl.DateTimeFormat('en-GB', { month: 'long', year: 'numeric' });

function asString(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length ? trimmed : null;
}

function asNumber(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function normalizeDate(value) {
  const stringValue = asString(value);
  if (!stringValue) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(stringValue)) return stringValue;
  const parsed = new Date(stringValue);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString().slice(0, 10);
}

function formatDate(date) {
  return date.toISOString().slice(0, 10);
}

function addDays(isoDate, days) {
  const date = new Date(`${isoDate}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

function daysBetween(fromIsoDate, toIsoDate) {
  const from = new Date(`${fromIsoDate}T12:00:00Z`);
  const to = new Date(`${toIsoDate}T12:00:00Z`);
  return Math.round((to.getTime() - from.getTime()) / 86400000);
}

function toNorm(value) {
  return String(value)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
}

function canonicalFromLabel(value, labels, aliases = {}) {
  if (typeof value !== 'string') return null;
  const lookup = new Map();
  for (const [key, label] of Object.entries(labels)) {
    lookup.set(toNorm(key), key);
    lookup.set(toNorm(label), key);
  }
  for (const [alias, key] of Object.entries(aliases)) {
    lookup.set(toNorm(alias), key);
  }
  return lookup.get(toNorm(value)) || null;
}

function extractIsoDate(value) {
  const stringValue = asString(value);
  if (!stringValue) return null;
  const directMatch = stringValue.match(/\b\d{4}-\d{2}-\d{2}\b/);
  if (directMatch) return directMatch[0];
  return normalizeDate(stringValue);
}

function detectCadenceKind(title) {
  const lower = String(title || '').toLowerCase();
  if (/d\+?7|d-?7/.test(lower)) return 'd7';
  if (/d\+?3|d-?3/.test(lower)) return 'd3';
  if (/d\+?0|d-?0|\bd0\b|initial|first outreach/.test(lower)) return 'd0';
  if (/follow.?up/.test(lower)) return 'd3';
  if (/outreach/.test(lower)) return 'd0';
  return null;
}

function normalizeKind(value) {
  const normalized = asString(value)?.toLowerCase();
  if (normalized === 'd0' || normalized === 'd3' || normalized === 'd7') return normalized;
  return null;
}

function createEmptyMetrics() {
  return {
    contactedCount: 0,
    repliedCount: 0,
    convertedCount: 0,
    parkedCount: 0,
    responseRate: 0,
    conversionRate: 0,
    parkRate: 0,
    averageDaysToFirstTouch: null,
    averageDaysToResponse: null,
    needsJimmyCount: 0,
    recentResponses: [],
    needsJimmy: [],
  };
}

function createRunwayMetrics(today, newLeads = 0, draftedPending = 0) {
  const available = Math.max(0, newLeads - draftedPending);
  const dailyRate = 10;
  const runwayDays = dailyRate > 0 ? Math.round(available / dailyRate) : null;

  let status = 'paused';
  if (runwayDays !== null) {
    status = runwayDays < 7 ? 'red' : runwayDays <= 21 ? 'amber' : 'green';
  }

  let exhaustionDate = null;
  if (runwayDays !== null) {
    const date = new Date(today);
    date.setUTCDate(date.getUTCDate() + runwayDays);
    exhaustionDate = date.toISOString().slice(0, 10);
  }

  return {
    newLeads,
    draftedPending,
    available,
    dailyRate,
    runwayDays,
    exhaustionDate,
    status,
  };
}

function fetchOutreachReviewItems(reviewDb, reviewBaseUrl) {
  const rows = reviewDb
    .prepare(`
      SELECT id, slug, title, category, status, decision, created_at, updated_at
      FROM items
      WHERE category = ?
      ORDER BY updated_at DESC, created_at DESC
    `)
    .all('outreach');

  return rows
    .map((item) => {
      const kind = detectCadenceKind(item.title);
      return {
        id: item.id,
        slug: item.slug,
        title: item.title,
        category: item.category,
        status: item.status,
        decision: item.decision,
        createdAt: item.created_at,
        updatedAt: item.updated_at,
        kind,
        batchDate: extractIsoDate(item.title) || extractIsoDate(item.updated_at),
        isPending: item.status === 'pending',
        isApproved: item.status === 'decided' && !!item.decision && APPROVE_DECISIONS.has(item.decision),
        reviewUrl: new URL(`/review/${item.slug}`, reviewBaseUrl).toString(),
      };
    })
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
}

function isReplied(contact) {
  return (
    contact.status === 'responded' ||
    contact.status === 'declined' ||
    contact.status === 'converted' ||
    !!contact.responseDate ||
    !!contact.responseType
  );
}

function isParked(contact) {
  if (contact.status === 'parked') return true;
  return !!contact.d7SentDate && !isReplied(contact);
}

function deriveCadenceState(contact, todayIso) {
  const replied = isReplied(contact);
  const parked = isParked(contact);

  let nextCadenceKind = null;
  let nextCadenceDueDate = null;

  if (contact.d0SentDate && !replied && !parked) {
    if (!contact.d3SentDate) {
      nextCadenceKind = 'd3';
      nextCadenceDueDate = addDays(contact.d0SentDate, 3);
    } else if (!contact.d7SentDate) {
      nextCadenceKind = 'd7';
      nextCadenceDueDate = addDays(contact.d0SentDate, 7);
    }
  }

  const daysUntilNextAction = nextCadenceDueDate ? daysBetween(todayIso, nextCadenceDueDate) : null;
  const followUpDue = nextCadenceDueDate ? nextCadenceDueDate <= todayIso : false;

  let funnelStage = 'new_lead';
  if (parked) {
    funnelStage = 'parked';
  } else if (replied) {
    funnelStage = 'replied';
  } else if (followUpDue || contact.status === 'follow_up_due') {
    funnelStage = 'follow_up_due';
  } else if (contact.d0SentDate || contact.status === 'contacted' || !!contact.outreachStage) {
    funnelStage = 'contacted';
  }

  let nextActionSummary = 'Awaiting first outreach';
  if (funnelStage === 'parked') {
    nextActionSummary = 'No active follow-up';
  } else if (funnelStage === 'replied') {
    nextActionSummary = contact.responseTypeLabel ? `${contact.responseTypeLabel} response logged` : 'Reply logged';
  } else if (nextCadenceKind && nextCadenceDueDate && daysUntilNextAction !== null) {
    if (daysUntilNextAction < 0) {
      nextActionSummary = `${nextCadenceKind.toUpperCase()} overdue by ${Math.abs(daysUntilNextAction)}d`;
    } else if (daysUntilNextAction === 0) {
      nextActionSummary = `${nextCadenceKind.toUpperCase()} due today`;
    } else {
      nextActionSummary = `${nextCadenceKind.toUpperCase()} due in ${daysUntilNextAction}d`;
    }
  } else if (contact.d0SentDate) {
    nextActionSummary = 'Waiting on reply window';
  }

  const lastTouchDate =
    contact.d7SentDate ||
    contact.d3SentDate ||
    contact.d0SentDate ||
    contact.lastActivityDate ||
    contact.lastContacted;

  return {
    funnelStage,
    funnelStageLabel: PIPELINE_STAGE_LABELS[funnelStage],
    nextCadenceKind,
    nextCadenceDueDate,
    followUpDue,
    daysUntilNextAction,
    nextActionSummary,
    lastTouchDate,
  };
}

function parseContactRow(row, todayIso) {
  const baseContact = {
    id: String(row.id),
    name: asString(row.name) || '(Unnamed)',
    type: canonicalFromLabel(row.type, TYPE_LABELS),
    typeLabel: null,
    status: canonicalFromLabel(row.status, STATUS_LABELS, { followup_due: 'follow_up_due' }),
    statusLabel: null,
    outreachStage: canonicalFromLabel(row.outreach_stage, STAGE_LABELS, {
      day0: 'd0',
      d_0: 'd0',
      d_plus_3: 'd3',
      d_plus_7: 'd7',
    }),
    outreachStageLabel: null,
    email: asString(row.email),
    website: asString(row.website_handle),
    websiteUrl: asString(row.website_url),
    region: canonicalFromLabel(row.region, REGION_LABELS),
    regionLabel: null,
    channel: canonicalFromLabel(row.channel, CHANNEL_LABELS, {
      form: 'contact_form',
      ig: 'ig_dm',
      instagram: 'ig_dm',
    }),
    channelLabel: null,
    d0SentDate: normalizeDate(row.d0_sent_date),
    d3SentDate: normalizeDate(row.d3_sent_date),
    d7SentDate: normalizeDate(row.d7_sent_date),
    nextFollowUpDate: normalizeDate(row.next_follow_up_date),
    lastContacted: normalizeDate(row.last_contacted),
    lastActivityDate: normalizeDate(row.last_activity_date),
    responseDate: normalizeDate(row.response_date),
    responseType: canonicalFromLabel(row.response_type, RESPONSE_TYPE_LABELS, {
      pos: 'positive',
      neg: 'negative',
    }),
    responseTypeLabel: null,
    outreachProof: asString(row.outreach_proof),
    contactName: asString(row.contact_name),
    estProperties: asNumber(row.est_properties),
    leadScore: asNumber(row.lead_score),
    needsJimmy: row.needs_jimmy === true || row.needs_jimmy === 1,
  };

  baseContact.typeLabel = baseContact.type ? TYPE_LABELS[baseContact.type] : null;
  baseContact.statusLabel = baseContact.status ? STATUS_LABELS[baseContact.status] : null;
  baseContact.outreachStageLabel = baseContact.outreachStage ? STAGE_LABELS[baseContact.outreachStage] : null;
  baseContact.regionLabel = baseContact.region ? REGION_LABELS[baseContact.region] : null;
  baseContact.channelLabel = baseContact.channel ? CHANNEL_LABELS[baseContact.channel] : null;
  baseContact.responseTypeLabel = baseContact.responseType ? RESPONSE_TYPE_LABELS[baseContact.responseType] : null;

  return {
    ...baseContact,
    ...deriveCadenceState(baseContact, todayIso),
  };
}

function fetchContacts(db, today) {
  const todayIso = formatDate(today);
  const rows = db
    .prepare(`
      SELECT
        id, name, type, status, outreach_stage, email, website_handle, website_url, region, channel,
        d0_sent_date, d3_sent_date, d7_sent_date, next_follow_up_date, last_contacted, last_activity_date,
        response_date, response_type, outreach_proof, contact_name, est_properties, lead_score, needs_jimmy
      FROM contacts
      ORDER BY name COLLATE NOCASE ASC
    `)
    .all();

  return rows.map((row) => parseContactRow(row, todayIso));
}

function fetchQueueItems(db, reviewBaseUrl) {
  const rows = db
    .prepare(`
      SELECT *
      FROM queue_items
      ORDER BY scheduled_for ASC, id ASC
    `)
    .all();

  return rows.map((row, index) => {
    const reviewSlug = asString(row.review_slug);
    return {
      id: asString(row.id) || `queue-${index}`,
      to: asString(row.recipient_email) || '(unknown recipient)',
      subject: asString(row.subject) || '(no subject)',
      scheduledFor: asString(row.scheduled_for) || '',
      scheduledDate: normalizeDate(row.scheduled_for),
      status: asString(row.status)?.toLowerCase() || 'pending',
      approvedAt: asString(row.approved_at),
      approvedBy: asString(row.approved_by),
      type: normalizeKind(row.cadence_kind),
      sentAt: asString(row.sent_at),
      sentDate: normalizeDate(row.sent_at),
      error: asString(row.error),
      reviewSlug,
      reviewUrl: reviewSlug ? new URL(`/review/${reviewSlug}`, reviewBaseUrl).toString() : null,
    };
  });
}

function fetchSendLog(db) {
  const rows = db
    .prepare(`
      SELECT queue_item_id, recipient_email, subject, cadence_kind, scheduled_for, sent_at
      FROM send_attempts
      WHERE sent_at IS NOT NULL
      ORDER BY sent_at DESC
    `)
    .all();

  const seen = new Set();

  return rows
    .map((row, index) => ({
      id: asString(row.queue_item_id) || `send-${index}`,
      to: asString(row.recipient_email) || '(unknown recipient)',
      subject: asString(row.subject) || '(no subject)',
      type: normalizeKind(row.cadence_kind),
      scheduledFor: asString(row.scheduled_for),
      scheduledDate: normalizeDate(row.scheduled_for),
      sentAt: asString(row.sent_at) || '',
      sentDate: normalizeDate(row.sent_at),
    }))
    .filter((entry) => {
      const key = `${entry.id}::${entry.to.toLowerCase()}::${entry.type || 'unknown'}::${entry.subject}::${entry.sentDate || entry.sentAt}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function average(values) {
  if (!values.length) return null;
  return Math.round((values.reduce((sum, value) => sum + value, 0) / values.length) * 10) / 10;
}

function getRecentResponseSortKey(contact) {
  return contact.responseDate || contact.lastActivityDate || contact.lastContacted || contact.lastTouchDate || '';
}

function fetchMetrics(db, contacts) {
  const rows = db
    .prepare(`
      SELECT id, name, status, created_time, d0_sent_date, response_date, response_type, response_summary, next_follow_up_date, contact_name, needs_jimmy
      FROM contacts
    `)
    .all();

  const contactedCount = contacts.filter((contact) => contact.funnelStage !== 'new_lead').length;
  const repliedCount = contacts.filter((contact) => contact.funnelStage === 'replied').length;
  const convertedCount = contacts.filter((contact) => contact.status === 'converted').length;
  const parkedCount = contacts.filter((contact) => contact.funnelStage === 'parked').length;

  const responseRate = contactedCount ? Math.round((repliedCount / contactedCount) * 1000) / 10 : 0;
  const conversionRate = contactedCount ? Math.round((convertedCount / contactedCount) * 1000) / 10 : 0;
  const parkRate = contactedCount ? Math.round((parkedCount / contactedCount) * 1000) / 10 : 0;

  const firstTouchDurations = rows
    .map((row) => {
      const created = normalizeDate(row.created_time);
      const d0 = normalizeDate(row.d0_sent_date);
      return created && d0 ? daysBetween(created, d0) : null;
    })
    .filter((value) => value !== null);

  const responseDurations = rows
    .map((row) => {
      const d0 = normalizeDate(row.d0_sent_date);
      const responseDate = normalizeDate(row.response_date);
      return d0 && responseDate ? daysBetween(d0, responseDate) : null;
    })
    .filter((value) => value !== null);

  const rowsById = new Map(
    rows
      .map((row) => {
        const id = asString(row.id);
        return id ? [id, row] : null;
      })
      .filter(Boolean)
  );

  const recentResponses = contacts
    .filter((contact) => contact.funnelStage === 'replied')
    .sort((left, right) => {
      const leftKey = getRecentResponseSortKey(left);
      const rightKey = getRecentResponseSortKey(right);
      if (leftKey !== rightKey) return rightKey.localeCompare(leftKey);
      return left.name.localeCompare(right.name);
    })
    .slice(0, 8)
    .map((contact) => {
      const row = rowsById.get(contact.id);
      return {
        id: contact.id,
        name: contact.name,
        responseType: contact.responseTypeLabel,
        responseDate: contact.responseDate,
        status: contact.statusLabel || asString(row?.status),
        summary: asString(row?.response_summary),
      };
    });

  const needsJimmyRows = rows
    .filter((row) => asNumber(row.needs_jimmy) === 1)
    .sort((left, right) => String(left.next_follow_up_date || '').localeCompare(String(right.next_follow_up_date || '')));

  const needsJimmy = needsJimmyRows.slice(0, 8).map((row) => ({
    id: String(row.id),
    name: asString(row.name) || '(Unnamed)',
    status: asString(row.status),
    nextFollowUpDate: normalizeDate(row.next_follow_up_date),
    contactName: asString(row.contact_name),
  }));

  return {
    contactedCount,
    repliedCount,
    convertedCount,
    parkedCount,
    responseRate,
    conversionRate,
    parkRate,
    averageDaysToFirstTouch: average(firstTouchDurations),
    averageDaysToResponse: average(responseDurations),
    needsJimmyCount: needsJimmyRows.length,
    recentResponses,
    needsJimmy,
  };
}

function fetchRunwayMetrics(db, contacts, today) {
  const row = db
    .prepare(`
      SELECT COALESCE(SUM(COALESCE(count, 0)), 0) AS drafted_pending
      FROM draft_batches
      WHERE status = 'pending'
    `)
    .get();

  const draftedPending = asNumber(row?.drafted_pending) || 0;
  const newLeads = contacts.filter((contact) => contact.funnelStage === 'new_lead' && contact.type === 'pm').length;

  return createRunwayMetrics(today, newLeads, draftedPending);
}

function buildPipelineSummary(contacts) {
  return PIPELINE_STAGE_ORDER.map((stage) => {
    const count = contacts.filter((contact) => contact.funnelStage === stage).length;
    return {
      key: stage,
      label: PIPELINE_STAGE_LABELS[stage],
      count,
      share: contacts.length ? count / contacts.length : 0,
    };
  });
}

function countSentToday(queue, sendLog, todayIso) {
  const sent = new Set();

  for (const item of queue) {
    if (item.sentDate !== todayIso) continue;
    const key = item.id || `${item.to}::${item.subject}::${item.sentDate}`;
    sent.add(key);
  }

  for (const item of sendLog) {
    if (item.sentDate !== todayIso) continue;
    const key = item.id || `${item.to}::${item.subject}::${item.sentDate}`;
    sent.add(key);
  }

  return sent.size;
}

function createEmptyBucket() {
  return {
    total: 0,
    sent: 0,
    approved: 0,
    pending_review: 0,
    not_drafted: 0,
    failed: 0,
  };
}

function createDay(date, todayIso, monthToken) {
  const labelDate = new Date(`${date}T12:00:00Z`);
  return {
    date,
    dayNumber: Number(DAY_FORMATTER.format(labelDate)),
    weekdayShort: WEEKDAY_FORMATTER.format(labelDate),
    monthShort: MONTH_FORMATTER.format(labelDate),
    isToday: date === todayIso,
    isCurrentMonth: date.startsWith(monthToken),
    items: [],
    totalsByKind: {
      d0: createEmptyBucket(),
      d3: createEmptyBucket(),
      d7: createEmptyBucket(),
    },
  };
}

function getWeekStart(date) {
  const copy = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), 12));
  const day = copy.getUTCDay();
  const offset = day === 0 ? -6 : 1 - day;
  copy.setUTCDate(copy.getUTCDate() + offset);
  return copy;
}

function toDateKey(value) {
  return value.toISOString().slice(0, 10);
}

function mapQueueStatus(status) {
  switch (status) {
    case 'sent':
      return 'sent';
    case 'approved':
      return 'approved';
    case 'failed':
      return 'failed';
    case 'pending':
    default:
      return 'pending_review';
  }
}

function groupByEmailAndKind(items) {
  const grouped = new Map();
  for (const item of items) {
    if (!item.type) continue;
    const key = `${item.to.toLowerCase()}::${item.type}`;
    const bucket = grouped.get(key) || [];
    bucket.push(item);
    grouped.set(key, bucket);
  }
  return grouped;
}

function findBestMatch(items, targetDate) {
  if (!items || !items.length) return null;

  const scored = items
    .map((item) => {
      const candidateDate = item.sentDate || item.scheduledDate || null;
      if (!candidateDate) return null;
      return {
        item,
        distance: Math.abs(daysBetween(candidateDate, targetDate)),
      };
    })
    .filter(Boolean)
    .sort((left, right) => left.distance - right.distance);

  if (!scored.length || scored[0].distance > 5) return null;
  return scored[0].item;
}

function reviewLookupKey(kind, date) {
  return `${kind}::${date}`;
}

function buildReviewSignals(reviewItems) {
  const signals = new Map();

  for (const item of reviewItems) {
    if (!item.kind || !item.batchDate) continue;
    const key = reviewLookupKey(item.kind, item.batchDate);
    const nextStatus = item.isPending ? 'pending_review' : item.isApproved ? 'approved' : 'not_drafted';
    const previousStatus = signals.get(key);

    if (!previousStatus) {
      signals.set(key, nextStatus);
      continue;
    }

    if (previousStatus === 'pending_review' || previousStatus === 'approved') continue;
    signals.set(key, nextStatus);
  }

  return signals;
}

function shouldSkipDueItem(contact, dueDate, todayIso) {
  if (!contact.responseDate && contact.status !== 'parked') return false;
  if (contact.responseDate && contact.responseDate < dueDate) return true;
  return contact.status === 'parked' && dueDate > todayIso;
}

function createFollowUpItem(contact, kind, dueDate, todayIso, queueLookup, logLookup, reviewSignals) {
  if (shouldSkipDueItem(contact, dueDate, todayIso)) return null;

  const sentDate = kind === 'd3' ? contact.d3SentDate : contact.d7SentDate;
  const lookupKey = contact.email ? `${contact.email.toLowerCase()}::${kind}` : null;
  const queueMatch = lookupKey ? findBestMatch(queueLookup.get(lookupKey), dueDate) : null;
  const logMatch = lookupKey ? findBestMatch(logLookup.get(lookupKey), dueDate) : null;

  let status = 'not_drafted';
  let subtitle = `${contact.name}`;
  let actualDate = sentDate;
  let reviewSlug = null;
  let reviewUrl = null;
  let inferred = false;

  if (sentDate || logMatch) {
    status = 'sent';
    actualDate = sentDate || logMatch?.sentDate || null;
    subtitle = actualDate ? `${contact.name} • sent ${actualDate}` : `${contact.name} • sent`;
  } else if (queueMatch) {
    status = mapQueueStatus(queueMatch.status);
    reviewSlug = queueMatch.reviewSlug;
    reviewUrl = queueMatch.reviewUrl;
    subtitle =
      status === 'approved'
        ? `${contact.name} • queued for send`
        : status === 'failed'
          ? `${contact.name} • send failed`
          : `${contact.name} • awaiting approval`;
  } else {
    const reviewStatus = reviewSignals.get(reviewLookupKey(kind, dueDate));
    if (reviewStatus === 'pending_review' || reviewStatus === 'approved') {
      status = reviewStatus;
      subtitle =
        reviewStatus === 'approved'
          ? `${contact.name} • approved batch exists`
          : `${contact.name} • draft batch awaiting review`;
      inferred = true;
    } else if (dueDate > todayIso) {
      subtitle = `${contact.name} • no draft staged yet`;
    } else {
      subtitle = `${contact.name} • no draft staged`;
    }
  }

  return {
    id: `${contact.id}-${kind}-${dueDate}`,
    date: dueDate,
    kind,
    status,
    title: contact.name,
    subtitle,
    contactId: contact.id,
    contactName: contact.name,
    email: contact.email,
    reviewSlug,
    reviewUrl,
    actualDate,
    inferred,
  };
}

function buildCalendarData({ contacts, queue, sendLog, reviewItems, today = new Date() }) {
  const todayIso = formatDate(today);
  const anchor = new Date(`${todayIso}T12:00:00Z`);
  const firstOfMonth = new Date(Date.UTC(anchor.getUTCFullYear(), anchor.getUTCMonth(), 1, 12));
  const monthToken = firstOfMonth.toISOString().slice(0, 7);
  const monthStart = getWeekStart(firstOfMonth);
  const days = Array.from({ length: 42 }, (_, index) => {
    const date = new Date(monthStart);
    date.setUTCDate(monthStart.getUTCDate() + index);
    return createDay(toDateKey(date), todayIso, monthToken);
  });

  const weekStart = getWeekStart(anchor);
  const weekDates = Array.from({ length: 7 }, (_, index) => {
    const date = new Date(weekStart);
    date.setUTCDate(weekStart.getUTCDate() + index);
    return toDateKey(date);
  });

  const queueLookup = groupByEmailAndKind(queue);
  const logLookup = groupByEmailAndKind(sendLog);
  const reviewSignals = buildReviewSignals(reviewItems);
  const dayMap = new Map(days.map((day) => [day.date, day]));
  const seen = new Set();

  for (const item of queue) {
    if (!item.type || !item.scheduledDate) continue;
    const day = dayMap.get(item.scheduledDate);
    if (!day) continue;

    day.items.push({
      id: `queue-${item.id}`,
      date: item.scheduledDate,
      kind: item.type,
      status: mapQueueStatus(item.status),
      title: item.subject,
      subtitle:
        item.status === 'sent'
          ? `${item.to} • sent ${item.sentDate || item.scheduledDate}`
          : item.status === 'failed'
            ? `${item.to} • send failed`
            : `${item.to} • scheduled ${item.scheduledDate}`,
      contactId: null,
      contactName: null,
      email: item.to,
      reviewSlug: item.reviewSlug,
      reviewUrl: item.reviewUrl,
      actualDate: item.sentDate,
      inferred: false,
    });

    seen.add(`${item.to.toLowerCase()}::${item.type}::${item.scheduledDate}::${item.subject}`);
  }

  for (const item of sendLog) {
    if (!item.type || !item.sentDate) continue;
    const key = `${item.to.toLowerCase()}::${item.type}::${item.sentDate}::${item.subject}`;
    if (seen.has(key)) continue;
    const day = dayMap.get(item.sentDate);
    if (!day) continue;

    day.items.push({
      id: `log-${item.id}`,
      date: item.sentDate,
      kind: item.type,
      status: 'sent',
      title: item.subject,
      subtitle: `${item.to} • sent ${item.sentDate}`,
      contactId: null,
      contactName: null,
      email: item.to,
      reviewSlug: null,
      reviewUrl: null,
      actualDate: item.sentDate,
      inferred: false,
    });

    seen.add(key);
  }

  for (const contact of contacts) {
    if (!contact.d0SentDate) continue;

    const sentKey = contact.email ? `${contact.email.toLowerCase()}::d0::${contact.d0SentDate}` : null;
    if (!sentKey || !seen.has(sentKey)) {
      const day = dayMap.get(contact.d0SentDate);
      if (day) {
        day.items.push({
          id: `${contact.id}-d0-${contact.d0SentDate}`,
          date: contact.d0SentDate,
          kind: 'd0',
          status: 'sent',
          title: contact.name,
          subtitle: `${contact.name} • D0 sent`,
          contactId: contact.id,
          contactName: contact.name,
          email: contact.email,
          reviewSlug: null,
          reviewUrl: null,
          actualDate: contact.d0SentDate,
          inferred: true,
        });
      }
    }

    const d3DueDate = addDays(contact.d0SentDate, 3);
    if (dayMap.has(d3DueDate)) {
      const item = createFollowUpItem(contact, 'd3', d3DueDate, todayIso, queueLookup, logLookup, reviewSignals);
      if (item) dayMap.get(d3DueDate).items.push(item);
    }

    const hasD3Track =
      !!contact.d3SentDate ||
      contact.outreachStage === 'd3' ||
      contact.outreachStage === 'd7' ||
      contact.outreachStage === 'completed' ||
      !!contact.d7SentDate;

    if (!hasD3Track) continue;

    const d7DueDate = addDays(contact.d0SentDate, 7);
    if (dayMap.has(d7DueDate)) {
      const item = createFollowUpItem(contact, 'd7', d7DueDate, todayIso, queueLookup, logLookup, reviewSignals);
      if (item) dayMap.get(d7DueDate).items.push(item);
    }
  }

  for (const day of days) {
    day.items.sort((left, right) => {
      if (left.kind !== right.kind) return left.kind.localeCompare(right.kind);
      if (left.status !== right.status) return left.status.localeCompare(right.status);
      return left.title.localeCompare(right.title);
    });

    for (const item of day.items) {
      const bucket = day.totalsByKind[item.kind];
      bucket.total += 1;
      bucket[item.status] += 1;
    }
  }

  return {
    monthLabel: MONTH_LABEL_FORMATTER.format(anchor),
    today: todayIso,
    weekDates,
    days,
  };
}

function buildDashboardData(reviewDb, reviewBaseUrl) {
  const generatedAt = new Date();
  const todayIso = formatDate(generatedAt);
  const warnings = [];
  const sources = [];
  let contacts = [];
  let reviewItems = [];
  let queue = [];
  let sendLog = [];
  let metrics = createEmptyMetrics();
  let runway = createRunwayMetrics(generatedAt);

  const crmDb = openCrmDb();
  try {
    try {
      contacts = fetchContacts(crmDb, generatedAt);
      sources.push({
        key: 'sqlite',
        label: 'SQLite CRM',
        ok: true,
        detail: `${contacts.length} contacts loaded`,
      });
    } catch (error) {
      warnings.push(`SQLite CRM unavailable: ${error.message}`);
      sources.push({
        key: 'sqlite',
        label: 'SQLite CRM',
        ok: false,
        detail: 'Using empty CRM dataset',
      });
    }

    try {
      reviewItems = fetchOutreachReviewItems(reviewDb, reviewBaseUrl);
      sources.push({
        key: 'turf_review',
        label: 'Turf Review',
        ok: true,
        detail: `${reviewItems.length} outreach items loaded`,
      });
    } catch (error) {
      warnings.push(`Turf Review unavailable: ${error.message}`);
      sources.push({
        key: 'turf_review',
        label: 'Turf Review',
        ok: false,
        detail: 'Approval feed unavailable',
      });
    }

    try {
      queue = fetchQueueItems(crmDb, reviewBaseUrl);
      sources.push({
        key: 'queue',
        label: 'SQLite queue snapshot',
        ok: true,
        detail: `${queue.length} queue entries loaded`,
      });
    } catch (error) {
      warnings.push(`Queue snapshot unavailable: ${error.message}`);
      sources.push({
        key: 'queue',
        label: 'SQLite queue snapshot',
        ok: false,
        detail: 'Queue file unavailable',
      });
    }

    try {
      sendLog = fetchSendLog(crmDb);
      sources.push({
        key: 'send_log',
        label: 'SQLite send attempts',
        ok: true,
        detail: `${sendLog.length} send log entries loaded`,
      });
    } catch (error) {
      warnings.push(`Send attempts unavailable: ${error.message}`);
      sources.push({
        key: 'send_log',
        label: 'SQLite send attempts',
        ok: false,
        detail: 'Send log unavailable',
      });
    }

    try {
      metrics = fetchMetrics(crmDb, contacts);
    } catch (error) {
      warnings.push(`Funnel metrics unavailable: ${error.message}`);
      metrics = createEmptyMetrics();
    }

    try {
      runway = fetchRunwayMetrics(crmDb, contacts, generatedAt);
    } catch (error) {
      warnings.push(`Runway metrics unavailable: ${error.message}`);
      const newLeads = contacts.filter((contact) => contact.funnelStage === 'new_lead' && contact.type === 'pm').length;
      runway = createRunwayMetrics(generatedAt, newLeads, 0);
    }
  } finally {
    crmDb.close();
  }

  const propertyManagers = contacts.filter((contact) => contact.type === 'pm').length;
  const influencers = contacts.filter((contact) => contact.type === 'influencer').length;
  const followUpsDueNow = contacts.filter((contact) => contact.funnelStage === 'follow_up_due').length;
  const overdueFollowUps = contacts.filter(
    (contact) => contact.followUpDue && typeof contact.daysUntilNextAction === 'number' && contact.daysUntilNextAction < 0
  ).length;
  const approvedQueued = queue.filter((item) => item.status === 'approved').length;
  const failedQueue = queue.filter((item) => item.status === 'failed').length;
  const sentToday = countSentToday(queue, sendLog, todayIso);
  const pipeline = buildPipelineSummary(contacts);

  const pendingItems = reviewItems
    .filter((item) => item.isPending)
    .map((item) => ({
      slug: item.slug,
      title: item.title,
      kind: item.kind,
      batchDate: item.batchDate,
      updatedAt: item.updatedAt,
      url: item.reviewUrl,
    }))
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));

  const calendar = buildCalendarData({
    contacts,
    queue,
    sendLog,
    reviewItems,
    today: generatedAt,
  });

  if (!contacts.length) {
    warnings.push('CRM data is empty, so funnel counts and follow-up views may be incomplete.');
  }

  return {
    version: DASHBOARD_VERSION,
    generatedAt: generatedAt.toISOString(),
    sources,
    warnings,
    summary: {
      totalContacts: contacts.length,
      propertyManagers,
      influencers,
      followUpsDueNow,
      overdueFollowUps,
      approvedQueued,
      sentToday,
      failedQueue,
    },
    pipeline,
    contacts,
    approval: {
      pendingDrafts: pendingItems.length,
      approvedQueued,
      sentToday,
      failedQueue,
      pendingItems,
    },
    metrics,
    runway,
    calendar,
    actions: {
      crmCommandBase: CRM_COMMAND_BASE,
      examples: {
        backendStatus: `${CRM_COMMAND_BASE} backend-status --json`,
        dueNow: `${CRM_COMMAND_BASE} due --json`,
        stats: `${CRM_COMMAND_BASE} stats --json`,
        reconcile: `${CRM_COMMAND_BASE} reconcile --json`,
      },
    },
  };
}

function createFunnelDashboardService({ reviewDb }) {
  const cacheByBaseUrl = new Map();

  function getCacheState(reviewBaseUrl) {
    if (!cacheByBaseUrl.has(reviewBaseUrl)) {
      cacheByBaseUrl.set(reviewBaseUrl, {
        payload: null,
        expiresAt: 0,
        inflight: null,
      });
    }
    return cacheByBaseUrl.get(reviewBaseUrl);
  }

  async function getDashboardData({ force = false, reviewBaseUrl }) {
    const cache = getCacheState(reviewBaseUrl);
    const now = Date.now();

    if (!force && cache.payload && now < cache.expiresAt) {
      return cache.payload;
    }

    if (!force && cache.inflight) {
      return cache.inflight;
    }

    cache.inflight = Promise.resolve()
      .then(() => buildDashboardData(reviewDb, reviewBaseUrl))
      .then((payload) => {
        cache.payload = payload;
        cache.expiresAt = Date.now() + CACHE_TTL_MS;
        return payload;
      })
      .finally(() => {
        cache.inflight = null;
      });

    return cache.inflight;
  }

  function getCachedPayload(reviewBaseUrl) {
    return getCacheState(reviewBaseUrl).payload;
  }

  return {
    getCachedPayload,
    getDashboardData,
  };
}

module.exports = {
  createFunnelDashboardService,
};

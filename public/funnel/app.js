const REFRESH_INTERVAL_MS = 5 * 60 * 1000;

const state = {
  data: null,
  selectedStage: null,
  contactType: "all",
  contactSearch: "",
  detailLimit: 12,
  dayDetailLimit: 8,
  calendarMode: window.innerWidth < 760 ? "week" : "month",
  selectedDay: null,
  refreshTimer: null,
  countdownTimer: null,
  nextRefreshAt: Date.now() + REFRESH_INTERVAL_MS,
};

const elements = {
  lastUpdated: document.getElementById("lastUpdated"),
  nextRefresh: document.getElementById("nextRefresh"),
  refreshButton: document.getElementById("refreshButton"),
  heroBrief: document.getElementById("heroBrief"),
  headlineStats: document.getElementById("headlineStats"),
  approvalMetrics: document.getElementById("approvalMetrics"),
  pendingBatches: document.getElementById("pendingBatches"),
  funnelTrack: document.getElementById("funnelTrack"),
  detailStageLabel: document.getElementById("detailStageLabel"),
  detailStageMeta: document.getElementById("detailStageMeta"),
  contactTypeFilter: document.getElementById("contactTypeFilter"),
  contactSearch: document.getElementById("contactSearch"),
  detailHighlights: document.getElementById("detailHighlights"),
  contactList: document.getElementById("contactList"),
  workList: document.getElementById("workList"),
  performanceMetrics: document.getElementById("performanceMetrics"),
  runwayCard: document.getElementById("runwayCard"),
  operatorShortcuts: document.getElementById("operatorShortcuts"),
  recentResponses: document.getElementById("recentResponses"),
  needsJimmy: document.getElementById("needsJimmy"),
  calendarModeToggle: document.getElementById("calendarModeToggle"),
  calendarLegend: document.getElementById("calendarLegend"),
  calendarWeekdays: document.getElementById("calendarWeekdays"),
  calendarGrid: document.getElementById("calendarGrid"),
  dayDetail: document.getElementById("dayDetail"),
  sourceStatus: document.getElementById("sourceStatus"),
  warningList: document.getElementById("warningList"),
};

const STAGE_PRIORITY = ["follow_up_due", "contacted", "new_lead", "replied", "parked"];
const STAGE_LABELS = {
  new_lead: "New Lead",
  contacted: "Contacted",
  follow_up_due: "Follow-up Due",
  replied: "Replied",
  parked: "Parked",
};
const KIND_LABELS = {
  d0: "D0",
  d3: "D+3",
  d7: "D+7",
};
const STATUS_LABELS = {
  sent: "Sent",
  approved: "Send queued",
  pending_review: "Drafted / pending",
  not_drafted: "Not drafted",
  failed: "Failed",
};
const STATUS_TONES = {
  sent: "tone-sent",
  approved: "tone-approved",
  pending_review: "tone-pending_review",
  not_drafted: "tone-not_drafted",
  failed: "tone-failed",
};

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function formatDateTime(value) {
  const date = new Date(value);
  return new Intl.DateTimeFormat("en-GB", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function formatShortDate(value) {
  if (!value) return "Unknown date";
  const date = new Date(`${value}T12:00:00Z`);
  return new Intl.DateTimeFormat("en-GB", {
    day: "numeric",
    month: "short",
  }).format(date);
}

function formatCalendarDate(value) {
  const date = new Date(`${value}T12:00:00Z`);
  return new Intl.DateTimeFormat("en-GB", {
    weekday: "long",
    day: "numeric",
    month: "long",
  }).format(date);
}

function formatCountdown(msRemaining) {
  const totalSeconds = Math.max(0, Math.ceil(msRemaining / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${String(minutes).padStart(1, "0")}:${String(seconds).padStart(2, "0")}`;
}

function formatPercent(value) {
  return `${Number(value || 0).toFixed(1)}%`;
}

function truncateText(value, maxLength = 160) {
  const text = String(value || "").trim().replace(/\s+/g, " ");
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength - 1).trimEnd()}…`;
}

function shellQuote(value) {
  return `'${String(value ?? "").replaceAll("'", "'\\''")}'`;
}

function normalizeExternalUrl(contact) {
  const raw = contact.websiteUrl || contact.website;
  if (!raw) return null;
  const trimmed = String(raw).trim();
  if (!trimmed) return null;
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  if (trimmed.startsWith("@")) {
    return `https://instagram.com/${trimmed.slice(1)}`;
  }
  if (/instagram\.com\//i.test(trimmed)) {
    return trimmed.startsWith("http") ? trimmed : `https://${trimmed}`;
  }
  if (/^[\w.-]+\.[a-z]{2,}/i.test(trimmed)) {
    return `https://${trimmed}`;
  }
  return null;
}

function crmGetCommand(contactId) {
  const base = state.data?.actions?.crmCommandBase || "crm.ts";
  return `${base} get ${shellQuote(contactId)} --json`;
}

function copyAction(label, value) {
  return `<button class="mini-action" type="button" data-copy="${escapeHtml(value)}">${escapeHtml(label)}</button>`;
}

function linkAction(label, href) {
  return `<a class="mini-action link-action" href="${escapeHtml(href)}" target="_blank" rel="noreferrer">${escapeHtml(label)}</a>`;
}

async function copyText(value) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.setAttribute("readonly", "true");
  textarea.style.position = "absolute";
  textarea.style.left = "-9999px";
  document.body.appendChild(textarea);
  textarea.select();
  document.execCommand("copy");
  textarea.remove();
}

function bindCopyActions(root) {
  root.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const originalHtml = button.innerHTML;
      try {
        await copyText(button.getAttribute("data-copy") || "");
        button.textContent = "Copied";
      } catch (error) {
        console.error(error);
        button.textContent = "Failed";
      } finally {
        window.setTimeout(() => {
          button.innerHTML = originalHtml;
        }, 1200);
      }
    });
  });
}

function emptyState(message) {
  return `<div class="empty-state">${escapeHtml(message)}</div>`;
}

function renderContactActions(contact) {
  const actions = [
    copyAction("Copy ID", contact.id),
    copyAction("Copy crm get", crmGetCommand(contact.id)),
  ];

  if (contact.email) {
    actions.push(linkAction("Email", `mailto:${contact.email}`));
  }

  const websiteHref = normalizeExternalUrl(contact);
  if (websiteHref) {
    actions.push(linkAction("Open site", websiteHref));
  }

  if (contact.outreachProof) {
    if (/^https?:\/\//i.test(contact.outreachProof)) {
      actions.push(linkAction("Open proof", contact.outreachProof));
    } else {
      actions.push(copyAction("Copy proof", contact.outreachProof));
    }
  }

  return `<div class="contact-actions">${actions.join("")}</div>`;
}

function defaultStage(data) {
  for (const stage of STAGE_PRIORITY) {
    const entry = data.pipeline.find((item) => item.key === stage);
    if (entry && entry.count > 0) return stage;
  }
  return "new_lead";
}

function ensureSelectedStage() {
  if (!state.data) return;
  const exists = state.data.pipeline.some((entry) => entry.key === state.selectedStage);
  if (!exists || !state.selectedStage) {
    state.selectedStage = defaultStage(state.data);
  }
}

function ensureSelectedDay() {
  if (!state.data) return;
  const visibleDays = getVisibleDays();
  const stillVisible = visibleDays.some((day) => day.date === state.selectedDay);
  if (stillVisible) return;

  const today = visibleDays.find((day) => day.date === state.data.calendar.today);
  const firstWithItems = visibleDays.find((day) => day.items.length > 0);
  state.selectedDay = (today || firstWithItems || visibleDays[0] || {}).date || null;
}

function getVisibleDays() {
  if (!state.data) return [];
  if (state.calendarMode === "week") {
    const allowed = new Set(state.data.calendar.weekDates);
    return state.data.calendar.days.filter((day) => allowed.has(day.date));
  }
  return state.data.calendar.days;
}

function getStageContacts() {
  if (!state.data || !state.selectedStage) return [];
  const query = state.contactSearch.trim().toLowerCase();
  const filtered = state.data.contacts
    .filter((contact) => {
      if (contact.funnelStage !== state.selectedStage) return false;
      if (state.contactType === "all") return true;
      return contact.type === state.contactType;
    })
    .filter((contact) => {
      if (!query) return true;
      const haystack = [
        contact.name,
        contact.contactName,
        contact.email,
        contact.regionLabel,
        contact.channelLabel,
        contact.website,
        contact.websiteUrl,
      ]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();
      return haystack.includes(query);
    });

  return filtered.sort((left, right) => {
    const leftUrgency = typeof left.daysUntilNextAction === "number" ? left.daysUntilNextAction : Number.POSITIVE_INFINITY;
    const rightUrgency = typeof right.daysUntilNextAction === "number" ? right.daysUntilNextAction : Number.POSITIVE_INFINITY;
    if (leftUrgency !== rightUrgency) return leftUrgency - rightUrgency;
    if ((right.leadScore || 0) !== (left.leadScore || 0)) return (right.leadScore || 0) - (left.leadScore || 0);
    return left.name.localeCompare(right.name);
  });
}

function dominantStatus(bucket) {
  if (!bucket || bucket.total === 0) return null;
  if (bucket.failed) return "failed";
  if (bucket.pending_review) return "pending_review";
  if (bucket.approved) return "approved";
  if (bucket.sent) return "sent";
  return "not_drafted";
}

function bucketCaption(bucket) {
  if (bucket.failed) return "failed";
  if (bucket.pending_review) return "pending";
  if (bucket.approved) return "queued";
  if (bucket.sent) return "sent";
  return "empty";
}

function renderHeadlineStats() {
  if (!state.data) {
    elements.headlineStats.innerHTML = "";
    return;
  }

  const summary = state.data.summary;
  const cards = [
    {
      value: summary.totalContacts,
      label: "Total contacts",
      note: `${summary.propertyManagers} PMs • ${summary.influencers} influencers`,
    },
    {
      value: summary.followUpsDueNow,
      label: "Follow-ups due now",
      note: summary.overdueFollowUps ? `${summary.overdueFollowUps} already overdue` : "Nothing overdue yet",
    },
    {
      value: summary.approvedQueued,
      label: "Send queued",
      note: summary.failedQueue ? `${summary.failedQueue} failed sends need checking` : "Queue is clean",
    },
    {
      value: summary.sentToday,
      label: "Sent today",
      note: "Pulled from queue and send log",
    },
  ];

  elements.headlineStats.innerHTML = cards
    .map(
      (card) => `
        <article class="stat-card">
          <strong>${escapeHtml(card.value)}</strong>
          <span>${escapeHtml(card.label)}</span>
          <small>${escapeHtml(card.note)}</small>
        </article>
      `,
    )
    .join("");
}

function renderHeroBrief() {
  if (!state.data || !elements.heroBrief) return;
  const summary = state.data.summary;
  const metrics = state.data.metrics;
  const cards = [
    {
      eyebrow: "Pressure point",
      title: summary.overdueFollowUps ? `${summary.overdueFollowUps} follow-ups are already late` : "No overdue follow-ups right now",
      note: summary.followUpsDueNow ? `${summary.followUpsDueNow} contacts need attention in the current cadence window.` : "The cadence queue is currently quiet.",
      tone: "brief-alert",
    },
    {
      eyebrow: "Send posture",
      title: summary.approvedQueued ? `${summary.approvedQueued} sends are ready to go` : "Nothing is queued to send",
      note: summary.sentToday ? `${summary.sentToday} sends already landed today.` : "No sends have landed yet today.",
      tone: "brief-steady",
    },
    {
      eyebrow: "Yield signal",
      title: metrics.repliedCount ? `${metrics.repliedCount} replies from ${metrics.contactedCount} touched contacts` : "Still waiting on the first reply wave",
      note: `${formatPercent(metrics.responseRate)} response rate • ${formatPercent(metrics.conversionRate)} conversion rate.`,
      tone: "brief-calm",
    },
  ];

  elements.heroBrief.innerHTML = cards
    .map(
      (card) => `
        <article class="brief-card ${card.tone}">
          <span class="brief-eyebrow">${escapeHtml(card.eyebrow)}</span>
          <strong>${escapeHtml(card.title)}</strong>
          <p>${escapeHtml(card.note)}</p>
        </article>
      `,
    )
    .join("");
}

function renderApprovalSection() {
  if (!state.data) return;
  const approval = state.data.approval;
  const metrics = [
    {
      value: approval.pendingDrafts,
      label: "Awaiting decision",
      note: "Pending in Turf Review",
      tone: "pending",
    },
    {
      value: approval.approvedQueued,
      label: "Send queued",
      note: "Ready for outreach send",
      tone: "approved",
    },
    {
      value: approval.sentToday,
      label: "Sent today",
      note: "Queue plus send log",
      tone: "sent",
    },
    {
      value: approval.failedQueue,
      label: "Failed sends",
      note: "Needs retry or cleanup",
      tone: "failed",
    },
  ];

  elements.approvalMetrics.innerHTML = metrics
    .map(
      (metric) => `
        <article class="metric-chip status-${escapeHtml(metric.tone)}">
          <strong>${escapeHtml(metric.value)}</strong>
          <span>${escapeHtml(metric.label)}</span>
          <small>${escapeHtml(metric.note)}</small>
        </article>
      `,
    )
    .join("");

  if (!approval.pendingItems.length) {
    elements.pendingBatches.innerHTML = emptyState("No pending Turf Review batches right now.");
    return;
  }

  elements.pendingBatches.innerHTML = approval.pendingItems
    .map(
      (item) => `
        <a class="batch-link" href="${escapeHtml(item.url)}" target="_blank" rel="noreferrer">
          <div>
            <strong>${escapeHtml(item.title)}</strong>
            <small>
              ${escapeHtml(item.kind ? KIND_LABELS[item.kind] || item.kind.toUpperCase() : "Batch")}
              ${item.batchDate ? ` • ${escapeHtml(item.batchDate)}` : ""}
              • updated ${escapeHtml(item.updatedAt.slice(0, 16).replace("T", " "))}
            </small>
          </div>
          <span class="batch-state">Review</span>
        </a>
      `,
    )
    .join("");
}

function renderFunnel() {
  if (!state.data) return;
  ensureSelectedStage();
  elements.funnelTrack.innerHTML = state.data.pipeline
    .map((entry) => {
      const activeClass = entry.key === state.selectedStage ? "active" : "";
      const share = `${Math.round(entry.share * 100)}% of pipeline`;
      const note =
        entry.key === "follow_up_due"
          ? "Needs operator attention"
          : entry.key === "new_lead"
            ? "Top of funnel inventory"
            : entry.key === "parked"
              ? "Intentionally out of cycle"
              : entry.key === "replied"
                ? "Warmest conversations"
                : "Touched, awaiting movement";
      return `
        <button class="stage-button ${activeClass}" type="button" data-stage="${escapeHtml(entry.key)}">
          <strong class="count">${escapeHtml(entry.count)}</strong>
          <span class="label">${escapeHtml(entry.label)}</span>
          <span class="share">${escapeHtml(share)}</span>
          <small class="stage-note">${escapeHtml(note)}</small>
        </button>
      `;
    })
    .join("");

  elements.funnelTrack.querySelectorAll("[data-stage]").forEach((button) => {
    button.addEventListener("click", () => {
      state.selectedStage = button.getAttribute("data-stage");
      state.detailLimit = 12;
      renderStageDetail();
      renderFunnel();
    });
  });
}

function renderContactFilters(stageContacts) {
  const options = [
    { key: "all", label: "All", count: stageContacts.length },
    {
      key: "pm",
      label: "Property Managers",
      count: stageContacts.filter((contact) => contact.type === "pm").length,
    },
    {
      key: "influencer",
      label: "Influencers",
      count: stageContacts.filter((contact) => contact.type === "influencer").length,
    },
  ].filter((option) => option.key === "all" || option.count > 0);

  if (!options.some((option) => option.key === state.contactType)) {
    state.contactType = "all";
  }

  elements.contactTypeFilter.innerHTML = options
    .map(
      (option) => `
        <button
          class="segment-button ${option.key === state.contactType ? "active" : ""}"
          type="button"
          data-contact-type="${escapeHtml(option.key)}"
        >
          ${escapeHtml(option.label)} (${escapeHtml(option.count)})
        </button>
      `,
    )
    .join("");

  elements.contactTypeFilter.querySelectorAll("[data-contact-type]").forEach((button) => {
    button.addEventListener("click", () => {
      state.contactType = button.getAttribute("data-contact-type");
      state.detailLimit = 12;
      renderStageDetail();
    });
  });
}

function renderStageDetail() {
  if (!state.data || !state.selectedStage) return;
  const stageContacts = state.data.contacts.filter((contact) => contact.funnelStage === state.selectedStage);
  const filteredContacts = getStageContacts();
  const visibleContacts = filteredContacts.slice(0, state.detailLimit);
  const overdueCount = filteredContacts.filter((contact) => typeof contact.daysUntilNextAction === "number" && contact.daysUntilNextAction < 0).length;
  const propertyManagerCount = filteredContacts.filter((contact) => contact.type === "pm").length;
  const influencerCount = filteredContacts.filter((contact) => contact.type === "influencer").length;

  elements.detailStageLabel.textContent = STAGE_LABELS[state.selectedStage] || state.selectedStage;
  elements.detailStageMeta.textContent = `${visibleContacts.length} visible • ${filteredContacts.length} matching • ${stageContacts.length} in stage`;
  renderContactFilters(stageContacts);
  if (elements.contactSearch) {
    elements.contactSearch.value = state.contactSearch;
  }
  if (elements.detailHighlights) {
    elements.detailHighlights.innerHTML = [
      `${propertyManagerCount} PMs`,
      `${influencerCount} influencers`,
      overdueCount ? `${overdueCount} overdue` : "Nothing overdue",
    ]
      .map((value) => `<span class="detail-chip">${escapeHtml(value)}</span>`)
      .join("");
  }

  if (!filteredContacts.length) {
    elements.contactList.innerHTML = emptyState("No contacts match this stage and filter.");
    return;
  }

  elements.contactList.innerHTML = visibleContacts
    .map((contact) => {
      const chips = [
        contact.typeLabel,
        contact.regionLabel,
        contact.channelLabel,
        contact.contactName ? `Contact: ${contact.contactName}` : null,
      ]
        .filter(Boolean)
        .slice(0, 4)
        .map((value) => `<span class="contact-pill">${escapeHtml(value)}</span>`)
        .join("");

      const urgencyClass =
        contact.funnelStage === "follow_up_due" ? '<span class="contact-pill emphasis">Needs action</span>' : "";
      const lastTouch = contact.lastTouchDate ? `Last touch ${contact.lastTouchDate}` : "No outreach logged";
      return `
        <article class="contact-row">
          <div>
            <p class="contact-name">${escapeHtml(contact.name)}</p>
            <div class="contact-meta">
              ${urgencyClass}
              ${chips}
            </div>
            ${renderContactActions(contact)}
          </div>
          <div class="contact-side">
            <strong>${escapeHtml(contact.nextActionSummary)}</strong>
            <small>${escapeHtml(lastTouch)}</small>
          </div>
        </article>
      `;
    })
    .join("") + (
      filteredContacts.length > visibleContacts.length
        ? `
          <button class="load-more-button" id="loadMoreContacts" type="button">
            Show ${Math.min(12, filteredContacts.length - visibleContacts.length)} more contacts
          </button>
        `
        : ""
    );

  bindCopyActions(elements.contactList);
  const loadMoreButton = document.getElementById("loadMoreContacts");
  if (loadMoreButton) {
    loadMoreButton.addEventListener("click", () => {
      state.detailLimit += 12;
      renderStageDetail();
    });
  }
}

function renderWorkList() {
  if (!state.data) return;
  const dueContacts = state.data.contacts
    .filter((contact) => contact.followUpDue)
    .sort((left, right) => {
      const leftDays = typeof left.daysUntilNextAction === "number" ? left.daysUntilNextAction : Number.POSITIVE_INFINITY;
      const rightDays = typeof right.daysUntilNextAction === "number" ? right.daysUntilNextAction : Number.POSITIVE_INFINITY;
      if (leftDays !== rightDays) return leftDays - rightDays;
      return left.name.localeCompare(right.name);
    })
    .slice(0, 8);

  if (!dueContacts.length) {
    elements.workList.innerHTML = emptyState("No due follow-ups right now.");
    return;
  }

  elements.workList.innerHTML = dueContacts
    .map((contact) => {
      const dueLabel =
        typeof contact.daysUntilNextAction === "number" && contact.daysUntilNextAction < 0
          ? `${Math.abs(contact.daysUntilNextAction)}d overdue`
          : contact.nextCadenceDueDate
            ? `Due ${formatShortDate(contact.nextCadenceDueDate)}`
            : "Due now";
      return `
        <article class="stack-card">
          <div class="row-top">
            <div>
              <strong>${escapeHtml(contact.name)}</strong>
              <small>${escapeHtml(contact.nextActionSummary)}</small>
            </div>
            <span class="status-tag ${typeof contact.daysUntilNextAction === "number" && contact.daysUntilNextAction < 0 ? "tone-failed" : "tone-approved"}">${escapeHtml(dueLabel)}</span>
          </div>
          <p>${escapeHtml([contact.typeLabel, contact.regionLabel, contact.contactName].filter(Boolean).join(" • ") || "No extra detail")}</p>
          ${renderContactActions(contact)}
        </article>
      `;
    })
    .join("");

  bindCopyActions(elements.workList);
}

function renderPerformanceMetrics() {
  if (!state.data) return;
  const metrics = state.data.metrics;
  const cards = [
    { label: "Contacted", value: metrics.contactedCount, note: "Touched at least once" },
    { label: "Replied", value: metrics.repliedCount, note: "Any response logged" },
    { label: "Converted", value: metrics.convertedCount, note: "Marked converted" },
    { label: "Response rate", value: formatPercent(metrics.responseRate), note: "Replies / contacted" },
    { label: "Conversion rate", value: formatPercent(metrics.conversionRate), note: "Converted / contacted" },
    {
      label: "Avg reply lag",
      value: metrics.averageDaysToResponse === null ? "n/a" : `${metrics.averageDaysToResponse}d`,
      note: "D0 to first response",
    },
  ];

  elements.performanceMetrics.innerHTML = cards
    .map(
      (card) => `
        <article class="mini-stat">
          <strong>${escapeHtml(card.value)}</strong>
          <span>${escapeHtml(card.label)}</span>
          <small>${escapeHtml(card.note)}</small>
        </article>
      `,
    )
    .join("");
}

function renderRunwayCard() {
  if (!state.data) return;
  const runway = state.data.runway;
  const toneClass = `runway-${runway.status}`;
  const note =
    runway.runwayDays === null
      ? "Daily send rate is paused."
      : runway.exhaustionDate
        ? `At ${runway.dailyRate}/day, current unassigned PM supply runs out around ${formatShortDate(runway.exhaustionDate)}.`
        : "Runway date unavailable.";

  elements.runwayCard.innerHTML = `
    <article class="runway-card ${toneClass}">
      <div class="row-top">
        <div>
          <p class="runway-label">Pipeline runway</p>
          <strong>${escapeHtml(runway.runwayDays === null ? "Paused" : `${runway.runwayDays} days`)}</strong>
        </div>
        <span class="status-tag tone-${escapeHtml(runway.status === "green" ? "sent" : runway.status === "amber" ? "approved" : runway.status === "red" ? "failed" : "not_drafted")}">${escapeHtml(runway.status)}</span>
      </div>
      <p>${escapeHtml(note)}</p>
      <div class="runway-metrics">
        <span><strong>${escapeHtml(runway.newLeads)}</strong> new PM leads</span>
        <span><strong>${escapeHtml(runway.draftedPending)}</strong> pending drafts</span>
        <span><strong>${escapeHtml(runway.available)}</strong> unassigned</span>
      </div>
    </article>
  `;
}

function renderOperatorShortcuts() {
  if (!state.data || !elements.operatorShortcuts) return;
  const examples = state.data.actions.examples;
  const shortcutDetails = {
    backendStatus: "Check source health and sync status.",
    dueNow: "List follow-ups that need action now.",
    stats: "See pipeline totals and response yield.",
    reconcile: "Sync queue and send history with the CRM.",
  };

  elements.operatorShortcuts.innerHTML = Object.entries(examples)
    .map(([key, command]) => {
      const label =
        key === "backendStatus"
          ? "Backend status"
          : key === "dueNow"
            ? "Due now"
            : key === "stats"
              ? "Pipeline stats"
              : "Reconcile";
      return `
        <button class="shortcut-button" type="button" data-copy="${escapeHtml(command)}">
          <span>${escapeHtml(label)}</span>
          <small>${escapeHtml(shortcutDetails[key] || "Run a CRM helper command.")}</small>
        </button>
      `;
    })
    .join("");

  bindCopyActions(elements.operatorShortcuts);
}

function renderRecentResponses() {
  if (!state.data) return;
  const items = state.data.metrics.recentResponses;
  if (!items.length) {
    elements.recentResponses.innerHTML = emptyState("No responses logged yet.");
    return;
  }

  elements.recentResponses.innerHTML = items
    .slice(0, 4)
    .map((item) => `
      <article class="stack-card">
        <div class="row-top">
          <div>
            <strong>${escapeHtml(item.name)}</strong>
            <small>${escapeHtml(item.responseDate ? formatShortDate(item.responseDate) : "Date unknown")}</small>
          </div>
          <span class="status-tag tone-approved">${escapeHtml(item.responseType || item.status || "response")}</span>
        </div>
        <p>${escapeHtml(truncateText(item.summary || "No summary captured.", 180))}</p>
        <div class="contact-actions">
          ${copyAction("Copy ID", item.id)}
          ${copyAction("Copy crm get", crmGetCommand(item.id))}
        </div>
      </article>
    `)
    .join("");

  bindCopyActions(elements.recentResponses);
}

function renderNeedsJimmy() {
  if (!state.data) return;
  const items = state.data.metrics.needsJimmy;
  if (!items.length) {
    elements.needsJimmy.innerHTML = emptyState("No contacts are flagged for Jimmy right now.");
    return;
  }

  elements.needsJimmy.innerHTML = items
    .map((item) => `
      <article class="stack-card">
        <div class="row-top">
          <div>
            <strong>${escapeHtml(item.name)}</strong>
            <small>${escapeHtml(item.contactName ? `Contact: ${item.contactName}` : "No contact name recorded")}</small>
          </div>
          <span class="status-tag tone-failed">${escapeHtml(item.nextFollowUpDate ? formatShortDate(item.nextFollowUpDate) : "No due date")}</span>
        </div>
        <p>${escapeHtml(item.status || "Status not set")}</p>
        <div class="contact-actions">
          ${copyAction("Copy ID", item.id)}
          ${copyAction("Copy crm get", crmGetCommand(item.id))}
        </div>
      </article>
    `)
    .join("");

  bindCopyActions(elements.needsJimmy);
}

function renderCalendarControls() {
  elements.calendarModeToggle.innerHTML = ["week", "month"]
    .map(
      (mode) => `
        <button class="segment-button ${mode === state.calendarMode ? "active" : ""}" type="button" data-calendar-mode="${mode}">
          ${mode === "week" ? "Week" : "Month"}
        </button>
      `,
    )
    .join("");

  elements.calendarModeToggle.querySelectorAll("[data-calendar-mode]").forEach((button) => {
    button.addEventListener("click", () => {
      state.calendarMode = button.getAttribute("data-calendar-mode");
      state.dayDetailLimit = 8;
      ensureSelectedDay();
      renderCalendar();
    });
  });
}

function renderCalendarLegend() {
  const legend = [
    ["sent", "Sent"],
    ["approved", "Send queued"],
    ["pending_review", "Drafted / pending"],
    ["not_drafted", "Not drafted"],
    ["failed", "Failed"],
  ];
  elements.calendarLegend.innerHTML = legend
    .map(
      ([status, label]) => `
        <span class="legend-item">
          <span class="legend-swatch ${STATUS_TONES[status]}"></span>
          ${escapeHtml(label)}
        </span>
      `,
    )
    .join("");
}

function renderCalendarWeekdays(visibleDays) {
  if (state.calendarMode !== "month" && window.innerWidth < 760) {
    elements.calendarWeekdays.innerHTML = "";
    return;
  }

  const weekdayLabels = state.calendarMode === "week" ? visibleDays : visibleDays.slice(0, 7);
  elements.calendarWeekdays.innerHTML = weekdayLabels
    .map((day) => `<div class="calendar-weekday">${escapeHtml(day.weekdayShort)}</div>`)
    .join("");
}

function renderCalendarGrid(visibleDays) {
  elements.calendarGrid.dataset.mode = state.calendarMode;
  if (!visibleDays.length) {
    elements.calendarGrid.innerHTML = emptyState("No calendar data available.");
    return;
  }

  elements.calendarGrid.innerHTML = visibleDays
    .map((day) => {
      const rows = ["d0", "d3", "d7"]
        .map((kind) => {
          const bucket = day.totalsByKind[kind];
          if (!bucket || bucket.total === 0) return "";
          const tone = dominantStatus(bucket);
          return `
            <div class="kind-strip ${STATUS_TONES[tone]}">
              <span>${escapeHtml(KIND_LABELS[kind])}</span>
              <strong>${escapeHtml(bucket.total)}</strong>
              <em>${escapeHtml(bucketCaption(bucket))}</em>
            </div>
          `;
        })
        .filter(Boolean)
        .join("");

      return `
        <button
          class="calendar-day ${day.date === state.selectedDay ? "active" : ""} ${day.isCurrentMonth ? "" : "muted"} ${day.isToday ? "today" : ""}"
          type="button"
          data-date="${escapeHtml(day.date)}"
        >
          <div class="day-header">
            <span>${escapeHtml(day.weekdayShort)}</span>
            <strong>${escapeHtml(day.dayNumber)}</strong>
          </div>
          <div class="day-stack">
            ${rows || '<div class="kind-strip tone-not_drafted"><span>No activity</span><strong>0</strong><em>quiet</em></div>'}
          </div>
        </button>
      `;
    })
    .join("");

  elements.calendarGrid.querySelectorAll("[data-date]").forEach((button) => {
    button.addEventListener("click", () => {
      state.selectedDay = button.getAttribute("data-date");
      state.dayDetailLimit = 8;
      renderCalendar();
    });
  });
}

function renderDayDetail() {
  if (!state.data || !state.selectedDay) {
    elements.dayDetail.innerHTML = emptyState("Pick a day to inspect its send queue and follow-up items.");
    return;
  }

  const day = state.data.calendar.days.find((entry) => entry.date === state.selectedDay);
  if (!day) {
    elements.dayDetail.innerHTML = emptyState("That day is outside the current calendar range.");
    return;
  }

  if (!day.items.length) {
    elements.dayDetail.innerHTML = `
      <h3>${escapeHtml(formatCalendarDate(day.date))}</h3>
      <p>No scheduled sends or follow-up items are currently mapped to this day.</p>
    `;
    return;
  }

  const visibleItems = day.items.slice(0, state.dayDetailLimit);
  const statusCounts = day.items.reduce((acc, item) => {
    const key = item.status || "not_drafted";
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});

  elements.dayDetail.innerHTML = `
    <h3>${escapeHtml(formatCalendarDate(day.date))}</h3>
    <p>${escapeHtml(day.items.length)} item${day.items.length === 1 ? "" : "s"} on this day.</p>
    <div class="day-detail-highlights">
      ${Object.entries(statusCounts)
        .slice(0, 3)
        .map(([status, count]) => `<span class="status-tag ${STATUS_TONES[status] || STATUS_TONES.not_drafted}">${escapeHtml(STATUS_LABELS[status] || status)} · ${escapeHtml(count)}</span>`)
        .join("")}
    </div>
    <div class="day-detail-list">
      ${visibleItems
        .map((item) => {
          const links = [];
          if (item.email) {
            links.push(`<a href="mailto:${escapeHtml(item.email)}">Email</a>`);
          }
          if (item.reviewUrl) {
            links.push(`<a href="${escapeHtml(item.reviewUrl)}" target="_blank" rel="noreferrer">Turf Review</a>`);
          }

          return `
            <article class="day-detail-item">
              <div class="row-top">
                <span class="status-tag ${STATUS_TONES[item.status]}">${escapeHtml(KIND_LABELS[item.kind])} • ${escapeHtml(STATUS_LABELS[item.status])}</span>
                ${item.inferred ? '<span class="status-tag tone-not_drafted">Inferred</span>' : ""}
              </div>
              <h4>${escapeHtml(item.contactName || item.title)}</h4>
              <p>${escapeHtml(truncateText(item.subtitle, 110))}</p>
              ${links.length ? `<div class="detail-links">${links.join("")}</div>` : ""}
            </article>
          `;
        })
        .join("")}
      ${day.items.length > visibleItems.length ? `<button class="load-more-button" id="loadMoreDayItems" type="button">Show ${Math.min(8, day.items.length - visibleItems.length)} more items</button>` : ""}
    </div>
  `;

  const loadMoreDayItems = document.getElementById("loadMoreDayItems");
  if (loadMoreDayItems) {
    loadMoreDayItems.addEventListener("click", () => {
      state.dayDetailLimit += 8;
      renderDayDetail();
    });
  }
}

function renderCalendar() {
  if (!state.data) return;
  ensureSelectedDay();
  const visibleDays = getVisibleDays();
  renderCalendarControls();
  renderCalendarLegend();
  renderCalendarWeekdays(visibleDays);
  renderCalendarGrid(visibleDays);
  renderDayDetail();
}

function renderSourceStatus() {
  if (!state.data) return;
  elements.sourceStatus.innerHTML = state.data.sources
    .map(
      (source) => `
        <article class="source-card ${source.ok ? "ok" : "error"}">
          <strong>${escapeHtml(source.label)}</strong>
          <small>${escapeHtml(source.detail)}</small>
        </article>
      `,
    )
    .join("");

  if (!state.data.warnings.length) {
    elements.warningList.innerHTML = "";
    return;
  }

  elements.warningList.innerHTML = state.data.warnings
    .map((warning) => `<div class="warning-item">${escapeHtml(warning)}</div>`)
    .join("");
}

function renderMeta() {
  if (!state.data) return;
  elements.lastUpdated.textContent = formatDateTime(state.data.generatedAt);
  elements.nextRefresh.textContent = formatCountdown(state.nextRefreshAt - Date.now());
}

function renderAll() {
  renderMeta();
  renderHeroBrief();
  renderHeadlineStats();
  renderApprovalSection();
  renderFunnel();
  renderStageDetail();
  renderWorkList();
  renderPerformanceMetrics();
  renderRunwayCard();
  renderOperatorShortcuts();
  renderRecentResponses();
  renderNeedsJimmy();
  renderCalendar();
  renderSourceStatus();
}

async function fetchDashboard({ fresh = false } = {}) {
  const query = fresh ? "?fresh=1" : "";
  const response = await fetch(`/api/funnel/dashboard${query}`);
  if (!response.ok) {
    throw new Error(`Dashboard request failed with ${response.status}`);
  }
  const payload = await response.json();
  if (payload.error) {
    throw new Error(payload.detail || payload.error);
  }
  state.data = payload;
  ensureSelectedStage();
  ensureSelectedDay();
  renderAll();
}

function armAutoRefresh() {
  clearInterval(state.refreshTimer);
  clearInterval(state.countdownTimer);

  state.nextRefreshAt = Date.now() + REFRESH_INTERVAL_MS;
  state.refreshTimer = setInterval(async () => {
    try {
      await fetchDashboard({ fresh: true });
    } catch (error) {
      console.error(error);
    } finally {
      state.nextRefreshAt = Date.now() + REFRESH_INTERVAL_MS;
      renderMeta();
    }
  }, REFRESH_INTERVAL_MS);

  state.countdownTimer = setInterval(() => {
    renderMeta();
  }, 1000);
}

async function initialize() {
  renderCalendarLegend();
  renderCalendarControls();
  elements.contactList.innerHTML = emptyState("Loading contacts...");
  elements.workList.innerHTML = emptyState("Loading due work...");
  elements.performanceMetrics.innerHTML = emptyState("Loading performance metrics...");
  elements.runwayCard.innerHTML = emptyState("Loading runway metrics...");
  elements.operatorShortcuts.innerHTML = emptyState("Loading CLI shortcuts...");
  elements.recentResponses.innerHTML = emptyState("Loading recent responses...");
  elements.needsJimmy.innerHTML = emptyState("Loading operator flags...");
  elements.pendingBatches.innerHTML = emptyState("Loading approval data...");
  elements.dayDetail.innerHTML = emptyState("Loading calendar...");

  if (elements.contactSearch) {
    elements.contactSearch.addEventListener("input", (event) => {
      state.contactSearch = event.target.value || "";
      state.detailLimit = 12;
      renderStageDetail();
    });
  }

  try {
    await fetchDashboard();
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    elements.warningList.innerHTML = `<div class="warning-item">Unable to load the dashboard: ${escapeHtml(message)}</div>`;
  }

  armAutoRefresh();
}

elements.refreshButton.addEventListener("click", async () => {
  try {
    await fetchDashboard({ fresh: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    elements.warningList.innerHTML = `<div class="warning-item">Refresh failed: ${escapeHtml(message)}</div>`;
  } finally {
    state.nextRefreshAt = Date.now() + REFRESH_INTERVAL_MS;
    renderMeta();
  }
});

initialize();

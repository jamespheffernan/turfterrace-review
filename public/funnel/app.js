const REFRESH_INTERVAL_MS = 5 * 60 * 1000;
const VIEWS = ["work", "overview", "calendar", "system"];

const state = {
  data: null,
  activeView: "work",
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
  hasHydrated: false,
  refreshState: "idle",
};

const elements = {
  toastStack: document.getElementById("toastStack"),
  statusAnnouncer: document.getElementById("statusAnnouncer"),
  lastUpdated: document.getElementById("lastUpdated"),
  nextRefresh: document.getElementById("nextRefresh"),
  refreshButton: document.getElementById("refreshButton"),
  heroPulse: document.getElementById("heroPulse"),
  heroBrief: document.getElementById("heroBrief"),
  headlineStats: document.getElementById("headlineStats"),
  viewToggle: document.getElementById("viewToggle"),
  approvalSummary: document.getElementById("approvalSummary"),
  approvalMetrics: document.getElementById("approvalMetrics"),
  pendingBatches: document.getElementById("pendingBatches"),
  overviewFunnelTrack: document.getElementById("overviewFunnelTrack"),
  funnelTrack: document.getElementById("funnelTrack"),
  detailStageLabel: document.getElementById("detailStageLabel"),
  detailStageMeta: document.getElementById("detailStageMeta"),
  contactTypeFilter: document.getElementById("contactTypeFilter"),
  contactSearch: document.getElementById("contactSearch"),
  detailHighlights: document.getElementById("detailHighlights"),
  detailOverview: document.getElementById("detailOverview"),
  detailPanel: document.querySelector(".detail-panel"),
  contactList: document.getElementById("contactList"),
  workList: document.getElementById("workList"),
  performanceMetrics: document.getElementById("performanceMetrics"),
  runwayCard: document.getElementById("runwayCard"),
  operatorShortcuts: document.getElementById("operatorShortcuts"),
  recentResponses: document.getElementById("recentResponses"),
  needsJimmy: document.getElementById("needsJimmy"),
  calendarModeToggle: document.getElementById("calendarModeToggle"),
  calendarLegend: document.getElementById("calendarLegend"),
  calendarOverview: document.getElementById("calendarOverview"),
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
const STAGE_PLAYBOOK = {
  new_lead: {
    cue: "Largest untouched inventory",
    move: "Protect quality here. Use this stage to identify the best-fit PMs and keep new names from stalling before first touch.",
  },
  contacted: {
    cue: "Waiting for the first signal back",
    move: "Watch for replies, bounces, and anything that should be escalated or moved back into a cadence task.",
  },
  follow_up_due: {
    cue: "Immediate operator action",
    move: "Prioritize the oldest overdue contacts first, then clear anything due today before opening new work.",
  },
  replied: {
    cue: "Warmest conversations",
    move: "Read for intent fast. Questions and positive responses should get manual handling before more outbound work.",
  },
  parked: {
    cue: "Intentionally out of cycle",
    move: "Keep this lane quiet. Only revisit if the reason for parking has changed or capacity improves.",
  },
};

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function pluralize(count, singular, plural = `${singular}s`) {
  return `${count} ${count === 1 ? singular : plural}`;
}

function delightAttr(index = 0, offset = 0) {
  return `style="--stagger:${index + offset}"`;
}

function announceStatus(message, { tone = "default", toast = true } = {}) {
  if (elements.statusAnnouncer) {
    elements.statusAnnouncer.textContent = "";
    window.setTimeout(() => {
      elements.statusAnnouncer.textContent = message;
    }, 20);
  }

  if (!toast || !elements.toastStack) return;

  const toastElement = document.createElement("div");
  toastElement.className = `toast toast-${tone}`;
  toastElement.textContent = message;
  elements.toastStack.appendChild(toastElement);

  window.setTimeout(() => {
    toastElement.classList.add("is-leaving");
    window.setTimeout(() => toastElement.remove(), 260);
  }, 2400);
}

function pulseElement(element) {
  if (!element) return;
  element.classList.remove("pulse-in");
  void element.offsetWidth;
  element.classList.add("pulse-in");
}

function setRefreshButtonState(mode = "idle") {
  if (!elements.refreshButton) return;
  state.refreshState = mode;
  elements.refreshButton.dataset.state = mode;
  elements.refreshButton.disabled = mode === "loading";

  if (mode === "loading") {
    elements.refreshButton.textContent = "Refreshing...";
  } else if (mode === "success") {
    elements.refreshButton.textContent = "Fresh snapshot";
  } else if (mode === "error") {
    elements.refreshButton.textContent = "Retry refresh";
  } else {
    elements.refreshButton.textContent = "Refresh now";
  }
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

function rankCounts(values) {
  return Object.entries(
    values.reduce((acc, value) => {
      if (!value) return acc;
      acc[value] = (acc[value] || 0) + 1;
      return acc;
    }, {}),
  ).sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]));
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

function stageJumpAction(label, stage) {
  return `<button class="mini-action" type="button" data-jump-stage="${escapeHtml(stage)}">${escapeHtml(label)}</button>`;
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
      const label = button.textContent?.trim() || "Value";
      try {
        await copyText(button.getAttribute("data-copy") || "");
        button.textContent = "Copied";
        announceStatus(`${label} copied`, { tone: "success" });
      } catch (error) {
        console.error(error);
        button.textContent = "Failed";
        announceStatus(`Could not copy ${label.toLowerCase()}`, { tone: "error" });
      } finally {
        window.setTimeout(() => {
          button.innerHTML = originalHtml;
        }, 1200);
      }
    });
  });
}

function bindStageJumpActions(root) {
  root.querySelectorAll("[data-jump-stage]").forEach((button) => {
    button.addEventListener("click", () => {
      const stage = button.getAttribute("data-jump-stage");
      if (!stage) return;
      state.selectedStage = stage;
      state.contactType = "all";
      state.contactSearch = "";
      state.detailLimit = 12;
      renderFunnel();
      renderStageDetail();
      announceStatus(`${STAGE_LABELS[stage] || stage} opened`, { tone: "info", toast: false });
      pulseElement(elements.detailOverview);
      const detailHeading = document.getElementById("stage-detail-heading");
      detailHeading?.scrollIntoView({ behavior: "smooth", block: "start" });
    });
  });
}

function emptyState(message) {
  return `<div class="empty-state delight-reveal" ${delightAttr(0, 1)}>${escapeHtml(message)}</div>`;
}

function parseViewFromLocation() {
  const params = new URLSearchParams(window.location.search);
  const candidate = params.get("view") || window.location.hash.replace("#", "");
  return VIEWS.includes(candidate) ? candidate : "work";
}

function updateViewUrl() {
  const url = new URL(window.location.href);
  url.searchParams.set("view", state.activeView);
  url.hash = state.activeView;
  window.history.replaceState({}, "", url);
}

function renderViewToggle() {
  if (!elements.viewToggle) return;
  const labels = {
    work: "Work queue",
    overview: "Overview",
    calendar: "Calendar",
    system: "System",
  };

  elements.viewToggle.innerHTML = VIEWS
    .map(
      (view) => `
        <button class="segment-button ${state.activeView === view ? "active" : ""}" type="button" data-view-toggle="${view}">
          ${escapeHtml(labels[view])}
        </button>
      `,
    )
    .join("");

  elements.viewToggle.querySelectorAll("[data-view-toggle]").forEach((button) => {
    button.addEventListener("click", () => {
      const nextView = button.getAttribute("data-view-toggle");
      if (!nextView || nextView === state.activeView) return;
      state.activeView = nextView;
      updateViewUrl();
      applyActiveView({ scroll: true });
      announceStatus(`${labels[nextView]} in view`, { tone: "info", toast: false });
    });
  });
}

function applyActiveView({ scroll = false } = {}) {
  document.querySelectorAll("[data-view]").forEach((section) => {
    const views = (section.getAttribute("data-view") || "").split(/\s+/).filter(Boolean);
    const isVisible = views.includes(state.activeView);
    section.hidden = !isVisible;
  });
  renderViewToggle();
  renderHeroPulse();
  pulseElement(elements.heroPulse?.firstElementChild || elements.heroPulse);
  if (scroll) {
    window.scrollTo({ top: 0, behavior: "smooth" });
  }
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
      (card, index) => `
        <article class="stat-card delight-reveal" ${delightAttr(index, 4)}>
          <strong>${escapeHtml(card.value)}</strong>
          <span>${escapeHtml(card.label)}</span>
          <small>${escapeHtml(card.note)}</small>
        </article>
      `,
    )
    .join("");
}

function renderHeroPulse() {
  if (!state.data || !elements.heroPulse) return;

  const { summary, metrics, runway, calendar, warnings, sources } = state.data;
  const nextBusyDay = calendar.days.find((day) => day.items.length > 0 && day.date >= calendar.today);
  const pendingDay = calendar.days.find((day) => day.items.some((item) => item.status === "pending_review" || item.status === "approved"));
  const sourceIssues = sources.filter((source) => !source.ok).length;
  const viewLabels = {
    overview: "Overview",
    work: "Work queue",
    calendar: "Calendar",
    system: "System",
  };

  let label = "Overview focus";
  let title = "Cadence is settled enough to look for the next best move.";
  let tone = "calm";
  let tags = [
    `${pluralize(summary.followUpsDueNow, "follow-up")} due`,
    `${pluralize(summary.approvedQueued, "send")} queued`,
    `${runway.runwayDays === null ? "Runway paused" : `${runway.runwayDays} day runway`}`,
  ];

  if (state.activeView === "work") {
    label = "Work queue focus";
    if (summary.followUpsDueNow) {
      title = `${pluralize(summary.followUpsDueNow, "contact")} need action now. Start with the oldest overdue follow-ups.`;
      tone = "alert";
    } else {
      title = "The queue is clear enough to open fresh outreach or tighten review decisions.";
      tone = "calm";
    }
    tags = [
      `${pluralize(summary.overdueFollowUps, "overdue item", "overdue items")}`,
      `${pluralize(summary.approvedQueued, "ready send", "ready sends")}`,
      `${pluralize(metrics.repliedCount, "reply")} waiting`,
    ];
  } else if (state.activeView === "calendar") {
    label = "Calendar focus";
    if (nextBusyDay) {
      title = `${formatShortDate(nextBusyDay.date)} is the next busy day with ${pluralize(nextBusyDay.items.length, "scheduled item")}.`;
      tone = nextBusyDay.date === calendar.today ? "warm" : "steady";
    } else {
      title = "The calendar is quiet. There is room to stage cleaner send windows.";
      tone = "calm";
    }
    tags = [
      pendingDay ? `${formatShortDate(pendingDay.date)} has pending work` : "No pending review dates",
      `${pluralize(calendar.days.filter((day) => day.items.length > 0).length, "active day")} visible`,
      `${state.calendarMode === "month" ? "Month lens" : "Week lens"}`,
    ];
  } else if (state.activeView === "system") {
    label = "System focus";
    if (warnings.length || sourceIssues) {
      title = `${pluralize(warnings.length || sourceIssues, "signal")} need checking before you trust the whole snapshot.`;
      tone = "alert";
    } else {
      title = "All tracked sources are checking in cleanly right now.";
      tone = "calm";
    }
    tags = [
      `${pluralize(sourceIssues, "source issue")}`,
      warnings.length ? `${pluralize(warnings.length, "warning")}` : "No warnings",
      `${pluralize(state.data.sources.length, "tracked source")}`,
    ];
  } else if (summary.overdueFollowUps) {
    title = `${pluralize(summary.overdueFollowUps, "follow-up")} already slipped past due. Clear the oldest cadence work first.`;
    tone = "alert";
    tags = [
      `${pluralize(summary.followUpsDueNow, "contact")} due now`,
      `${pluralize(summary.approvedQueued, "send")} queued`,
      `${formatPercent(metrics.responseRate)} reply rate`,
    ];
  } else if (summary.approvedQueued) {
    title = `${pluralize(summary.approvedQueued, "send")} are ready to move. Decision work can become outbound today.`;
    tone = "steady";
    tags = [
      `${pluralize(summary.sentToday, "send")} already sent`,
      `${pluralize(summary.followUpsDueNow, "follow-up")} still due`,
      `${runway.runwayDays === null ? "Runway paused" : `${runway.runwayDays} day runway`}`,
    ];
  } else if (metrics.repliedCount) {
    title = `${pluralize(metrics.repliedCount, "reply")} turned the pipeline warm. Human judgment has the highest leverage now.`;
    tone = "warm";
    tags = [
      `${pluralize(metrics.contactedCount, "contact")} touched`,
      `${formatPercent(metrics.responseRate)} response rate`,
      `${formatPercent(metrics.conversionRate)} conversion rate`,
    ];
  }

  elements.heroPulse.innerHTML = `
    <article class="hero-pulse-card hero-pulse-${tone} delight-reveal" ${delightAttr(0)}>
      <div class="hero-pulse-top">
        <span class="hero-pulse-label">${escapeHtml(label)}</span>
        <span class="hero-pulse-view">${escapeHtml(viewLabels[state.activeView] || state.activeView)}</span>
      </div>
      <strong>${escapeHtml(title)}</strong>
      <div class="hero-pulse-tags">
        ${tags.map((tag) => `<span class="hero-pulse-tag">${escapeHtml(tag)}</span>`).join("")}
      </div>
    </article>
  `;
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
      (card, index) => `
        <article class="brief-card ${card.tone} delight-reveal" ${delightAttr(index, 1)}>
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

  if (elements.approvalSummary) {
    const summaryLine = approval.pendingDrafts
      ? `${approval.pendingDrafts} draft${approval.pendingDrafts === 1 ? "" : "s"} still need a decision before they can move.`
      : approval.approvedQueued
        ? `${approval.approvedQueued} item${approval.approvedQueued === 1 ? "" : "s"} are ready for send.`
        : "No backlog in Turf Review right now.";
    const queueLine = approval.failedQueue
      ? `${approval.failedQueue} failed send${approval.failedQueue === 1 ? "" : "s"} need cleanup.`
      : approval.sentToday
        ? `${approval.sentToday} sends already landed today.`
        : "Send queue is quiet.";
    elements.approvalSummary.innerHTML = `
      <article class="approval-brief-card delight-reveal" ${delightAttr(0, 1)}>
        <span class="approval-brief-label">Decision posture</span>
        <strong>${escapeHtml(summaryLine)}</strong>
        <small>${escapeHtml(queueLine)}</small>
      </article>
    `;
  }

  elements.approvalMetrics.innerHTML = metrics
    .map(
      (metric, index) => `
        <article class="metric-chip status-${escapeHtml(metric.tone)} delight-reveal" ${delightAttr(index, 2)}>
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
      (item, index) => `
        <a class="batch-link delight-reveal" ${delightAttr(index, 6)} href="${escapeHtml(item.url)}" target="_blank" rel="noreferrer">
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
  const maxCount = Math.max(...state.data.pipeline.map((entry) => entry.count), 1);
  elements.funnelTrack.innerHTML = state.data.pipeline
    .map((entry, index) => {
      const activeClass = entry.key === state.selectedStage ? "active" : "";
      const stageContacts = state.data.contacts.filter((contact) => contact.funnelStage === entry.key);
      const pmCount = stageContacts.filter((contact) => contact.type === "pm").length;
      const influencerCount = stageContacts.filter((contact) => contact.type === "influencer").length;
      const overdueCount = stageContacts.filter((contact) => typeof contact.daysUntilNextAction === "number" && contact.daysUntilNextAction < 0).length;
      const share = `${Math.round(entry.share * 100)}% of pipeline`;
      const config =
        entry.key === "follow_up_due"
          ? {
              note: "Needs operator attention",
              cue: overdueCount ? `${overdueCount} already late` : "Cadence attention lane",
              tone: "stage-urgent",
            }
          : entry.key === "new_lead"
            ? {
                note: "Top of funnel inventory",
                cue: pmCount ? `${pmCount} PMs available` : "Fresh inventory",
                tone: "stage-fresh",
              }
            : entry.key === "parked"
              ? {
                  note: "Intentionally out of cycle",
                  cue: "Held back on purpose",
                  tone: "stage-muted",
                }
              : entry.key === "replied"
                ? {
                    note: "Warmest conversations",
                    cue: influencerCount ? `${influencerCount} influencer replies` : "Ready for human judgment",
                    tone: "stage-warm",
                  }
                : {
                    note: "Touched, awaiting movement",
                    cue: "Waiting on first signal",
                    tone: "stage-cool",
                  };
      const meterWidth = Math.max(14, Math.round((entry.count / maxCount) * 100));
      return `
        <button class="stage-button ${activeClass} ${config.tone} delight-reveal" ${delightAttr(index, 3)} type="button" data-stage="${escapeHtml(entry.key)}" aria-pressed="${entry.key === state.selectedStage ? "true" : "false"}">
          <div class="stage-topline">
            <span class="stage-kicker">${escapeHtml(config.cue)}</span>
            <span class="stage-share">${escapeHtml(share)}</span>
          </div>
          <div class="stage-count-row">
            <strong class="count">${escapeHtml(entry.count)}</strong>
            <span class="stage-label-shell">
              <span class="label">${escapeHtml(entry.label)}</span>
              <small class="stage-note">${escapeHtml(config.note)}</small>
            </span>
          </div>
          <div class="stage-meter" aria-hidden="true">
            <span style="width:${meterWidth}%"></span>
          </div>
          <div class="stage-breakdown">
            <span class="stage-break-chip">${escapeHtml(pmCount)} PM</span>
            <span class="stage-break-chip">${escapeHtml(influencerCount)} INF</span>
            ${
              entry.key === "follow_up_due"
                ? `<span class="stage-break-chip stage-break-chip-alert">${escapeHtml(overdueCount)} overdue</span>`
                : `<span class="stage-break-chip">${escapeHtml(stageContacts.length ? "active" : "quiet")}</span>`
            }
          </div>
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
      announceStatus(`${STAGE_LABELS[state.selectedStage] || state.selectedStage} selected`, { tone: "info", toast: false });
      pulseElement(elements.detailPanel);
    });
  });
}

function renderOverviewFunnel() {
  if (!state.data || !elements.overviewFunnelTrack) return;
  const notes = {
    new_lead: "Untouched inventory",
    contacted: "Waiting on signal",
    follow_up_due: "Needs action",
    replied: "Warm conversations",
    parked: "Out of cycle",
  };

  elements.overviewFunnelTrack.innerHTML = state.data.pipeline
    .map((entry, index) => `
      <button class="overview-stage-card delight-reveal" ${delightAttr(index, 2)} type="button" data-overview-stage="${escapeHtml(entry.key)}">
        <span>${escapeHtml(entry.label)}</span>
        <strong>${escapeHtml(entry.count)}</strong>
        <small>${escapeHtml(notes[entry.key] || "Pipeline stage")}</small>
      </button>
    `)
    .join("");

  elements.overviewFunnelTrack.querySelectorAll("[data-overview-stage]").forEach((button) => {
    button.addEventListener("click", () => {
      const stage = button.getAttribute("data-overview-stage");
      if (!stage) return;
      state.selectedStage = stage;
      state.activeView = "work";
      updateViewUrl();
      renderFunnel();
      renderStageDetail();
      applyActiveView({ scroll: true });
      announceStatus(`${STAGE_LABELS[stage] || stage} opened in Work queue`, { tone: "info", toast: false });
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
      pulseElement(elements.contactList);
    });
  });
}

function renderStageDetail() {
  if (!state.data || !state.selectedStage) return;
  const stageContacts = state.data.contacts.filter((contact) => contact.funnelStage === state.selectedStage);
  const filteredContacts = getStageContacts();
  const visibleContacts = filteredContacts.slice(0, state.detailLimit);
  const spotlightContacts = visibleContacts.slice(0, Math.min(3, visibleContacts.length));
  const secondaryContacts = visibleContacts.slice(spotlightContacts.length);
  const overdueCount = filteredContacts.filter((contact) => typeof contact.daysUntilNextAction === "number" && contact.daysUntilNextAction < 0).length;
  const propertyManagerCount = filteredContacts.filter((contact) => contact.type === "pm").length;
  const influencerCount = filteredContacts.filter((contact) => contact.type === "influencer").length;
  const topRegions = rankCounts(filteredContacts.map((contact) => contact.regionLabel)).slice(0, 2);
  const topChannels = rankCounts(filteredContacts.map((contact) => contact.channelLabel)).slice(0, 2);
  const playbook = STAGE_PLAYBOOK[state.selectedStage] || {
    cue: "Stage overview",
    move: "Inspect the contacts below and move the lane deliberately.",
  };

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

  if (elements.detailOverview) {
    elements.detailOverview.innerHTML = `
      <article class="detail-brief-card delight-reveal" ${delightAttr(0, 2)}>
        <span class="detail-brief-label">${escapeHtml(playbook.cue)}</span>
        <strong>${escapeHtml(playbook.move)}</strong>
      </article>
      <div class="detail-mini-grid">
        <article class="detail-mini-card delight-reveal" ${delightAttr(1, 2)}>
          <span>Top regions</span>
          <strong>${escapeHtml(topRegions.map(([label]) => label).join(" • ") || "Mixed")}</strong>
          <small>${escapeHtml(topRegions.map(([, count]) => `${count} contacts`).join(" • ") || "No region data")}</small>
        </article>
        <article class="detail-mini-card delight-reveal" ${delightAttr(2, 2)}>
          <span>Top channels</span>
          <strong>${escapeHtml(topChannels.map(([label]) => label).join(" • ") || "Mixed")}</strong>
          <small>${escapeHtml(topChannels.map(([, count]) => `${count} contacts`).join(" • ") || "No channel data")}</small>
        </article>
      </div>
    `;
  }

  if (!filteredContacts.length) {
    elements.contactList.innerHTML = emptyState("No contacts match this stage and filter.");
    return;
  }

  const spotlightMarkup = spotlightContacts
    .map((contact, index) => {
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
        <article class="contact-row contact-row-spotlight delight-reveal" ${delightAttr(index, 3)}>
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
    .join("");

  const compactMarkup = secondaryContacts.length
    ? `
      <div class="compact-list">
        <div class="compact-list-top">
          <strong>More in this lane</strong>
          <span>${escapeHtml(secondaryContacts.length)} additional contacts in view</span>
        </div>
        ${secondaryContacts
          .map((contact, index) => {
            const days = contact.daysUntilNextAction;
            const dueLabel =
              typeof days === "number" && days < 0
                ? `${Math.abs(days)}d overdue`
                : contact.nextCadenceDueDate
                  ? `Due ${formatShortDate(contact.nextCadenceDueDate)}`
                  : contact.nextActionSummary;
            return `
              <article class="compact-contact-row delight-reveal" ${delightAttr(index, 6)}>
                <div class="compact-contact-copy">
                  <strong>${escapeHtml(contact.name)}</strong>
                  <small>${escapeHtml([contact.typeLabel, contact.regionLabel, contact.contactName].filter(Boolean).join(" • ") || "No extra detail")}</small>
                </div>
                <div class="compact-contact-side">
                  <span class="status-tag ${typeof days === "number" && days < 0 ? "tone-failed" : "tone-pending_review"}">${escapeHtml(dueLabel)}</span>
                  <div class="contact-actions">
                    ${copyAction("Copy ID", contact.id)}
                    ${copyAction("CRM", crmGetCommand(contact.id))}
                  </div>
                </div>
              </article>
            `;
          })
          .join("")}
      </div>
    `
    : "";

  const loadMoreMarkup =
    filteredContacts.length > visibleContacts.length
      ? `
        <button class="load-more-button" id="loadMoreContacts" type="button">
          Show ${Math.min(12, filteredContacts.length - visibleContacts.length)} more contacts
        </button>
      `
      : "";

  elements.contactList.innerHTML = `
    <div class="spotlight-stack">${spotlightMarkup}</div>
    ${compactMarkup}
    ${loadMoreMarkup}
  `;

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
    .slice(0, 6);

  if (!dueContacts.length) {
    elements.workList.innerHTML = emptyState("No follow-ups are due right now. The cadence board is clear.");
    return;
  }

  const overdueCount = state.data.contacts.filter((contact) => typeof contact.daysUntilNextAction === "number" && contact.daysUntilNextAction < 0).length;
  const dueSoonCount = state.data.contacts.filter((contact) => typeof contact.daysUntilNextAction === "number" && contact.daysUntilNextAction >= 0 && contact.daysUntilNextAction <= 1).length;

  elements.workList.innerHTML = dueContacts
    .map((contact, index) => {
      const days = contact.daysUntilNextAction;
      const dueLabel =
        typeof days === "number" && days < 0
          ? `${Math.abs(days)}d overdue`
          : contact.nextCadenceDueDate
            ? `Due ${formatShortDate(contact.nextCadenceDueDate)}`
            : "Due now";
      const toneClass = typeof days === "number" && days < 0 ? "tone-failed" : typeof days === "number" && days <= 1 ? "tone-approved" : "tone-pending_review";
      const leadBadge = typeof contact.leadScore === "number" ? `<span class="contact-pill emphasis">Lead ${escapeHtml(contact.leadScore)}</span>` : "";
      return `
        <article class="stack-card task-card ${index === 0 ? "task-card-priority" : ""} delight-reveal" ${delightAttr(index, 3)}>
          <div class="row-top">
            <div>
              <strong>${escapeHtml(contact.name)}</strong>
              <small>${escapeHtml(contact.nextActionSummary)}</small>
            </div>
            <span class="status-tag ${toneClass}">${escapeHtml(dueLabel)}</span>
          </div>
          <div class="contact-meta">
            ${leadBadge}
            <span class="contact-pill">${escapeHtml(contact.typeLabel || "Unknown type")}</span>
            ${contact.regionLabel ? `<span class="contact-pill">${escapeHtml(contact.regionLabel)}</span>` : ""}
            ${contact.contactName ? `<span class="contact-pill">Contact: ${escapeHtml(contact.contactName)}</span>` : ""}
          </div>
          <p>${escapeHtml(contact.lastTouchDate ? `Last touch ${contact.lastTouchDate}` : "No outreach logged yet")}</p>
          <div class="contact-actions">
            ${stageJumpAction("Open stage", "follow_up_due")}
            ${renderContactActions(contact)}
          </div>
        </article>
      `;
    })
    .join("");

  elements.workList.innerHTML = `
    <div class="task-summary">
      <span class="detail-chip">${escapeHtml(overdueCount)} overdue</span>
      <span class="detail-chip">${escapeHtml(dueSoonCount)} due within 24h</span>
      <span class="detail-chip">${escapeHtml(state.data.summary.approvedQueued)} ready to send</span>
    </div>
    ${elements.workList.innerHTML}
  `;

  bindCopyActions(elements.workList);
  bindStageJumpActions(elements.workList);
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

  const narrative = metrics.repliedCount
    ? `${metrics.repliedCount} conversations have moved from outreach into response.`
    : "No responses yet; the pipeline is still in outbound mode.";

  elements.performanceMetrics.innerHTML = `
    <div class="performance-banner delight-reveal" ${delightAttr(0, 2)}>
      <strong>${escapeHtml(narrative)}</strong>
      <span>${escapeHtml(`${formatPercent(metrics.responseRate)} response rate and ${formatPercent(metrics.conversionRate)} conversion rate so far.`)}</span>
    </div>
    ${cards
      .map(
        (card, index) => `
        <article class="mini-stat delight-reveal" ${delightAttr(index, 3)}>
          <strong>${escapeHtml(card.value)}</strong>
          <span>${escapeHtml(card.label)}</span>
          <small>${escapeHtml(card.note)}</small>
        </article>
      `,
      )
    .join("")}
  `;
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
    <article class="runway-card ${toneClass} delight-reveal" ${delightAttr(0, 2)}>
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
    .map(([key, command], index) => {
      const label =
        key === "backendStatus"
          ? "Backend status"
          : key === "dueNow"
            ? "Due now"
            : key === "stats"
              ? "Pipeline stats"
              : "Reconcile";
      return `
        <button class="shortcut-button delight-reveal" ${delightAttr(index, 2)} type="button" data-copy="${escapeHtml(command)}">
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
    elements.recentResponses.innerHTML = emptyState("No responses logged yet. This lane will light up when outreach starts to land.");
    return;
  }

  elements.recentResponses.innerHTML = items
    .slice(0, 4)
    .map((item, index) => `
      <article class="stack-card delight-reveal" ${delightAttr(index, 2)}>
        <div class="row-top">
          <div>
            <strong>${escapeHtml(item.name)}</strong>
            <small>${escapeHtml(item.responseDate ? formatShortDate(item.responseDate) : "Date unknown")}</small>
          </div>
          <span class="status-tag tone-approved">${escapeHtml(item.responseType || item.status || "response")}</span>
        </div>
        <p>${escapeHtml(truncateText(item.summary || "No summary captured.", 180))}</p>
        <div class="contact-actions">
          ${stageJumpAction("Open replied", "replied")}
          ${copyAction("Copy ID", item.id)}
          ${copyAction("Copy crm get", crmGetCommand(item.id))}
        </div>
      </article>
    `)
    .join("");

  bindCopyActions(elements.recentResponses);
  bindStageJumpActions(elements.recentResponses);
}

function renderNeedsJimmy() {
  if (!state.data) return;
  const items = state.data.metrics.needsJimmy;
  if (!items.length) {
    elements.needsJimmy.innerHTML = emptyState("Nothing is escalated right now. Manual attention is clear.");
    return;
  }

  elements.needsJimmy.innerHTML = items
    .slice(0, 5)
    .map((item, index) => `
      <article class="stack-card delight-reveal" ${delightAttr(index, 2)}>
        <div class="row-top">
          <div>
            <strong>${escapeHtml(item.name)}</strong>
            <small>${escapeHtml(item.contactName ? `Contact: ${item.contactName}` : "No contact name recorded")}</small>
          </div>
          <span class="status-tag tone-failed">${escapeHtml(item.nextFollowUpDate ? formatShortDate(item.nextFollowUpDate) : "No due date")}</span>
        </div>
        <p>${escapeHtml(item.status || "Status not set")}</p>
        <div class="contact-actions">
          ${stageJumpAction("Open contacted", "contacted")}
          ${copyAction("Copy ID", item.id)}
          ${copyAction("Copy crm get", crmGetCommand(item.id))}
        </div>
      </article>
    `)
    .join("");

  bindCopyActions(elements.needsJimmy);
  bindStageJumpActions(elements.needsJimmy);
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
      announceStatus(`${state.calendarMode === "week" ? "Week" : "Month"} calendar view`, { tone: "info", toast: false });
      pulseElement(elements.calendarGrid);
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

function renderCalendarOverview() {
  if (!state.data || !elements.calendarOverview) return;
  const days = state.data.calendar.days;
  const today = days.find((day) => day.date === state.data.calendar.today);
  const nextBusyDay = days.find((day) => day.items.length > 0 && day.date >= state.data.calendar.today);
  const pendingDay = days.find((day) => day.items.some((item) => item.status === "pending_review" || item.status === "approved"));
  const summaryCards = [
    {
      label: "Today",
      title: today ? `${today.items.length} scheduled items` : "No day loaded",
      note: today ? (today.items.length ? "Current operational load." : "Quiet day.") : "Missing today snapshot.",
    },
    {
      label: "Next busy day",
      title: nextBusyDay ? `${formatShortDate(nextBusyDay.date)} • ${nextBusyDay.items.length} items` : "No future activity",
      note: nextBusyDay ? "Closest day with cadence activity." : "Calendar is quiet.",
    },
    {
      label: "Pending review on calendar",
      title: pendingDay ? `${formatShortDate(pendingDay.date)} has drafts or queued sends` : "No pending send dates",
      note: pendingDay ? "Useful for checking readiness against schedule." : "Everything scheduled is already resolved.",
    },
  ];

  elements.calendarOverview.innerHTML = summaryCards
    .map(
      (card, index) => `
        <article class="calendar-summary-card delight-reveal" ${delightAttr(index, 1)}>
          <span>${escapeHtml(card.label)}</span>
          <strong>${escapeHtml(card.title)}</strong>
          <small>${escapeHtml(card.note)}</small>
        </article>
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
    .map((day, index) => {
      const activeKinds = ["d0", "d3", "d7"].filter((kind) => {
        const bucket = day.totalsByKind[kind];
        return bucket && bucket.total > 0;
      });
      const rows = state.calendarMode === "month"
        ? (() => {
            if (!activeKinds.length) {
              return '<div class="kind-strip kind-strip-summary tone-not_drafted"><span>No activity</span><strong>0</strong><em>quiet</em></div>';
            }
            const primaryKind = activeKinds.reduce((best, kind) => {
              if (!best) return kind;
              return day.totalsByKind[kind].total > day.totalsByKind[best].total ? kind : best;
            }, null);
            const primaryBucket = day.totalsByKind[primaryKind];
            const tone = dominantStatus(primaryBucket);
            const totalItems = activeKinds.reduce((sum, kind) => sum + (day.totalsByKind[kind]?.total || 0), 0);
            const label = activeKinds.length === 1 ? KIND_LABELS[primaryKind] : `${activeKinds.length} cadence steps`;
            return `
              <div class="kind-strip kind-strip-summary ${STATUS_TONES[tone]}">
                <span>${escapeHtml(label)}</span>
                <strong>${escapeHtml(totalItems)}</strong>
                <em>${escapeHtml(bucketCaption(primaryBucket))}</em>
              </div>
            `;
          })()
        : activeKinds
            .map((kind) => {
              const bucket = day.totalsByKind[kind];
              const tone = dominantStatus(bucket);
              return `
                <div class="kind-strip ${STATUS_TONES[tone]}">
                  <span>${escapeHtml(KIND_LABELS[kind])}</span>
                  <strong>${escapeHtml(bucket.total)}</strong>
                  <em>${escapeHtml(bucketCaption(bucket))}</em>
                </div>
              `;
            })
            .join("");

      return `
        <button
          class="calendar-day delight-reveal ${day.date === state.selectedDay ? "active" : ""} ${day.isCurrentMonth ? "" : "muted"} ${day.isToday ? "today" : ""}"
          type="button"
          data-date="${escapeHtml(day.date)}"
          ${delightAttr(index, 1)}
        >
          <div class="day-header">
            <span>${escapeHtml(day.weekdayShort)}</span>
            <strong>${escapeHtml(day.dayNumber)}</strong>
          </div>
          <div class="day-stack">
            ${rows}
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
      pulseElement(elements.dayDetail);
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
  const kindCounts = day.items.reduce((acc, item) => {
    const key = item.kind || "other";
    acc[key] = (acc[key] || 0) + 1;
    return acc;
  }, {});

  elements.dayDetail.innerHTML = `
    <h3 class="delight-reveal" ${delightAttr(0, 1)}>${escapeHtml(formatCalendarDate(day.date))}</h3>
    <p class="delight-reveal" ${delightAttr(1, 1)}>${escapeHtml(day.items.length)} item${day.items.length === 1 ? "" : "s"} on this day.</p>
    <div class="day-detail-highlights">
      ${Object.entries(statusCounts)
        .slice(0, 3)
        .map(([status, count], index) => `<span class="status-tag delight-reveal ${STATUS_TONES[status] || STATUS_TONES.not_drafted}" ${delightAttr(index, 2)}>${escapeHtml(STATUS_LABELS[status] || status)} · ${escapeHtml(count)}</span>`)
        .join("")}
    </div>
    <div class="day-detail-overview">
      ${Object.entries(kindCounts)
        .slice(0, 3)
        .map(([kind, count], index) => `
          <article class="day-overview-card delight-reveal" ${delightAttr(index, 3)}>
            <span>${escapeHtml(KIND_LABELS[kind] || kind.toUpperCase())}</span>
            <strong>${escapeHtml(count)}</strong>
            <small>${escapeHtml(count === 1 ? "item in this cadence step" : "items in this cadence step")}</small>
          </article>
        `)
        .join("")}
    </div>
    <div class="day-detail-list">
      ${visibleItems
        .map((item, index) => {
          const links = [];
          if (item.email) {
            links.push(`<a href="mailto:${escapeHtml(item.email)}">Email</a>`);
          }
          if (item.reviewUrl) {
            links.push(`<a href="${escapeHtml(item.reviewUrl)}" target="_blank" rel="noreferrer">Turf Review</a>`);
          }

          return `
            <article class="day-detail-item delight-reveal" ${delightAttr(index, 4)}>
              <div class="row-top">
                <span class="status-tag ${STATUS_TONES[item.status]}">${escapeHtml(KIND_LABELS[item.kind])} • ${escapeHtml(STATUS_LABELS[item.status])}</span>
                ${item.inferred ? '<span class="status-tag tone-not_drafted">Inferred</span>' : ""}
              </div>
              <h4>${escapeHtml(item.contactName || item.title)}</h4>
              <p>${escapeHtml(truncateText(item.subtitle, 88))}</p>
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
  renderCalendarOverview();
  renderCalendarWeekdays(visibleDays);
  renderCalendarGrid(visibleDays);
  renderDayDetail();
}

function renderSourceStatus() {
  if (!state.data) return;
  elements.sourceStatus.innerHTML = state.data.sources
    .map(
      (source, index) => `
        <article class="source-card ${source.ok ? "ok" : "error"} delight-reveal" ${delightAttr(index, 1)}>
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
    .map((warning, index) => `<div class="warning-item delight-reveal" ${delightAttr(index, 1)}>${escapeHtml(warning)}</div>`)
    .join("");
}

function renderMeta() {
  if (!state.data) return;
  elements.lastUpdated.textContent = formatDateTime(state.data.generatedAt);
  elements.nextRefresh.textContent = formatCountdown(state.nextRefreshAt - Date.now());
}

function renderAll() {
  renderViewToggle();
  renderMeta();
  renderHeroPulse();
  renderHeroBrief();
  renderHeadlineStats();
  renderApprovalSection();
  renderOverviewFunnel();
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
  applyActiveView();

  if (!state.hasHydrated) {
    state.hasHydrated = true;
    window.requestAnimationFrame(() => {
      document.body.classList.add("page-ready");
    });
  }
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

async function performRefresh({ fresh = true, source = "manual" } = {}) {
  const isManual = source === "manual";

  if (isManual) {
    setRefreshButtonState("loading");
  }

  try {
    await fetchDashboard({ fresh });
    pulseElement(elements.heroPulse?.firstElementChild || elements.heroPulse);
    pulseElement(elements.headlineStats);

    if (isManual) {
      setRefreshButtonState("success");
      announceStatus("Fresh funnel snapshot loaded", { tone: "success" });
    } else {
      announceStatus("Funnel snapshot auto-refreshed", { tone: "info", toast: false });
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    elements.warningList.innerHTML = `<div class="warning-item">Refresh failed: ${escapeHtml(message)}</div>`;

    if (isManual) {
      setRefreshButtonState("error");
      announceStatus(`Refresh failed: ${message}`, { tone: "error" });
    } else {
      announceStatus("Background refresh failed", { tone: "error", toast: false });
    }
  } finally {
    state.nextRefreshAt = Date.now() + REFRESH_INTERVAL_MS;
    renderMeta();

    if (isManual) {
      window.setTimeout(() => {
        if (state.refreshState !== "loading") {
          setRefreshButtonState("idle");
        }
      }, 1400);
    }
  }
}

function armAutoRefresh() {
  clearInterval(state.refreshTimer);
  clearInterval(state.countdownTimer);

  state.nextRefreshAt = Date.now() + REFRESH_INTERVAL_MS;
  state.refreshTimer = setInterval(async () => {
    await performRefresh({ fresh: true, source: "auto" });
  }, REFRESH_INTERVAL_MS);

  state.countdownTimer = setInterval(() => {
    renderMeta();
  }, 1000);
}

async function initialize() {
  state.activeView = parseViewFromLocation();
  setRefreshButtonState("idle");
  renderCalendarLegend();
  renderCalendarControls();
  renderViewToggle();
  elements.contactList.innerHTML = emptyState("Loading contacts...");
  elements.workList.innerHTML = emptyState("Loading due work...");
  elements.performanceMetrics.innerHTML = emptyState("Loading performance metrics...");
  elements.runwayCard.innerHTML = emptyState("Loading runway metrics...");
  elements.operatorShortcuts.innerHTML = emptyState("Loading CLI shortcuts...");
  elements.recentResponses.innerHTML = emptyState("Loading recent responses...");
  elements.needsJimmy.innerHTML = emptyState("Loading operator flags...");
  elements.pendingBatches.innerHTML = emptyState("Loading approval data...");
  elements.dayDetail.innerHTML = emptyState("Loading calendar...");
  if (elements.detailOverview) {
    elements.detailOverview.innerHTML = emptyState("Loading stage summary...");
  }
  if (elements.calendarOverview) {
    elements.calendarOverview.innerHTML = emptyState("Loading calendar summary...");
  }

  if (elements.contactSearch) {
    elements.contactSearch.addEventListener("input", (event) => {
      state.contactSearch = event.target.value || "";
      state.detailLimit = 12;
      renderStageDetail();
    });
  }

  try {
    await fetchDashboard();
    announceStatus("Funnel dashboard ready", { tone: "success", toast: false });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    elements.warningList.innerHTML = `<div class="warning-item">Unable to load the dashboard: ${escapeHtml(message)}</div>`;
  }

  armAutoRefresh();
}

elements.refreshButton.addEventListener("click", async () => {
  await performRefresh({ fresh: true, source: "manual" });
});

window.addEventListener("popstate", () => {
  state.activeView = parseViewFromLocation();
  applyActiveView();
});

initialize();

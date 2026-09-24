const EXECUTOR_KINDS = Object.freeze({
  'openclaw-build': ['agent_build', 'codex_implementation'],
  'openclaw-followup': ['agent_followup'],
  'openclaw-rework': ['agent_rework'],
  omnifocus: ['create_omnifocus_task'],
  calendar: ['create_calendar_event'],
  outreach: ['outreach_approval', 'send_message'],
  'confirmation-review': ['sensitive_confirmation'],
  'clarification-review': ['decision_clarification'],
  'origin-session': ['origin_decision_notice'],
});

function executorForRequestKind(kind) {
  const normalized = String(kind || '').trim();
  for (const [executor, kinds] of Object.entries(EXECUTOR_KINDS)) {
    if (kinds.includes(normalized)) return executor;
  }
  return 'openclaw-followup';
}

module.exports = {
  EXECUTOR_KINDS,
  executorForRequestKind,
};

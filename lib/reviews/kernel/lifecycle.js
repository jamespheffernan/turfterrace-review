function nowSql() {
  return new Date().toISOString().slice(0, 19).replace('T', ' ');
}

function stringifyPayload(payload) {
  if (payload === undefined || payload === null) return '{}';
  return JSON.stringify(payload);
}

function appendReviewEvent(stmts, slug, event = {}) {
  if (!stmts?.insertReviewEvent) throw new Error('insertReviewEvent statement is required');
  const eventType = String(event.eventType || event.event_type || event.transition || '').trim();
  if (!slug) throw new Error('slug is required');
  if (!eventType) throw new Error('eventType is required');

  return stmts.insertReviewEvent.run({
    slug,
    event_type: eventType,
    actor: event.actor || 'system',
    source: event.source || 'kernel',
    transition: event.transition || eventType,
    payload_json: stringifyPayload(event.payload),
    proof_ref: event.proofRef || event.proof_ref || null,
    provenance: event.provenance || 'live',
  });
}

function listReviewEvents(stmts, slug) {
  if (!stmts?.listReviewEventsForSlug) throw new Error('listReviewEventsForSlug statement is required');
  return stmts.listReviewEventsForSlug.all(slug);
}

function replayWorkflowState(events = []) {
  let state = 'unknown';
  let publicVerification = 'unverified';
  for (const event of events) {
    const type = event.event_type || event.eventType || event.transition;
    if (!type) continue;
    state = type;
    if (type === 'public_verified') publicVerification = 'verified';
    if (type === 'public_verification_failed') publicVerification = 'failed';
  }
  return {
    state,
    publicVerification,
    eventCount: events.length,
  };
}

function appendEventAndProject(db, stmts, slug, event = {}) {
  const tx = db.transaction(() => {
    appendReviewEvent(stmts, slug, event);
    if (stmts.updateItemWorkflowState) {
      stmts.updateItemWorkflowState.run({
        slug,
        workflow_state: event.transition || event.eventType || event.event_type,
        public_verification_status: event.publicVerificationStatus || null,
        public_verification_message: event.publicVerificationMessage || null,
        public_verification_checked_at: event.publicVerificationStatus ? nowSql() : null,
      });
    }
  });
  return tx();
}

module.exports = {
  appendEventAndProject,
  appendReviewEvent,
  listReviewEvents,
  replayWorkflowState,
};

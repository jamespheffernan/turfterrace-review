const { getActionPolicy } = require('./action-policy');
const { replayWorkflowState } = require('./lifecycle');

function parseProof(row) {
  if (!row?.proof_json) return null;
  try {
    return JSON.parse(row.proof_json);
  } catch (_error) {
    return null;
  }
}

function summarizeRequests(requests = []) {
  const byStatus = {};
  for (const request of requests) {
    byStatus[request.status] = (byStatus[request.status] || 0) + 1;
  }
  return {
    total: requests.length,
    byStatus,
    items: requests.map((request) => ({
      id: request.id,
      kind: request.kind,
      status: request.status,
      sensitivity: request.sensitivity,
      summary: request.summary,
      proof: parseProof(request),
      confirmationSlug: request.confirmation_slug || null,
      attempts: request.attempts || 0,
      maxAttempts: request.max_attempts || 0,
      lastError: request.last_error || null,
    })),
  };
}

function summarizeProof(requests = []) {
  const proven = requests.filter((request) => request.proof_json || request.status === 'succeeded').length;
  const blocked = requests.filter((request) => /blocked/.test(String(request.status || ''))).length;
  const failed = requests.filter((request) => request.status === 'failed').length;
  return {
    proven,
    blocked,
    failed,
    complete: requests.length === 0 || (proven + blocked) === requests.length,
  };
}

function buildPublishStatus({ item, reviewTargets, requests = [], events = [] }) {
  if (!item) throw new Error('item is required');
  const replay = replayWorkflowState(events);
  const publicStatus = item.public_verification_status || replay.publicVerification || 'unverified';
  return {
    slug: item.slug,
    title: item.title,
    category: item.category || 'general',
    status: item.status || 'pending',
    workflowState: item.workflow_state || replay.state,
    artifact: {
      type: item.artifact_type || 'markdown',
      url: item.artifact_type === 'custom_html' ? `/review/${item.slug}/artifact/` : null,
      isolated: item.artifact_type === 'custom_html',
    },
    source: {
      workspaceDir: item.workspace_dir || null,
      sourcePath: item.source_path || null,
      provenance: item.source_path ? 'git_tracked_or_declared' : 'missing',
    },
    publicVerification: {
      status: publicStatus,
      message: item.public_verification_message || null,
      checkedAt: item.public_verification_checked_at || null,
    },
    actions: getActionPolicy(item.category),
    targets: reviewTargets?.summary || {
      total: 0,
      approved: 0,
      rejected: 0,
      undecided: 0,
      decided: 0,
      complete: true,
    },
    requests: summarizeRequests(requests),
    proof: summarizeProof(requests),
    events: {
      count: events.length,
      latest: events.length ? events[events.length - 1].event_type : null,
    },
  };
}

module.exports = {
  buildPublishStatus,
  summarizeProof,
  summarizeRequests,
};

function hasSourceProvenance(item) {
  return Boolean(item.workspace_dir && item.source_path);
}

function classifyItem(item) {
  const source = hasSourceProvenance(item) ? 'git_backed_or_declared' : 'missing';
  const schemaVersion = Number(item.decision_schema_version || 1);
  const executable = source !== 'missing' && schemaVersion >= 3;
  const proposedAction = executable ? 'migrate_executable' : 'legacy_readonly';
  const blockedReasons = [];
  if (source === 'missing') blockedReasons.push('missing_source_provenance');
  if (schemaVersion < 3) blockedReasons.push('legacy_decision_schema');

  return {
    slug: item.slug,
    title: item.title,
    category: item.category || 'general',
    status: item.status || 'pending',
    artifactType: item.artifact_type || 'markdown',
    source,
    schemaVersion,
    proposedAction,
    blockedReasons,
  };
}

function auditKernelMigration({ db, stmts }) {
  const rows = stmts?.listAll ? stmts.listAll.all() : db.prepare('SELECT * FROM items ORDER BY created_at DESC').all();
  const items = rows.map(classifyItem);
  return {
    mode: 'audit',
    total: items.length,
    executable: items.filter((item) => item.proposedAction === 'migrate_executable').length,
    legacyReadonly: items.filter((item) => item.proposedAction === 'legacy_readonly').length,
    items,
  };
}

function applyKernelMigration({ db, stmts, backupPath = null }) {
  const report = auditKernelMigration({ db, stmts });
  const marker = `kernel-v1:${new Date().toISOString()}`;
  const tx = db.transaction(() => {
    for (const item of report.items) {
      const existing = db.prepare('SELECT migration_marker FROM items WHERE slug = ?').get(item.slug);
      if (existing?.migration_marker) continue;
      db.prepare(`
        UPDATE items
        SET migration_marker = @marker,
            workflow_state = COALESCE(workflow_state, @workflow_state),
            updated_at = datetime('now')
        WHERE slug = @slug
      `).run({
        slug: item.slug,
        marker,
        workflow_state: item.proposedAction === 'migrate_executable' ? 'migrated' : 'legacy_readonly',
      });
      if (stmts?.insertReviewEvent) {
        stmts.insertReviewEvent.run({
          slug: item.slug,
          event_type: 'migrated',
          actor: 'system',
          source: 'migration',
          transition: item.proposedAction === 'migrate_executable' ? 'migrated' : 'legacy_readonly',
          payload_json: JSON.stringify({
            proposedAction: item.proposedAction,
            blockedReasons: item.blockedReasons,
            backupPath,
          }),
          proof_ref: null,
          provenance: 'migrated',
        });
      }
    }
  });
  tx();
  return {
    ...report,
    applied: true,
    marker,
    backupPath,
  };
}

module.exports = {
  applyKernelMigration,
  auditKernelMigration,
  classifyItem,
};

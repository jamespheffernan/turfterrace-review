function createReviewStatements(db) {
  return {
    insert: db.prepare(`
      INSERT INTO items (
        slug, title, markdown, rendered_html, category, actions, content_hash,
        mindwtr_task_id, mindwtr_project_id, on_approve, session_key, workspace_dir,
        source_path, decision_schema_version
      )
      VALUES (
        @slug, @title, @markdown, @rendered_html, @category, @actions, @content_hash,
        @mindwtr_task_id, @mindwtr_project_id, @on_approve, @session_key, @workspace_dir,
        @source_path, @decision_schema_version
      )
    `),
    getByContentHash: db.prepare('SELECT slug FROM items WHERE content_hash = ? ORDER BY created_at ASC LIMIT 1'),
    getBySlug: db.prepare('SELECT * FROM items WHERE slug = ?'),
    listAll: db.prepare(`
      SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
             session_key, workspace_dir, source_path, decision_schema_version,
             action_status, action_message, approval_status, approval_message, approval_exit_code,
             LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
             created_at, updated_at
      FROM items
      ORDER BY created_at DESC
    `),
    listByStatus: db.prepare(`
      SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
             session_key, workspace_dir, source_path, decision_schema_version,
             action_status, action_message, approval_status, approval_message, approval_exit_code,
             LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
             created_at, updated_at
      FROM items
      WHERE status = ?
      ORDER BY created_at DESC
    `),
    listByCategory: db.prepare(`
      SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
             session_key, workspace_dir, source_path, decision_schema_version,
             action_status, action_message, approval_status, approval_message, approval_exit_code,
             LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
             created_at, updated_at
      FROM items
      WHERE category = ?
      ORDER BY created_at DESC
    `),
    listByStatusAndCategory: db.prepare(`
      SELECT id, slug, title, category, status, decision, actions, feedback, mindwtr_task_id, mindwtr_project_id,
             session_key, workspace_dir, source_path, decision_schema_version,
             action_status, action_message, approval_status, approval_message, approval_exit_code,
             LENGTH(COALESCE(NULLIF(markdown, ''), rendered_html, '')) AS content_length,
             created_at, updated_at
      FROM items
      WHERE status = ? AND category = ?
      ORDER BY created_at DESC
    `),
    decide: db.prepare(`
      UPDATE items
      SET status = @status,
          decision = @decision,
          feedback = @feedback,
          action_status = @action_status,
          action_message = @action_message,
          action_updated_at = datetime('now'),
          approval_status = @action_status,
          approval_message = @action_message,
          approval_exit_code = NULL,
          approval_updated_at = datetime('now'),
          updated_at = datetime('now')
      WHERE slug = @slug
    `),
    dismiss: db.prepare(`UPDATE items SET status = 'dismissed', decision = 'Dismissed', updated_at = datetime('now') WHERE slug = @slug`),
    enqueueOutbox: db.prepare(`INSERT INTO decision_outbox (slug, payload) VALUES (@slug, @payload)`),
    listPendingOutbox: db.prepare(`SELECT id, payload FROM decision_outbox WHERE sent_at IS NULL ORDER BY created_at ASC, id ASC LIMIT @limit`),
    markOutboxSent: db.prepare(`UPDATE decision_outbox SET attempts = attempts + 1, last_error = NULL, sent_at = datetime('now') WHERE id = @id`),
    markOutboxFailed: db.prepare(`UPDATE decision_outbox SET attempts = attempts + 1, last_error = @last_error WHERE id = @id`),
    enqueueAction: db.prepare(`
      INSERT INTO decision_actions (slug, decision, payload, status, max_attempts)
      VALUES (@slug, @decision, @payload, 'queued', COALESCE(@max_attempts, 3))
    `),
    listRunnableActions: db.prepare(`
      SELECT *
      FROM decision_actions
      WHERE status = 'queued'
         OR (
          status = 'failed'
          AND attempts < max_attempts
          AND (next_attempt_at IS NULL OR next_attempt_at <= datetime('now'))
        )
      ORDER BY created_at ASC, id ASC
      LIMIT @limit
    `),
    recoverStaleActions: db.prepare(`
      UPDATE decision_actions
      SET status = 'failed',
          last_error = 'Recovered stale running action after restart',
          next_attempt_at = datetime('now'),
          updated_at = datetime('now')
      WHERE status = 'running'
        AND claimed_at IS NOT NULL
        AND claimed_at <= datetime('now', '-' || @minutes || ' minutes')
    `),
    markActionRunning: db.prepare(`
      UPDATE decision_actions
      SET status = 'running',
          attempts = attempts + 1,
          last_error = NULL,
          claimed_at = datetime('now'),
          completed_at = NULL,
          updated_at = datetime('now')
      WHERE id = @id
        AND (
          status = 'queued'
          OR (
            status = 'failed'
            AND attempts < max_attempts
            AND (next_attempt_at IS NULL OR next_attempt_at <= datetime('now'))
          )
        )
    `),
    markActionDone: db.prepare(`
      UPDATE decision_actions
      SET status = @status,
          last_error = @last_error,
          next_attempt_at = NULL,
          completed_at = datetime('now'),
          updated_at = datetime('now')
      WHERE id = @id
    `),
    markActionFailed: db.prepare(`
      UPDATE decision_actions
      SET status = 'failed',
          last_error = @last_error,
          next_attempt_at = CASE
            WHEN attempts < max_attempts THEN datetime('now', @retry_modifier)
            ELSE NULL
          END,
          completed_at = CASE
            WHEN attempts >= max_attempts THEN datetime('now')
            ELSE NULL
          END,
          updated_at = datetime('now')
      WHERE id = @id
    `),
    getLatestActionForSlug: db.prepare(`
      SELECT *
      FROM decision_actions
      WHERE slug = ?
      ORDER BY created_at DESC, id DESC
      LIMIT 1
    `),
    listActionsForSlug: db.prepare(`
      SELECT id, slug, decision, status, attempts, max_attempts, last_error,
             next_attempt_at, claimed_at, completed_at, created_at, updated_at
      FROM decision_actions
      WHERE slug = ?
      ORDER BY created_at DESC, id DESC
    `),
    listActionsByStatus: db.prepare(`
      SELECT id, slug, decision, status, attempts, max_attempts, last_error,
             next_attempt_at, claimed_at, completed_at, created_at, updated_at
      FROM decision_actions
      WHERE status = ?
      ORDER BY updated_at DESC, created_at DESC
      LIMIT @limit
    `),
    requeueAction: db.prepare(`
      UPDATE decision_actions
      SET status = 'queued',
          attempts = 0,
          last_error = NULL,
          next_attempt_at = NULL,
          claimed_at = NULL,
          completed_at = NULL,
          updated_at = datetime('now')
      WHERE id = @id
    `),
  };
}

module.exports = {
  createReviewStatements,
};

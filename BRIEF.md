# Turf Review Brief

This file is now a durable architecture snapshot, not an open build brief.

## Routing Model

- Decisions are no longer free-text approval buttons.
- Button sets are derived from `category` and enforced on publish and decide.
- Every canonical item uses `decision_schema_version = 2`.

### Canonical category mapping

- `outreach` → `Send`, `Edit`, `Kill`
- `kitchenlux` → `Execute`, `Inbox`, `Rework`, `Park`, `Kill`
- `general` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`
- `admin` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`

## Session Model

- Every item gets a stable OpenClaw session key: `review:{slug}`.
- The same session is reused for:
  - bootstrap context
  - user chat
  - annotation notes
  - decision routing
  - rework/edit loops
- Review chat history is loaded from OpenClaw session history, not local `chat.db`.

## Publish Contract

`POST /api/publish` now requires:

- `title`
- `markdown` or `html`
- valid canonical `category`
- absolute `workspaceDir`
- absolute `sourcePath`

Validation rules:

- `sourcePath` must be inside `workspaceDir`
- `workspaceDir` must be inside a git repo
- `sourcePath` must be git-tracked
- optional `actions`, if supplied, must exactly match the canonical set for the chosen category

## Source of Truth

- New review items should point at the real owning repo/file whenever possible.
- Legacy items without a recoverable source were migrated to the dedicated review-docs repo:
  `/Users/username/GitHub/turfterrace-review-docs`

## Routed Actions

- `Send` keeps the outreach send path and funnel accounting
- `Inbox` creates an OmniFocus inbox item
- `Execute` runs through the linked OpenClaw session in the linked workspace
- `Edit` / `Rework` request updated source from the session, write it back to the tracked file, commit, and republish the same slug
- `Noted`, `Kill`, and `Park` close or park immediately

## Operational Files

- Runtime server: `/Users/username/GitHub/turfterrace-review/server.js`
- Publish client: `/Users/username/GitHub/turfterrace-review/publish-review.sh`
- Migration utility: `/Users/username/GitHub/turfterrace-review/scripts/migrate-pending-items.js`
- Executed migration config: `/Users/username/GitHub/turfterrace-review/scripts/pending-item-migration.json`

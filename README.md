# Turf Review

Review queue and decision surface for Turf Terrace workstreams.

## Current Model

- Review items use canonical category-driven decisions.
- Each item has a stable OpenClaw session key: `review:{slug}`.
- Chat, annotations, decisions, and rework all accumulate in that same session.
- New publishes must include a git-backed `workspaceDir` and `sourcePath`.
- `Edit` and `Rework` operate on tracked source, commit changes, and republish the same slug.
- Routed decisions create durable action records instead of fire-and-forget callbacks.
- Failed or blocked action records are visible on the review page and can be retried.

## Canonical Decisions

- `outreach` → `Send`, `Edit`, `Kill`
- `kitchenlux` → `Execute`, `Inbox`, `Rework`, `Park`, `Kill`
- `general` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`
- `admin` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`

## Important Paths

- App: [server.js](/Users/username/GitHub/turfterrace-review-clean-rebuild/server.js)
- Architecture note: [ARCHITECTURE.md](/Users/username/GitHub/turfterrace-review-clean-rebuild/ARCHITECTURE.md)
- Routing helpers: [lib/review-routing.js](/Users/username/GitHub/turfterrace-review-clean-rebuild/lib/review-routing.js)
- OpenClaw client: [lib/openclaw.js](/Users/username/GitHub/turfterrace-review-clean-rebuild/lib/openclaw.js)
- Chat routes/context: [lib/chat/routes.js](/Users/username/GitHub/turfterrace-review-clean-rebuild/lib/chat/routes.js), [lib/chat/openclaw-context.js](/Users/username/GitHub/turfterrace-review-clean-rebuild/lib/chat/openclaw-context.js)
- Publish script: [publish-review.sh](/Users/username/GitHub/turfterrace-review-clean-rebuild/publish-review.sh)
- Pending-item migration config: [scripts/pending-item-migration.json](/Users/username/GitHub/turfterrace-review-clean-rebuild/scripts/pending-item-migration.json)
- Legacy review-doc source repo: `/Users/username/GitHub/turfterrace-review-docs`

## Legacy Pending Backfill

The 5 previously pending legacy items were moved onto the git-backed review-docs repo and migrated to decision schema v2. That repo is only for documents whose original source was missing or ambiguous. New publishes should still point at the real owning repo when one exists.

## Commands

```bash
npm test
./publish-review.sh path/to/file.md "Title" category
node scripts/migrate-pending-items.js --config scripts/pending-item-migration.json
curl -u "$REVIEW_USER:$REVIEW_PASSWORD" /api/items/:slug/actions
```

For isolated local smoke runs, set `TURF_REVIEW_DATA_DIR` to a temporary directory. Set `OPENCLAW_TOKEN` for review-aware chat and decision execution.

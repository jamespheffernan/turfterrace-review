# Turf Review

Review queue and decision surface for Turf Terrace workstreams.

## Current Model

- Review items use canonical category-driven decisions.
- Each item has a stable OpenClaw session key: `review:{slug}`.
- Chat, annotations, decisions, and rework all accumulate in that same session.
- New publishes must include a git-backed `workspaceDir` and `sourcePath`.
- A decision moves the item out of the pending inbox immediately.
- Decision feedback is decomposed into durable downstream requests.
- Sensitive downstream work creates a new confirmation review before execution.
- Clarification needs create a new clarification review instead of silent failure.
- Durable completion requires authoritative proof from the downstream system.
- Failed or blocked request records are visible on archived review pages and can be retried.

## Canonical Decisions

- `outreach` → `Send`, `Edit`, `Kill`
- `kitchenlux` → `Execute`, `Inbox`, `Rework`, `Park`, `Kill`
- `general` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`
- `admin` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`
- `confirmation` → `Approve`, `Rework`, `Kill`, `No further action`
- `clarification` → `Execute`, `Rework`, `Kill`, `No further action`

## Important Paths

- App: [server.js](/Users/username/GitHub/turfterrace-review/server.js)
- Architecture note: [ARCHITECTURE.md](/Users/username/GitHub/turfterrace-review/ARCHITECTURE.md)
- Routing helpers: [lib/review-routing.js](/Users/username/GitHub/turfterrace-review/lib/review-routing.js)
- Decision contract: [lib/reviews/decision-contract.js](/Users/username/GitHub/turfterrace-review/lib/reviews/decision-contract.js)
- Decision orchestrator: [lib/reviews/orchestrator.js](/Users/username/GitHub/turfterrace-review/lib/reviews/orchestrator.js)
- OpenClaw client: [lib/openclaw.js](/Users/username/GitHub/turfterrace-review/lib/openclaw.js)
- Chat routes/context: [lib/chat/routes.js](/Users/username/GitHub/turfterrace-review/lib/chat/routes.js), [lib/chat/openclaw-context.js](/Users/username/GitHub/turfterrace-review/lib/chat/openclaw-context.js)
- Publish script: [publish-review.sh](/Users/username/GitHub/turfterrace-review/publish-review.sh)
- Pending-item migration config: [scripts/pending-item-migration.json](/Users/username/GitHub/turfterrace-review/scripts/pending-item-migration.json)
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

For isolated local smoke runs, set `TURF_REVIEW_DATA_DIR` to a temporary directory. Set `OPENCLAW_TOKEN` or `OPENCLAW_GATEWAY_TOKEN` for review-aware chat and decision execution.

Set `TURF_REVIEW_WEB_ONLY=1` only when the process should not execute downstream actions or drain Telegram notifications.

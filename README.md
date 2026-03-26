# Turf Review

Review queue and decision surface for Turf Terrace workstreams.

## Current Model

- Review items use canonical category-driven decisions.
- Each item has a stable OpenClaw session key: `review:{slug}`.
- Chat, annotations, decisions, and rework all accumulate in that same session.
- New publishes must include a git-backed `workspaceDir` and `sourcePath`.
- `Edit` and `Rework` operate on tracked source, commit changes, and republish the same slug.

## Canonical Decisions

- `outreach` → `Send`, `Edit`, `Kill`
- `kitchenlux` → `Execute`, `Inbox`, `Rework`, `Park`, `Kill`
- `general` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`
- `admin` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`

## Important Paths

- App: [server.js](/Users/username/GitHub/turfterrace-review/server.js)
- Routing helpers: [lib/review-routing.js](/Users/username/GitHub/turfterrace-review/lib/review-routing.js)
- OpenClaw client: [lib/openclaw.js](/Users/username/GitHub/turfterrace-review/lib/openclaw.js)
- Chat bridge: [lib/db/chat.js](/Users/username/GitHub/turfterrace-review/lib/db/chat.js)
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
```

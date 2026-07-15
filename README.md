# Turf Review

Review queue and decision surface for Turf Terrace workstreams.

## Setup

Turf Review requires Node.js 22.

```bash
npm ci
cp .env.example .env
npm test
npm start
```

Replace the example values in `.env` before exposing the server outside a local development environment. The native SwiftUI client lives in `TurfReviewNative/` and can be opened with Xcode.

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

- App: [server.js](server.js)
- Architecture note: [ARCHITECTURE.md](ARCHITECTURE.md)
- Routing helpers: [lib/review-routing.js](lib/review-routing.js)
- Decision contract: [lib/reviews/decision-contract.js](lib/reviews/decision-contract.js)
- Decision orchestrator: [lib/reviews/orchestrator.js](lib/reviews/orchestrator.js)
- OpenClaw client: [lib/openclaw.js](lib/openclaw.js)
- Chat routes/context: [lib/chat/routes.js](lib/chat/routes.js), [lib/chat/openclaw-context.js](lib/chat/openclaw-context.js)
- Publish script: [publish-review.sh](publish-review.sh)
- Pending-item migration example: [scripts/pending-item-migration.example.json](scripts/pending-item-migration.example.json)
- Native client: [TurfReviewNative](TurfReviewNative)

## Legacy Pending Backfill

The 5 previously pending legacy items were moved onto the git-backed review-docs repo and migrated to decision schema v2. That repo is only for documents whose original source was missing or ambiguous. New publishes should still point at the real owning repo when one exists.

## Commands

```bash
npm test
REVIEW_USER=reviewer REVIEW_PASSWORD='your-password' \
  ./publish-review.sh path/to/file.md "Title" category
node scripts/migrate-pending-items.js --config scripts/pending-item-migration.example.json
curl -u "$REVIEW_USER:$REVIEW_PASSWORD" /api/items/:slug/actions
```

For isolated local smoke runs, set `TURF_REVIEW_DATA_DIR` to a temporary directory. Set `OPENCLAW_TOKEN` or `OPENCLAW_GATEWAY_TOKEN` for review-aware chat and decision execution.

Set `TURF_REVIEW_WEB_ONLY=1` only when the process should not execute downstream actions or drain Telegram notifications.

## Security and Privacy

Do not commit `.env` files, credentials, SQLite databases, review source documents, uploads, generated HTML, or text-to-speech media. The included publish helper reads Basic Auth credentials from `REVIEW_USER` and `REVIEW_PASSWORD`; it does not contain defaults.

## License

No license is currently granted. You may inspect and learn from the source, but reuse requires the copyright holder's permission.

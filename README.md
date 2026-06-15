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
- Software plans can also store the OpenClaw session that drafted the plan.
- Review chat, annotations, and ordinary decisions accumulate in that review session.
- New publishes must include a git-backed `workspaceDir` and `sourcePath`.
- Markdown task-list items and approval/checklist sections become native per-item review targets.
- A decision moves the item out of the pending inbox immediately.
- Decision feedback is decomposed into durable downstream requests.
- Approved software build plans create `agent_build` requests, which run the agent in build mode.
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

## Review Target Format

Use review targets when one document contains several things Jimmy must approve or reject individually: candidate lists, send lists, shortlist options, decision batches, required checks, or any list where one document-level decision is too coarse.

Turf Review extracts native per-item targets from:

- any Markdown task-list item: `- [ ] item text`
- any list item under a heading containing `approval`, `approve`, `reject`, `yes/no`, `yes-no`, `decide`, `decision`, `review target`, `items to review`, `per-item`, or `checklist`

Prefer task-list syntax for new uploads:

```markdown
## Items to review

- [ ] Send follow-up to Alice on Friday
- [ ] Keep Bob in the nurture list
- [ ] Drop the unverified supplier intro
```

Do not use review targets for background notes, ordinary explanatory bullets, or todos that belong in OmniFocus. Put enough text in each item for it to stand alone in the native Items panel.

## Software Build Plans

Turf Review treats a general review as a software build plan when the title or source path says build, implementation, engineering, technical, feature, rebuild, or refactor plan, and the body includes concrete software cues such as files, tests, API work, migrations, routes, components, workers, code fences, or commands.

When Jimmy chooses `Execute`, that review queues an `agent_build` decision request. The request includes the source workspace, source path, document body, feedback, annotations, and review-target judgments. The server and Mac worker send that request to OpenClaw in build mode and require durable proof, a changed artifact, child requests, or a blocker.

If the review has an `originSessionKey`, the build request goes to that drafting session instead of the review session. Turf Review includes the review session key in the payload for context. `Kill`, `Noted`, and `No further action` send a non-consent notice to the origin session and do not execute the plan.

To force the path for a borderline document, include this marker in the Markdown:

```markdown
<!-- turf-review: software-build-plan -->
```

To preserve the drafting session, publish with one of these:

```bash
TURF_REVIEW_ORIGIN_SESSION_KEY="agent:main:review:plan-session" ./publish-review.sh path/to/file.md "Title" general
./publish-review.sh path/to/file.md "Title" general --origin-session "agent:main:review:plan-session"
```

The API also accepts `originSessionKey`, `sourceSessionKey`, or `draftSessionKey`. Markdown can carry `<!-- turf-review-origin-session: agent:main:review:plan-session -->`.

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
./publish-review.sh path/to/file.md "Title" category
./publish-review.sh path/to/file.md "Title" category --origin-session "agent:main:review:plan-session"
node scripts/migrate-pending-items.js --config scripts/pending-item-migration.example.json
curl -u "$REVIEW_USER:$REVIEW_PASSWORD" /api/items/:slug/actions
```

For isolated local smoke runs, set `TURF_REVIEW_DATA_DIR` to a temporary directory. Set `OPENCLAW_TOKEN` or `OPENCLAW_GATEWAY_TOKEN` for review-aware chat and decision execution.

Set `TURF_REVIEW_WEB_ONLY=1` only when the process should not execute downstream actions or drain Telegram notifications.

## Security and Privacy

Do not commit `.env` files, credentials, SQLite databases, review source documents, uploads, generated HTML, or text-to-speech media. The included publish helper reads Basic Auth credentials from `REVIEW_USER` and `REVIEW_PASSWORD`; it does not contain defaults.

## License

No license is currently granted. You may inspect and learn from the source, but reuse requires the copyright holder's permission.

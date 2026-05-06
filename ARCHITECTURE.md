# Turf Review Foundations

Turf Review is Jimmy's review inbox for Benji/Jimmy workflows. A review decision is not complete just because the UI accepted a button click. Each decision must end in one durable outcome:

- verified downstream action completed;
- explicit blocker/clarification delivered through a visible follow-up path;
- intentionally dismissed/no-action terminal state.

SSE is only a notification pipe. Workflow truth lives in SQLite and the authoritative downstream systems.

## Decision Contract

Current review categories keep the existing UX and buttons:

- `outreach`: `Send`, `Edit`, `Kill`
- `kitchenlux`: `Execute`, `Inbox`, `Rework`, `Park`, `Kill`
- `general`: `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`
- `admin`: `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`
- `confirmation`: `Approve`, `Rework`, `Kill`, `No further action`
- `clarification`: `Execute`, `Rework`, `Kill`, `No further action`

Button meanings:

- `Send`: approve the visible outbound copy, recipients, and stated send plan. If any of those are missing, Turf Review creates a clarification review instead of treating the send as approved.
- `Execute`: decompose Jimmy's feedback into concrete downstream requests. Non-sensitive requests run; sensitive requests become confirmation reviews.
- `Inbox`: create an OmniFocus task.
- `Rework` / `Edit`: require feedback, archive the current item, and ask Benji to produce a replacement review.
- `Noted`, `Park`, `No further action`: archive with no downstream action. `Park` is compatibility only; it does not create a managed purgatory.
- `Kill`: terminally kill/archive the item.

Feedback is authoritative. If Jimmy responds to an email approval by asking for a meeting or a task instead, Turf Review records the decision and creates the downstream requests implied by that response.

## Durable Tables

New decisions use the v3 contract:

- `review_intents`: what the review is asking Jimmy to decide, including any stated approval/send plan.
- `decisions`: immutable record of Jimmy's decision text and feedback.
- `decision_requests`: decomposed downstream requests, with status, sensitivity, attempts, and links to follow-up reviews.
- `action_runs`: execution attempts for each request.
- `outcome_proofs`: authoritative proof objects, such as OmniFocus task IDs, Calendar event IDs, send logs, or produced artifacts.
- `notifications`: durable notification queue, currently for Telegram blocker/confirmation messages.

The legacy `decision_outbox` and `decision_actions` tables remain for already-queued legacy rows, but `/api/items/:slug/decide` no longer writes new rows to those side paths.

## Downstream Authorities

- Tasks: OmniFocus via `of task create`; success requires a returned task id.
- Calendar/time blocks: Apple Calendar via AppleScript; success requires an event uid. Ambiguous time requests become clarification reviews.
- Outreach/email: `/Users/username/clawd/scripts/review-decision-ingest.ts` plus the KitchenLux CRM/send database; success requires queued/sent state and, once available, sent email proof.
- Agent/OpenClaw work: session completion is intermediate only. The agent must return structured proof, a produced artifact/report, child requests, or a blocker.
- Source document edits: out of scope for this contract.

## Inbox Semantics

When Jimmy responds, the item leaves the pending inbox immediately and becomes `processed`, `archived`, or `killed`. Processing can continue downstream without keeping the item in the inbox. Old review links remain reachable and show decision/request state.

If a request needs Jimmy:

- Turf Review creates a new `confirmation` or `clarification` item.
- A Telegram notification is queued.
- The original review links to the follow-up item.

If a system action repeatedly fails:

- the request retries silently up to `TURF_REVIEW_ACTION_MAX_ATTEMPTS`;
- after repeated failure it becomes `blocked_system`;
- a Telegram notification is queued with the error and review link.

## Operational Notes

Important environment variables:

- `TURF_REVIEW_DATA_DIR`: use a disposable DB for smoke tests.
- `TURF_REVIEW_WEB_ONLY=1`: disables downstream execution and notification draining.
- `TURF_REVIEW_ACTION_RETRY_SECONDS`: retry delay for failed requests.
- `TURF_REVIEW_ACTION_MAX_ATTEMPTS`: repeated-failure threshold before a system blocker.
- `TURF_REVIEW_EXTERNAL_RECHECK_SECONDS`: recheck delay for waiting external send queues.
- `TURF_REVIEW_BASE_URL`: base URL used in follow-up review and blocker links.
- `TURF_REVIEW_OMNIFOCUS_BIN`, `TURF_REVIEW_CALENDAR_NAME`, `TURF_REVIEW_CLAWD_ROOT`, `TURF_REVIEW_DECISION_INGEST_SCRIPT`, `TURF_REVIEW_KITCHENLUX_CRM_DB`: downstream integration points.

## Smooth Switchover

1. Backup the current production DB files together: `data/reviews.db`, `data/reviews.db-wal`, and `data/reviews.db-shm`.
2. Deploy this code without migrating or deleting existing review items. The schema migration is additive.
3. Run the app against a disposable `TURF_REVIEW_DATA_DIR` first and publish/decide a test review.
4. Confirm a decision writes `decisions` and `decision_requests`, moves the item out of `pending`, and does not enqueue new `decision_outbox` rows.
5. Start production with `TURF_REVIEW_WEB_ONLY` unset when the app process is allowed to execute OmniFocus, Calendar, OpenClaw, and send-queue work. Use `TURF_REVIEW_WEB_ONLY=1` only for display-only hosting.
6. Leave archived/legacy items untouched. Existing links still resolve; old legacy action rows can still be retried from the existing endpoint.
7. Keep the old SSE listener harmless during switchover by relying on the new `review-processed` event. It does not emit the legacy `decision` event for new decisions.

## Validation

Minimum validation before production cutover:

- `npm test`
- local disposable-DB publish/decide smoke
- rendered dashboard/review check in a browser
- one production no-action test item
- one production confirmation/clarification test item that creates a follow-up review

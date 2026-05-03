# Turf Review Clean Rebuild Brief

## Context

Turf Review (`review.turfterrace.com`) was built fast on cursed ground. The product idea is right, but the implementation has accumulated fragile/cursed internals. The goal is a clean rebuild/refactor in this worktree that preserves the current high-level UX while making the system good instead of haunted.

Primary user requirement from Jimmy:

> Ensure we keep the level UX the same, it should just… all be good, instead of bad. For instance I’d like to be able to chat with you within the context of those reviews. That no longer works but was definitely badly engineered to begin with.

## Non-negotiables

- Work only in this worktree: `/Users/username/GitHub/turfterrace-review-clean-rebuild`.
- Do not touch production worktree `/Users/username/GitHub/turfterrace-review`.
- Preserve user-facing UX and routes unless there is a clear reason not to.
- Preserve existing review URLs: `/review/:slug`.
- Preserve publish compatibility with existing `publish-review.sh` / API contract.
- Preserve canonical category decision sets:
  - `outreach` → `Send`, `Edit`, `Kill`
  - `kitchenlux` → `Execute`, `Inbox`, `Rework`, `Park`, `Kill`
  - `general` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`
  - `admin` → `Noted`, `Execute`, `Inbox`, `Rework`, `Kill`
- Preserve stable OpenClaw review session key shape: `review:{slug}`.
- Chat must work inside a review with the review content/context available to Benji/OpenClaw.
- Avoid adding broad secrets or new external dependencies unless justified.

## Product Goal

Turf Review should be the clean review/approval surface for Benji-generated deliverables.

It should support:

1. Review document/content.
2. Make a decision with canonical actions.
3. Leave feedback/annotations.
4. Chat with Benji in the context of that specific review.
5. Preserve the decision/event bridge back into OpenClaw.

Turf Review should **not** be a general file bucket or random dashboard swamp. Large temporary media should move elsewhere later.

## Existing Important Files

- `server.js` — current Express app, too much in one file.
- `views/review.ejs` — current review page UX to preserve.
- `views/dashboard.ejs` — review queue/dashboard.
- `public/styles.css` — current visual design.
- `public/chat.js`, `public/chat.css` — existing chat widget, currently broken/fragile.
- `lib/openclaw.js` — OpenClaw client helpers.
- `lib/db/chat.js` — current chat persistence/bridge.
- `lib/review-routing.js` — canonical decision/routing helpers.
- `test/*.test.js` — existing tests.

## Desired Architecture

Refactor/rebuild into clear modules. Suggested shape:

```text
server.js                    # thin app bootstrap
lib/
  config.js                  # env/config validation
  db.js                      # sqlite connection + migrations
  reviews/
    repository.js            # review CRUD
    routes.js                # review/dashboard/API routes
    render.js                # markdown/html rendering/sanitizing
    decisions.js             # decision handling/outbox
  chat/
    repository.js            # chat persistence if local cache needed
    routes.js                # chat HTTP/WS/SSE endpoints
    openclaw-context.js      # review context packet for OpenClaw
    openclaw-client.js       # OpenClaw API calls / streaming
  uploads/
    routes.js
  middleware/
    auth.js
    csrf.js
    errors.js
public/
  review.js                  # page behavior if needed
  chat.js                    # chat client, simple/reliable
views/
  ...
```

You do not have to use this exact shape, but produce an equivalently clean structure.

## Chat Requirements

This is the first-class rebuild requirement.

Review chat should:

- Appear inside the existing review page sidebar/panel UX.
- Load prior messages for that review.
- Send a user question/message for the review.
- Include review context in the OpenClaw request:
  - slug
  - title
  - category
  - markdown/content excerpt or full content where safe
  - current decision/status
  - allowed actions
  - feedback/annotations where relevant
  - source path/workspace when present
- Use stable session key `review:{slug}` so context and history persist per review.
- Stream or at least show progress clearly.
- Fail gracefully with a visible error if OpenClaw is unavailable.
- Not leak internal bootstrap/system messages into visible chat history.
- Be covered by tests at the helper/API level.

Implementation options:

- Prefer a simple HTTP POST + history endpoint first if WebSocket streaming is cursed.
- Streaming is nice, but correctness/reliability beats fancy streaming.
- If WebSockets remain, make them narrow and well-tested.
- Do not over-engineer a custom chat framework if a simpler robust flow works.

## UX Preservation

Keep the same “level UX”:

- Dashboard/review queue still looks and feels like Turf Review.
- Review page still has document/content as primary surface.
- Decision panel/sidebar remains clear.
- Chat should feel native to the review page, not bolted on.
- Mobile should remain usable.
- Existing auth/login flow should continue unless deliberately improved.

You can improve rough edges, but do not redesign into a totally different product.

## Validation

Minimum required before declaring done:

- `npm test` passes.
- Add/keep tests for:
  - canonical action routing
  - source path/workspace validation if touched
  - chat context packet creation
  - OpenClaw client request shape / session key
  - internal message filtering
- Run a local smoke test if possible:
  - start app on a non-production port
  - open or curl a review page
  - verify chat endpoints respond sanely

## Deliverables

1. Clean rebuild/refactor in this worktree.
2. Passing tests.
3. Short architecture note: what changed and why.
4. Known limitations / follow-up list.
5. Completion notification to Jimmy via Telegram.

## Completion Notification Route

When completely finished, send exactly one message:

```bash
openclaw message send \
  --channel telegram \
  --account default \
  --target '8339963854' \
  --reply-to '16397' \
  --message 'Turf Review clean rebuild Codex pass finished: <brief summary + worktree path + test status>'
```

If fatally blocked, send exactly one failure/blocker message using the same route.
Do not use `openclaw system event`.
Do not rely on heartbeat.

# Turf Review Rebuild Notes

This pass keeps the existing dashboard, review routes, publish contract, and canonical decision sets intact while pulling the fragile pieces into explicit modules.

## What Changed

- `server.js` now delegates configuration, database schema setup, Markdown rendering, source validation, review statements, and chat routing to modules under `lib/`.
- Review data still lives in SQLite with the same tables and API shape. Migrations are centralized in `lib/db.js`.
- Review rendering and sanitizing live in `lib/reviews/render.js`.
- Git workspace/source-path validation lives in `lib/reviews/source-paths.js`.
- Review chat no longer depends on a broad WebSocket module. The browser uses:
  - `GET /api/items/:slug/chat/history`
  - `POST /api/items/:slug/chat`
- Every chat turn builds a review context packet with slug, title, category, status, decision, allowed actions, feedback, annotations, source paths, and document content.
- OpenClaw requests keep the stable session key shape: `review:{slug}`.
- Visible chat history filters developer/tool messages and Turf internal bootstrap notes.
- Decisions that need downstream work now create durable `decision_actions` rows. The action worker claims queued rows, records attempts, retries transient failures, marks terminal `succeeded`/`blocked`/`failed` states, and mirrors status back onto the review item.
- Failed or blocked action rows can be inspected with `GET /api/items/:slug/actions` and manually requeued with `POST /api/items/:slug/action/retry`.

## Operational Notes

- `OPENCLAW_TOKEN` is no longer hardcoded. Without it, the chat panel remains visible and reports that OpenClaw chat is not configured.
- The OpenClaw gateway must have `gateway.http.endpoints.chatCompletions.enabled=true` when Turf Review chat/action execution uses the HTTP bridge.
- `TURF_REVIEW_DATA_DIR` can point the app at a disposable database for smoke tests or isolated local runs.
- `TURF_REVIEW_HOST` can bind the server to a specific host when the environment disallows the default bind.
- Action retry behavior is controlled by `TURF_REVIEW_ACTION_RETRY_SECONDS` and `TURF_REVIEW_ACTION_MAX_ATTEMPTS`.

## Follow-Ups

- The remaining upload, annotation, audio, and decision routes still live in `server.js`; they are narrower now but can be moved into route modules in a later pass.
- Chat is reliable HTTP request/response first. Streaming can be added on top once the simple path stays healthy.
- A broader operations dashboard for failed `decision_actions` would make recurring infrastructure failures easier to spot.

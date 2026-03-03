# Turf Review: Deterministic Control Upgrade

## Philosophy

We run an AI agent (Benji) that manages tasks, publishes documents for human review, and processes approvals. The agent is probabilistic by nature — it doesn't reliably do the same thing every time unless forced to by deterministic structure.

Our design principle (from @alexhillman): **"The most powerful thing in a probabilistic workflow is a sprinkle of deterministic control at the right moment."** Think of this as moving from a loosely-typed to a strongly-typed system. Every place the agent currently has discretion about *how* to do something should be replaced with a script/enum/constraint that makes the correct path the only path.

## System Overview

- **Turf Review** (`~/GitHub/turfterrace-review/`): Express app where Benji publishes markdown documents for Jimmy to review. Jimmy approves/rejects via web UI. Port 3457.
- **Mindwtr**: SQLite-based task manager. DB at `~/Library/Application Support/mindwtr/mindwtr.db`. CLI: `bun ~/clawd/skills/mindwtr/scripts/mw.ts`.
- **OmniFocus sync**: `~/clawd/scripts/sync-mindwtr-to-of.ts` syncs "waiting on Jimmy" tasks to OmniFocus inbox.
- **publish-review.sh**: Shell script that publishes markdown to Turf Review via its API.
- **OpenClaw system events**: The agent receives system events via `openclaw system event --text "..." --mode now`. This is how webhooks reach the agent.

## What to Build

### 1. Approval webhook → OpenClaw system event
When Jimmy hits approve/reject/any decision button on Turf Review, the server should fire an OpenClaw system event so the agent is immediately notified. No polling.

Implementation: In `server.js`, after the `/api/items/:slug/decide` endpoint processes a decision, call out to OpenClaw. The `notifyBenji()` function already exists — check what it does and either fix it or replace it. The system event text should include: decision, item title, slug, feedback (if any), and any linked Mindwtr task/project IDs.

The OpenClaw system event command is:
```bash
/opt/homebrew/bin/openclaw system event --text "REVIEW DECIDED: ..." --mode now
```

### 2. Category enum enforcement
The publish API (`POST /api/publish`) currently accepts any string for `category`. Change it to validate against an allowed list: `kitchenlux`, `outreach`, `admin`, `general`. Reject anything else with a 400 error.

Update `publish-review.sh` to also validate the category argument before sending to the API.

### 3. Mandatory task linkage
For categories other than `general`, require either `taskId` or `projectId` in the publish request. Return 400 if missing. This ensures every non-trivial review item is connected to the project management system.

Update `publish-review.sh` to enforce this too — if category != general and no `--task` or `--project` flag, error out.

### 4. process-approval.sh — deterministic post-approval pipeline
Create `~/clawd/scripts/process-approval.sh` that takes a Turf Review slug and runs the full post-decision pipeline:

1. Fetch the review item from Turf Review API (get decision, feedback, linked task/project)
2. If a Mindwtr task is linked, update its status based on the decision (approved → done, rejected → back to next with feedback note)
3. Prompt for / create the successor task in Mindwtr (the "what's next" after this task completes)
4. Run `sync-mindwtr-to-of.ts` to push any new waiting-on-Jimmy tasks to OmniFocus

This script should be callable both by the agent and by the webhook (so the webhook can optionally trigger it directly).

Script should exit with clear codes: 0 = success, 1 = error, 2 = no linked task (manual processing needed).

### 5. Idempotent publishing
When publishing, compute a content hash (SHA256 of title + markdown). If an item with the same hash already exists, return the existing slug instead of creating a duplicate. Add a `content_hash` column to the items table.

Update `publish-review.sh` to report "Already published: <url>" when dedup kicks in.

### 6. Markdown validation in publish-review.sh
Before sending to the API, the script should validate:
- File is not empty
- File has at least 10 characters of content
- File contains at least one markdown heading (`#`)

Reject with clear error if validation fails.

## Files to Modify

- `~/GitHub/turfterrace-review/server.js` — items 1, 2, 3, 5 (API changes)
- `~/clawd/scripts/publish-review.sh` — items 2, 3, 5, 6 (client-side validation)
- `~/clawd/scripts/process-approval.sh` — item 4 (new file)

## Constraints

- Do NOT break existing functionality. The publish API must remain backward-compatible for items already in the DB.
- The SQLite migration (adding content_hash column) must be safe for existing data.
- Use absolute paths for all CLI calls in scripts (no PATH assumptions — this runs via launchd).
- Keep the Express app as a single `server.js` file — don't refactor into modules.
- Test: after changes, the existing publish flow should still work. A curl to publish with bad category should get 400. A curl to publish without task link for kitchenlux category should get 400.

## Auth for API calls from scripts
Basic auth: `jimmy:JWkx5ba0OOGEqVVc` (already used in publish-review.sh).

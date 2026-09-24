# Turf Review Web Items And Custom HTML Plan

Date: 2026-06-30
Repo: `/Users/username/GitHub/turfterrace-review`

## Goal

Turf Review needs two review-surface upgrades.

1. Web review pages must support item-by-item decisions, matching the native per-item review flow.
2. Turf Review must support custom HTML review artifacts, because many review packets are websites, app mockups, or UI prototypes rather than Markdown documents.

The two features should share the review shell and decision sidebar, but they should not share storage assumptions. Markdown review items can keep using extracted review targets. Custom HTML must become a first-class artifact type.

## Current State

The backend already has most of the item-by-item review contract.

- `lib/reviews/review-targets.js` extracts review targets from Markdown task-list items and approval-style sections such as `## Items to review`.
- `lib/db.js` already creates `review_targets` and `review_target_judgments`.
- `lib/reviews/repository.js` already exposes target upsert, list, and judgment statements.
- `server.js` already exposes `GET /api/items/:slug/targets` and `PATCH /api/items/:slug/targets/:targetKey`.
- `POST /api/items/:slug/decide` already blocks positive decisions while targets remain undecided and includes target judgments in the downstream decision contract.

The web page does not expose that contract yet.

- `GET /review/:slug` renders `views/review.ejs` with `item`, `actions`, `returnTab`, `hasChat`, and `decisionRequests`, but not `reviewTargets`.
- The review page uses a lean item select and then replaces `markdown` with a truthiness sentinel. The render path must not call any helper that re-syncs targets from `item.markdown`, or it will deactivate every target for that slug.
- `views/review.ejs` has document-level decision buttons and feedback, but no target list, target progress, or Yes/No/Clear controls.
- Markdown checkbox inputs are not a reliable rendered control because `lib/reviews/render.js` sanitizes generated HTML and does not allow form controls.

Custom HTML support is currently half-present but unsafe and lossy.

- `POST /api/publish` accepts `markdown` or `html`, but both flow through `renderSourceDocument`.
- `renderSourceDocument` sanitizes HTML with a narrow allowlist, which strips page structure, styles, scripts, most attributes, and therefore breaks custom pages.
- `views/review.ejs` tries to infer full-page HTML by searching sanitized `rendered_html` for `<!DOCTYPE` or `<html`, then uses `srcdoc`. That cannot preserve relative assets and cannot work reliably after sanitization.
- `republishItemFromSource` detects `.html` and `.htm`, but still sends the HTML through the sanitizer.
- `~/clawd/scripts/publish-review.sh` is Markdown-shaped: it requires a Markdown heading and posts a `markdown` payload.

## Architecture

Ship this as two verticals.

### Vertical 1: Web Review Items

Web item support should reuse the existing target model. No schema migration is needed.

Add a review-target panel to the web review page. It should sit above the final decision buttons on pending reviews and appear read-only on decided reviews.

Each target row should show:

- item label
- current state: undecided, approved, or rejected
- Yes, No, and Clear controls while the review is pending
- an optional feedback field, visible when rejected or when feedback already exists
- a compact progress summary such as `2 of 5 decided`

The rendered document may get inline controls where matching is reliable, but the sidebar target panel must be the source of truth. Inline DOM matching can fail when labels repeat or when custom HTML is inside an iframe.

Positive final actions such as `Approve`, `Execute`, and `Send` should be visually disabled while targets remain undecided. The server remains authoritative and keeps the existing 409 guard.

### Vertical 2: Custom HTML Artifacts

Custom HTML needs a first-class artifact model.

Add `artifact_type` to items. Supported v1 values:

- `markdown`
- `custom_html`

For Markdown, keep the current behavior.

For custom HTML:

- store the raw entry HTML in a separate snapshot column such as `artifact_html`
- keep `markdown = ''`
- populate `rendered_html` with a safe plain-text or escaped-summary fallback, because TTS, chat context, and downstream agent payloads already fall back to `item.markdown || item.rendered_html`
- serve the artifact through a URL, not `srcdoc`

The review page should render:

```html
<iframe
  src="/review/<slug>/artifact/"
  sandbox="allow-scripts allow-popups"
  referrerpolicy="no-referrer">
</iframe>
```

Do not include `allow-same-origin`, `allow-forms`, or top navigation in v1. Those permissions can come later only if a concrete review artifact needs them.

Relative assets should work in v1. UI mockups often split HTML, CSS, JS, fonts, and images. Serve them through:

- `GET /review/:slug/artifact/`
- `GET /review/:slug/artifact/*`

Resolve assets from `dirname(source_path)` by default, with an optional `assetRoot` later if needed. Asset reads must enforce:

- absolute-path and realpath containment
- workspace and git-root containment
- git-tracked source files
- path traversal rejection
- extension allowlist
- correct content type plus `X-Content-Type-Options: nosniff`

Remote live websites are out of scope. V1 reviews git-backed HTML snapshots.

The entry HTML snapshot and asset model must stay coherent. The simplest v1 contract is: `artifact_html` stores the publish-time entry snapshot for hashing, fallback text, and provenance, while the artifact route reads the current git-tracked source file and tracked assets from disk. Republish refreshes the snapshot. That avoids a frozen entry page accidentally rendering against live CSS and JS without an explicit refresh.

## Implementation Steps

### 1. Web Review Items

Update `server.js`.

- Add a read-only target reader for render paths, for example `readReviewTargetsForSlug(stmts, slug)`, composed from `stmts.listReviewTargetsForSlug`, `compactReviewTarget`, and `summarizeReviewTargets`.
- In `GET /review/:slug`, call the read-only target reader and pass `reviewTargets` into `review.ejs`.
- In `warmReviewHtmlCache`, call the same read-only target reader.
- Do not call `listReviewTargetsForItem` from render paths. That helper syncs targets from Markdown and would deactivate targets when given the lean review-page item whose `markdown` field is only a sentinel.
- Keep cache invalidation as-is. The target PATCH route already calls `invalidateReviewCache`.

Update `views/review.ejs`.

- Add a `review-targets` block in pending and decided sidebars.
- Emit initial target data in a JSON script tag.
- Add a visible incomplete-target warning near the final action buttons.
- Keep document-level decisions where they are.

Add `public/review-targets.js`.

- Load initial target JSON.
- Render target rows and summary.
- Call `PATCH /api/items/:slug/targets/:targetKey`.
- Use `encodeURIComponent(target.key)` for target keys.
- Preserve feedback draft text while users move between Yes/No/Clear.
- Update the target row, progress summary, and action-button disabled states after each PATCH.
- On final decision 409, show the returned target summary in the page.
- Read the server-provided positive-decision set from page JSON instead of hardcoding `Approve`, `Execute`, or `Send`, so the visual disabled state matches the server guard.

Update `public/styles.css`.

- Style target rows, state chips, segmented Yes/No/Clear controls, rejection feedback, read-only decided states, and mobile layout.
- Keep the controls compact. The review sidebar is an operational surface, not a marketing panel.

Tests:

- Extend `test/review-targets.test.js` for `## Items to review` with task-list items, checked items, and plain bullets.
- Add coverage for clearing a judgment and preserving summary counts.
- Add a regression test or small unit helper proving render-path target reads do not deactivate active targets.
- Add an EJS render smoke test for empty, pending, and decided target states if the template can be rendered without refactoring `server.js`.

### 2. Custom HTML Artifact Model

Update `lib/db.js`.

- Add `artifact_type TEXT NOT NULL DEFAULT 'markdown'`.
- Add `artifact_html TEXT`.
- Optionally add `artifact_asset_root TEXT` if asset roots are supported beyond `dirname(source_path)`.
- Add the new columns to both the `CREATE TABLE` definition and the `ALTER TABLE` migration list. No manual artifact-type backfill is needed because SQLite applies the constant default to existing rows.

Update `lib/reviews/repository.js`.

- Include artifact columns in insert and select statements.
- Include `artifact_type` in list responses so queues can show artifact type.
- Preserve the existing lean review-page select. Include `artifact_type`, but do not include raw `artifact_html` in that select. The artifact content route can use the full item row or a dedicated narrow select.

Update `lib/db.js` content hashing.

- Keep existing Markdown content hashes byte-stable so republishing existing Markdown documents still dedupes.
- If cross-type collision protection is needed, namespace only the custom HTML arm, for example by hashing `custom_html\0${html}` while leaving Markdown as the current body string.
- Do not run a content-hash migration for existing rows.

Add artifact helpers.

- Classify publish payloads by explicit `artifactType`, then by source extension.
- Reject ambiguous payloads.
- Keep Markdown in `renderSourceDocument`.
- Do not send custom HTML through the sanitizer.
- Generate a safe fallback summary for `rendered_html` by stripping HTML tags from the raw artifact snapshot, escaping the result, and capping it at existing context limits.

Update `server.js`.

- Extend `POST /api/publish` to accept `artifactType: "custom_html"` and `html`.
- Treat `.html` and `.htm` source paths as custom HTML when `artifactType` is omitted.
- Add `GET /review/:slug/artifact/` for the entry HTML.
- Add `GET /review/:slug/artifact/*` for tracked relative assets.
- Set strict response headers for artifact routes.
- Replace the current `views/review.ejs` full-page HTML heuristic with `item.artifact_type === "custom_html"`.
- Update `republishItemFromSource` to preserve artifact type by source extension or stored type.
- Serve artifacts after the global `auth` middleware, not through any pre-auth static mount.
- Cache the tracked-file listing or tracked-file checks for each git root during an artifact request, rather than spawning `git ls-files --error-unmatch` once per asset.

Security headers for artifact responses:

```text
Content-Security-Policy: default-src 'none'; img-src <review-origin> data: blob:; style-src <review-origin> 'unsafe-inline'; script-src <review-origin> 'unsafe-inline'; font-src <review-origin> data:; connect-src <review-origin>; frame-ancestors <review-origin>; base-uri 'none'; form-action 'none'
X-Content-Type-Options: nosniff
X-Robots-Tag: noindex
Cache-Control: no-store
```

Derive `<review-origin>` from the request or review base URL. Do not use `'self'` for fetch directives while the iframe omits `allow-same-origin`; the sandbox gives the artifact an opaque origin, and `'self'` would block the relative assets this feature needs to load. Do not add `allow-same-origin` to fix that, because it would re-grant access to the parent app's origin and cookies.

Update publishing tools.

- Update the repo-root `publish-review.sh` if it is still used.
- Update `~/clawd/scripts/publish-review.sh` to support `.html` and `.htm`.
- Skip Markdown heading checks for HTML.
- Post `{ artifactType: "custom_html", html, workspaceDir, sourcePath }`.
- Keep Markdown behavior unchanged.
- Update `~/clawd/scripts/validate-review-source.ts` if it blocks HTML. Treat these home-level script edits as part of the operational rollout, but keep repo changes reviewable here.

Native follow-up:

- Add `artifactType` and `artifactURL` to `TurfModels.swift`.
- For `custom_html`, load the artifact URL in `HTMLDocumentView.swift` instead of wrapping `renderedHTML`.
- Keep per-item overlay support Markdown-only in this pass. HTML review items can use the sidebar target panel if targets exist.

Tests:

- Add artifact-classification unit tests.
- Add DB migration/insert/select tests for `artifact_type` and `artifact_html`.
- Add source-path asset tests for traversal, outside-root rejection, untracked asset rejection, and tracked asset success.
- Add source-path or artifact-asset resolver unit tests directly, even if `server.js` cannot be imported without listening.
- Add API smoke tests if the server can be imported without listening; otherwise keep only the HTTP route checks manual until server startup is refactored.
- Add native decoding tests for `artifact_type` and `artifact_url`.

## Verification

Run the standard test suite:

```bash
npm test
```

Run focused Node tests after adding them:

```bash
node --test test/review-targets.test.js test/source-paths.test.js test/chat-context.test.js test/decision-contract.test.js
```

Run a local web smoke:

```bash
TURF_REVIEW_WEB_ONLY=1 TURF_REVIEW_DISABLE_MEDIA_JOBS=1 npm start
```

Publish a Markdown item packet with targets:

```bash
TURF_REVIEW_BASE_URL=http://localhost:3457 \
~/clawd/scripts/publish-review.sh docs/plans/example-items.md "Items smoke" general --ad-hoc
```

Publish an HTML mockup:

```bash
TURF_REVIEW_BASE_URL=http://localhost:3457 \
~/clawd/scripts/publish-review.sh docs/mockups/option-A.html "HTML mockup smoke" general --ad-hoc
```

Check the artifact route:

```bash
curl -I http://localhost:3457/review/<slug>/artifact/
curl -s http://localhost:3457/review/<slug> | rg 'iframe.*artifact'
curl --path-as-is -I http://localhost:3457/review/<slug>/artifact/../.env
```

Run a browser smoke, not only `curl`, for the custom HTML feature. Use an HTML mockup with separate CSS, JS, image, and font files. Confirm those assets load under the sandbox and CSP, and confirm the artifact cannot read or mutate the parent review app.

Expected outcomes:

- Web review targets render on the page.
- Yes/No/Clear decisions persist after reload.
- Positive final actions cannot complete until all targets are decided.
- Rejected target feedback flows into Rework when no global feedback exists.
- Custom HTML renders as a working page inside an iframe.
- Relative tracked assets load.
- Path traversal and untracked assets fail.
- Markdown publishing continues to behave exactly as before.

## Rollout Order

Ship web items first, but only with the read-only target reader in place. Calling the mutating sync helper from the review-page render path would make this feature data-destructive.

Then ship custom HTML artifacts behind the `artifact_type` model. Do not try to fix HTML by widening the sanitizer. That would mix trusted review UI and untrusted reviewed UI in the same DOM.

## Open Questions

- Should HTML artifact scripts be allowed in v1? The plan allows scripts inside a sandboxed iframe because UI mockups often need interaction. If that feels too broad, make scripts opt-in per artifact.
- Should remote assets be blocked hard or allowed behind a flag? The safer default is to block them and require git-backed snapshots.
- Should `assetRoot` ship in v1? If not, HTML packets must keep relative assets inside the source file's directory. Shared `../assets` and root-relative `/assets` paths will fail under the default `dirname(source_path)` contract.
- Should target judgments be editable after final review decision? The current backend allows it. The web UI should start read-only after final decision unless post-decision correction becomes a real workflow.
- Should custom HTML artifacts support annotations in v1? The plan says no. Add annotations later using an iframe overlay only after the artifact model is stable.

## Claude Opus Review Notes Incorporated

This plan was reviewed with `claude -p --model opus --effort max` after the CLI rejected `--effort ultracode` as an unknown effort value. The critique was saved at `/Users/username/.claude/plans/ultracode-level-plan-review-you-hashed-whisper.md`.

Changes incorporated:

- render paths must use a read-only target reader, not `listReviewTargetsForItem`
- custom HTML CSP must not use `'self'` fetch directives with an opaque sandbox origin
- custom HTML must populate `rendered_html` with a safe summary fallback
- Markdown content hashes must stay stable
- the lean review-page select must not load raw HTML snapshots
- asset traversal checks should use `curl --path-as-is` plus browser CSP smoke tests
- both publish scripts need an explicit ownership decision

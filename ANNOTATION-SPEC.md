# Inline Annotation Feature — Current Spec

## Summary
Turf Review supports inline text/image annotation on review detail pages. One user (Jimmy), zero friction. Select text or tap an image marker, then speak or type the note.

## Interaction Flow

### Text Annotation
1. User selects/highlights text in the review content area
2. On `mouseup` (desktop) or `touchend` (mobile):
   - Capture `window.getSelection()` — extract the quoted text and its position
   - Show a popover anchored near the selection (above or below, whichever has space)
   - Popover contains: a single text input (auto-focused) + a small submit button + a cancel (×) button
   - **Simultaneously**: start Web Speech API recording (`SpeechRecognition`, `lang: 'en-GB'`)
   - Show a subtle red pulse dot next to the input to indicate mic is live
3. Input race — whichever arrives first:
   - **User starts typing** → kill the speech recognition, let them type. Enter submits.
   - **Speech recognition returns result** → fill the text input with transcription. User can edit. Enter submits.
   - **User presses Escape or clicks away** → cancel, discard, remove highlight
4. On submit:
   - POST to `/api/items/:slug/annotate` with `{ quote, comment, charOffset }`
   - Highlight the quoted text permanently (until annotation is deleted)
   - Show the annotation as a subtle inline marker (clickable to reveal comment)
   - Mirror the annotation into the item's OpenClaw session as a hidden internal note so review context accumulates in the same session transcript

### Image Annotation
1. On hover over any `<img>` in review content, show a small annotation button (pin icon or comment icon) in the top-right corner
2. Click the button → open same popover (no quote text, anchor is `image:N` where N is the image index)
3. Same voice + text input race as above
4. On submit: POST with `{ anchor: "image:N", comment }`
5. Show a badge on the image indicating it has an annotation
6. Mirror the annotation into the item's OpenClaw session as a hidden internal note

### Voice Capture Details
- Use `webkitSpeechRecognition` / `SpeechRecognition` (built into Chrome/Safari)
- `continuous: false`, `interimResults: true` (show live transcription in the input as greyed text)
- `lang: 'en-GB'`
- Auto-stops after ~2s silence (browser native behaviour)
- If browser doesn't support it, just skip — text input still works
- Mic permission requested on first use, browser remembers it

## Data Model

### New table: `annotations`
```sql
CREATE TABLE annotations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT NOT NULL,
  quote TEXT,              -- highlighted text (null for image annotations)
  anchor_type TEXT NOT NULL DEFAULT 'text',  -- 'text' or 'image'
  anchor_ref TEXT,         -- char offset for text, image index for images
  comment TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (slug) REFERENCES items(slug)
);
CREATE INDEX idx_annotations_slug ON annotations(slug);
```

## API Endpoints

### POST `/api/items/:slug/annotate`
```json
{
  "quote": "the highlighted text",
  "anchor_type": "text",
  "anchor_ref": "char:1234",
  "comment": "my feedback"
}
```
Returns: `{ id, slug, quote, comment, created_at }`

### GET `/api/items/:slug/annotations`
Returns: array of all annotations for this review

### DELETE `/api/items/:slug/annotations/:id`
Deletes a single annotation

## UI Details

### Popover
- Glass/dark theme consistent with existing TR design
- Appears within 50ms of mouseup (no delay)
- Text input: single line, placeholder "Say or type your note…"
- Red pulse dot (CSS animation) when mic is active
- Compact: ~300px wide max

### Highlights
- Annotated text gets a subtle background highlight (e.g. `rgba(0, 229, 255, 0.15)` — cyan tint matching TR theme)
- Hover on highlight shows the comment in a tooltip
- Click on highlight opens the comment with option to delete

### Image badges
- Small comment count badge, top-right of image
- Click reveals annotations list for that image

## Rendering Annotations on Page Load
- Fetch annotations via GET endpoint on page load
- For text annotations: use `anchor_ref` (char offset) to find and wrap the quoted text in a `<mark>` element
- For image annotations: add badge to the Nth image
- Annotation deletes use `DELETE /api/items/:slug/annotations/:id`

## Edge Cases
- Selection spans multiple paragraphs → still works, quote captures full selection text
- Selection is empty (click without drag) → ignore, don't show popover
- Same text appears multiple times → `anchor_ref` char offset disambiguates
- Annotation text on decided/archived/parked reviews → still allowed (post-decision notes)

## What NOT to build
- No threading/replies on annotations
- No edit (delete + re-annotate if needed)
- No annotation types/categories
- No export (yet)

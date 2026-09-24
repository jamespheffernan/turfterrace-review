---
name: Turf Review native
description: A calm native reading app for reviewing documents and recording decisions on iPhone, iPad and Mac.
colors:
  accent: "#357256"
  accent-dark: "#74C49B"
  accent-fill: "#357256"
  accent-fill-dark: "#357256"
  accent-soft: "rgba(53, 114, 86, 0.12)"
  accent-soft-dark: "rgba(116, 196, 155, 0.16)"
  on-accent: "#FFFFFF"
  destructive: "#BD3629"
  destructive-dark: "#FF8A80"
  destructive-fill: "#BD3629"
  destructive-fill-dark: "#BD3629"
  destructive-soft: "rgba(189, 54, 41, 0.12)"
  destructive-soft-dark: "rgba(255, 138, 128, 0.16)"
  attention: "#955A00"
  attention-dark: "#E9A847"
  attention-soft: "rgba(149, 90, 0, 0.12)"
  attention-soft-dark: "rgba(233, 168, 71, 0.16)"
  muted: "#67676C"
  muted-dark: "#A0A0A7"
  faint: "#AEAEB2"
  faint-dark: "#636366"
  fill: "rgba(118, 118, 128, 0.12)"
  fill-dark: "rgba(118, 118, 128, 0.24)"
  selection: "rgba(53, 114, 86, 0.22)"
  selection-dark: "rgba(116, 196, 155, 0.30)"
  highlight: "rgba(255, 204, 0, 0.32)"
  highlight-dark: "rgba(255, 212, 38, 0.30)"
  highlight-active: "rgba(255, 204, 0, 0.55)"
  highlight-active-dark: "rgba(255, 212, 38, 0.40)"
typography:
  reader-body:
    fontFamily: "ui-serif, \"New York\", Georgia, serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.6
  reader-h1:
    fontFamily: "ui-serif, \"New York\", Georgia, serif"
    fontSize: "min(1.75rem, calc(1rem + 4vw))"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "-0.01em"
  reader-h2:
    fontFamily: "ui-serif, \"New York\", Georgia, serif"
    fontSize: "min(1.33rem, calc(1rem + 2.5vw))"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  reader-h3:
    fontFamily: "ui-serif, \"New York\", Georgia, serif"
    fontSize: "1.125rem"
    fontWeight: 600
    lineHeight: 1.3
  reader-h4:
    fontFamily: "ui-serif, \"New York\", Georgia, serif"
    fontSize: "1rem"
    fontWeight: 600
    lineHeight: 1.4
  reader-table:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "0.875rem"
    fontFeature: "tnum"
  reader-table-header:
    fontFamily: "-apple-system, system-ui, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 600
    letterSpacing: "0.06em"
  reader-code:
    fontFamily: "ui-monospace, \"SF Mono\", Menlo, monospace"
    fontSize: "0.85em"
  reader-pre:
    fontFamily: "ui-monospace, \"SF Mono\", Menlo, monospace"
    fontSize: "0.85rem"
    lineHeight: 1.55
rounded:
  mark: "4px"
  field: "10px"
  card: "14px"
  capsule: "9999px"
spacing:
  xxs: "2px"
  xs: "4px"
  s: "8px"
  m: "12px"
  l: "16px"
  xl: "20px"
  xxl: "24px"
  xxxl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.accent-fill}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.capsule}"
    padding: "8px 16px"
    height: "44px"
  button-kill:
    backgroundColor: "{colors.destructive-fill}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.capsule}"
    padding: "8px 16px"
    height: "44px"
  button-tinted-approved:
    backgroundColor: "{colors.accent-soft}"
    textColor: "{colors.accent}"
    rounded: "{rounded.capsule}"
    padding: "8px 16px"
    height: "44px"
  button-tinted-rejected:
    backgroundColor: "{colors.destructive-soft}"
    textColor: "{colors.destructive}"
    rounded: "{rounded.capsule}"
    padding: "8px 16px"
    height: "44px"
  button-tinted-neutral:
    backgroundColor: "{colors.fill}"
    rounded: "{rounded.capsule}"
    padding: "8px 16px"
    height: "44px"
  field:
    backgroundColor: "{colors.fill}"
    rounded: "{rounded.field}"
  card:
    rounded: "{rounded.card}"
    padding: "{spacing.m}"
  count-badge:
    backgroundColor: "{colors.accent-fill}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.capsule}"
    height: "18px"
---

# Design System: Turf Review native

## Overview

**Creative North Star: "The Reading Library"**

Turf Review is a calm native reading app. The document leads; system navigation, lists, sheets, popovers and SF Symbols stay, and the chrome recedes while you read. The apps run on iPhone, iPad and Mac from one SwiftUI code base, and the reader is HTML in a `WKWebView` styled by CSS that the app generates.

This file describes what shipped. Tokens live in `TurfReviewNative/TurfReviewNative/Support/TurfTheme.swift` (color) and `Support/TurfStyle.swift` (spacing, radius, type, motion, buttons, cards). The reader CSS is in `Support/HTMLDocumentView.swift`. When this file and the code disagree, the code wins; fix this file.

A saved review opens without a server round trip and reads the same with networking off. Check navigation, decisions, annotations and audio in the simulator before release.

**Key Characteristics:**
- One tint. Sea green marks what you can act on and what you approved; nothing else is green.
- One meaning, one color, everywhere. Swift and the reader CSS read the same token table, so a state looks the same in the reader, the panels, the dock and the library.
- System surfaces and text. Custom colors exist only where the system has no role (tint, status tones, highlighter) or fails contrast (secondary text).
- Motion confirms a change. A few named curves, each with a Reduce Motion fallback; the one authored moment is a decision landing.

## Colors

Apple's cool system greys, one sea green, a red and an amber set to the same lightness as the green, and a yellow highlighter for your own notes. The frontmatter gives light and dark values. Every custom role also has an Increase Contrast pair in `TurfPalette.Swatch`; accent, destructive, attention and muted reach 7:1 or better on paper there, and translucent roles rise in alpha, except the dark highlighter, which drops (.30 saved, .40 draft) so white text on it stays above 4.5:1.

### Primary
- **Sea Green** (`accent`): the app tint. Tinted icons and text, links, approved and chosen state text, focus, reader selection base. Never a fill behind white text.
- **Sea Green Fill** (`accentFill`): the background of the single primary button, the user chat bubble and count badges. It stays mid green in dark mode, because white on the light dark-mode green fails contrast.
- **Sea Green Wash** (`accentSoft`): approved and chosen fills on buttons and reader marks, and the info banner. Plain actions such as Save feedback and Add review note use the neutral `fill` with an accent icon, so this wash always means approved or chosen.
- **On Accent** (`onAccent`): white text and icons on `accentFill` and `destructiveFill`.

### Secondary
- **Reject Red** (`destructive`, `destructiveFill`, `destructiveSoft`): Reject, Kill, failed, errors, delete glyphs; the Kill primary button; rejected fills and the system chat message.
- **Waiting Amber** (`attention`, `attentionSoft`): awaiting a decision. Open review targets, parked, needs confirmation, the blocking Send gate, the offline and demo banner icon. The soft form fills the warning banner only.

### Tertiary
- **Highlighter Yellow** (`highlight`): saved notes in the reader and the quote in a Notes row.
- **Highlighter Yellow, active** (`highlightActive`): the quote in the composer, and the first frame of a new mark's settle.
- **Selection** (`selection`): reader text selection, a green wash distinct from the yellow notes.

### Neutral
- **Paper** (`paper`: iOS `systemBackground`, Mac `textBackgroundColor`): the reader page, library canvas, detail placeholder and audio row. Toolbar, audio row, web view and CSS page share this color, so there is no seam and no load flash.
- **Panel** (`panel`: iOS `systemGroupedBackground`, Mac `windowBackgroundColor`): the canvas of sheets and popovers, set with `presentationBackground` so sheets are opaque.
- **Card** (`card`: iOS `secondarySystemGroupedBackground`, Mac `controlBackgroundColor`): cards inside panels, the assistant chat bubble, field wells on the panel canvas.
- **Ink** (`ink`: `label` / `Color.primary`): all primary text and the reader body.
- **Muted** (`muted`): secondary text, metadata, subtitles, list markers. Custom because the system secondary label fails AA on white.
- **Faint** (`faint`): decorative glyphs and disabled states only, such as row chevrons and the unset selection ring.
- **Hairline** (`hairline`: the system separator, unmodified): dividers, table rules, the blockquote rule.
- **Fill** (`fill`): neutral translucent fill for secondary buttons, inline code, `pre`, fields inside cards, the decided-dock capsule, and an author's own `<mark>`.

### Named Rules
**The Single Source Rule.** `TurfPalette` is the only color table. SwiftUI reads it through `TurfTheme` (`Color(uiColor:)` / `Color(nsColor:)`, still dynamic). The reader reads it through `TurfTheme.cssVariables`, which resolves every token under light, dark and both Increase Contrast appearances and emits `--turf-*` variables in a `:root` block plus three `@media` blocks. The same block is injected into custom-HTML artifacts. The `AccentColor` asset carries the accent for system UI, and a test asserts it matches `TurfPalette.accent` in all four appearances. Add a color to `TurfPalette` or not at all.

**Placement Rule S1.** Tone-colored text (accent, destructive, attention) and tinted buttons sit only on paper or card, never on the grey panel canvas, where soft fills drop below 4.5:1. The panel canvas carries only section titles and subtitles. Every control group, row and callout inside a panel sits in a card. Never put muted text on a highlight or a soft fill.

**The One Green Rule.** Approved, succeeded, processed and audio ready all use the accent family. There is no second green.

**The Tone Rule.** Status color comes from `TurfTheme.statusTone(_:)`, which maps every downstream status to accent, destructive, attention or neutral. Views read the tone's roles (`text`, `icon`, `soft`, `fill`, `onFill`); they never pick a raw color for status.

## Typography

**Reader Font:** New York (`ui-serif`, with Georgia and serif fallbacks)
**Interface Font:** San Francisco (system text styles; `-apple-system, system-ui` inside the reader)
**Code Font:** SF Mono (`ui-monospace`, with Menlo)

**Character:** A serif page for reading, system sans for everything you operate. The serif returns in the app as the quote style, which ties a note to its passage.

### Hierarchy
SwiftUI roles are `TurfType` constants. All scale with Dynamic Type; the Pencil canvas and sketch image are the only fixed sizes.
- **Screen title** (`.largeTitle.bold()`): "Library".
- **Panel title** (`.headline`): section headers and the composer header.
- **Row title** (`.body` semibold): queue rows and the item label in the Items card.
- **Body** (`.body`): note comments, chat text, feedback text.
- **Dock label** (`.body` semibold): dock primary, secondary and Review labels.
- **Control** (`.subheadline` semibold): buttons inside panels and Mac toolbar labels; the default label of `TurfButtonStyle`.
- **Meta** (`.footnote`) and **Meta strong** (`.footnote` semibold): row metadata, status row, subtitles, helper text; field labels, chat author, the gate line.
- **Caption** (`.caption`): timestamps and request detail lines.
- **Badge** (`.caption2` bold, monospaced digits): count badges, 11pt floor.
- **Quote** (`.callout`, serif design): quoted passages in Notes rows and the composer.

The reader scale is in the frontmatter, in `rem` and `em` from one base. `html { font-size: var(--turf-reader-size) }` comes from `TurfType.readerBodySize(for:)`, which is `round(18 × body_pt / 17)`: xSmall 15, small 16, medium 17, large 18, xLarge 20, xxLarge 22, xxxLarge 24, AX1 30, AX2 35, AX3 42, AX4 50, AX5 56. macOS is always 18. A Dynamic Type change sets the property in place without reloading the document. Headings use `text-wrap: balance`; paragraphs use `text-wrap: pretty` and hanging punctuation; blocks space at `0 0 1em`.

### Named Rules
**The Live Number Rule.** Every number that changes on screen uses monospaced digits and `.contentTransition(.numericText())`, with `.opacity` under Reduce Motion. Badges cap the display at 99.

**The No-Shrink Rule.** Primary labels never use `minimumScaleFactor`. At accessibility sizes the dock's Review button drops to icon only and keeps its VoiceOver label.

## Layout

The spacing scale is 2, 4, 8, 12, 16, 20, 24, 32 (`TurfSpacing.xxs` through `xxxl`). Values off the scale are allowed only for the 44pt iOS hit target, the reader measure, and fixed popover, column and window sizes. Views use the semantic tokens:

- **screenInset** (16 compact / 20 regular): the one leading edge of a screen. Library header, status row, picker, banner and list rows all use it.
- **panelInset** (16 / 20): inside panels, the iOS Notes sheet and popovers.
- **readerInset** (20 / 32): reader text inline padding, the audio-row content edge and the dock pill edges. The CSS mirrors it as `--turf-reader-inline`, 32px from `min-width: 600px`. The reader view switches only when its width crosses 600pt.
- **cardInset** 12 (trim the top by 2 when a card starts with a headline), **cardGap** 8, **sectionGap** 24, **stackTight** 4, **controlGap** 8, **rowVertical** 12.
- **dockOuter / dockInner** (12 / 8 compact, 16 / 8 regular): `dockOuter + dockInner` equals the compact reader inset, so pill edges line up with the text.

The reading column is 36em of text, about 70 characters of New York. On regular width and Mac the audio row and dock match the column, `36 × readerSize + 64` (712pt at 18), centered. Wide tables scroll sideways inside the column; the column never widens for them. Custom HTML layouts keep their own layout.

## Elevation & Depth

Flat. Cards separate from the panel by fill alone. Panels, sheets, the composer and the dock carry no shadow.

### Shadow Vocabulary
- **Floating overlay** (`shadow(color: .black.opacity(0.12), radius: 12, y: 4)`): the selection-capture pulse and the loading pill, the only two views that float over the reader.

The dock uses `glassEffect(.regular, in: Capsule())` on iOS 26, matching the system toolbar glass. On iOS 17 to 25 it is a full-width `.bar` band with a top divider. Custom views use no other material.

### Named Rules
**The Two Shadows Rule.** Only the two floating overlays cast a shadow. Colored shadows do not exist.

## Shapes

Three radii and the capsule, all `style: .continuous`: `mark` for reader marks and inline code, `field` for text fields, editors, `pre` and reader images, `card` for cards, chat bubbles, the capture pulse, the banner and the composer quote card. Every button is a capsule: dock pills, decision options, Approve and Reject, reader target buttons, Save and Add, badges, the loading pill, the decided-dock capsule. Sheets and popovers keep the system shape.

A shape nested in another at inset `p` uses `outer − p`, floor 4: a field inset 4 inside a card is 10.

### Named Rules
**The One Stroke Rule.** Strokes are 1pt (CSS 1px) and appear only as system separators and dividers, table rules, the ring on an open reader target's status dot, and a field's focus stroke (accent) or invalid stroke (destructive). The blockquote rule is the one exception at 2px, and the open-target underline is 2px text decoration. Cards, buttons, badges and pills have no stroke.

## Components

### Buttons
Capsules with the control font, 16pt horizontal padding, 44pt minimum height on iOS and 32pt on Mac.
- **Filled** (`.turfFilled`): the single primary action. Accent fill, or destructive fill for Kill. Attention and neutral have no filled form.
- **Tinted** (`.turfTinted`): secondary actions and choices that carry state. The tone's soft fill with its text color; neutral is `fill` with ink.
- **Press:** opacity 0.72 and scale 0.97 with `quick`; the scale drops under Reduce Motion. Disabled is opacity 0.4.
- **Busy:** the primary pill swaps its icon for a spinner, announces "Submitting" to VoiceOver, and ignores repeat taps.
- **Reader target buttons:** the same capsule in CSS (`fill`, 44px minimum height, 16px padding). The active choice takes the tone's soft fill and text. Press is `opacity: 0.7`; hover on pointer devices is `brightness(0.97)`.

### Cards / Containers
- **Corner Style:** `card` radius.
- **Background:** `card` on the `panel` canvas.
- **Shadow Strategy:** none.
- **Border:** none.
- **Internal Padding:** `cardInset` (12).

### Inputs / Fields
- **Style:** `fill` well, `field` radius, no stroke at rest.
- **Focus:** a 1pt accent stroke fades in with `quick`.
- **Error:** a 1pt destructive stroke.

### Navigation
System navigation on every platform: a large "Library" title with search on iPhone, a split view on iPad and Mac, system sheets and popovers. Queue rows carry a title, compact metadata and a status dot; they have no colored rails or category badges. A short download line reports what is on the device, and a row's download glyph fades out when the review lands locally.

### Decision Dock
One primary pill and a labeled Review button, with no nested floating containers. When a decision lands, the pills fade and shrink to 0.96 (`exit`), the decided capsule fades in, and its status dot settles from half size with `confirm`. A success haptic fires on iOS only when the decision came from this device. On Mac the primary toolbar button crossfades out (`content`) and the Review menu keeps the default toolbar menu look.

### Reader
The document fills the reader. One compact audio row appears when audio exists; secondary audio and its availability live in the listening sheet. Notes stay one tap away.
- **Saved note:** `highlight` background, `mark` radius.
- **Review target:** 2px underline in the state color, offset .28em so it clears descenders. Open is amber with no fill; approved or chosen is `accentSoft`; rejected is `destructiveSoft`.
- **Links:** accent text with a 1px underline at 45% accent, full accent on hover.
- **Blockquote:** 2px hairline rule on the left, ink text, no fill.
- **Code:** `fill` background, ink text, in both appearances.
- **Tables:** system sans, tabular figures, hairline row rules, muted uppercase headers.
- **Focus:** 2px accent outline, offset 2px.

### Motion
Every animation goes through `turfAnimation`, `withTurfAnimation`, `turfLift` or `turfSettle`, which substitute `reduced` under Reduce Motion. Tokens (`TurfMotion`): `quick` `.snappy(0.18)`, `content` `.smooth(0.28)`, `panel` `.spring(0.36, bounce 0.12)`, `confirm` `.spring(0.44, bounce 0.18)`, `exit` `.easeOut(0.16)`, `reduced` `.easeInOut(0.2)`; `lift` 8pt, `pressScale` 0.97, `loadingRevealDelay` 400ms. CSS tokens: `--turf-ease-out: cubic-bezier(0.16, 1, 0.3, 1)`, `--turf-duration-quick: 180ms`, `--turf-duration-settle: 700ms`.

The complete motion list. Nothing else animates.

| Moment | Treatment | Reduce Motion |
|---|---|---|
| Decision lands, iOS dock | Pills fade and scale to 0.96 (`exit`); capsule fades in; dot 0.5 → 1 (`confirm`); success haptic | Crossfade, dot at rest; haptic stays |
| Decision lands, Mac toolbar | Primary button crossfades out (`content`) | Crossfade |
| Submitting | Icon swaps to a spinner (`quick`) | Same |
| Decision panel, pending to decided | Crossfade (`content`); the feedback field fades in when a choice needs it (`quick`) | Same |
| Retry label, status panel | Opacity swap (`quick`) | Same |
| Library list insert and remove | `content`, keyed on the visible slugs, so search typing is instant | Instant |
| Library tab switch | `content` | Instant |
| Banner | `turfLift` in its own container (`content`); the list does not move with it | Opacity |
| Row download glyph | Fades out (`content`) | Same |
| Count changes | Numeric text (`quick`) | Opacity |
| Archive selection mark | Symbol replace (`quick`) | Opacity |
| Items row state | Symbol replace; tint change (`quick`); feedback field with `turfLift` | Opacity |
| New note or chat row | `turfLift` with `panel` | Opacity |
| Composer entrance | Header, quote, editor staged at 0, 70, 120ms with `panel` and an 8pt lift | All at once |
| Field focus | Stroke fades in (`quick`) | Same |
| Selection-capture pulse, iPhone | `turfSettle` in (`panel`), visible 620ms, out with `exit` | Opacity |
| Loading pill and loading states | After 400ms, in with `content`; the pill leaves with `exit` | Opacity |
| Play and pause glyph | Symbol replace (`quick`) | Opacity |
| New note in the reader | `.is-new` marks fade from `highlightActive` to `highlight` over 700ms, only for notes saved since the last apply | Same fade, 300ms linear |
| Reader target press | `opacity: 0.7` | Same |

**Never animate:** the web view's frame, scroll position, zoom or layout, including reading-position restore; reader content other than the `.is-new` fade; sheet, popover and navigation transitions, which stay system; the status-row height during download ticks; anything with `repeatForever`. No `TimelineView`, animation timers or per-row geometry readers.

## Do's and Don'ts

### Do:
- **Do** add every new color to `TurfPalette` with light, dark and both Increase Contrast values, then mirror it in `TurfTheme` and, if the reader needs it, in `TurfCSS.colorTokens`.
- **Do** put tone-colored text and tinted buttons in a card when they appear in a panel (rule S1).
- **Do** use `accentFill`, never `accent`, behind white text.
- **Do** use the semantic spacing tokens and keep one leading edge per screen.
- **Do** route every animation through the `TurfMotion` helpers.
- **Do** use curly punctuation in copy the app writes.

### Don't:
- **Don't** write hex, `Color.red`, `Color.green`, `Color.orange`, or `.white` on a tone in a view; read a `TurfTheme` role or a `TurfTone`. The Pencil canvas is the one exception.
- **Don't** reintroduce the retired palette: coral, moss, gold, plum, terracotta, teal `#007c89`, olive, brick, warm white `#fffdf7`, the Mac beige `#F7F2E8`, green-tinted neutrals, or Avenir Next.
- **Don't** use yellow for anything except your own notes; an author's `<mark>` gets `fill`.
- **Don't** use `.borderedProminent` with `.tint(TurfTheme.accent)`.
- **Don't** add strokes around cards, buttons, badges or pills, or shadows beyond the two floating overlays.
- **Don't** hard-code point sizes, or use `presentationCornerRadius`, `.regularMaterial` or `.ultraThinMaterial` in custom views.
- **Don't** write raw `withAnimation`, `.animation(.easeInOut…)` or inline durations.

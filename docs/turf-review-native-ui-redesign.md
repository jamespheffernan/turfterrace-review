# Turf Review (native iPad) — surfacing controls without the column-squeeze

A set of design options for the review workspace. The goal: kill the bottom-bar-that-becomes-a-right-sidebar reflow, strip the control set back to what earns its place, and make the **Apple Pencil the primary instrument** rather than an afterthought.

---

## 1. Diagnosis — why it feels clunky

`ReviewDetailView` picks its layout from a single hard width breakpoint (`proxy.size.width >= 760`):

| Pane width | What you get |
|---|---|
| **≥ 760pt** | Reader + a fixed **360pt inspector pinned right** |
| **< 760pt** | Reader on top + inspector as a **≤360pt-tall bottom bar** |

A portrait iPad pane is ~820pt. So:

- **Queue sidebar open** → pane < 760 → inspector drops to the **bottom bar**.
- **Queue sidebar dismissed** → pane > 760 → inspector **snaps to the right** and eats 360pt → reader collapses to ~460pt: the *narrow column*.

The reflow you hate is the layout tripping over that 760 threshold. Two layouts, two personalities, triggered by an action (hiding the queue) that should have made things **roomier**, not worse.

Second problem: the inspector crams **five modes** into one segmented control — Decide / Items / Notes / Chat / Status — yet two of them are already doable *inside the document*:

- **Items** → review targets already render inline yes/no controls in the HTML (`onReviewTargetDecision`).
- **Notes** → Pencil-select text in the document already fires the annotation composer (`onPencilSelection`).

So the inspector simultaneously **fights the document for width** and **duplicates** what the document already does.

---

## 2. Principles for the redesign

1. **The document is the product.** Reading and marking up the artifact is the job. Chrome should never permanently shrink the reader in portrait.
2. **Summon, don't occupy.** Only ever-present control = the *decision*. Everything else is pulled in when wanted and dismissed when done.
3. **Pencil-first.** Mark up by writing on the page; tap inline yes/no with the tip; flick from an edge to summon tools. Touch/keyboard stay as fallbacks, not the primary path.
4. **One layout, all orientations.** A full-bleed reader + an overlay surface that floats *on top* (never reflows the reader). Portrait and landscape behave identically.
5. **Strip to four jobs, not five tabs:** Decide · Mark up (items + notes unified) · Ask · Proof/Audio.

---

## 3. Control audit — keep / cut / merge

| Today | Verdict | Where it goes |
|---|---|---|
| **Decide** (action chips + feedback) | **Keep — promote** | The one always-visible control |
| **Items** (yes/no review targets) | **Keep — move inline** | Decided in the document; panel becomes an optional "jump to unresolved" list |
| **Notes** (annotations) | **Keep — Pencil-native** | Created by writing/selecting on the page; list summoned on demand |
| **Chat** | **Keep — demote** | Summoned sheet/popover, not a standing tab |
| **Status** (audio + downstream + retry) | **Split** | Audio = slim transport shown only when audio exists; retry/downstream = rare, lives in an overflow sheet |

Net: **5 standing tabs → 1 standing control + 3 summoned surfaces**, and "Items" + "Notes" merge into a single *Markup* idea because both are just things the Pencil does to the page.

---

## 4. The options

Each shows **portrait** (the painful case) and notes the landscape behavior. All five remove the reflow by keeping the reader full-bleed and floating everything else.

### Option A — Decision Dock (floating, document-first)

Reader fills the whole pane, both orientations. The only persistent chrome is a **floating decision dock** bottom-centre: it shows the recommended action and the 2–3 most-likely verdicts as large Pencil-tappable chips. Tap **⋯ More** for the full action set + feedback. Top-right toolbar holds three summon icons (Markup list · Ask · Proof). Items/notes are handled inline on the page.

```
PORTRAIT
┌─────────────────────────────────────┐
│ ‹ Queue            Review   ✎  💬  ♪ │  ← summon icons (notes list, ask, proof)
├─────────────────────────────────────┤
│                                     │
│   The full review document,         │
│   full width. Pencil-select to      │
│   annotate. Inline ✓ / ✗ on each    │
│   review item, right in the text.   │
│                                     │
│         …reads edge to edge…        │
│                                     │
│      ┌───────────────────────┐      │
│      │  SEND ▸   Edit   ⋯More │      │  ← floating decision dock
│      └───────────────────────┘      │
└─────────────────────────────────────┘
```

- **Landscape:** identical; dock can shift bottom-right to clear margin notes.
- **Pencil:** select → inline annotate; tap inline yes/no; tap dock chips to decide.
- **Pros:** maximum reading width; the decision is unmissable; nothing reflows.
- **Cons:** dock floats over content (needs a safe, collapsible footprint); notes list is one tap away rather than always visible.

---

### Option B — Edge Rail + Overlay Drawer

A thin **icon rail (~56pt)** sits on the trailing edge always: Decide · Markup · Ask · Proof. Tapping one (or **flicking the Pencil in from the edge**) slides a drawer *over* the reader (reader dims, does not resize). Drawer is dismissed with a flick back or tap-away. Keeps all functions one gesture away while the reader stays full-width whenever the drawer is closed.

```
PORTRAIT (drawer closed)        PORTRAIT (Decide drawer open)
┌──────────────────────────┬─┐  ┌──────────────┬───────────────┬─┐
│                          │◉│  │              │ Choose action │◉│
│   Document, full width   │✎│  │   Document   │  ▸ Send       │✎│
│   inline items + notes   │💬│  │   (dimmed)   │  ◦ Edit       │💬│
│                          │♪│  │              │  ◦ Kill       │♪│
│                          │ │  │              │  [feedback…]  │ │
└──────────────────────────┴─┘  └──────────────┴───────────────┴─┘
        trailing rail                 overlay, no reflow
```

- **Landscape:** rail + drawer same; drawer can be wider since there's room.
- **Pencil:** edge-flick to open the rail's drawer; write directly in the drawer's notes field.
- **Pros:** all five functions reachable; reader never permanently shrinks; familiar (Mail/Notes inspector vibe).
- **Cons:** still a persistent ~56pt rail; overlay-over-text can feel heavy if opened a lot.

---

### Option C — Bottom Sheet with Detents (iPadOS-idiomatic)

Replace the bottom bar with a **proper resizable bottom sheet** (`.presentationDetents([.minimized, .medium, .large])`) floating over a full-bleed reader. Collapsed = a slim **decision handle**: recommended action + quick ✓ / ✗. Drag up to reveal Markup / Ask / Proof. Same component, same gesture, identical in both orientations — the most native-feeling fix.

```
PORTRAIT (collapsed)               PORTRAIT (dragged to medium)
┌─────────────────────────────┐    ┌─────────────────────────────┐
│                             │    │   Document (still visible    │
│   Document, full width      │    │   above the sheet)           │
│   inline items + notes      │    ├═════════════ ▭ ═════════════┤
│                             │    │ Decide │ Markup │ Ask │ ♪    │
│                             │    │ ▸ Send   ◦ Edit   ◦ Kill     │
├═════════════ ▭ ═════════════┤    │ [ feedback travels with… ]  │
│  Recommend: SEND   ✓    ✗   │    │ ─ unresolved items: 3       │
└─────────────────────────────┘    └─────────────────────────────┘
       slim handle                      grabber-resized sheet
```

- **Landscape:** same sheet, anchored bottom; or optionally a trailing sheet — but bottom keeps one mental model.
- **Pencil:** inline on page; drag the grabber; write in the sheet's note field.
- **Pros:** zero custom layout logic, fully standard gesture, never reflows the reader, scales from glance to full work.
- **Cons:** at the `.large` detent it covers the reader (expected for sheets); decision quick-actions must be genuinely 1-tap at the collapsed detent to stay fast.

---

### Option D — Pencil Margin (Books-style)

The reader gets a generous **right margin/gutter**. Annotations live as **margin pins** beside the text they anchor to (like iBooks notes), so notes are visible *without* a panel. The decision is a compact **vertical action stack** in the gutter's foot. Chat and Proof are toolbar popovers. This leans hardest into "Pencil on paper" and removes the inspector concept entirely.

```
PORTRAIT
┌──────────────────────────────┬──────────┐
│                              │  ✎ note  │ ← margin pins sit beside
│   Document text column       │  ╲       │   the lines they anchor to
│   …………………………………………………………… │   ●──────│
│   …………………………………………………………… │          │
│   review item ……………… ✓ / ✗   │  ✎ note  │
│   …………………………………………………………… │   ●──────│
│                              │          │
│                              │  ┌─────┐ │ ← vertical decision stack
│                              │  │SEND │ │
│                              │  │Edit │ │
│                              │  │Kill │ │
└──────────────────────────────┴──────────┘
```

- **Landscape:** margin widens; pins get more room; reading column stays a comfortable measure.
- **Pencil:** write a note → it drops a pin in the margin; tap inline yes/no; tap a stack chip to decide.
- **Pros:** notes are *ambiently visible* (best for a review tool); deeply Pencil-native; no overlay covering text.
- **Cons:** biggest build (margin-anchoring layout in the web doc); decision chips compete with margin in narrow portrait; chat/proof still need a home.

---

### Option E — Pencil HUD (hover-aware tool palette)

Reader is full-bleed. A small **floating HUD** (like the PencilKit tool palette) appears when the Pencil approaches the screen (hover) and fades when it leaves — offering **Annotate · Highlight · Decide**. "Decide" expands to the action chips in place, under the pencil. No standing inspector at all; touch users get the same HUD via a single corner button.

```
PORTRAIT (pencil near screen)
┌─────────────────────────────────────┐
│                                     │
│   Document, full width              │
│            ✎ ← pencil               │
│          ╭───────────────╮          │ ← HUD follows the pencil,
│          │ ✎  ▱  ✓Decide │          │   fades when it lifts away
│          ╰───────────────╯          │
│   inline items + notes on page      │
│                                     │
└─────────────────────────────────────┘
```

- **Landscape:** identical; HUD is positional, orientation-agnostic.
- **Pencil:** hover summons tools; the decision lives under your hand, not across the screen.
- **Pros:** most "magical" / Pencil-centric; reader is 100% clean when not marking up.
- **Cons:** hover needs Pencil-capable hardware (graceful touch fallback required); discoverability ("where did my controls go?"); decision is summoned rather than always-on — risk for the app's core action.

---

## 5. Recommendation

**Lead with Option C (Bottom Sheet w/ detents) as the structural fix, borrowing the inline-everything stance from A/D.**

Reasoning: C is the smallest, most native change that *fully removes the reflow* — one component, one gesture, identical in both orientations, reader never horizontally squeezed. It also naturally enforces the strip-back: the collapsed handle forces us to name the **one** thing that's always visible (the decision + quick ✓/✗), and pushes Items/Notes onto the page where they already half-live.

Then layer the Pencil-native behavior from D (margin pins so notes are ambiently visible) as a fast-follow once the structure is right. A is the fallback if a floating dock tests better than a sheet. E is the "wow" experiment — worth a spike, too risky as the only path because it summons the core action.

A natural sequence: **C now → fold in inline items/notes (A/D) → trial the Pencil HUD (E) behind a setting.**

---

## Items to review

- [ ] **Option A — Decision Dock** — worth prototyping
- [ ] **Option B — Edge Rail + Overlay Drawer** — worth prototyping
- [ ] **Option C — Bottom Sheet w/ Detents** — worth prototyping (recommended lead)
- [ ] **Option D — Pencil Margin (Books-style)** — worth prototyping
- [ ] **Option E — Pencil HUD (hover palette)** — worth a spike
- [ ] **Strip to 1 standing control + 3 summoned surfaces** (Decide always; Markup/Ask/Proof summoned)
- [ ] **Move Items (yes/no) fully inline into the document**, panel becomes "jump to unresolved"
- [ ] **Demote Chat and Status to summoned sheets** (audio transport only appears when audio exists)
- [ ] **Build a live SwiftUI prototype of the chosen option** before committing

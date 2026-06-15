// Generates 5 iPad-portrait UI mockups for the Turf Review native redesign.
// Palette matches TurfTheme.swift.
const fs = require("fs");
const path = require("path");

const C = {
  paper: "#F7F2E8", panel: "#FFFCF5", ink: "#211F1B", muted: "#6F6A61",
  hairline: "#DDD1BF", accent: "#007C89", coral: "#C95F45", moss: "#687F4E",
  gold: "#C99A38", plum: "#5B4662",
};

const css = `
*{box-sizing:border-box;-webkit-font-smoothing:antialiased;margin:0;padding:0}
:root{
  --paper:${C.paper};--panel:${C.panel};--ink:${C.ink};--muted:${C.muted};
  --hairline:${C.hairline};--accent:${C.accent};--coral:${C.coral};
  --moss:${C.moss};--gold:${C.gold};--plum:${C.plum};
}
body{background:#cfc6b6;font-family:-apple-system,"SF Pro Text","Helvetica Neue",system-ui,sans-serif}
.screen{width:834px;height:1194px;position:relative;overflow:hidden;background:var(--paper);
  display:flex;flex-direction:column}
.serif{font-family:"Charter","Iowan Old Style",Georgia,"Times New Roman",serif}

/* status bar */
.status{height:34px;display:flex;align-items:center;justify-content:space-between;
  padding:0 28px;font-size:15px;font-weight:600;color:var(--ink);flex:none}
.status .right{display:flex;gap:7px;align-items:center;font-size:13px}

/* nav */
.nav{height:52px;display:flex;align-items:center;justify-content:space-between;
  padding:0 20px;border-bottom:1px solid var(--hairline);background:var(--panel);flex:none}
.nav .back{color:var(--accent);font-size:17px;font-weight:600;display:flex;align-items:center;gap:4px}
.nav .title{font-size:15px;font-weight:700;color:var(--ink);letter-spacing:.2px}
.nav .tools{display:flex;gap:14px}
.toolbtn{display:flex;flex-direction:column;align-items:center;gap:2px;color:var(--muted);
  font-size:9px;font-weight:600;text-transform:uppercase;letter-spacing:.4px}
.toolbtn svg{width:22px;height:22px;stroke:var(--ink);stroke-width:1.7;fill:none}

/* document */
.doc{flex:1;overflow:hidden;position:relative}
.docpad{padding:38px 64px 120px}
.eyebrow{font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:1.4px;
  color:var(--accent);margin-bottom:10px}
.h1{font-size:34px;line-height:1.15;color:var(--ink);font-weight:700;margin-bottom:6px}
.byline{font-size:13px;color:var(--muted);margin-bottom:26px}
.p{font-size:18px;line-height:1.62;color:#33302a;margin-bottom:18px}
.hl{background:rgba(201,154,56,.28);border-bottom:2px solid var(--gold);padding:1px 2px;
  border-radius:2px;position:relative}
.h2{font-size:21px;font-weight:700;color:var(--ink);margin:24px 0 12px}

/* inline review item */
.item{border:1px solid var(--hairline);border-left:4px solid var(--accent);background:var(--panel);
  border-radius:10px;padding:16px 18px;margin:18px 0;display:flex;gap:14px;align-items:center}
.item .q{flex:1;font-size:16px;line-height:1.45;color:var(--ink)}
.item .q b{font-weight:700}
.chip{font-size:14px;font-weight:700;padding:9px 16px;border-radius:999px;border:1.5px solid;
  display:flex;align-items:center;gap:6px;white-space:nowrap}
.chip.yes{color:#fff;background:var(--moss);border-color:var(--moss)}
.chip.no{color:var(--coral);background:#fff;border-color:var(--coral)}

/* pencil cursor */
.pencil{position:absolute;width:120px;height:120px;pointer-events:none;filter:drop-shadow(0 6px 10px rgba(0,0,0,.25))}

/* generic floating shadow */
.float{box-shadow:0 18px 50px rgba(33,31,27,.22),0 2px 8px rgba(33,31,27,.12)}

/* caption ribbon */
.caption{position:absolute;left:0;right:0;bottom:0;background:var(--ink);color:#f3ecdd;
  padding:14px 28px;font-size:14px;line-height:1.4;display:flex;gap:10px;align-items:baseline}
.caption b{color:var(--gold);font-weight:700}
.tag{position:absolute;top:14px;left:14px;background:var(--ink);color:var(--paper);
  font-size:12px;font-weight:700;letter-spacing:.6px;padding:7px 13px;border-radius:8px;text-transform:uppercase}

/* dimmer */
.dim{position:absolute;inset:0;background:rgba(33,31,27,.34)}
`;

// shared SVG icons
const ic = {
  pencil: `<svg viewBox="0 0 24 24"><path d="M4 20l4-1L19 8l-3-3L5 16l-1 4z"/><path d="M14.5 6.5l3 3"/></svg>`,
  chat: `<svg viewBox="0 0 24 24"><path d="M4 5h16v11H9l-4 4V5z"/></svg>`,
  wave: `<svg viewBox="0 0 24 24"><path d="M3 12h3l2-6 3 14 3-11 2 5h5"/></svg>`,
  list: `<svg viewBox="0 0 24 24"><path d="M8 6h12M8 12h12M8 18h12"/><circle cx="4" cy="6" r="1.4" fill="currentColor" stroke="none"/><circle cx="4" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="4" cy="18" r="1.4" fill="currentColor" stroke="none"/></svg>`,
  check: `<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M8 12l3 3 5-6"/></svg>`,
};

// a pencil-tip graphic pointing where it is placed
function pencilGraphic() {
  return `<svg viewBox="0 0 120 120" xmlns="http://www.w3.org/2000/svg">
    <g transform="rotate(35 60 60)">
      <rect x="50" y="6" width="20" height="74" rx="9" fill="#f5f0e6" stroke="#cdbfa6" stroke-width="1.5"/>
      <rect x="50" y="6" width="20" height="16" rx="9" fill="#211F1B"/>
      <rect x="56" y="22" width="8" height="58" fill="#e9e0cd"/>
      <path d="M50 80 L60 104 L70 80 Z" fill="#f0e7d5" stroke="#cdbfa6" stroke-width="1.5"/>
      <path d="M55 92 L60 104 L65 92 Z" fill="#211F1B"/>
    </g></svg>`;
}

const statusBar = `<div class="status"><span>9:41</span>
  <span class="right">Turf&nbsp;Review&nbsp;&nbsp;<span style="letter-spacing:-1px">●●●</span>&nbsp;Wi-Fi&nbsp;&nbsp;100%▮</span></div>`;

function nav(tools = "") {
  return `<div class="nav">
    <div class="back">‹&nbsp;Queue</div>
    <div class="title">Q3 Infra Migration — review</div>
    <div class="tools">${tools}</div>
  </div>`;
}

function tool(svg, label) {
  return `<div class="toolbtn">${svg}<span>${label}</span></div>`;
}

// the review document body (reused). `narrow` shrinks measure for margin layout.
function docBody(opts = {}) {
  const pad = opts.pad || "38px 64px 120px";
  return `<div class="doc"><div class="docpad serif" style="padding:${pad}">
    <div class="eyebrow">Decision packet · pending</div>
    <div class="h1">Migrate the ingest tier to the new queue</div>
    <div class="byline">Drafted by the platform pod · 1,840 words · 6 review items</div>
    <p class="p">The current ingest path routes every event through a single synchronous
      worker pool. Under the Q2 peak it sat at <span class="hl">94% saturation for nine
      hours</span> and dropped 0.3% of events on the floor — small, but the wrong events.</p>
    <p class="p">This plan moves ingest behind a durable queue so spikes buffer instead of
      drop, and so we can replay a bad window without a redeploy.</p>
    <div class="item">
      <div class="q"><b>Item 2.</b> Cut over writes in a single switch rather than a dual-write window?</div>
      <div class="chip yes">✓ Yes</div>
      <div class="chip no">✗ No</div>
    </div>
    <p class="p">The team prefers a hard cutover at low traffic with a tested rollback,
      arguing dual-write doubles the surface for subtle drift.</p>
    <div class="h2 serif">Rollback &amp; blast radius</div>
    <p class="p">A failed cutover reverts in under four minutes by flipping the router flag.
      The queue retains 24h, so no window is unrecoverable.</p>
  </div></div>`;
}

// ---- OPTION A: Decision Dock ----
function optionA() {
  return wrap("A", `
    ${statusBar}
    ${nav(tool(ic.list, "Items") + tool(ic.pencil, "Notes") + tool(ic.chat, "Ask") + tool(ic.wave, "Proof"))}
    ${docBody()}
    <div class="float" style="position:absolute;left:50%;bottom:104px;transform:translateX(-50%);
      display:flex;align-items:center;gap:10px;background:var(--panel);border:1px solid var(--hairline);
      border-radius:999px;padding:10px 12px">
      <div style="font-size:11px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:.6px;padding-left:8px">Recommend</div>
      <div style="display:flex;align-items:center;gap:8px;background:var(--accent);color:#fff;font-size:18px;font-weight:700;padding:13px 26px;border-radius:999px">Send ▸</div>
      <div style="font-size:17px;font-weight:600;color:var(--ink);padding:13px 20px;border:1.5px solid var(--hairline);border-radius:999px">Edit</div>
      <div style="font-size:22px;font-weight:700;color:var(--muted);padding:8px 16px">⋯</div>
    </div>
    <div class="caption"><b>A · Decision Dock.</b> Reader is full width. One floating pill always shows the recommended verdict + a second option; ⋯ opens the full action set. Items &amp; notes act inline on the page.</div>
    <div class="tag">Option A</div>
  `);
}

// ---- OPTION B: Edge Rail + Overlay Drawer (drawer open) ----
function optionB() {
  const rail = `<div style="position:absolute;top:86px;right:0;bottom:0;width:62px;background:var(--panel);
    border-left:1px solid var(--hairline);display:flex;flex-direction:column;align-items:center;gap:22px;padding-top:26px;z-index:3">
    ${railIcon(ic.check, "Decide", true)}${railIcon(ic.pencil, "Mark")}${railIcon(ic.chat, "Ask")}${railIcon(ic.wave, "Proof")}
  </div>`;
  const drawer = `<div class="float" style="position:absolute;top:52px;right:62px;bottom:0;width:340px;
    background:var(--panel);border-left:1px solid var(--hairline);padding:26px 24px;z-index:4">
    <div style="font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:1px;color:var(--accent);margin-bottom:4px">Decide</div>
    <div class="serif" style="font-size:22px;font-weight:700;color:var(--ink);margin-bottom:18px">Choose the next action</div>
    ${drawerAction("Send", "Ship as written", C.accent, true)}
    ${drawerAction("Edit / rework", "Send back with notes", C.gold)}
    ${drawerAction("Kill", "Stop here", C.coral)}
    ${drawerAction("Park", "Decide later", C.muted)}
    <div style="margin-top:18px;font-size:13px;font-weight:600;color:var(--muted)">Feedback travels with the decision</div>
    <div style="margin-top:8px;height:84px;border:1px solid var(--hairline);border-radius:10px;background:#fff"></div>
  </div>`;
  return wrap("B", `
    ${statusBar}${nav()}
    ${docBody({ pad: "38px 56px 60px" })}
    <div class="dim" style="left:0;right:402px;top:52px;z-index:2"></div>
    ${drawer}${rail}
    <div class="pencil" style="right:300px;top:300px">${pencilGraphic()}</div>
    <div class="caption"><b>B · Edge Rail + Overlay Drawer.</b> A thin always-on rail; tap an icon — or flick the Pencil in from the edge — and a drawer slides <i>over</i> the dimmed reader. Reader never resizes; closing it returns full width.</div>
    <div class="tag">Option B</div>
  `);
}
function railIcon(svg, label, on) {
  return `<div class="toolbtn" style="${on ? "color:var(--accent)" : ""}">
    <div style="width:22px;height:22px">${svg.replace('stroke="var(--ink)"', "")}</div><span>${label}</span></div>`
    .replace("<svg", `<svg style="stroke:${on ? C.accent : C.ink}"`);
}
function drawerAction(title, sub, color, primary) {
  return `<div style="display:flex;align-items:center;gap:12px;border:1.5px solid ${primary ? color : C.hairline};
    background:${primary ? color : "#fff"};border-radius:12px;padding:13px 15px;margin-bottom:10px">
    <div style="width:30px;height:30px;border-radius:8px;background:${primary ? "rgba(255,255,255,.25)" : color};flex:none"></div>
    <div><div style="font-size:16px;font-weight:700;color:${primary ? "#fff" : C.ink}">${title}</div>
      <div style="font-size:12px;color:${primary ? "rgba(255,255,255,.85)" : C.muted}">${sub}</div></div></div>`;
}

// ---- OPTION C: Bottom Sheet w/ detents (medium) ----
function optionC() {
  const sheet = `<div class="float" style="position:absolute;left:0;right:0;bottom:0;height:560px;
    background:var(--panel);border-top:1px solid var(--hairline);border-radius:22px 22px 0 0;z-index:3;
    padding:14px 28px 28px">
    <div style="width:42px;height:5px;border-radius:3px;background:var(--hairline);margin:0 auto 16px"></div>
    <div style="display:flex;gap:8px;background:#efe7d6;border-radius:11px;padding:5px;margin-bottom:20px">
      ${segTab("Decide", true)}${segTab("Markup")}${segTab("Ask")}${segTab("♪ Proof")}
    </div>
    <div class="serif" style="font-size:21px;font-weight:700;color:var(--ink);margin-bottom:4px">Choose the next action</div>
    <div style="font-size:13px;color:var(--muted);margin-bottom:18px">Feedback travels with the decision and existing annotations.</div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:18px">
      ${bigAction("Send", "Ship as written", C.accent, true)}
      ${bigAction("Edit / rework", "Send back with notes", C.gold)}
      ${bigAction("Kill", "Stop here", C.coral)}
      ${bigAction("Park", "Decide later", C.plum)}
    </div>
    <div style="display:flex;align-items:center;gap:10px;border-top:1px solid var(--hairline);padding-top:16px">
      <div style="width:26px;height:26px;border-radius:7px;background:var(--coral);color:#fff;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:14px">3</div>
      <div style="font-size:15px;color:var(--ink)">review items still unresolved —
        <span style="color:var(--accent);font-weight:700">jump to first ▸</span></div>
    </div>
  </div>`;
  return wrap("C", `
    ${statusBar}${nav()}
    ${docBody({ pad: "30px 64px 40px" })}
    <div class="dim" style="background:rgba(33,31,27,.10);top:52px;bottom:560px;z-index:2"></div>
    ${sheet}
    <div class="caption"><b>C · Bottom Sheet with detents</b> (shown at the medium detent). A native resizable sheet over a full-bleed reader. Collapsed = a slim handle with the recommended action + quick ✓/✗; drag up for the rest. Identical in portrait &amp; landscape.</div>
    <div class="tag" style="background:var(--accent)">Option C · recommended</div>
  `);
}
function segTab(t, on) {
  return `<div style="flex:1;text-align:center;font-size:15px;font-weight:${on ? 700 : 600};padding:9px 0;border-radius:8px;
    color:${on ? C.ink : C.muted};background:${on ? "#fff" : "transparent"};${on ? "box-shadow:0 1px 3px rgba(0,0,0,.12)" : ""}">${t}</div>`;
}
function bigAction(title, sub, color, primary) {
  return `<div style="display:flex;align-items:center;gap:12px;border:1.5px solid ${primary ? color : C.hairline};
    background:${primary ? color : "#fff"};border-radius:13px;padding:15px 16px">
    <div style="width:34px;height:34px;border-radius:9px;background:${primary ? "rgba(255,255,255,.25)" : color};flex:none"></div>
    <div><div style="font-size:17px;font-weight:700;color:${primary ? "#fff" : C.ink}">${title}</div>
      <div style="font-size:12px;color:${primary ? "rgba(255,255,255,.85)" : C.muted}">${sub}</div></div></div>`;
}

// ---- OPTION D: Pencil Margin (Books-style) ----
function optionD() {
  const text = `<div class="doc"><div style="display:flex;height:100%">
    <div class="docpad serif" style="flex:1;padding:34px 30px 40px 64px">
      <div class="eyebrow">Decision packet · pending</div>
      <div class="h1" style="font-size:30px">Migrate the ingest tier to the new queue</div>
      <div class="byline">Platform pod · 1,840 words · 6 items</div>
      <p class="p" style="font-size:17px">The current ingest path routes every event through a single
        synchronous worker pool. Under the Q2 peak it sat at <span class="hl">94% saturation for nine
        hours</span> and dropped 0.3% of events.</p>
      <div class="item" style="margin-right:0">
        <div class="q" style="font-size:15px"><b>Item 2.</b> Hard cutover instead of dual-write?</div>
        <div class="chip yes" style="padding:7px 12px;font-size:13px">✓</div>
        <div class="chip no" style="padding:7px 12px;font-size:13px">✗</div>
      </div>
      <p class="p" style="font-size:17px">The team prefers a hard cutover at low traffic with a tested
        rollback, arguing dual-write doubles the surface for subtle drift.</p>
      <p class="p" style="font-size:17px">A failed cutover reverts in under four minutes by flipping the
        router flag; the queue retains 24h so no window is unrecoverable.</p>
    </div>
    <div style="width:250px;flex:none;border-left:1px solid var(--hairline);background:rgba(255,252,245,.6);
      position:relative;padding:34px 18px">
      ${marginPin(120, "“nine hours is past our SLO — call it out in the post.”")}
      ${marginPin(300, "agree on hard cutover — but only after the replay test passes.")}
      <div class="float" style="position:absolute;left:14px;right:14px;bottom:92px;background:var(--panel);
        border:1px solid var(--hairline);border-radius:14px;padding:12px">
        <div style="font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.8px;color:var(--muted);margin-bottom:10px;text-align:center">Decision</div>
        ${stackChip("Send", C.accent, true)}${stackChip("Edit", C.gold)}${stackChip("Kill", C.coral)}
      </div>
    </div></div></div>`;
  return wrap("D", `
    ${statusBar}
    ${nav(tool(ic.chat, "Ask") + tool(ic.wave, "Proof"))}
    ${text}
    <div class="pencil" style="left:300px;top:430px">${pencilGraphic()}</div>
    <div class="caption"><b>D · Pencil Margin.</b> A Books-style gutter: handwritten notes drop as pins beside the line they anchor to, so notes are <i>ambiently visible</i> with no panel. The decision is a compact stack in the margin foot. Chat/Proof are toolbar popovers.</div>
    <div class="tag">Option D</div>
  `);
}
function marginPin(top, text) {
  return `<div style="position:absolute;top:${top}px;left:14px;right:14px">
    <div style="display:flex;align-items:center;gap:6px;color:var(--accent);font-size:11px;font-weight:700;margin-bottom:5px">
      <span style="font-size:14px">✎</span> note</div>
    <div class="serif" style="font-size:13px;line-height:1.4;color:var(--ink);background:rgba(201,154,56,.14);
      border-left:3px solid var(--gold);border-radius:6px;padding:8px 10px">${text}</div></div>`;
}
function stackChip(t, color, primary) {
  return `<div style="font-size:15px;font-weight:700;text-align:center;padding:11px 0;border-radius:10px;margin-bottom:8px;
    color:${primary ? "#fff" : color};background:${primary ? color : "#fff"};border:1.5px solid ${color}">${t}</div>`;
}

// ---- OPTION E: Pencil HUD ----
function optionE() {
  const hud = `<div class="float" style="position:absolute;left:330px;top:560px;display:flex;align-items:center;gap:6px;
    background:rgba(33,31,27,.93);border-radius:16px;padding:8px;z-index:4">
    ${hudBtn("✎", "Annotate")}${hudBtn("▱", "Highlight")}
    <div style="display:flex;align-items:center;gap:7px;background:var(--accent);color:#fff;font-size:15px;font-weight:700;padding:11px 18px;border-radius:11px">✓ Decide</div>
  </div>`;
  return wrap("E", `
    ${statusBar}
    ${nav(`<div style="width:34px;height:34px;border-radius:999px;background:var(--ink);color:var(--paper);display:flex;align-items:center;justify-content:center;font-size:18px">✎</div>`)}
    ${docBody()}
    ${hud}
    <div class="pencil" style="left:300px;top:470px">${pencilGraphic()}</div>
    <div class="caption"><b>E · Pencil HUD.</b> Reader is 100% clean. As the Pencil approaches the screen a floating palette appears under your hand — Annotate · Highlight · Decide — and fades when you lift away. Touch users get the same HUD from the nav button.</div>
    <div class="tag">Option E</div>
  `);
}
function hudBtn(glyph, label) {
  return `<div style="display:flex;flex-direction:column;align-items:center;gap:1px;color:#f3ecdd;padding:6px 12px">
    <span style="font-size:18px">${glyph}</span><span style="font-size:9px;font-weight:600;text-transform:uppercase;letter-spacing:.4px;opacity:.8">${label}</span></div>`;
}

function wrap(id, inner) {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css}</style></head>
<body><div class="screen" id="opt${id}">${inner}</div></body></html>`;
}

const out = path.join(__dirname);
const opts = { A: optionA(), B: optionB(), C: optionC(), D: optionD(), E: optionE() };
for (const [k, v] of Object.entries(opts)) {
  fs.writeFileSync(path.join(out, `option-${k}.html`), v);
  console.log("wrote option-" + k + ".html");
}

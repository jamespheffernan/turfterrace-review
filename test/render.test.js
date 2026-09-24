const test = require('node:test');
const assert = require('node:assert/strict');

const {
  renderSourceDocument,
  stripFrontMatter,
  stripMarkdownToPlain,
} = require('../lib/reviews/render');

const FRONT_MATTER_DOCUMENT = `---
title: "Chronicle dynamic programme specification"
created_at: "2026-08-06"
type: specification
artifact_contract: chronicle-dynamic-programme/v1
beads:
  - fm26-1x6m
  - fm26-rnab
---

# Chronicle dynamic programme specification

Review this document.`;

test('renderSourceDocument hides YAML front matter and preserves the source markdown', () => {
  const rendered = renderSourceDocument({ markdown: FRONT_MATTER_DOCUMENT, html: null });

  assert.equal(rendered.markdown, FRONT_MATTER_DOCUMENT);
  assert.match(rendered.rendered_html, /<h1>Chronicle dynamic programme specification<\/h1>/);
  assert.doesNotMatch(rendered.rendered_html, /artifact_contract|fm26-1x6m|created_at/);
});

test('stripMarkdownToPlain excludes YAML front matter from read-aloud text', () => {
  const plainText = stripMarkdownToPlain(FRONT_MATTER_DOCUMENT);

  assert.match(plainText, /^Chronicle dynamic programme specification/);
  assert.doesNotMatch(plainText, /artifact_contract|fm26-1x6m|created_at/);
});

test('stripFrontMatter keeps an ordinary opening horizontal rule', () => {
  const markdown = `---

This is document content, not metadata.

---

# Heading`;

  assert.equal(stripFrontMatter(markdown), markdown);
});

test('stripFrontMatter accepts a byte-order mark and a YAML document terminator', () => {
  const markdown = '\uFEFF---\r\ntitle: Example\r\n...\r\n\r\n# Heading';

  assert.equal(stripFrontMatter(markdown), '# Heading');
});

test('renderSourceDocument puts tables in a horizontal scroll container', () => {
  const markdown = `| # | Review workstream | Reusable capability output |
| --- | --- | --- |
| 1 | Programme governance | Versioned truth and failure policy |`;

  const rendered = renderSourceDocument({ markdown, html: null });

  assert.match(rendered.rendered_html, /<div class="table-wrap"><table>/);
  assert.match(rendered.rendered_html, /<th>Review workstream<\/th>/);
});

test('renderSourceDocument also wraps literal HTML tables', () => {
  const html = '<table><tr><th>Review workstream</th></tr><tr><td>Programme governance</td></tr></table>';

  const rendered = renderSourceDocument({ markdown: 'Source', html });

  assert.equal(
    rendered.rendered_html,
    '<div class="table-wrap"><table><tr><th>Review workstream</th></tr><tr><td>Programme governance</td></tr></table></div>'
  );
});

test('renderSourceDocument removes document-head CSS and script bodies', () => {
  const html = `<!doctype html>
    <html>
      <head>
        <title>GitHub Weekly Review</title>
        <style>:root { --ink: #111; } body { color: var(--ink); }</style>
        <script>window.bad = true;</script>
      </head>
      <body><h1>Review body</h1><p>Visible content.</p></body>
    </html>`;

  const rendered = renderSourceDocument({ markdown: '', html });

  assert.match(rendered.rendered_html, /<h1>Review body<\/h1>/);
  assert.match(rendered.rendered_html, /<p>Visible content\.<\/p>/);
  assert.doesNotMatch(rendered.rendered_html, /GitHub Weekly Review|--ink|window\.bad/);
});

test('renderSourceDocument preserves CSS shown intentionally inside a code block', () => {
  const html = '<pre><code>:root { --ink: #111; }</code></pre>';

  const rendered = renderSourceDocument({ markdown: '', html });

  assert.match(rendered.rendered_html, /:root \{ --ink: #111; \}/);
});

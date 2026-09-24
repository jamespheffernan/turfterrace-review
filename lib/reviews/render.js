const { Marked } = require('marked');
const { markedHighlight } = require('marked-highlight');
const hljs = require('highlight.js');
const xss = require('xss');

const marked = new Marked(
  markedHighlight({
    langPrefix: 'hljs language-',
    highlight(code, lang) {
      if (lang === 'mermaid') return code;
      if (lang && hljs.getLanguage(lang)) {
        return hljs.highlight(code, { language: lang }).value;
      }
      return hljs.highlightAuto(code).value;
    },
  })
);

const renderer = new marked.Renderer();
renderer.code = function renderCodeBlock({ text, lang }) {
  if (lang === 'mermaid') {
    return `<div class="mermaid">${text}</div>`;
  }
  const escaped = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return `<pre><code class="hljs language-${lang || ''}">${escaped}</code></pre>`;
};
marked.setOptions({ gfm: true, breaks: true, renderer });

function stripFrontMatter(text) {
  const source = String(text || '').replace(/^\uFEFF/, '');
  const lines = source.split(/\r?\n/);
  if (lines[0] !== '---') return source;

  const closingIndex = lines.findIndex((line, index) => (
    index > 0 && (line === '---' || line === '...')
  ));
  if (closingIndex === -1) return source;

  const firstMetadataLine = lines
    .slice(1, closingIndex)
    .find((line) => line.trim() && !line.trimStart().startsWith('#'));
  if (!firstMetadataLine || !/^[A-Za-z0-9_-]+\s*:/.test(firstMetadataLine)) {
    return source;
  }

  return lines.slice(closingIndex + 1).join('\n').replace(/^\n/, '');
}

function sanitizeRenderedHtml(rawHtml) {
  const sanitized = xss(rawHtml, {
    whiteList: {
      a: ['href', 'title', 'target'],
      b: [],
      strong: [],
      i: [],
      em: [],
      s: [],
      del: [],
      p: [],
      br: [],
      hr: [],
      h1: [],
      h2: [],
      h3: [],
      h4: [],
      h5: [],
      h6: [],
      ul: [],
      ol: [],
      li: [],
      blockquote: [],
      pre: ['class'],
      code: ['class'],
      table: [],
      thead: [],
      tbody: [],
      tr: [],
      th: ['scope'],
      td: [],
      img: ['src', 'alt', 'title'],
      span: ['class'],
      div: ['class'],
    },
    stripIgnoreTag: true,
    stripIgnoreTagBody: ['script', 'style', 'title'],
  });
  return sanitized
    .replace(/<table>/gi, '<div class="table-wrap"><table>')
    .replace(/<\/table>/gi, '</table></div>');
}

function renderSourceDocument({ markdown, html }) {
  const sourceMarkdown = markdown || '';
  const rawHtml = html || marked.parse(stripFrontMatter(sourceMarkdown));
  return {
    markdown: sourceMarkdown,
    rendered_html: sanitizeRenderedHtml(rawHtml),
  };
}

function stripMarkdownToPlain(text) {
  return stripFrontMatter(text)
    .replace(/<[^>]*>/g, '')
    .replace(/#{1,6}\s*/g, '')
    .replace(/\*{1,3}([^*]+)\*{1,3}/g, '$1')
    .replace(/`{1,3}[^`]*`{1,3}/g, '')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/!\[.*?\]\(.*?\)/g, '')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/^\s*\d+\.\s+/gm, '')
    .replace(/^\s*>\s*/gm, '')
    .replace(/---+/g, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

module.exports = {
  renderSourceDocument,
  sanitizeRenderedHtml,
  stripFrontMatter,
  stripMarkdownToPlain,
};

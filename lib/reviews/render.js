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

function sanitizeRenderedHtml(rawHtml) {
  return xss(rawHtml, {
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
  });
}

function renderSourceDocument({ markdown, html }) {
  const sourceMarkdown = markdown || '';
  const rawHtml = html || marked.parse(sourceMarkdown);
  return {
    markdown: sourceMarkdown,
    rendered_html: sanitizeRenderedHtml(rawHtml),
  };
}

function stripMarkdownToPlain(text) {
  return (text || '')
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
  stripMarkdownToPlain,
};

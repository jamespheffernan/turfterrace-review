const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ARTIFACT_MARKDOWN = 'markdown';
const ARTIFACT_CUSTOM_HTML = 'custom_html';
const ARTIFACT_TYPES = new Set([ARTIFACT_MARKDOWN, ARTIFACT_CUSTOM_HTML]);
const HTML_EXTS = new Set(['.html', '.htm']);
const MARKDOWN_EXTS = new Set(['.md', '.markdown', '.mdown', '.mkdn']);
const ALLOWED_ASSET_EXTS = new Set([
  '.css',
  '.js',
  '.mjs',
  '.json',
  '.map',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.svg',
  '.ico',
  '.woff',
  '.woff2',
  '.ttf',
  '.otf',
]);

const CONTENT_TYPES = {
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
};

function isHtmlSource(sourcePath) {
  return HTML_EXTS.has(path.extname(String(sourcePath || '')).toLowerCase());
}

function isMarkdownSource(sourcePath) {
  return MARKDOWN_EXTS.has(path.extname(String(sourcePath || '')).toLowerCase());
}

function normalizeArtifactType(value) {
  const normalized = String(value || '').trim().toLowerCase().replace(/-/g, '_');
  if (!normalized) return null;
  if (ARTIFACT_TYPES.has(normalized)) return normalized;
  return null;
}

function classifyReviewArtifact({ artifactType, markdown, html, sourcePath }) {
  const explicitType = normalizeArtifactType(artifactType);
  if (artifactType && !explicitType) {
    throw new Error(`Invalid artifactType. Allowed: ${Array.from(ARTIFACT_TYPES).join(', ')}`);
  }

  const hasMarkdown = typeof markdown === 'string' && markdown.length > 0;
  const hasHtml = typeof html === 'string' && html.length > 0;
  let type = explicitType;

  if (!type) {
    if (isHtmlSource(sourcePath)) type = ARTIFACT_CUSTOM_HTML;
    else if (hasMarkdown || isMarkdownSource(sourcePath)) type = ARTIFACT_MARKDOWN;
    else if (hasHtml) {
      throw new Error('artifactType is required when publishing raw html without an .html sourcePath');
    } else {
      type = ARTIFACT_MARKDOWN;
    }
  }

  if (type === ARTIFACT_CUSTOM_HTML) {
    const body = html || markdown || '';
    if (!body.trim()) throw new Error('html is required for custom_html artifacts');
    return {
      artifactType: ARTIFACT_CUSTOM_HTML,
      markdown: '',
      html: body,
      hashBody: `custom_html\0${body}`,
      renderedHtml: renderHtmlFallback(body),
    };
  }

  if (!hasMarkdown) throw new Error('markdown is required for markdown artifacts');
  return {
    artifactType: ARTIFACT_MARKDOWN,
    markdown,
    html: null,
    hashBody: markdown,
    renderedHtml: null,
  };
}

function stripHtmlToPlain(html) {
  return String(html || '')
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/\s+/g, ' ')
    .trim();
}

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function renderHtmlFallback(html) {
  const plain = stripHtmlToPlain(html).slice(0, 20000);
  if (!plain) return '<p>Custom HTML artifact.</p>';
  return `<pre class="artifact-text-fallback">${escapeHtml(plain)}</pre>`;
}

function getArtifactContentType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  return CONTENT_TYPES[ext] || 'application/octet-stream';
}

function getGitRoot(workspaceDir) {
  const root = execFileSync('git', ['-C', workspaceDir, 'rev-parse', '--show-toplevel'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
  return fs.realpathSync.native ? fs.realpathSync.native(root) : fs.realpathSync(root);
}

function getTrackedFiles(gitRoot, cache) {
  if (cache && cache.has(gitRoot)) return cache.get(gitRoot);
  const output = execFileSync('git', ['-C', gitRoot, 'ls-files', '-z'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const tracked = new Set(output.split('\0').filter(Boolean));
  if (cache) cache.set(gitRoot, tracked);
  return tracked;
}

function assertInside(parentDir, childPath, label) {
  const relative = path.relative(parentDir, childPath);
  if (!relative || relative === '') return relative;
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`${label} must be inside ${parentDir}`);
  }
  return relative;
}

function resolveArtifactAsset({ item, requestPath, trackedFilesCache = new Map() }) {
  if (!item || item.artifact_type !== ARTIFACT_CUSTOM_HTML) {
    throw new Error('Review item is not a custom HTML artifact');
  }
  if (!item.source_path) throw new Error('source_path is required for artifact assets');

  const rawPath = String(requestPath || '').replace(/^\/+/, '');
  if (!rawPath || rawPath.includes('\0')) throw new Error('asset path is required');
  const ext = path.extname(rawPath).toLowerCase();
  if (!ALLOWED_ASSET_EXTS.has(ext)) throw new Error('asset type is not allowed');

  const sourcePath = fs.realpathSync.native
    ? fs.realpathSync.native(item.source_path)
    : fs.realpathSync(item.source_path);
  const assetRoot = path.dirname(sourcePath);
  const candidate = path.resolve(assetRoot, rawPath);
  const realCandidate = fs.realpathSync.native
    ? fs.realpathSync.native(candidate)
    : fs.realpathSync(candidate);
  assertInside(assetRoot, realCandidate, 'asset path');

  const workspaceDir = item.workspace_dir || path.dirname(sourcePath);
  const gitRoot = getGitRoot(workspaceDir);
  const relativeToGitRoot = assertInside(gitRoot, realCandidate, 'asset path');
  const trackedFiles = getTrackedFiles(gitRoot, trackedFilesCache);
  if (!trackedFiles.has(relativeToGitRoot)) {
    throw new Error('asset path must point to a git-tracked file');
  }

  return {
    path: realCandidate,
    contentType: getArtifactContentType(realCandidate),
  };
}

module.exports = {
  ARTIFACT_CUSTOM_HTML,
  ARTIFACT_MARKDOWN,
  classifyReviewArtifact,
  getArtifactContentType,
  isHtmlSource,
  renderHtmlFallback,
  resolveArtifactAsset,
  stripHtmlToPlain,
};

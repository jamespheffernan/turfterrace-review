const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const test = require('node:test');
const assert = require('node:assert/strict');

const {
  ARTIFACT_CUSTOM_HTML,
  ARTIFACT_MARKDOWN,
  classifyReviewArtifact,
  resolveArtifactAsset,
} = require('../lib/reviews/artifacts');

test('classifyReviewArtifact keeps markdown hashes stable and namespaces custom html', () => {
  const markdown = classifyReviewArtifact({
    markdown: '# Review\n\nBody',
    sourcePath: '/repo/review.md',
  });
  assert.equal(markdown.artifactType, ARTIFACT_MARKDOWN);
  assert.equal(markdown.markdown, '# Review\n\nBody');
  assert.equal(markdown.hashBody, '# Review\n\nBody');

  const html = classifyReviewArtifact({
    html: '<!doctype html><h1>Mockup</h1>',
    artifactType: 'custom_html',
    sourcePath: '/repo/mockup.html',
  });
  assert.equal(html.artifactType, ARTIFACT_CUSTOM_HTML);
  assert.equal(html.markdown, '');
  assert.equal(html.hashBody, 'custom_html\0<!doctype html><h1>Mockup</h1>');
  assert.match(html.renderedHtml, /Mockup/);
});

test('classifyReviewArtifact infers custom html from source extension', () => {
  const artifact = classifyReviewArtifact({
    markdown: '<!doctype html><h1>Legacy script body</h1>',
    sourcePath: '/repo/mockup.html',
  });

  assert.equal(artifact.artifactType, ARTIFACT_CUSTOM_HTML);
  assert.equal(artifact.html, '<!doctype html><h1>Legacy script body</h1>');
});

test('resolveArtifactAsset serves only tracked assets inside html source directory', (t) => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-artifacts-'));
  const htmlPath = path.join(repoDir, 'mockup', 'index.html');
  const cssPath = path.join(repoDir, 'mockup', 'style.css');
  const untrackedPath = path.join(repoDir, 'mockup', 'draft.css');
  const outsidePath = path.join(repoDir, 'secret.css');

  t.after(() => {
    fs.rmSync(repoDir, { recursive: true, force: true });
  });

  fs.mkdirSync(path.dirname(htmlPath), { recursive: true });
  fs.writeFileSync(htmlPath, '<!doctype html><link rel="stylesheet" href="style.css">', 'utf8');
  fs.writeFileSync(cssPath, 'body { color: black; }', 'utf8');
  fs.writeFileSync(untrackedPath, 'body { color: red; }', 'utf8');
  fs.writeFileSync(outsidePath, 'body { color: blue; }', 'utf8');
  execFileSync('git', ['init'], { cwd: repoDir, stdio: 'ignore' });
  execFileSync('git', ['add', 'mockup/index.html', 'mockup/style.css', 'secret.css'], { cwd: repoDir, stdio: 'ignore' });

  const item = {
    artifact_type: ARTIFACT_CUSTOM_HTML,
    workspace_dir: repoDir,
    source_path: htmlPath,
  };

  const resolved = resolveArtifactAsset({ item, requestPath: 'style.css' });
  const realCssPath = fs.realpathSync.native ? fs.realpathSync.native(cssPath) : fs.realpathSync(cssPath);
  assert.equal(resolved.path, realCssPath);
  assert.equal(resolved.contentType, 'text/css; charset=utf-8');

  assert.throws(() => resolveArtifactAsset({ item, requestPath: 'draft.css' }), /git-tracked file/);
  assert.throws(() => resolveArtifactAsset({ item, requestPath: '../secret.css' }), /inside/);
});

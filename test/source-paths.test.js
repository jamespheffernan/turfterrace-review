const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const {
  assertAbsolutePath,
  assertPathInside,
  resolveGitTrackedSource,
} = require('../lib/reviews/source-paths');

test('source path helpers require absolute paths inside workspace', () => {
  assert.throws(() => assertAbsolutePath('relative/file.md', 'sourcePath'), /must be an absolute path/);

  const root = path.join(os.tmpdir(), 'workspace-root');
  const child = path.join(root, 'docs', 'file.md');
  assert.doesNotThrow(() => assertPathInside(root, child, 'sourcePath'));
  assert.throws(() => assertPathInside(root, path.join(os.tmpdir(), 'elsewhere.md'), 'sourcePath'), /inside workspaceDir/);
});

test('resolveGitTrackedSource accepts only git-tracked files inside workspace', (t) => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-source-'));
  const trackedPath = path.join(repoDir, 'review.md');
  const untrackedPath = path.join(repoDir, 'untracked.md');
  const outsidePath = path.join(os.tmpdir(), `outside-${Date.now()}.md`);

  t.after(() => {
    fs.rmSync(repoDir, { recursive: true, force: true });
    fs.rmSync(outsidePath, { force: true });
  });

  execFileSync('git', ['init'], { cwd: repoDir, stdio: 'ignore' });
  fs.writeFileSync(trackedPath, '# Review\n', 'utf8');
  fs.writeFileSync(untrackedPath, '# Not tracked\n', 'utf8');
  fs.writeFileSync(outsidePath, '# Outside\n', 'utf8');
  execFileSync('git', ['add', 'review.md'], { cwd: repoDir, stdio: 'ignore' });

  const resolved = resolveGitTrackedSource(repoDir, trackedPath);
  assert.equal(resolved.workspaceDir, repoDir);
  assert.equal(resolved.sourcePath, trackedPath);
  assert.equal(resolved.relativeToGitRoot, 'review.md');

  assert.throws(() => resolveGitTrackedSource(repoDir, untrackedPath), /git-tracked file/);
  assert.throws(() => resolveGitTrackedSource(repoDir, outsidePath), /inside workspaceDir/);
});

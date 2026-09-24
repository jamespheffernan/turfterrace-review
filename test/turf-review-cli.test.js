const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildPublishPayload,
  publishCommand,
  parseFlags,
} = require('../scripts/turf-review');

test('CLI flag parser keeps positional source and option values', () => {
  const parsed = parseFlags(['plan.md', '--title', 'Review Plan', '--category', 'general', '--json', '--ad-hoc']);

  assert.deepEqual(parsed.positional, ['plan.md']);
  assert.equal(parsed.flags.title, 'Review Plan');
  assert.equal(parsed.flags.category, 'general');
  assert.equal(parsed.flags.json, true);
  assert.equal(parsed.flags['ad-hoc'], true);
});

test('buildPublishPayload uses git-backed source provenance and artifact classification', (t) => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-cli-'));
  const planPath = path.join(repoDir, 'docs', 'plan.md');
  t.after(() => fs.rmSync(repoDir, { recursive: true, force: true }));

  fs.mkdirSync(path.dirname(planPath), { recursive: true });
  fs.writeFileSync(planPath, '# Plan\n\n## Items to review\n\n- [ ] Build it\n', 'utf8');
  execFileSync('git', ['init'], { cwd: repoDir, stdio: 'ignore' });
  execFileSync('git', ['add', 'docs/plan.md'], { cwd: repoDir, stdio: 'ignore' });

  const payload = buildPublishPayload(planPath, {
    title: 'Review Plan',
    category: 'general',
  });

  assert.equal(payload.title, 'Review Plan');
  assert.equal(payload.category, 'general');
  assert.equal(payload.workspaceDir, fs.realpathSync(repoDir));
  assert.equal(payload.sourcePath, path.resolve(planPath));
  assert.match(payload.markdown, /Items to review/);
});

test('publish command accepts positional title and category', async (t) => {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'turf-review-cli-positional-'));
  const planPath = path.join(repoDir, 'plan.md');
  t.after(() => fs.rmSync(repoDir, { recursive: true, force: true }));

  fs.writeFileSync(planPath, '# Plan\n', 'utf8');
  execFileSync('git', ['init'], { cwd: repoDir, stdio: 'ignore' });
  execFileSync('git', ['add', 'plan.md'], { cwd: repoDir, stdio: 'ignore' });

  const previousFetch = global.fetch;
  const previousLog = console.log;
  t.after(() => {
    global.fetch = previousFetch;
    console.log = previousLog;
  });

  let requestBody = null;
  console.log = () => {};
  global.fetch = async (url, options) => {
    assert.equal(url, 'http://localhost:3457/api/publish');
    requestBody = JSON.parse(options.body);
    return {
      ok: true,
      text: async () => JSON.stringify({ slug: 'plan-review' }),
    };
  };

  const result = await publishCommand([planPath, 'Review Plan', 'admin', '--ad-hoc']);

  assert.equal(result.slug, 'plan-review');
  assert.equal(requestBody.title, 'Review Plan');
  assert.equal(requestBody.category, 'admin');
});

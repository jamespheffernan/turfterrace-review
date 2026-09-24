#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const dotenv = require('dotenv');

const { classifyReviewArtifact } = require('../lib/reviews/artifacts');
const { resolveGitTrackedSource } = require('../lib/reviews/source-paths');
const { normalizeCategory } = require('../lib/review-routing');

const DEFAULT_BASE_URL = process.env.TURF_REVIEW_BASE_URL || 'http://localhost:3457';

function loadEnv() {
  const root = path.resolve(__dirname, '..');
  for (const filePath of [
    path.join(root, '.env'),
    path.join(process.env.HOME || '', 'clawd/.env.local'),
    path.join(process.env.HOME || '', 'clawd/.env'),
  ]) {
    if (filePath && fs.existsSync(filePath)) dotenv.config({ path: filePath, override: false });
  }
}

function parseFlags(argv) {
  const positional = [];
  const flags = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith('--')) {
      positional.push(arg);
      continue;
    }
    const key = arg.slice(2);
    if (key === 'json' || key === 'ad-hoc') {
      flags[key] = true;
      continue;
    }
    const next = argv[index + 1];
    if (next === undefined || next.startsWith('--')) throw new Error(`--${key} requires a value`);
    flags[key] = next;
    index += 1;
  }
  return { positional, flags };
}

function authHeader() {
  const direct = String(process.env.TURF_REVIEW_AUTH || '').trim();
  if (direct.startsWith('Basic ')) return direct;
  if (direct) return `Basic ${Buffer.from(direct).toString('base64')}`;

  const user = process.env.REVIEW_USER;
  const password = process.env.REVIEW_PASSWORD;
  if (!user || !password) return null;
  return `Basic ${Buffer.from(`${user}:${password}`).toString('base64')}`;
}

async function requestJson(baseUrl, pathname, { method = 'GET', body = null } = {}) {
  const headers = {
    Accept: 'application/json',
    'Content-Type': 'application/json',
  };
  const auth = authHeader();
  if (auth) headers.Authorization = auth;
  const response = await fetch(`${baseUrl.replace(/\/+$/, '')}${pathname}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : {};
  if (!response.ok) throw new Error(payload.error || `${method} ${pathname} failed with ${response.status}`);
  return payload;
}

function buildPublishPayload(sourceFile, flags = {}) {
  const sourcePath = path.resolve(sourceFile);
  if (!fs.existsSync(sourcePath)) throw new Error(`File not found: ${sourcePath}`);
  const workspaceDir = flags.workspace || path.dirname(sourcePath);
  const resolvedSource = resolveGitTrackedSource(workspaceDir, sourcePath);
  const content = fs.readFileSync(sourcePath, 'utf8');
  const artifact = classifyReviewArtifact({
    artifactType: flags['artifact-type'],
    markdown: content,
    html: content,
    sourcePath,
  });
  const title = flags.title || flags.t;
  if (!title) throw new Error('publish requires --title');
  const payload = {
    title,
    category: normalizeCategory(flags.category || flags.c || 'general'),
    workspaceDir: resolvedSource.gitRoot,
    sourcePath: resolvedSource.sourcePath,
  };
  if (artifact.artifactType === 'custom_html') {
    payload.html = artifact.html;
    payload.artifactType = 'custom_html';
  } else {
    payload.markdown = artifact.markdown;
  }
  if (flags.task) payload.taskId = flags.task;
  if (flags.project) payload.projectId = flags.project;
  if (flags['origin-session']) payload.originSessionKey = flags['origin-session'];
  return payload;
}

async function publishCommand(argv) {
  const { positional, flags } = parseFlags(argv);
  const sourceFile = positional[0];
  if (!sourceFile) throw new Error('publish requires a source file');
  const publishFlags = { ...flags };
  if (!publishFlags.title && positional[1]) publishFlags.title = positional[1];
  if (!publishFlags.category && positional[2]) publishFlags.category = positional[2];
  const payload = buildPublishPayload(sourceFile, publishFlags);
  const baseUrl = flags['base-url'] || DEFAULT_BASE_URL;
  const result = await requestJson(baseUrl, '/api/publish', { method: 'POST', body: payload });
  if (flags.json) console.log(JSON.stringify(result, null, 2));
  else {
    const publicBase = flags['public-base-url'] || baseUrl;
    console.log(`Published: ${publicBase.replace(/\/+$/, '')}/review/${result.slug}`);
  }
  return result;
}

async function statusCommand(argv) {
  const { positional, flags } = parseFlags(argv);
  const slug = positional[0];
  if (!slug) throw new Error('status requires a slug');
  const baseUrl = flags['base-url'] || DEFAULT_BASE_URL;
  const result = await requestJson(baseUrl, `/api/items/${encodeURIComponent(slug)}/status`);
  if (flags.json) console.log(JSON.stringify(result, null, 2));
  else {
    console.log(`${result.slug}\t${result.status}\t${result.publicVerification.status}\t${result.targets.total} target(s)\t${result.requests.total} request(s)`);
  }
  return result;
}

function printHelp() {
  console.log([
    'Usage:',
    '  turf-review.js publish <file.md|file.html> "Title" [category] [--base-url URL]',
    '  turf-review.js publish <file.md|file.html> --title "Title" [--category general] [--base-url URL]',
    '  turf-review.js status <slug> [--base-url URL] [--json]',
    '  turf-review.js inspect <slug> [--base-url URL] [--json]',
    '  turf-review.js doctor <slug> [--base-url URL] [--json]',
  ].join('\n'));
}

async function main(argv = process.argv.slice(2)) {
  loadEnv();
  const command = argv[0];
  const rest = argv.slice(1);
  if (!command || command === '--help' || command === '-h') {
    printHelp();
    return null;
  }
  if (command === 'publish') return publishCommand(rest);
  if (command === 'status' || command === 'inspect' || command === 'doctor' || command === 'verify-url') {
    return statusCommand(rest);
  }
  throw new Error(`Unknown command: ${command}`);
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}

module.exports = {
  buildPublishPayload,
  main,
  parseFlags,
  publishCommand,
  statusCommand,
};

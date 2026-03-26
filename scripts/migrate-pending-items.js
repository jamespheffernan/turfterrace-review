#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const Database = require('better-sqlite3');

const {
  ALLOWED_CATEGORIES,
  DECISION_SCHEMA_VERSION,
  getCanonicalActions,
  getSessionKey,
} = require('../lib/review-routing');

function usage() {
  console.error('Usage: node scripts/migrate-pending-items.js --config <path-to-json>');
}

function readConfig(configPath) {
  const raw = fs.readFileSync(configPath, 'utf8');
  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed)) {
    throw new Error('Migration config must be a JSON array');
  }
  return parsed;
}

function ensureAbsolutePath(value, label) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`${label} is required`);
  }
  if (!path.isAbsolute(value)) {
    throw new Error(`${label} must be an absolute path`);
  }
  return path.resolve(value);
}

function assertPathInside(parentDir, childPath, childLabel) {
  const relative = path.relative(parentDir, childPath);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`${childLabel} must be inside workspaceDir`);
  }
}

function ensureTrackedSource(workspaceDir, sourcePath) {
  const resolvedWorkspaceDir = ensureAbsolutePath(workspaceDir, 'workspaceDir');
  const resolvedSourcePath = ensureAbsolutePath(sourcePath, 'sourcePath');
  assertPathInside(resolvedWorkspaceDir, resolvedSourcePath, 'sourcePath');

  const gitRoot = execFileSync('git', ['-C', resolvedWorkspaceDir, 'rev-parse', '--show-toplevel'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
  const relative = path.relative(gitRoot, resolvedSourcePath);

  execFileSync('git', ['-C', gitRoot, 'ls-files', '--error-unmatch', relative], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });

  return {
    workspaceDir: resolvedWorkspaceDir,
    sourcePath: resolvedSourcePath,
  };
}

function main() {
  const args = process.argv.slice(2);
  const configIndex = args.indexOf('--config');
  if (configIndex === -1 || !args[configIndex + 1]) {
    usage();
    process.exit(1);
  }

  const configPath = path.resolve(args[configIndex + 1]);
  const repoRoot = path.resolve(__dirname, '..');
  const dbPath = path.join(repoRoot, 'data', 'reviews.db');
  const db = new Database(dbPath);

  const pendingItems = db.prepare(`
    SELECT slug, title, category, actions
    FROM items
    WHERE status = 'pending'
    ORDER BY created_at ASC
  `).all();

  const config = readConfig(configPath);
  const bySlug = new Map(config.map((entry) => [entry.slug, entry]));
  const missing = pendingItems.filter((item) => !bySlug.has(item.slug));

  if (missing.length > 0) {
    throw new Error(`Missing explicit mappings for pending slugs: ${missing.map((item) => item.slug).join(', ')}`);
  }

  const update = db.prepare(`
    UPDATE items
    SET category = @category,
        actions = @actions,
        session_key = @session_key,
        workspace_dir = @workspace_dir,
        source_path = @source_path,
        decision_schema_version = @decision_schema_version,
        updated_at = datetime('now')
    WHERE slug = @slug AND status = 'pending'
  `);

  const tx = db.transaction(() => {
    for (const item of pendingItems) {
      const mapping = bySlug.get(item.slug);
      if (!mapping || mapping.confirmed !== true) {
        throw new Error(`Mapping for ${item.slug} must include "confirmed": true`);
      }

      const category = String(mapping.category || '').trim().toLowerCase();
      if (!ALLOWED_CATEGORIES.has(category)) {
        throw new Error(`Invalid category for ${item.slug}: ${mapping.category}`);
      }

      const source = ensureTrackedSource(mapping.workspaceDir, mapping.sourcePath);
      update.run({
        slug: item.slug,
        category,
        actions: JSON.stringify(getCanonicalActions(category)),
        session_key: getSessionKey(item.slug),
        workspace_dir: source.workspaceDir,
        source_path: source.sourcePath,
        decision_schema_version: DECISION_SCHEMA_VERSION,
      });
    }
  });

  tx();
  db.close();
  console.log(`Migrated ${pendingItems.length} pending item(s).`);
}

try {
  main();
} catch (error) {
  console.error(error.message || error);
  process.exit(1);
}

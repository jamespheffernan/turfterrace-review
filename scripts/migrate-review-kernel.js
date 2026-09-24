#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const { loadConfig } = require('../lib/config');
const { createReviewDatabase } = require('../lib/db');
const { createReviewStatements } = require('../lib/reviews/repository');
const {
  applyKernelMigration,
  auditKernelMigration,
} = require('../lib/reviews/kernel/migrations');

function parseArgs(argv) {
  const args = {
    mode: 'audit',
    json: false,
  };
  for (const arg of argv) {
    if (arg === '--audit') args.mode = 'audit';
    else if (arg === '--apply') args.mode = 'apply';
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
}

function backupDatabase(config) {
  const dbPath = path.join(config.paths.dataDir, 'reviews.db');
  if (!fs.existsSync(dbPath)) return null;
  const backupPath = `${dbPath}.kernel-v1-${new Date().toISOString().replace(/[:.]/g, '-')}.bak`;
  fs.copyFileSync(dbPath, backupPath);
  return backupPath;
}

function printHuman(report) {
  console.log(`mode: ${report.mode || 'apply'}`);
  console.log(`total: ${report.total}`);
  console.log(`executable: ${report.executable}`);
  console.log(`legacyReadonly: ${report.legacyReadonly}`);
  if (report.backupPath) console.log(`backupPath: ${report.backupPath}`);
  for (const item of report.items) {
    const suffix = item.blockedReasons.length ? ` (${item.blockedReasons.join(', ')})` : '';
    console.log(`${item.slug}\t${item.proposedAction}${suffix}`);
  }
}

function main(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (args.help) {
    console.log('Usage: migrate-review-kernel.js [--audit|--apply] [--json]');
    return 0;
  }

  const config = loadConfig(process.env, path.resolve(__dirname, '..'));
  const db = createReviewDatabase({ dataDir: config.paths.dataDir });
  const stmts = createReviewStatements(db);
  try {
    const report = args.mode === 'apply'
      ? applyKernelMigration({ db, stmts, backupPath: backupDatabase(config) })
      : auditKernelMigration({ db, stmts });
    if (args.json) console.log(JSON.stringify(report, null, 2));
    else printHuman(report);
    return 0;
  } finally {
    db.close();
  }
}

if (require.main === module) {
  try {
    process.exitCode = main();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = {
  main,
  parseArgs,
};

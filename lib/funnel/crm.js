const os = require('os');
const path = require('path');
const Database = require('better-sqlite3');

const DEFAULT_CRM_DB_PATH = process.env.KITCHENLUX_CRM_DB_PATH || path.resolve(os.homedir(), 'clawd', 'data', 'kitchenlux-crm.db');
const REQUIRED_TABLES = ['contacts', 'queue_items', 'send_attempts', 'draft_batches'];

function assertRequiredTables(db, filePath) {
  const existing = db
    .prepare(`SELECT name FROM sqlite_master WHERE type = 'table'`)
    .all()
    .map((row) => row.name);
  const found = new Set(existing);
  const missing = REQUIRED_TABLES.filter((tableName) => !found.has(tableName));

  if (missing.length > 0) {
    throw new Error(`KitchenLux CRM DB is missing required tables [${missing.join(', ')}] in ${filePath}`);
  }
}

function openCrmDb(filePath = DEFAULT_CRM_DB_PATH) {
  const db = new Database(filePath, {
    readonly: true,
    fileMustExist: true,
  });

  db.pragma('busy_timeout = 5000');
  db.pragma('query_only = ON');
  db.pragma('foreign_keys = ON');

  try {
    assertRequiredTables(db, filePath);
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}

module.exports = {
  DEFAULT_CRM_DB_PATH,
  openCrmDb,
};

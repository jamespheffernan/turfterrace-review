#!/usr/bin/env node

require('dotenv').config();

const path = require('path');
const Database = require('better-sqlite3');

const { createOpenClawClient } = require('../lib/openclaw');
const { getSessionKey } = require('../lib/review-routing');

const REVIEW_BASE_URL = process.env.REVIEW_BASE_URL || process.env.APP_BASE_URL || 'http://localhost:3457';
const OPENCLAW_TOKEN = process.env.OPENCLAW_TOKEN || '';
const OPENCLAW_BASE_URL = process.env.OPENCLAW_BASE_URL || 'http://127.0.0.1:18789/v1';
const OPENCLAW_AGENT_ID = process.env.OPENCLAW_AGENT_ID || 'main';
const CHAT_MODEL = process.env.CHAT_MODEL || `openclaw/${OPENCLAW_AGENT_ID}`;
const DATA_DIR = process.env.TURF_REVIEW_DATA_DIR || path.join(__dirname, '..', 'data');

function parseArgs(argv) {
  const args = {
    all: false,
    includeParked: true,
    dryRun: false,
    slugs: [],
  };

  for (const value of argv) {
    if (value === '--all') args.all = true;
    else if (value === '--pending-only') args.includeParked = false;
    else if (value === '--dry-run') args.dryRun = true;
    else args.slugs.push(value);
  }

  return args;
}

function buildReviewUrl(slug) {
  return new URL(`/review/${slug}`, REVIEW_BASE_URL).toString();
}

function buildBootstrapPayload(item, reviewUrl) {
  return {
    responseInstruction: 'Reply only with an internal Turf Review message. Do not produce any user-facing text.',
    instruction: 'Read the full document now and build a working understanding before Jimmy opens chat. Produce only an internal Turf Review note with your private digest of the document, key intent, risks, and any ambiguities. Do not send any user-facing text until Jimmy chats with this review or triggers a decision.',
    bootstrapChecklist: [
      'Read the full document body in this bootstrap payload.',
      'Summarize the document intent and the main points privately.',
      'Note likely review risks, execution concerns, or ambiguities privately.',
      'Keep the result internal-only; do not speak to Jimmy yet.',
    ],
    title: item.title,
    slug: item.slug,
    category: item.category,
    reviewUrl,
    source: {
      workspaceDir: item.workspace_dir,
      sourcePath: item.source_path,
    },
    document: item.markdown || item.rendered_html,
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!OPENCLAW_TOKEN && !args.dryRun) {
    throw new Error('OPENCLAW_TOKEN is required to reseed OpenClaw sessions');
  }

  const db = new Database(path.join(DATA_DIR, 'reviews.db'), { readonly: true });
  const openclaw = OPENCLAW_TOKEN ? createOpenClawClient({
    token: OPENCLAW_TOKEN,
    baseUrl: OPENCLAW_BASE_URL,
    agentId: OPENCLAW_AGENT_ID,
    model: CHAT_MODEL,
  }) : null;

  let rows;
  if (args.slugs.length > 0) {
    const stmt = db.prepare(`
      SELECT slug, title, category, status, markdown, rendered_html, session_key, workspace_dir, source_path
      FROM items
      WHERE slug = ?
    `);
    rows = args.slugs
      .map((slug) => stmt.get(slug))
      .filter(Boolean);
  } else if (args.all) {
    rows = db.prepare(`
      SELECT slug, title, category, status, markdown, rendered_html, session_key, workspace_dir, source_path
      FROM items
      WHERE session_key IS NOT NULL
      ORDER BY created_at DESC
    `).all();
  } else {
    const statuses = args.includeParked ? ['pending', 'parked'] : ['pending'];
    const placeholders = statuses.map(() => '?').join(', ');
    rows = db.prepare(`
      SELECT slug, title, category, status, markdown, rendered_html, session_key, workspace_dir, source_path
      FROM items
      WHERE session_key IS NOT NULL
        AND status IN (${placeholders})
      ORDER BY created_at DESC
    `).all(...statuses);
  }

  if (!rows.length) {
    console.log('No matching review items found.');
    return;
  }

  console.log(`Reseeding ${rows.length} session(s)...`);

  for (const item of rows) {
    const sessionKey = item.session_key || getSessionKey(item.slug);
    const reviewUrl = buildReviewUrl(item.slug);
    const payload = buildBootstrapPayload(item, reviewUrl);

    if (args.dryRun) {
      console.log(`DRY RUN ${item.slug} -> ${sessionKey}`);
      continue;
    }

    await openclaw.appendInternalMessage({
      sessionKey,
      content: `[TURF_REVIEW_INTERNAL] refresh\n${JSON.stringify(payload, null, 2)}`,
    });
    console.log(`OK ${item.slug} -> ${sessionKey}`);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});

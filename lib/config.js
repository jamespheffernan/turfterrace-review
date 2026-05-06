const path = require('path');

function parsePort(value, fallback = 3457) {
  const parsed = Number(value);
  if (Number.isInteger(parsed) && parsed > 0 && parsed < 65536) return parsed;
  return fallback;
}

function loadConfig(env = process.env, rootDir = path.resolve(__dirname, '..')) {
  if (!env.SESSION_SECRET) {
    throw new Error('SESSION_SECRET environment variable must be set. Refusing to start with a weak fallback.');
  }

  const openclawAgentId = env.OPENCLAW_AGENT_ID || 'main';
  const dataDir = env.TURF_REVIEW_DATA_DIR
    ? path.resolve(env.TURF_REVIEW_DATA_DIR)
    : path.join(rootDir, 'data');

  return {
    rootDir,
    port: parsePort(env.PORT),
    host: env.TURF_REVIEW_HOST || env.HOST || '',
    paths: {
      dataDir,
      publicDir: path.join(rootDir, 'public'),
      viewsDir: path.join(rootDir, 'views'),
      ttsCacheDir: path.join(rootDir, 'tts-cache'),
      uploadsDir: path.join(dataDir, 'uploads'),
      audioDir: path.join(dataDir, 'audio'),
    },
    auth: {
      reviewUser: env.REVIEW_USER || '',
      reviewPassword: env.REVIEW_PASSWORD || '',
      sessionSecret: env.SESSION_SECRET,
    },
    openai: {
      apiKey: env.OPENAI_API_KEY || '',
    },
    openclaw: {
      token: env.OPENCLAW_TOKEN || '',
      baseUrl: env.OPENCLAW_BASE_URL || 'http://127.0.0.1:18789/v1',
      agentId: openclawAgentId,
      chatModel: env.CHAT_MODEL || `openclaw/${openclawAgentId}`,
      bin: env.OPENCLAW_BIN || '/opt/homebrew/bin/openclaw',
      telegramTarget: env.TURF_REVIEW_TELEGRAM_TARGET || '8339963854',
      telegramReplyTo: env.TURF_REVIEW_TELEGRAM_REPLY_TO || '',
    },
    integrations: {
      omnifocusBin: env.TURF_REVIEW_OMNIFOCUS_BIN || path.join(env.HOME || '', '.bun/bin/of'),
      calendarName: env.TURF_REVIEW_CALENDAR_NAME || 'Calendar',
      clawdRoot: env.TURF_REVIEW_CLAWD_ROOT || '/Users/username/clawd',
      bunBin: env.TURF_REVIEW_BUN_BIN || '/opt/homebrew/bin/bun',
      reviewDecisionIngestScript: env.TURF_REVIEW_DECISION_INGEST_SCRIPT || '/Users/username/clawd/scripts/review-decision-ingest.ts',
      kitchenLuxCrmDb: env.TURF_REVIEW_KITCHENLUX_CRM_DB || '/Users/username/clawd/data/kitchenlux-crm.db',
    },
    reviewBaseUrl: env.TURF_REVIEW_BASE_URL || '',
  };
}

module.exports = {
  loadConfig,
  parsePort,
};

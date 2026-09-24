const crypto = require('crypto');
const fs = require('fs');
const http2 = require('http2');

const APNS_HOSTS = {
  development: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
};
const SUPPORTED_TARGETS = new Map([
  ['ios:com.jamesheffernan.turfreviewnative', true],
  ['macos:com.jamesheffernan.turfreviewmac', true],
]);
const DEVICE_TOKEN_PATTERN = /^[0-9a-f]{32,256}$/;
const MAX_ATTEMPTS = 6;
const STALE_CLAIM_MINUTES = 5;
const PROVIDER_TOKEN_LIFETIME_SECONDS = 50 * 60;

function normalizeDeviceRegistration(value = {}) {
  const token = String(value.token || '').trim().toLowerCase();
  const platform = String(value.platform || '').trim().toLowerCase();
  const environment = String(value.environment || '').trim().toLowerCase();
  const bundleId = String(value.bundleId || '').trim();

  if (!DEVICE_TOKEN_PATTERN.test(token)) {
    throw new Error('token must be a hexadecimal APNs device token');
  }
  if (!['ios', 'macos'].includes(platform)) {
    throw new Error('platform must be ios or macos');
  }
  if (!Object.hasOwn(APNS_HOSTS, environment)) {
    throw new Error('environment must be development or production');
  }
  if (!SUPPORTED_TARGETS.has(`${platform}:${bundleId}`)) {
    throw new Error('bundleId is not a supported Turf Review notification target');
  }

  return { token, platform, environment, bundleId };
}

function base64url(value) {
  return Buffer.from(value)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

function truncateText(value, maxLength) {
  const text = String(value || '').trim();
  if (text.length <= maxLength) return text;
  return `${text.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
}

function parseAPNsBody(body) {
  if (!body) return {};
  try {
    return JSON.parse(body);
  } catch (_error) {
    return {};
  }
}

function createAPNsTransport({ teamId, keyId, privateKey, privateKeyPath }) {
  const clients = new Map();
  let cachedProviderToken = null;
  let cachedProviderTokenIssuedAt = 0;

  function loadPrivateKey() {
    if (privateKey) return privateKey.replace(/\\n/g, '\n');
    if (privateKeyPath) return fs.readFileSync(privateKeyPath, 'utf8');
    throw new Error('APNs private key is not configured');
  }

  function providerToken() {
    const issuedAt = Math.floor(Date.now() / 1000);
    if (
      cachedProviderToken
      && issuedAt - cachedProviderTokenIssuedAt < PROVIDER_TOKEN_LIFETIME_SECONDS
    ) {
      return cachedProviderToken;
    }

    if (!teamId || !keyId) throw new Error('APNs team ID and key ID are required');
    const header = base64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
    const claims = base64url(JSON.stringify({ iss: teamId, iat: issuedAt }));
    const signingInput = `${header}.${claims}`;
    const signature = crypto.sign('sha256', Buffer.from(signingInput), {
      key: loadPrivateKey(),
      dsaEncoding: 'ieee-p1363',
    });
    cachedProviderToken = `${signingInput}.${base64url(signature)}`;
    cachedProviderTokenIssuedAt = issuedAt;
    return cachedProviderToken;
  }

  function clientFor(environment) {
    const existing = clients.get(environment);
    if (existing && !existing.closed && !existing.destroyed) return existing;

    const client = http2.connect(APNS_HOSTS[environment]);
    const clear = () => {
      if (clients.get(environment) === client) clients.delete(environment);
    };
    client.on('close', clear);
    client.on('error', clear);
    clients.set(environment, client);
    return client;
  }

  async function send({ deviceToken, environment, bundleId, apnsId, collapseId, payload }) {
    const client = clientFor(environment);
    const body = JSON.stringify(payload);

    return new Promise((resolve, reject) => {
      let settled = false;
      let responseBody = '';
      let responseHeaders = null;
      const request = client.request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${providerToken()}`,
        'apns-id': apnsId,
        'apns-topic': bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-collapse-id': collapseId,
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      });

      const finish = (error, result) => {
        if (settled) return;
        settled = true;
        if (error) reject(error);
        else resolve(result);
      };

      request.setEncoding('utf8');
      request.on('response', (headers) => {
        responseHeaders = headers;
      });
      request.on('data', (chunk) => {
        responseBody += chunk;
      });
      request.on('end', () => {
        const status = Number(responseHeaders?.[':status'] || 0);
        finish(null, {
          status,
          apnsId: responseHeaders?.['apns-id'] || apnsId,
          ...parseAPNsBody(responseBody),
        });
      });
      request.on('error', (error) => finish(error));
      request.setTimeout(15_000, () => {
        request.close(http2.constants.NGHTTP2_CANCEL);
        finish(new Error('APNs request timed out'));
      });
      request.end(body);
    });
  }

  function invalidateProviderToken() {
    cachedProviderToken = null;
    cachedProviderTokenIssuedAt = 0;
  }

  function close() {
    for (const client of clients.values()) client.close();
    clients.clear();
  }

  return { close, invalidateProviderToken, send };
}

function createPushNotificationService({ db, baseUrl, env = process.env, logger = console, transport } = {}) {
  if (!db) throw new Error('db is required');
  const publicBaseUrl = baseUrl || 'https://review.turfterrace.com';
  const teamId = env.TURF_REVIEW_APNS_TEAM_ID || '';
  const keyId = env.TURF_REVIEW_APNS_KEY_ID || '';
  const privateKey = env.TURF_REVIEW_APNS_PRIVATE_KEY || '';
  const privateKeyPath = env.TURF_REVIEW_APNS_PRIVATE_KEY_PATH || '';
  const configured = Boolean(teamId && keyId && (privateKey || privateKeyPath));
  const apns = transport || createAPNsTransport({ teamId, keyId, privateKey, privateKeyPath });
  let draining = false;
  let drainScheduled = false;
  let retryTimer = null;

  const statements = {
    getDevice: db.prepare(`
      SELECT * FROM push_devices
      WHERE device_token = @device_token
        AND environment = @environment
        AND bundle_id = @bundle_id
    `),
    registerDevice: db.prepare(`
      INSERT INTO push_devices (
        device_token, platform, environment, bundle_id, active, invalidated_at,
        last_registered_at, updated_at
      ) VALUES (
        @device_token, @platform, @environment, @bundle_id, 1, NULL,
        datetime('now'), datetime('now')
      )
      ON CONFLICT(device_token, environment, bundle_id) DO UPDATE SET
        platform = excluded.platform,
        active = 1,
        invalidated_at = NULL,
        last_registered_at = datetime('now'),
        updated_at = datetime('now')
    `),
    unregisterDevice: db.prepare(`
      UPDATE push_devices
      SET active = 0,
          invalidated_at = datetime('now'),
          updated_at = datetime('now')
      WHERE device_token = @device_token
        AND environment = @environment
        AND bundle_id = @bundle_id
        AND active = 1
    `),
    listActiveDevices: db.prepare(`
      SELECT id FROM push_devices WHERE active = 1 ORDER BY id ASC
    `),
    enqueueDelivery: db.prepare(`
      INSERT OR IGNORE INTO push_deliveries (
        review_slug, device_id, apns_id, status
      ) VALUES (
        @review_slug, @device_id, @apns_id, 'queued'
      )
    `),
    recoverStale: db.prepare(`
      UPDATE push_deliveries
      SET status = 'queued',
          next_attempt_at = datetime('now'),
          last_error = 'Recovered interrupted APNs delivery',
          updated_at = datetime('now')
      WHERE status = 'sending'
        AND claimed_at <= datetime('now', '-' || @minutes || ' minutes')
    `),
    listReadyDeliveries: db.prepare(`
      SELECT
        delivery.*,
        item.title,
        device.device_token,
        device.environment,
        device.bundle_id,
        device.platform
      FROM push_deliveries AS delivery
      JOIN push_devices AS device ON device.id = delivery.device_id
      JOIN items AS item ON item.slug = delivery.review_slug
      WHERE delivery.status = 'queued'
        AND device.active = 1
        AND (delivery.next_attempt_at IS NULL OR delivery.next_attempt_at <= datetime('now'))
      ORDER BY delivery.created_at ASC, delivery.id ASC
      LIMIT @limit
    `),
    claimDelivery: db.prepare(`
      UPDATE push_deliveries
      SET status = 'sending',
          attempts = attempts + 1,
          claimed_at = datetime('now'),
          last_error = NULL,
          updated_at = datetime('now')
      WHERE id = @id AND status = 'queued'
    `),
    markSent: db.prepare(`
      UPDATE push_deliveries
      SET status = 'sent',
          response_apns_id = @response_apns_id,
          sent_at = datetime('now'),
          claimed_at = NULL,
          next_attempt_at = NULL,
          last_error = NULL,
          updated_at = datetime('now')
      WHERE id = @id
    `),
    markRetry: db.prepare(`
      UPDATE push_deliveries
      SET status = 'queued',
          claimed_at = NULL,
          next_attempt_at = datetime('now', '+' || @delay_seconds || ' seconds'),
          last_error = @last_error,
          updated_at = datetime('now')
      WHERE id = @id
    `),
    markFailed: db.prepare(`
      UPDATE push_deliveries
      SET status = 'failed',
          claimed_at = NULL,
          next_attempt_at = NULL,
          last_error = @last_error,
          updated_at = datetime('now')
      WHERE id = @id
    `),
    invalidateDevice: db.prepare(`
      UPDATE push_devices
      SET active = 0,
          invalidated_at = datetime('now'),
          updated_at = datetime('now')
      WHERE id = @id
    `),
  };

  function registerDevice(value) {
    const registration = normalizeDeviceRegistration(value);
    const params = {
      device_token: registration.token,
      platform: registration.platform,
      environment: registration.environment,
      bundle_id: registration.bundleId,
    };
    const existing = statements.getDevice.get(params);
    statements.registerDevice.run(params);
    return {
      created: !existing,
      active: true,
      configured,
    };
  }

  function unregisterDevice(value) {
    const registration = normalizeDeviceRegistration(value);
    const result = statements.unregisterDevice.run({
      device_token: registration.token,
      environment: registration.environment,
      bundle_id: registration.bundleId,
    });
    return { deactivated: result.changes > 0 };
  }

  function enqueueReview(slug) {
    let enqueued = 0;
    for (const device of statements.listActiveDevices.all()) {
      const result = statements.enqueueDelivery.run({
        review_slug: slug,
        device_id: device.id,
        apns_id: crypto.randomUUID(),
      });
      enqueued += result.changes;
    }
    return enqueued;
  }

  function reviewURL(slug) {
    return new URL(`/review/${encodeURIComponent(slug)}`, publicBaseUrl).toString();
  }

  function payloadFor(row) {
    const url = reviewURL(row.review_slug);
    return {
      aps: {
        alert: {
          title: 'New Turf Review',
          body: truncateText(row.title, 180) || 'A new review is ready.',
        },
        sound: 'default',
      },
      reviewURL: url,
      slug: row.review_slug,
    };
  }

  function errorText(error) {
    return truncateText(error?.message || String(error || 'Unknown APNs error'), 500);
  }

  function scheduleRetry(row, error) {
    const attempt = Number(row.attempts || 0) + 1;
    const lastError = errorText(error);
    if (attempt >= MAX_ATTEMPTS) {
      statements.markFailed.run({ id: row.id, last_error: lastError });
      return;
    }
    const delaySeconds = Math.min(15 * (2 ** Math.max(0, attempt - 1)), 15 * 60);
    statements.markRetry.run({
      id: row.id,
      delay_seconds: delaySeconds,
      last_error: lastError,
    });
  }

  async function deliver(row) {
    const collapseId = crypto.createHash('sha256').update(row.review_slug).digest('hex');
    let response;
    try {
      response = await apns.send({
        deviceToken: row.device_token,
        environment: row.environment,
        bundleId: row.bundle_id,
        apnsId: row.apns_id,
        collapseId,
        payload: payloadFor(row),
      });
    } catch (error) {
      scheduleRetry(row, error);
      return;
    }

    if (response.status === 200) {
      statements.markSent.run({
        id: row.id,
        response_apns_id: response.apnsId || row.apns_id,
      });
      return;
    }

    const reason = response.reason || `APNs returned HTTP ${response.status || 'unknown'}`;
    if (
      response.status === 410
      || ['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'].includes(reason)
    ) {
      const deactivate = db.transaction(() => {
        statements.invalidateDevice.run({ id: row.device_id });
        statements.markFailed.run({ id: row.id, last_error: reason });
      });
      deactivate();
      return;
    }

    if (response.status === 403) apns.invalidateProviderToken();
    if (response.status === 403 || response.status === 429 || response.status >= 500) {
      scheduleRetry(row, new Error(reason));
      return;
    }
    statements.markFailed.run({ id: row.id, last_error: reason });
  }

  async function drain(limit = 25) {
    if (!configured || draining) return { configured, processed: 0 };
    draining = true;
    let processed = 0;
    try {
      statements.recoverStale.run({ minutes: STALE_CLAIM_MINUTES });
      const rows = statements.listReadyDeliveries.all({ limit });
      for (const row of rows) {
        const claim = statements.claimDelivery.run({ id: row.id });
        if (claim.changes === 0) continue;
        processed += 1;
        await deliver(row);
      }
      return { configured: true, processed };
    } finally {
      draining = false;
    }
  }

  function scheduleDrain() {
    if (!configured || drainScheduled) return;
    drainScheduled = true;
    setImmediate(async () => {
      drainScheduled = false;
      try {
        await drain();
      } catch (error) {
        logger.error(`[push] APNs drain failed: ${errorText(error)}`);
      }
    });
  }

  function start() {
    if (!configured) {
      logger.warn('[push] APNs delivery disabled: provider credentials are not configured');
      return;
    }
    scheduleDrain();
    retryTimer = setInterval(scheduleDrain, 30_000);
    retryTimer.unref?.();
  }

  function close() {
    if (retryTimer) clearInterval(retryTimer);
    retryTimer = null;
    apns.close?.();
  }

  return {
    close,
    configured,
    drain,
    enqueueReview,
    registerDevice,
    scheduleDrain,
    start,
    unregisterDevice,
  };
}

module.exports = {
  createAPNsTransport,
  createPushNotificationService,
  normalizeDeviceRegistration,
};

const crypto = require('crypto');
const { WebSocketServer } = require('ws');

const { createOpenClawClient } = require('../openclaw');
const { getSessionKey, isInternalMessageText } = require('../review-routing');

function createChatModule(config = {}) {
  if (!config.openclawToken) {
    return null;
  }

  const openclaw = createOpenClawClient({
    token: config.openclawToken,
    baseUrl: config.openclawBaseUrl,
    model: config.chatModel,
    agentId: config.openclawAgentId || 'main',
  });

  const tokenStore = new Map();
  const activeSockets = new Map();
  const activeStreams = new Map();

  function cleanupExpiredTokens() {
    const now = Date.now();
    for (const [token, entry] of tokenStore.entries()) {
      if (now - entry.created > 5 * 60 * 1000) {
        tokenStore.delete(token);
      }
    }
  }

  function generateChatToken(slug) {
    cleanupExpiredTokens();
    const token = crypto.randomBytes(32).toString('hex');
    tokenStore.set(token, { slug, created: Date.now() });
    return token;
  }

  function getTokenEntry(token) {
    cleanupExpiredTokens();
    return tokenStore.get(token) || null;
  }

  async function loadVisibleHistory(slug, item) {
    const sessionKey = item?.session_key || getSessionKey(slug);
    const rows = await openclaw.getHistory(sessionKey, 200);
    return rows.filter((row) => {
      if (!row) return false;
      if (!['user', 'assistant'].includes(row.role)) return false;
      if (!row.content || isInternalMessageText(row.content)) return false;
      return true;
    });
  }

  async function sendHistory(ws, slug, item) {
    const messages = await loadVisibleHistory(slug, item);
    ws.send(JSON.stringify({ type: 'history', messages }));
  }

  function abortActiveStream(slug) {
    const controller = activeStreams.get(slug);
    if (!controller) return;
    controller.abort();
    activeStreams.delete(slug);
  }

  function attachToServer(server, getItem) {
    const wss = new WebSocketServer({ noServer: true });

    server.on('upgrade', (req, socket, head) => {
      const match = req.url.match(/^\/ws\/chat\/([^/?]+)/);
      if (!match) {
        socket.destroy();
        return;
      }

      const slug = decodeURIComponent(match[1]);
      const url = new URL(req.url, `http://${req.headers.host}`);
      const token = url.searchParams.get('token');
      const tokenEntry = getTokenEntry(token);

      if (!tokenEntry || tokenEntry.slug !== slug) {
        socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
        socket.destroy();
        return;
      }

      const origin = req.headers.origin || '';
      const host = req.headers.host || '';
      if (origin && !origin.includes(host)) {
        socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
        socket.destroy();
        return;
      }

      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit('connection', ws, req, slug);
      });
    });

    const heartbeat = setInterval(() => {
      wss.clients.forEach((ws) => {
        if (!ws.isAlive) return ws.terminate();
        ws.isAlive = false;
        ws.ping();
      });
    }, 15000);
    heartbeat.unref();

    wss.on('connection', async (ws, _req, slug) => {
      ws.isAlive = true;
      ws.on('pong', () => {
        ws.isAlive = true;
      });

      const item = getItem(slug);
      if (!item) {
        ws.send(JSON.stringify({ type: 'error', message: 'Review item not found' }));
        ws.close(1008, 'item_not_found');
        return;
      }

      const existingSocket = activeSockets.get(slug);
      if (existingSocket && existingSocket !== ws) {
        try {
          existingSocket.close(1000, 'replaced');
        } catch (_error) {
          // Ignore replaced socket failures.
        }
      }
      activeSockets.set(slug, ws);

      try {
        await sendHistory(ws, slug, item);
      } catch (error) {
        ws.send(JSON.stringify({ type: 'error', message: error.message }));
      }

      ws.on('message', async (data) => {
        let parsed;
        try {
          parsed = JSON.parse(data.toString());
        } catch (_error) {
          ws.send(JSON.stringify({ type: 'error', message: 'Invalid JSON' }));
          return;
        }

        const freshItem = getItem(slug) || item;
        const sessionKey = freshItem.session_key || getSessionKey(slug);

        if (parsed.type === 'history') {
          try {
            await sendHistory(ws, slug, freshItem);
          } catch (error) {
            ws.send(JSON.stringify({ type: 'error', message: error.message }));
          }
          return;
        }

        if (parsed.type === 'new_chat') {
          abortActiveStream(slug);
          ws.send(JSON.stringify({ type: 'session_reset' }));
          try {
            await sendHistory(ws, slug, freshItem);
          } catch (error) {
            ws.send(JSON.stringify({ type: 'error', message: error.message }));
          }
          return;
        }

        if (parsed.type !== 'message' || !String(parsed.content || '').trim()) {
          return;
        }

        abortActiveStream(slug);
        const messageId = crypto.randomUUID();
        const controller = new AbortController();
        activeStreams.set(slug, controller);

        ws.send(JSON.stringify({ type: 'thinking' }));

        try {
          const result = await openclaw.streamCompletion({
            sessionKey,
            signal: controller.signal,
            messages: [{ role: 'user', content: String(parsed.content).trim() }],
            onChunk(chunk) {
              if (ws.readyState !== 1) return;
              ws.send(JSON.stringify({
                type: 'chunk',
                content: chunk,
                message_id: messageId,
              }));
            },
          });

          if (controller.signal.aborted) return;

          ws.send(JSON.stringify({
            type: 'message',
            id: messageId,
            role: 'assistant',
            content: result.text,
          }));
        } catch (error) {
          if (!controller.signal.aborted) {
            ws.send(JSON.stringify({
              type: 'error',
              message: error.message || 'Failed to get response',
            }));
          }
        } finally {
          if (activeStreams.get(slug) === controller) {
            activeStreams.delete(slug);
          }
        }
      });

      ws.on('close', () => {
        if (activeSockets.get(slug) === ws) {
          activeSockets.delete(slug);
        }
      });
    });
  }

  return {
    attachToServer,
    generateChatToken,
  };
}

module.exports = { createChatModule };

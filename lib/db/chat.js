const crypto = require("crypto");
const path = require("path");

const Database = require("better-sqlite3");
const OpenAI = require("openai");
const { WebSocketServer } = require("ws");

const { ensureParentDirectory } = require("../utils");

function createChatModule(config) {
  const chatDbPath = path.join(config.dataDir, "chat.db");
  ensureParentDirectory(chatDbPath);

  const db = new Database(chatDbPath);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");

  db.exec(`
    CREATE TABLE IF NOT EXISTS chat_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL,
      status TEXT DEFAULT 'active',
      metadata TEXT,
      created_at TEXT DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS chat_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL REFERENCES chat_sessions(id),
      message_id TEXT NOT NULL,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      failure_reason TEXT,
      created_at TEXT DEFAULT (datetime('now'))
    );
  `);

  try {
    db.exec(`
      CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_sessions_active_slug
        ON chat_sessions(slug) WHERE status = 'active';
      CREATE INDEX IF NOT EXISTS idx_chat_messages_session
        ON chat_messages(session_id);
    `);
  } catch (_error) {
    // Indexes may already exist.
  }

  const stmts = {
    createSession: db.prepare(`
      INSERT INTO chat_sessions (slug, metadata)
      VALUES (@slug, @metadata)
    `),
    getActiveSession: db.prepare(`
      SELECT * FROM chat_sessions
      WHERE slug = @slug AND status = 'active'
      ORDER BY created_at DESC LIMIT 1
    `),
    closeSession: db.prepare(`
      UPDATE chat_sessions SET status = 'closed'
      WHERE id = @id
    `),
    closeActiveBySlug: db.prepare(`
      UPDATE chat_sessions SET status = 'closed'
      WHERE slug = @slug AND status = 'active'
    `),
    insertMessage: db.prepare(`
      INSERT INTO chat_messages (session_id, message_id, role, content)
      VALUES (@session_id, @message_id, @role, @content)
    `),
    updateMessageFailure: db.prepare(`
      UPDATE chat_messages SET failure_reason = @failure_reason
      WHERE id = @id
    `),
    getSessionMessages: db.prepare(`
      SELECT id, message_id, role, content, created_at
      FROM chat_messages
      WHERE session_id = @session_id
      ORDER BY created_at ASC, id ASC
    `),
  };

  const openai = config.openclawToken
    ? new OpenAI({
        apiKey: config.openclawToken,
        baseURL: config.openclawBaseUrl || "http://127.0.0.1:18789/v1",
      })
    : config.openaiApiKey
      ? new OpenAI({ apiKey: config.openaiApiKey })
      : null;

  // --- Token management for WebSocket auth ---
  const tokenStore = new Map();

  function generateChatToken(slug) {
    const token = crypto.randomBytes(32).toString("hex");
    tokenStore.set(token, { slug, created: Date.now() });
    setTimeout(() => tokenStore.delete(token), 60000);
    return token;
  }

  function consumeToken(token) {
    const entry = tokenStore.get(token);
    if (!entry) return null;
    if (Date.now() - entry.created > 60000) {
      tokenStore.delete(token);
      return null;
    }
    tokenStore.delete(token);
    return entry;
  }

  // --- Session management ---
  const activeSessions = new Map(); // slug -> { ws, idleTimer, sessionId, abortController }

  function getOrCreateSession(slug, item) {
    let session = stmts.getActiveSession.get({ slug });
    if (!session) {
      const metadata = JSON.stringify({
        agent_id: item?.mindwtr_task_id || "unknown",
        model_used: item?.context_summary ? "gpt-5-mini" : "unknown",
        original_prompt: null,
      });
      const result = stmts.createSession.run({ slug, metadata });
      session = { id: result.lastInsertRowid, slug, status: "active", metadata };
    }
    return session;
  }

  function buildSystemPrompt(item) {
    let metadata = {};
    const session = stmts.getActiveSession.get({ slug: item.slug });
    if (session?.metadata) {
      try {
        metadata = JSON.parse(session.metadata);
      } catch (_e) {
        // Ignore.
      }
    }

    return `You are the author of a review item on Turf Review. Jimmy is asking you questions about your work.

## Original Context
Agent: ${metadata.agent_id || "unknown"}
Model: ${metadata.model_used || "unknown"}
Original prompt: ${metadata.original_prompt || "not available"}

## Review Item
Title: ${item.title}
Category: ${item.category}
Status: ${item.status}
Created: ${item.created_at}

## Content
${item.markdown || item.rendered_html}

## Your Role
- Answer questions about why you made certain choices
- Explain your reasoning
- If Jimmy requests edits, describe what you'd change (don't modify files directly)
- Be honest about limitations or uncertainties in your work
- Reference specific sections of the content when relevant`;
  }

  function resetIdleTimer(slug) {
    const state = activeSessions.get(slug);
    if (!state) return;
    if (state.idleTimer) clearTimeout(state.idleTimer);
    state.idleTimer = setTimeout(() => {
      closeSlugSession(slug, "idle_timeout");
    }, 30 * 60 * 1000);
  }

  function closeSlugSession(slug, reason) {
    const state = activeSessions.get(slug);
    if (!state) return;
    if (state.idleTimer) clearTimeout(state.idleTimer);
    if (state.abortController) state.abortController.abort();
    stmts.closeActiveBySlug.run({ slug });
    try {
      if (state.ws && state.ws.readyState === 1) {
        state.ws.send(JSON.stringify({ type: "session_reset" }));
        state.ws.close(1000, reason || "session_closed");
      }
    } catch (_e) {
      // Ignore send errors on closing socket.
    }
    activeSessions.delete(slug);
  }

  // --- Streaming LLM call ---
  async function streamResponse(ws, sessionId, item, slug) {
    if (!openai) {
      ws.send(JSON.stringify({ type: "error", message: "OPENAI_API_KEY is not configured" }));
      return;
    }

    const systemPrompt = buildSystemPrompt(item);
    const history = stmts.getSessionMessages.get
      ? stmts.getSessionMessages.all({ session_id: sessionId })
      : [];

    const messages = [
      { role: "system", content: systemPrompt },
      ...history.map((m) => ({ role: m.role, content: m.content })),
    ];

    const messageId = crypto.randomUUID();
    let fullContent = "";
    let seq = 0;

    ws.send(JSON.stringify({ type: "thinking" }));

    const state = activeSessions.get(slug);
    const abortController = new AbortController();
    if (state) state.abortController = abortController;

    try {
      const stream = await openai.chat.completions.create(
        {
          model: config.chatModel,
          messages,
          stream: true,
        },
        { signal: abortController.signal },
      );

      for await (const chunk of stream) {
        if (abortController.signal.aborted) break;
        const content = chunk.choices[0]?.delta?.content;
        if (content) {
          fullContent += content;
          ws.send(JSON.stringify({
            type: "chunk",
            content,
            message_id: messageId,
            sequence_number: seq++,
          }));
        }
      }

      if (fullContent) {
        const result = stmts.insertMessage.run({
          session_id: sessionId,
          message_id: messageId,
          role: "assistant",
          content: fullContent,
        });

        ws.send(JSON.stringify({
          type: "message",
          role: "assistant",
          content: fullContent,
          id: result.lastInsertRowid,
        }));
      }
    } catch (error) {
      if (abortController.signal.aborted) return;
      console.error("[chat] streaming error:", error.message);

      if (fullContent) {
        const result = stmts.insertMessage.run({
          session_id: sessionId,
          message_id: messageId,
          role: "assistant",
          content: fullContent,
        });
        stmts.updateMessageFailure.run({
          id: result.lastInsertRowid,
          failure_reason: error.message,
        });
      }

      ws.send(JSON.stringify({
        type: "error",
        message: "Failed to get response: " + error.message,
      }));
    }
  }

  // --- WebSocket server ---
  function attachToServer(server, getItem) {
    const wss = new WebSocketServer({ noServer: true });

    server.on("upgrade", (req, socket, head) => {
      const match = req.url.match(/^\/ws\/chat\/([^/?]+)/);
      if (!match) {
        socket.destroy();
        return;
      }

      const slug = decodeURIComponent(match[1]);

      // Validate token from query string
      const url = new URL(req.url, `http://${req.headers.host}`);
      const token = url.searchParams.get("token");
      const tokenData = consumeToken(token);
      if (!tokenData || tokenData.slug !== slug) {
        socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
        socket.destroy();
        return;
      }

      // Check Origin header
      const origin = req.headers.origin || "";
      const host = req.headers.host || "";
      if (origin && !origin.includes(host)) {
        socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
        socket.destroy();
        return;
      }

      wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit("connection", ws, req, slug);
      });
    });

    // Ping/pong heartbeat
    const heartbeat = setInterval(() => {
      wss.clients.forEach((ws) => {
        if (!ws.isAlive) return ws.terminate();
        ws.isAlive = false;
        ws.ping();
      });
    }, 15000);
    heartbeat.unref();

    wss.on("connection", (ws, _req, slug) => {
      ws.isAlive = true;
      ws.on("pong", () => { ws.isAlive = true; });

      const item = getItem(slug);
      if (!item) {
        ws.send(JSON.stringify({ type: "error", message: "Review item not found" }));
        ws.close(1008, "item_not_found");
        return;
      }

      const session = getOrCreateSession(slug, item);
      const sessionId = session.id;

      // Clean up any existing connection for this slug
      const existingState = activeSessions.get(slug);
      if (existingState?.ws && existingState.ws !== ws) {
        try { existingState.ws.close(1000, "replaced"); } catch (_e) { /* ignore */ }
      }

      activeSessions.set(slug, { ws, idleTimer: null, sessionId, abortController: null });
      resetIdleTimer(slug);

      // Send existing history
      const messages = stmts.getSessionMessages.all({ session_id: sessionId });
      ws.send(JSON.stringify({
        type: "history",
        messages: messages.map((m) => ({
          role: m.role,
          content: m.content,
          id: m.id,
          created_at: m.created_at,
        })),
      }));

      ws.on("message", (data) => {
        resetIdleTimer(slug);
        let parsed;
        try {
          parsed = JSON.parse(data.toString());
        } catch (_e) {
          ws.send(JSON.stringify({ type: "error", message: "Invalid JSON" }));
          return;
        }

        if (parsed.type === "message" && parsed.content) {
          const msgId = crypto.randomUUID();
          stmts.insertMessage.run({
            session_id: sessionId,
            message_id: msgId,
            role: "user",
            content: parsed.content,
          });

          const freshItem = getItem(slug) || item;
          streamResponse(ws, sessionId, freshItem, slug);
        } else if (parsed.type === "new_chat") {
          if (activeSessions.get(slug)?.abortController) {
            activeSessions.get(slug).abortController.abort();
          }
          stmts.closeActiveBySlug.run({ slug });
          const newSession = getOrCreateSession(slug, item);
          const newState = activeSessions.get(slug);
          if (newState) newState.sessionId = newSession.id;

          ws.send(JSON.stringify({ type: "session_reset" }));
          ws.send(JSON.stringify({ type: "history", messages: [] }));
        } else if (parsed.type === "history") {
          const msgs = stmts.getSessionMessages.all({ session_id: sessionId });
          ws.send(JSON.stringify({
            type: "history",
            messages: msgs.map((m) => ({
              role: m.role,
              content: m.content,
              id: m.id,
              created_at: m.created_at,
            })),
          }));
        }
      });

      ws.on("close", () => {
        const state = activeSessions.get(slug);
        if (state && state.ws === ws) {
          // Give 2 minutes for reconnect before cleanup
          const reconnectTimer = setTimeout(() => {
            const current = activeSessions.get(slug);
            if (current && current.ws === ws) {
              if (current.idleTimer) clearTimeout(current.idleTimer);
              activeSessions.delete(slug);
            }
          }, 2 * 60 * 1000);
          reconnectTimer.unref();
        }
      });
    });
  }

  return {
    attachToServer,
    generateChatToken,
    db,
  };
}

module.exports = { createChatModule };

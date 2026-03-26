const crypto = require('crypto');

function normalizeGatewayBaseUrl(baseUrl) {
  const trimmed = String(baseUrl || 'http://127.0.0.1:18789').replace(/\/+$/, '');
  return trimmed.endsWith('/v1') ? trimmed.slice(0, -3) : trimmed;
}

function normalizeOpenClawModel(model, agentId = 'main') {
  const trimmed = String(model || '').trim();
  if (!trimmed) {
    return agentId ? `openclaw/${agentId}` : 'openclaw';
  }
  if (trimmed === 'openclaw' || trimmed.startsWith('openclaw/')) {
    return trimmed;
  }
  return agentId ? `openclaw/${agentId}` : 'openclaw';
}

function extractText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (!part) return '';
        if (typeof part === 'string') return part;
        if (part.type === 'text') return part.text || '';
        return '';
      })
      .join('');
  }
  if (content && typeof content === 'object' && typeof content.text === 'string') {
    return content.text;
  }
  return '';
}

function formatHistoryTimestamp(timestamp) {
  const date = typeof timestamp === 'number' ? new Date(timestamp) : new Date(timestamp || Date.now());
  if (Number.isNaN(date.getTime())) return null;
  return date.toISOString().slice(0, 19).replace('T', ' ');
}

function parseCompletionContent(data) {
  const message = data?.choices?.[0]?.message;
  return extractText(message?.content);
}

function createOpenClawClient(config = {}) {
  const baseUrl = normalizeGatewayBaseUrl(config.baseUrl);
  const completionUrl = `${baseUrl}/v1/chat/completions`;
  const defaultAgentId = config.agentId || 'main';
  const defaultModel = normalizeOpenClawModel(config.model, defaultAgentId);

  async function requestJson(url, options = {}) {
    const response = await fetch(url, options);
    const body = await response.text();

    if (!response.ok) {
      const detail = body || `${response.status} ${response.statusText}`;
      throw new Error(`OpenClaw request failed (${response.status}): ${detail}`);
    }

    return body ? JSON.parse(body) : {};
  }

  function buildHeaders(extraHeaders = {}) {
    return {
      Authorization: `Bearer ${config.token}`,
      'Content-Type': 'application/json',
      'x-openclaw-agent-id': defaultAgentId,
      ...extraHeaders,
    };
  }

  async function getHistory(sessionKey, limit = 200) {
    const url = new URL(`${baseUrl}/sessions/${encodeURIComponent(sessionKey)}/history`);
    url.searchParams.set('limit', String(limit));

    try {
      const data = await requestJson(url.toString(), {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${config.token}`,
          'x-openclaw-agent-id': defaultAgentId,
        },
      });

      const rows = Array.isArray(data.messages) ? data.messages : Array.isArray(data.items) ? data.items : [];
      return rows.map((row) => ({
        id: row?.__openclaw?.id || row?.id || crypto.randomUUID(),
        role: row?.role || 'assistant',
        content: extractText(row?.content),
        created_at: formatHistoryTimestamp(row?.timestamp || row?.created_at || row?.createdAt),
      }));
    } catch (error) {
      if (/404/.test(String(error.message || ''))) {
        return [];
      }
      throw error;
    }
  }

  async function createCompletion({ sessionKey, messages, stream = false, model = defaultModel, signal }) {
    const normalizedModel = normalizeOpenClawModel(model, defaultAgentId);
    const response = await fetch(completionUrl, {
      method: 'POST',
      headers: buildHeaders({
        Accept: stream ? 'text/event-stream' : 'application/json',
        'x-openclaw-session-key': sessionKey,
      }),
      body: JSON.stringify({
        model: normalizedModel,
        stream,
        messages,
      }),
      signal,
    });

    if (!response.ok) {
      const detail = await response.text();
      throw new Error(`OpenClaw completion failed (${response.status}): ${detail || response.statusText}`);
    }

    return response;
  }

  async function complete({ sessionKey, messages, model, signal }) {
    const response = await createCompletion({ sessionKey, messages, model, signal, stream: false });
    const data = await response.json();
    return {
      raw: data,
      text: parseCompletionContent(data),
    };
  }

  async function streamCompletion({ sessionKey, messages, model, signal, onChunk }) {
    const response = await createCompletion({ sessionKey, messages, model, signal, stream: true });
    const reader = response.body?.getReader();
    if (!reader) throw new Error('OpenClaw stream unavailable');

    const decoder = new TextDecoder();
    let pending = '';
    let fullText = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      pending += decoder.decode(value, { stream: true });
      const lines = pending.split(/\r?\n/);
      pending = lines.pop() || '';

      for (const line of lines) {
        if (!line.startsWith('data:')) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === '[DONE]') continue;

        let event;
        try {
          event = JSON.parse(payload);
        } catch (_error) {
          continue;
        }

        const content = extractText(event?.choices?.[0]?.delta?.content);
        if (!content) continue;
        fullText += content;
        if (typeof onChunk === 'function') onChunk(content);
      }
    }

    return { text: fullText };
  }

  async function appendInternalMessage({ sessionKey, content, model, signal }) {
    return complete({
      sessionKey,
      model,
      signal,
      messages: [
        {
          role: 'developer',
          content: 'You are processing an internal Turf Review session note. Reply only with a single internal Turf Review message. Start the first line with [TURF_REVIEW_INTERNAL] followed by a short kind label, then put the body on subsequent lines. Do not produce any user-facing prose.',
        },
        {
          role: 'user',
          content,
        },
      ],
    });
  }

  return {
    appendInternalMessage,
    complete,
    completionUrl,
    extractText,
    formatHistoryTimestamp,
    getHistory,
    normalizeGatewayBaseUrl,
    streamCompletion,
  };
}

module.exports = {
  createOpenClawClient,
  extractText,
  formatHistoryTimestamp,
  normalizeGatewayBaseUrl,
  normalizeOpenClawModel,
};

const express = require('express');

const { buildReviewChatMessages } = require('./openclaw-context');
const { loadVisibleHistory } = require('./repository');
const { getSessionKey, isInternalMessageText } = require('../review-routing');

function createChatRouter({ getItem, listAnnotations, listReviewTargets = () => ({ targets: [] }), openclaw }) {
  const router = express.Router();

  function getReviewOr404(req, res) {
    const item = getItem(req.params.slug);
    if (!item) {
      res.status(404).json({ error: 'Review item not found' });
      return null;
    }
    return item;
  }

  function requireOpenClaw(res) {
    if (openclaw) return true;
    res.status(503).json({
      error: 'OpenClaw chat is not configured',
      detail: 'Set OPENCLAW_TOKEN or OPENCLAW_GATEWAY_TOKEN for review-aware chat.',
    });
    return false;
  }

  router.get('/api/items/:slug/chat/history', async (req, res) => {
    const item = getReviewOr404(req, res);
    if (!item) return;
    if (!requireOpenClaw(res)) return;

    try {
      const sessionKey = item.session_key || getSessionKey(item.slug);
      const messages = await loadVisibleHistory(openclaw, sessionKey, 200);
      res.json({ sessionKey, messages });
    } catch (error) {
      res.status(502).json({
        error: 'Unable to load chat history',
        detail: error.message || 'OpenClaw history request failed',
      });
    }
  });

  router.post('/api/items/:slug/chat', async (req, res) => {
    const item = getReviewOr404(req, res);
    if (!item) return;
    if (!requireOpenClaw(res)) return;

    const message = String(req.body?.message || '').trim();
    if (!message) {
      return res.status(400).json({ error: 'message is required' });
    }

    try {
      const annotations = listAnnotations(item.slug);
      const reviewTargets = listReviewTargets(item.slug).targets || [];
      const request = buildReviewChatMessages({ item, annotations, reviewTargets, userMessage: message });
      const result = await openclaw.complete({
        sessionKey: request.sessionKey,
        messages: request.messages,
      });

      const content = String(result.text || '').trim();
      if (!content || isInternalMessageText(content)) {
        return res.status(502).json({
          error: 'OpenClaw returned no visible chat reply',
        });
      }

      res.json({
        sessionKey: request.sessionKey,
        message: {
          role: 'assistant',
          content,
          created_at: new Date().toISOString().slice(0, 19).replace('T', ' '),
        },
      });
    } catch (error) {
      res.status(502).json({
        error: 'Unable to send chat message',
        detail: error.message || 'OpenClaw completion request failed',
      });
    }
  });

  return router;
}

module.exports = {
  createChatRouter,
};

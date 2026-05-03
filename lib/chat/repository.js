const { isInternalMessageText } = require('../review-routing');

function isVisibleChatMessage(message) {
  if (!message) return false;
  if (!['user', 'assistant'].includes(message.role)) return false;
  if (!message.content || isInternalMessageText(message.content)) return false;
  return true;
}

function filterVisibleMessages(messages) {
  return (Array.isArray(messages) ? messages : []).filter(isVisibleChatMessage);
}

async function loadVisibleHistory(openclaw, sessionKey, limit = 200) {
  if (!openclaw) return [];
  let rows;
  try {
    rows = await openclaw.getHistory(sessionKey, limit);
  } catch (error) {
    const message = String(error?.message || '');
    if (/missing scope: operator\.read|\b401\b|\b403\b/.test(message)) {
      return [];
    }
    throw error;
  }
  return filterVisibleMessages(rows);
}

module.exports = {
  filterVisibleMessages,
  isVisibleChatMessage,
  loadVisibleHistory,
};

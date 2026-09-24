'use strict';

const MAC_USER_AGENT = /Macintosh/i;
const IOS_USER_AGENT = /(?:iPhone|iPad|iPod|Mobile)/i;

function buildNativeReviewURL(slug) {
  return `turf-review://review/${encodeURIComponent(slug)}`;
}

function shouldOpenReviewInNativeApp({ userAgent, webOverride, iosEnabled = false }) {
  if (webOverride === '1') return false;
  const normalizedUserAgent = userAgent || '';
  if (IOS_USER_AGENT.test(normalizedUserAgent)) return iosEnabled;
  return MAC_USER_AGENT.test(normalizedUserAgent);
}

module.exports = {
  buildNativeReviewURL,
  shouldOpenReviewInNativeApp,
};

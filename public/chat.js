(function () {
  "use strict";

  var sidebar = document.getElementById("reviewSidebar");
  var decideView = document.getElementById("decideView");
  var chatView = document.getElementById("chatView");
  var decideTab = document.getElementById("decideTab");
  var chatTab = document.getElementById("chatTab");
  var chatDot = document.getElementById("chatDot");
  var mobileChatFab = document.getElementById("mobileChatFab");
  var sidebarCloseBtn = document.getElementById("sidebarCloseBtn");
  var sidebarOverlay = document.getElementById("sidebarOverlay");
  var messagesEl = document.getElementById("chatMessages");
  var inputEl = document.getElementById("chatInput");
  var sendBtn = document.getElementById("chatSendBtn");
  var refreshBtn = document.getElementById("chatNewBtn");
  var chatStatus = document.getElementById("chatStatus");

  if (!chatView || !messagesEl || !inputEl) return;

  var slug = chatView.dataset.slug;
  var isChatOpen = false;
  var isLoadingHistory = false;
  var isSending = false;
  var hasLoadedHistory = false;
  var hasMessages = false;
  var userScrolledUp = false;

  function isMobileViewport() {
    return window.matchMedia("(max-width: 900px)").matches;
  }

  function setSidebarOpen(open) {
    if (!sidebar) return;
    sidebar.classList.toggle("is-open", open);
    if (sidebarOverlay) sidebarOverlay.classList.toggle("is-open", open);
    document.body.classList.toggle("sidebar-open", open && isMobileViewport());
    if (mobileChatFab) mobileChatFab.classList.toggle("active", open);
  }

  function closeSidebar() {
    if (inputEl) inputEl.blur();
    setSidebarOpen(false);
  }

  function setStatus(text) {
    if (chatStatus) chatStatus.textContent = text;
  }

  function syncComposerState() {
    if (!inputEl || !sendBtn) return;
    sendBtn.disabled = isLoadingHistory || isSending || !inputEl.value.trim();
  }

  function showDecide() {
    isChatOpen = false;
    if (sidebar) sidebar.classList.remove("chat-mode");
    if (decideTab) decideTab.classList.add("active");
    if (chatTab) chatTab.classList.remove("active");
    if (inputEl) inputEl.blur();
    if (decideView) decideView.removeAttribute("aria-hidden");
    if (chatView) chatView.setAttribute("aria-hidden", "true");
    setStatus(hasMessages ? "Conversation tucked away" : "Ready when you are");
  }

  function showChat() {
    isChatOpen = true;
    if (sidebar) sidebar.classList.add("chat-mode");
    if (chatTab) chatTab.classList.add("active");
    if (decideTab) decideTab.classList.remove("active");
    if (decideView) decideView.setAttribute("aria-hidden", "true");
    if (chatView) chatView.removeAttribute("aria-hidden");

    if (isMobileViewport()) {
      setSidebarOpen(true);
    } else {
      inputEl.focus();
    }

    if (!hasLoadedHistory) {
      loadHistory();
    } else {
      setStatus(hasMessages ? "Conversation live" : "Ask the first question");
    }
  }

  function openMobileChat() {
    setSidebarOpen(true);
    showChat();
  }

  window.openMobileChat = openMobileChat;
  window.closeMobileSidebar = closeSidebar;

  if (decideTab) decideTab.addEventListener("click", showDecide);
  if (chatTab) chatTab.addEventListener("click", showChat);
  if (mobileChatFab) mobileChatFab.addEventListener("click", openMobileChat);
  if (sidebarCloseBtn) sidebarCloseBtn.addEventListener("click", closeSidebar);
  if (sidebarOverlay) sidebarOverlay.addEventListener("click", closeSidebar);
  window.addEventListener("resize", function () {
    if (!isMobileViewport()) setSidebarOpen(false);
  });

  function updateDot() {
    if (chatDot) chatDot.style.display = hasMessages ? "inline-block" : "none";
  }

  function relativeTime(value) {
    if (!value) return "";
    var normalized = String(value).indexOf("T") === -1 ? String(value).replace(" ", "T") + "Z" : String(value);
    var millis = new Date(normalized).getTime();
    if (Number.isNaN(millis)) return "";
    var diff = Math.floor((Date.now() - millis) / 1000);
    if (diff < 10) return "just now";
    if (diff < 60) return diff + "s ago";
    if (diff < 3600) return Math.floor(diff / 60) + "m ago";
    if (diff < 86400) return Math.floor(diff / 3600) + "h ago";
    return Math.floor(diff / 86400) + "d ago";
  }

  function renderMarkdown(text) {
    if (typeof marked !== "undefined" && marked.parse) {
      return marked.parse(text || "");
    }
    return String(text || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\n/g, "<br>");
  }

  function addCopyButtons(container) {
    container.querySelectorAll("pre").forEach(function (pre) {
      if (pre.querySelector(".btn-copy-code")) return;
      var btn = document.createElement("button");
      btn.className = "btn-copy-code";
      btn.textContent = "Copy";
      btn.addEventListener("click", function () {
        var code = pre.querySelector("code");
        var text = code ? code.textContent : pre.textContent;
        navigator.clipboard.writeText(text).then(function () {
          btn.textContent = "Copied";
          setTimeout(function () {
            btn.textContent = "Copy";
          }, 1500);
        });
      });
      pre.style.position = "relative";
      pre.appendChild(btn);
    });
  }

  function isNearBottom() {
    return messagesEl.scrollHeight - messagesEl.scrollTop - messagesEl.clientHeight < 60;
  }

  function scrollToBottom() {
    if (!userScrolledUp) messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  messagesEl.addEventListener("scroll", function () {
    userScrolledUp = !isNearBottom();
  });

  function clearMessages() {
    messagesEl.innerHTML = "";
  }

  function removeEmpty() {
    var empty = messagesEl.querySelector(".chat-empty");
    if (empty) empty.remove();
  }

  function appendMessage(role, content, timestamp, id) {
    removeThinking();
    removeEmpty();

    var div = document.createElement("div");
    div.className = "chat-message " + role;
    if (id) div.dataset.messageId = id;

    if (role === "assistant") {
      div.innerHTML = renderMarkdown(content);
      addCopyButtons(div);
    } else {
      div.textContent = content;
    }

    if (timestamp) {
      var time = document.createElement("span");
      time.className = "chat-message-time";
      time.textContent = relativeTime(timestamp);
      div.appendChild(time);
    }

    messagesEl.appendChild(div);
    scrollToBottom();
    return div;
  }

  function showThinking() {
    removeThinking();
    var div = document.createElement("div");
    div.className = "chat-thinking";
    div.id = "chatThinking";
    div.innerHTML = '<div class="thinking-dots"><span></span><span></span><span></span></div> Thinking';
    messagesEl.appendChild(div);
    scrollToBottom();
  }

  function removeThinking() {
    var el = document.getElementById("chatThinking");
    if (el) el.remove();
  }

  function showError(message) {
    removeThinking();
    removeEmpty();
    var div = document.createElement("div");
    div.className = "chat-message assistant";
    div.style.borderColor = "#b84233";
    div.style.color = "#b84233";
    div.textContent = message || "Chat is unavailable right now.";
    messagesEl.appendChild(div);
    scrollToBottom();
  }

  function showEmpty() {
    messagesEl.innerHTML =
      '<div class="chat-empty">' +
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">' +
      '<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>' +
      "</svg>" +
      '<div class="chat-empty-title">Fresh eyes, on demand</div>' +
      "<p>Ask for a risk read, a tighter summary, or the first change worth making.</p>" +
      '<div class="chat-suggestions">' +
      '<button type="button" class="chat-suggestion" data-prompt="What matters most here?">What matters most?</button>' +
      '<button type="button" class="chat-suggestion" data-prompt="What is the biggest risk in this document?">Biggest risk</button>' +
      '<button type="button" class="chat-suggestion" data-prompt="If you changed one thing first, what would it be?">First change</button>' +
      "</div>" +
      "</div>";

    messagesEl.querySelectorAll(".chat-suggestion").forEach(function (button) {
      button.addEventListener("click", function () {
        inputEl.value = button.dataset.prompt || "";
        syncComposerState();
        if (!isMobileViewport()) inputEl.focus();
      });
    });
  }

  async function fetchJson(url, options) {
    var response = await fetch(url, options || {});
    var payload = null;
    try {
      payload = await response.json();
    } catch (_error) {
      payload = null;
    }

    if (!response.ok) {
      var message = (payload && (payload.detail || payload.error)) || response.statusText || "Request failed";
      throw new Error(message);
    }

    return payload || {};
  }

  async function loadHistory() {
    if (isLoadingHistory) return;
    isLoadingHistory = true;
    syncComposerState();
    setStatus("Loading history");

    try {
      var data = await fetchJson("/api/items/" + encodeURIComponent(slug) + "/chat/history");
      clearMessages();
      if (!data.messages || data.messages.length === 0) {
        showEmpty();
        hasMessages = false;
        setStatus("Ask the first question");
      } else {
        data.messages.forEach(function (message) {
          appendMessage(message.role, message.content, message.created_at, message.id);
        });
        hasMessages = true;
        setStatus("Conversation live");
      }
      hasLoadedHistory = true;
      updateDot();
    } catch (error) {
      clearMessages();
      showError(error.message || "Unable to load chat history.");
      hasLoadedHistory = true;
      hasMessages = false;
      setStatus("Chat unavailable");
      updateDot();
    } finally {
      isLoadingHistory = false;
      syncComposerState();
    }
  }

  async function sendMessage() {
    var text = inputEl.value.trim();
    if (!text || isSending || isLoadingHistory) return;

    appendMessage("user", text);
    inputEl.value = "";
    hasMessages = true;
    updateDot();
    isSending = true;
    syncComposerState();
    setStatus("Thinking it through");
    showThinking();

    try {
      var data = await fetchJson("/api/items/" + encodeURIComponent(slug) + "/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: text }),
      });

      if (data.message) {
        appendMessage(data.message.role || "assistant", data.message.content || "", data.message.created_at, data.message.id);
      }
      setStatus("Conversation live");
    } catch (error) {
      showError(error.message || "Unable to send chat message.");
      setStatus("Hit a snag");
    } finally {
      isSending = false;
      syncComposerState();
    }
  }

  inputEl.addEventListener("input", syncComposerState);
  inputEl.addEventListener("keydown", function (event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      sendMessage();
    }
  });

  if (sendBtn) sendBtn.addEventListener("click", sendMessage);
  if (refreshBtn) {
    refreshBtn.addEventListener("click", function () {
      hasLoadedHistory = false;
      loadHistory();
    });
  }

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && isChatOpen) showDecide();
  });

  syncComposerState();
})();

(function () {
  "use strict";

  // ── DOM refs ──
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
  var newChatBtn = document.getElementById("chatNewBtn");
  var chatStatus = document.getElementById("chatStatus");

  if (!chatView || !messagesEl || !inputEl) return;

  var slug = chatView.dataset.slug;
  var token = chatView.dataset.chatToken;

  var ws = null;
  var isChatOpen = false;
  var isStreaming = false;
  var streamBuffer = "";
  var streamMessageId = null;
  var streamEl = null;
  var renderTimer = null;
  var userScrolledUp = false;
  var hasMessages = false;

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
    if (chatStatus) {
      chatStatus.textContent = text;
    }
  }

  function syncComposerState() {
    if (!inputEl || !sendBtn) return;
    sendBtn.disabled = isStreaming || inputEl.disabled || !inputEl.value.trim();
  }

  // ── Sidebar toggle ──
  function showDecide() {
    isChatOpen = false;
    sidebar.classList.remove("chat-mode");
    decideTab.classList.add("active");
    chatTab.classList.remove("active");
    if (inputEl) inputEl.blur();
    setStatus(hasMessages ? "Conversation tucked away" : "Ready when you are");
  }

  function showChat() {
    isChatOpen = true;
    sidebar.classList.add("chat-mode");
    chatTab.classList.add("active");
    decideTab.classList.remove("active");
    if (isMobileViewport()) {
      setSidebarOpen(true);
    } else {
      inputEl.focus();
    }
    connectWs();
    setStatus(hasMessages ? "Conversation live" : "Ask the first question");
  }

  function openMobileChat() {
    setSidebarOpen(true);
    showChat();
  }

  window.openMobileChat = openMobileChat;
  window.closeMobileSidebar = closeSidebar;

  if (decideTab) {
    decideTab.addEventListener("click", showDecide);
  }
  if (chatTab) {
    chatTab.addEventListener("click", showChat);
  }
  if (mobileChatFab) {
    mobileChatFab.addEventListener("click", openMobileChat);
  }
  if (sidebarCloseBtn) {
    sidebarCloseBtn.addEventListener("click", closeSidebar);
  }
  if (sidebarOverlay) {
    sidebarOverlay.addEventListener("click", closeSidebar);
  }
  window.addEventListener("resize", function () {
    if (!isMobileViewport()) {
      setSidebarOpen(false);
    }
  });

  // ── Show chat dot indicator ──
  function updateDot() {
    if (chatDot) {
      chatDot.style.display = hasMessages ? "inline-block" : "none";
    }
  }

  // ── Relative time ──
  function relativeTime(iso) {
    if (!iso) return "";
    var diff = Math.floor((Date.now() - new Date(iso + "Z").getTime()) / 1000);
    if (diff < 10) return "just now";
    if (diff < 60) return diff + "s ago";
    if (diff < 3600) return Math.floor(diff / 60) + "m ago";
    if (diff < 86400) return Math.floor(diff / 3600) + "h ago";
    return Math.floor(diff / 86400) + "d ago";
  }

  // ── Markdown rendering ──
  function renderMarkdown(text) {
    if (typeof marked !== "undefined" && marked.parse) {
      return marked.parse(text);
    }
    return text
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\n/g, "<br>");
  }

  // ── Copy-to-clipboard on code blocks ──
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

  // ── Auto-scroll logic ──
  function isNearBottom() {
    return messagesEl.scrollHeight - messagesEl.scrollTop - messagesEl.clientHeight < 60;
  }

  function scrollToBottom() {
    if (!userScrolledUp) {
      messagesEl.scrollTop = messagesEl.scrollHeight;
    }
  }

  messagesEl.addEventListener("scroll", function () {
    userScrolledUp = !isNearBottom();
  });

  // ── Message rendering ──
  function appendMessage(role, content, timestamp, id) {
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

    removeThinking();
    messagesEl.appendChild(div);
    scrollToBottom();
    return div;
  }

  function showThinking() {
    removeThinking();
    var div = document.createElement("div");
    div.className = "chat-thinking";
    div.id = "chatThinking";
    div.innerHTML =
      '<div class="thinking-dots"><span></span><span></span><span></span></div> Thinking';
    messagesEl.appendChild(div);
    scrollToBottom();
  }

  function removeThinking() {
    var el = document.getElementById("chatThinking");
    if (el) el.remove();
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
        if (!isMobileViewport()) {
          inputEl.focus();
        }
      });
    });
  }

  function clearMessages() {
    messagesEl.innerHTML = "";
  }

  // ── Input handling ──
  function setInputEnabled(enabled) {
    inputEl.disabled = !enabled;
    isStreaming = !enabled;
    syncComposerState();
  }

  inputEl.addEventListener("input", syncComposerState);

  inputEl.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  });

  function sendMessage() {
    var text = inputEl.value.trim();
    if (!text || isStreaming || !ws || ws.readyState !== WebSocket.OPEN) return;

    appendMessage("user", text);
    inputEl.value = "";
    setInputEnabled(false);
    hasMessages = true;
    updateDot();
    setStatus("Thinking it through");

    ws.send(JSON.stringify({ type: "message", content: text }));
  }

  // ── WebSocket ──
  function connectWs() {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

    var protocol = location.protocol === "https:" ? "wss:" : "ws:";
    var url = protocol + "//" + location.host + "/ws/chat/" + encodeURIComponent(slug) + "?token=" + encodeURIComponent(token);

    ws = new WebSocket(url);

    ws.onopen = function () {
      // Connection established
    };

    ws.onmessage = function (event) {
      var data;
      try {
        data = JSON.parse(event.data);
      } catch (_e) {
        return;
      }

      switch (data.type) {
        case "history":
          clearMessages();
          if (!data.messages || data.messages.length === 0) {
            showEmpty();
            hasMessages = false;
            setStatus("Ask the first question");
          } else {
            data.messages.forEach(function (m) {
              appendMessage(m.role, m.content, m.created_at, m.id);
            });
            hasMessages = true;
            setStatus("Conversation live");
          }
          updateDot();
          setInputEnabled(true);
          break;

        case "thinking":
          setStatus("Thinking it through");
          showThinking();
          break;

        case "chunk":
          if (streamMessageId !== data.message_id) {
            streamMessageId = data.message_id;
            streamBuffer = "";
            removeThinking();
            streamEl = document.createElement("div");
            streamEl.className = "chat-message assistant";
            messagesEl.appendChild(streamEl);
          }
          streamBuffer += data.content;

          if (!renderTimer) {
            renderTimer = setTimeout(function () {
              renderTimer = null;
              if (streamEl) {
                streamEl.innerHTML = renderMarkdown(streamBuffer);
                addCopyButtons(streamEl);
                scrollToBottom();
              }
            }, 100);
          }
          break;

        case "message":
          if (renderTimer) {
            clearTimeout(renderTimer);
            renderTimer = null;
          }
          if (streamEl && data.role === "assistant") {
            streamEl.innerHTML = renderMarkdown(data.content);
            addCopyButtons(streamEl);
            if (data.id) streamEl.dataset.messageId = data.id;
            scrollToBottom();
            streamEl = null;
            streamMessageId = null;
            streamBuffer = "";
          } else if (data.role === "assistant") {
            appendMessage("assistant", data.content, null, data.id);
          }
          hasMessages = true;
          updateDot();
          setInputEnabled(true);
          setStatus("Conversation live");
          break;

        case "error":
          removeThinking();
          setInputEnabled(true);
          setStatus("Hit a snag");
          var errDiv = document.createElement("div");
          errDiv.className = "chat-message assistant";
          errDiv.style.borderColor = "#b84233";
          errDiv.style.color = "#b84233";
          errDiv.textContent = data.message || "An error occurred";
          messagesEl.appendChild(errDiv);
          scrollToBottom();
          break;

        case "session_reset":
          clearMessages();
          showEmpty();
          streamEl = null;
          streamMessageId = null;
          streamBuffer = "";
          hasMessages = false;
          updateDot();
          setInputEnabled(true);
          setStatus("Fresh thread");
          break;
      }
    };

    ws.onclose = function () {
      setStatus("Reconnecting soon");
    };

    ws.onerror = function () {
      setStatus("Connection trouble");
    };
  }

  // ── Event bindings ──
  if (sendBtn) sendBtn.addEventListener("click", sendMessage);

  if (newChatBtn) {
    newChatBtn.addEventListener("click", function () {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      setStatus("Fresh thread");
      ws.send(JSON.stringify({ type: "new_chat" }));
    });
  }

  // Escape to switch back to decide
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && isChatOpen) showDecide();
  });

  syncComposerState();
})();

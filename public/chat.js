(function () {
  "use strict";

  // ── DOM refs ──
  const panel = document.getElementById("chatPanel");
  const overlay = document.getElementById("chatOverlay");
  const messagesEl = document.getElementById("chatMessages");
  const inputEl = document.getElementById("chatInput");
  const sendBtn = document.getElementById("chatSendBtn");
  const newChatBtn = document.getElementById("chatNewBtn");
  const closeBtn = document.getElementById("chatCloseBtn");
  const toggleBtns = document.querySelectorAll(".btn-chat");
  const agentLabel = document.getElementById("chatAgentLabel");

  if (!panel || !messagesEl || !inputEl) return;

  const slug = panel.dataset.slug;
  const token = panel.dataset.chatToken;

  let ws = null;
  let isOpen = false;
  let isStreaming = false;
  let streamBuffer = "";
  let streamMessageId = null;
  let streamEl = null;
  let renderTimer = null;
  let userScrolledUp = false;

  // ── Relative time ──
  function relativeTime(iso) {
    if (!iso) return "";
    const diff = Math.floor((Date.now() - new Date(iso + "Z").getTime()) / 1000);
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
    // Fallback: basic escaping
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
      '<div class="thinking-dots"><span></span><span></span><span></span></div> Thinking\u2026';
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
      "<p>Ask a question about this review item.</p>" +
      "</div>";
  }

  function clearMessages() {
    messagesEl.innerHTML = "";
  }

  // ── Toggle panel ──
  function openPanel() {
    if (isOpen) return;
    isOpen = true;
    panel.classList.add("open");
    overlay.classList.add("visible");
    connectWs();
    inputEl.focus();
  }

  function closePanel() {
    if (!isOpen) return;
    isOpen = false;
    panel.classList.remove("open");
    overlay.classList.remove("visible");
  }

  function togglePanel() {
    if (isOpen) closePanel();
    else openPanel();
  }

  // ── Input handling ──
  function setInputEnabled(enabled) {
    inputEl.disabled = !enabled;
    sendBtn.disabled = !enabled;
    isStreaming = !enabled;
  }

  function autoResizeInput() {
    inputEl.style.height = "auto";
    inputEl.style.height = Math.min(inputEl.scrollHeight, 120) + "px";
  }

  inputEl.addEventListener("input", autoResizeInput);

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
    autoResizeInput();
    setInputEnabled(false);

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
          } else {
            data.messages.forEach(function (m) {
              appendMessage(m.role, m.content, m.created_at, m.id);
            });
          }
          setInputEnabled(true);
          break;

        case "thinking":
          showThinking();
          break;

        case "chunk":
          if (streamMessageId !== data.message_id) {
            // New stream starting
            streamMessageId = data.message_id;
            streamBuffer = "";
            removeThinking();
            streamEl = document.createElement("div");
            streamEl.className = "chat-message assistant";
            messagesEl.appendChild(streamEl);
          }
          streamBuffer += data.content;

          // Debounced re-render at ~100ms
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
          // Final complete message from assistant
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
          setInputEnabled(true);
          break;

        case "error":
          removeThinking();
          setInputEnabled(true);
          // Show error inline
          var errDiv = document.createElement("div");
          errDiv.className = "chat-message assistant";
          errDiv.style.borderColor = "var(--danger)";
          errDiv.style.color = "var(--danger)";
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
          setInputEnabled(true);
          break;
      }
    };

    ws.onclose = function () {
      // Connection closed — user can reopen
    };

    ws.onerror = function () {
      // WebSocket error
    };
  }

  // ── Event bindings ──
  toggleBtns.forEach(function (btn) {
    btn.addEventListener("click", togglePanel);
  });

  if (closeBtn) closeBtn.addEventListener("click", closePanel);
  if (overlay) overlay.addEventListener("click", closePanel);
  if (sendBtn) sendBtn.addEventListener("click", sendMessage);

  if (newChatBtn) {
    newChatBtn.addEventListener("click", function () {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      ws.send(JSON.stringify({ type: "new_chat" }));
    });
  }

  // Close on Escape
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && isOpen) closePanel();
  });

  // Set agent label from item metadata if available
  if (agentLabel) {
    var itemCategory = panel.dataset.category || "";
    agentLabel.textContent = itemCategory || "Review Author";
  }
})();

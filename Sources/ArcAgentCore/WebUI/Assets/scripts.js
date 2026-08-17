(function(){
  'use strict';

  // ── WebSocket Client ──────────────────────────────────────
  var ws = null;
  var reconnectTimer = null;
  var reconnectAttempts = 0;
  var maxReconnectDelay = 30000;
  var messageQueue = [];
  var isStreaming = false;

  function connect() {
    var url = document.getElementById('app').dataset.wsUrl || 'ws://'+location.host+'/ui/ws';
    ws = new WebSocket(url);

    ws.onopen = function() {
      reconnectAttempts = 0;
      setStatus('on', 'Connected');
      flushQueue();
    };

    ws.onmessage = function(e) {
      try {
        var msg = JSON.parse(e.data);
        handleMessage(msg);
      } catch(err) {
        console.warn('WS parse error:', err);
      }
    };

    ws.onclose = function() {
      setStatus('off', 'Disconnected');
      scheduleReconnect();
    };

    ws.onerror = function() {
      // onclose will fire after this
    };
  }

  function scheduleReconnect() {
    var delay = Math.min(1000 * Math.pow(2, reconnectAttempts), maxReconnectDelay);
    delay += Math.random() * 1000;
    reconnectAttempts++;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, delay);
  }

  function send(data) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(data));
    } else {
      messageQueue.push(data);
      if (!reconnectTimer) connect();
    }
  }

  function flushQueue() {
    while (messageQueue.length > 0) {
      var item = messageQueue.shift();
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(item));
      }
    }
  }

  // ── Message Handling ──────────────────────────────────────

  function handleMessage(msg) {
    switch (msg.type) {
      case 'token':
        appendToken(msg.text);
        break;
      case 'message':
        // Ignore user messages echoed by the server — JS already
        // shows them locally in sendMessage()
        if (msg.role !== 'user') {
          appendMessage(msg.html, msg.role || 'assistant');
        }
        break;
      case 'done':
        finalizeStreaming();
        break;
      case 'error':
        showError(msg.text || 'An error occurred');
        break;
      case 'status':
        if (msg.text === 'streaming') { isStreaming = true; }
        else { isStreaming = false; }
        break;
      case 'pong':
        break;
    }
  }

  function appendToken(text) {
    var container = document.getElementById('messages');
    if (!container) return;

    // Remove welcome screen if present
    var welcome = container.querySelector('.welcome-screen');
    if (welcome) welcome.style.display = 'none';

    var lastRow = container.lastElementChild;
    if (!lastRow || !lastRow.classList.contains('streaming-row')) {
      // Create new streaming row
      lastRow = document.createElement('div');
      lastRow.className = 'message-row assistant streaming-row';
      lastRow.innerHTML = '<div class="message-avatar avatar-assistant">⚡</div>' +
        '<div class="message-content">' +
        '<div class="message-header-row"><span class="message-role-label">ARC Agent</span></div>' +
        '<div class="message-bubble streaming-bubble" id="streaming-content"></div>' +
        '</div>';
      container.appendChild(lastRow);
    }

    var bubble = lastRow.querySelector('.message-bubble');
    if (bubble) {
      // Remove typing dots if present
      var dots = bubble.querySelector('.typing-dots');
      if (dots) dots.remove();
      bubble.textContent += text;
    }

    smartScroll();
  }

  function appendMessage(html, role) {
    var container = document.getElementById('messages');
    if (!container) return;

    // Remove streaming row if present
    var streamingRow = container.querySelector('.streaming-row');
    if (streamingRow) streamingRow.remove();

    // Remove welcome screen if present
    var welcome = container.querySelector('.welcome-screen');
    if (welcome) welcome.style.display = 'none';

    var isUser = role === 'user';
    var avatarIcon = isUser ? '👤' : '⚡';
    var avatarClass = isUser ? 'avatar-user' : 'avatar-assistant';
    var roleLabel = isUser ? 'You' : 'ARC Agent';
    var now = new Date();
    var time = now.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'});

    var row = document.createElement('div');
    row.className = 'message-row ' + role;
    row.innerHTML =
      '<div class="message-avatar ' + avatarClass + '">' + avatarIcon + '</div>' +
      '<div class="message-content">' +
      '<div class="message-header-row">' +
      '<span class="message-role-label">' + roleLabel + '</span>' +
      '<span class="message-timestamp">' + time + '</span>' +
      '</div>' +
      '<div class="message-bubble"><div class="markdown">' + html + '</div></div>' +
      (isUser ? '' :
      '<div class="message-actions">' +
      '<button class="action-btn" onclick="copyLastMessage()" title="Copy">' +
      '<svg width="14" height="14" viewBox="0 0 14 14" fill="none">' +
      '<rect x="3" y="3" width="10" height="10" rx="1.5" stroke="currentColor" stroke-width="1.2"/>' +
      '<path d="M1 11V2.5A1.5 1.5 0 012.5 1H11" stroke="currentColor" stroke-width="1.2"/>' +
      '</svg></button>' +
      '<button class="action-btn" onclick="regenerate()" title="Regenerate">' +
      '<svg width="14" height="14" viewBox="0 0 14 14" fill="none">' +
      '<path d="M1 7a6 6 0 0111.3-3M13 7a6 6 0 01-11.3 3" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>' +
      '<path d="M13 1v4h-4M1 13V9h4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/>' +
      '</svg></button>' +
      '</div>') +
      '</div>';

    container.appendChild(row);
    smartScroll();
  }

  function finalizeStreaming() {
    var container = document.getElementById('messages');
    if (!container) return;
    var streamingRow = container.querySelector('.streaming-row');
    if (streamingRow) {
      streamingRow.classList.remove('streaming-row');
    }
    isStreaming = false;
    enableInput();
  }

  function showError(text) {
    var container = document.getElementById('messages');
    if (!container) return;
    var row = document.createElement('div');
    row.className = 'message-row error';
    row.innerHTML = '<div class="message-content"><div class="message-bubble" style="color:var(--danger)">⚠️ ' + escapeHtml(text) + '</div></div>';
    container.appendChild(row);
    smartScroll();
    isStreaming = false;
    enableInput();
  }

  // ── Smart Auto-Scroll ─────────────────────────────────────

  function smartScroll() {
    var container = document.getElementById('messages-container');
    if (!container) return;
    var threshold = 100;
    var atBottom = container.scrollHeight - container.scrollTop - container.clientHeight < threshold;
    if (atBottom) {
      container.scrollTop = container.scrollHeight;
    }
  }

  // ── Input ─────────────────────────────────────────────────

  function sendMessage() {
    var input = document.getElementById('message-input');
    if (!input) return;
    var text = input.value.trim();
    if (!text || isStreaming) return;

    // Show user message immediately
    appendMessage(escapeHtml(text), 'user');

    // Send to server
    send({type: 'message', text: text});

    // Clear input and reset
    input.value = '';
    input.style.height = 'auto';
    disableInput();
    updateSendButton();
  }

  function sendSuggestion(text) {
    var input = document.getElementById('message-input');
    if (input) {
      input.value = text;
      sendMessage();
    }
  }

  function disableInput() {
    var input = document.getElementById('message-input');
    var btn = document.getElementById('send-button');
    if (input) input.disabled = true;
    if (btn) btn.disabled = true;
  }

  function enableInput() {
    var input = document.getElementById('message-input');
    var btn = document.getElementById('send-button');
    if (input) { input.disabled = false; input.focus(); }
    if (btn) btn.disabled = false;
  }

  function updateSendButton() {
    var input = document.getElementById('message-input');
    var btn = document.getElementById('send-button');
    if (!input || !btn) return;
    btn.disabled = !input.value.trim() || isStreaming;
  }

  // ── Actions ───────────────────────────────────────────────

  function copyMessage(id) {
    var row = document.getElementById(id);
    if (!row) return;
    var text = row.textContent.replace(/CopyRegenerate/g, '').trim();
    copyToClipboard(text);
  }

  function copyLastMessage() {
    var container = document.getElementById('messages');
    if (!container) return;
    var rows = container.querySelectorAll('.message-row.assistant:not(.streaming-row)');
    var last = rows[rows.length - 1];
    if (last) {
      var text = last.textContent.replace(/CopyRegenerate/g, '').trim();
      copyToClipboard(text);
    }
  }

  function copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).catch(function() {
        fallbackCopy(text);
      });
    } else {
      fallbackCopy(text);
    }
  }

  function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
  }

  function regenerate() {
    if (isStreaming) return;
    // Send regenerate signal — server will re-run the last turn
    send({type: 'regenerate'});
  }

  function regenerateMessage(id) {
    regenerate();
  }

  // ── Model Switching ───────────────────────────────────────

  function switchModel(model) {
    send({type: 'set_model', model: model});
    var selects = document.querySelectorAll('.model-select, #settings-model');
    selects.forEach(function(s) { s.value = model; });
  }

  // ── Settings ──────────────────────────────────────────────

  function toggleSettings() {
    var overlay = document.getElementById('settings-overlay');
    if (!overlay) return;
    var isOpen = overlay.style.display !== 'none' && overlay.style.display !== '';
    overlay.style.display = isOpen ? 'none' : 'flex';
  }

  // ── Status ────────────────────────────────────────────────

  function setStatus(className, text) {
    var el = document.getElementById('conn');
    if (el) {
      el.className = 'status-badge ' + className;
      el.textContent = text;
    }
  }

  // ── Keyboard ──────────────────────────────────────────────

  document.addEventListener('keydown', function(e) {
    // Escape to close settings
    if (e.key === 'Escape') {
      var overlay = document.getElementById('settings-overlay');
      if (overlay && overlay.style.display !== 'none' && overlay.style.display !== '') {
        overlay.style.display = 'none';
        return;
      }
    }

    var input = document.getElementById('message-input');
    if (!input || document.activeElement !== input) return;

    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  });

  // ── Auto-resize Textarea ──────────────────────────────────

  document.addEventListener('input', function(e) {
    if (e.target && e.target.id === 'message-input') {
      e.target.style.height = 'auto';
      e.target.style.height = Math.min(e.target.scrollHeight, 200) + 'px';
      updateSendButton();
    }
  });

  // ── Init ──────────────────────────────────────────────────

  function escapeHtml(str) {
    var div = document.createElement('div');
    div.appendChild(document.createTextNode(str));
    return div.innerHTML;
  }

  // Start connection
  connect();

  // Expose globals
  window.sendMessage = sendMessage;
  window.sendSuggestion = sendSuggestion;
  window.copyMessage = copyMessage;
  window.copyLastMessage = copyLastMessage;
  window.regenerate = regenerate;
  window.regenerateMessage = regenerateMessage;
  window.switchModel = switchModel;
  window.toggleSettings = toggleSettings;
  Object.defineProperty(window, '__ws', { get: function() { return ws; } });

})();

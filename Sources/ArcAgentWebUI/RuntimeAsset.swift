// AUTO-GENERATED from Assets/runtime.js (the canonical patched no-webui
// runtime). Regenerate with: python3 Scripts/gen_runtime.py
import Foundation

enum RuntimeAsset {
    /// The patched no-webui runtime (Enter-to-send + passive-event filter),
    /// embedded via Swift raw string — no bundle, no resource pipeline.
    static let patchedRuntimeJS = #"""


window.WebUIRuntime = (function () {
  'use strict';

  var DEFAULTS = {
    wsUrl: null,
    wsReconnect: true,
    wsMaxReconnectDelay: 30000,
    wsPingInterval: 30000,
    wsPongTimeout: 60000,
    maxQueueSize: 1000,
    debounceInputMs: 300,
    debounceMaxWaitMs: 1000,
    optimisticSettleMs: 5000,
    logLevel: 'warn',
  };

  var LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3, silent: 4 };
  var EVENT_TYPES = ['click', 'input', 'change', 'submit', 'keydown', 'keyup', 'keypress', 'focus', 'blur', 'focusin', 'focusout', 'mouseover', 'mouseout', 'mousedown', 'mouseup', 'contextmenu'];

  function createLogger(level) {
    var min = LOG_LEVELS[level] || LOG_LEVELS.warn;
    return {
      debug: function (msg) { if (LOG_LEVELS.debug >= min) console.log('[WebUIRuntime] ' + msg); },
      info:  function (msg) { if (LOG_LEVELS.info >= min)  console.info('[WebUIRuntime] ' + msg); },
      warn:  function (msg) { if (LOG_LEVELS.warn >= min)  console.warn('[WebUIRuntime] ' + msg); },
      error: function (msg) { if (LOG_LEVELS.error >= min) console.error('[WebUIRuntime] ' + msg); },
    };
  }

  function createWSClient(log, onMessage) {
    var ws = null;
    var reconnectTimer = null;
    var reconnectAttempts = 0;
    var messageQueue = [];
    var isConnected = false;
    var pingTimer = null;
    var pongTimer = null;
    var config = {};
    var destroyed = false;

    function connect(url) {
      if (destroyed) return;
      if (typeof WebSocket === 'undefined') {
        log.warn('WebSocket is not available in this environment');
        return;
      }
      if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

      var wsUrl = url || config.wsUrl || 'ws://' + location.host + '/ws';
      log.info('Connecting to ' + wsUrl);
      ws = new WebSocket(wsUrl);

      ws.onopen = function () {
        if (destroyed) return;
        log.info('Connected');
        isConnected = true;
        reconnectAttempts = 0;
        flushQueue();
        startPing();
        dispatchEvent('webui:connected', {});
      };

      ws.onmessage = function (e) {
        if (destroyed) return;
        try {
          var msg = JSON.parse(e.data);
          if (msg && msg.type === 'pong' && pongTimer) {
            clearTimeout(pongTimer);
            pongTimer = null;
          }
          onMessage(msg);
        } catch (err) {
          log.error('Failed to parse message: ' + err.message);
        }
      };

      ws.onclose = function () {
        if (destroyed) return;
        log.info('Disconnected');
        isConnected = false;
        stopPing();
        dispatchEvent('webui:disconnected', {});
        if (config.wsReconnect) scheduleReconnect();
      };

      ws.onerror = function () {  };
    }

    function disconnect() {
      destroyed = true;
      stopPing();
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
      if (ws) {
        ws.onclose = null;
        ws.close();
        ws = null;
      }
      isConnected = false;
    }

    function scheduleReconnect() {
      if (reconnectTimer || destroyed) return;

      var baseDelay = Math.min(1000 * Math.pow(2, reconnectAttempts), config.wsMaxReconnectDelay);
      var jitter = 0.5 + Math.random();
      var delay = Math.round(baseDelay * jitter);
      reconnectAttempts++;
      log.info('Reconnecting in ' + delay + 'ms (attempt ' + reconnectAttempts + ')');
      reconnectTimer = setTimeout(function () {
        reconnectTimer = null;
        connect();
      }, delay);
    }

    function send(data) {
      if (destroyed) return;
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(data));
      } else {
        if (messageQueue.length >= config.maxQueueSize) {
          messageQueue.shift();
        }
        messageQueue.push(data);
        if (!reconnectTimer) connect();
      }
    }

    function flushQueue() {
      while (messageQueue.length > 0) {
        var item = messageQueue.shift();
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify(item));
        } else {
          messageQueue.unshift(item);
          break;
        }
      }
    }

    function startPing() {
      stopPing();
      pingTimer = setInterval(function () {
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: 'ping' }));

          if (pongTimer) clearTimeout(pongTimer);
          pongTimer = setTimeout(function () {
            log.warn('Pong timeout — reconnecting');
            if (ws) { ws.onclose = null; ws.close(); ws = null; }
            isConnected = false;
            scheduleReconnect();
          }, config.wsPongTimeout);
        }
      }, config.wsPingInterval);
    }

    function stopPing() {
      if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
      if (pongTimer) { clearTimeout(pongTimer); pongTimer = null; }
    }

    function reset(config_) {
      destroyed = false;
      config = config_;
      messageQueue = [];
      reconnectAttempts = 0;
    }

    return {
      connect: connect,
      disconnect: disconnect,
      send: send,
      reset: reset,
      isConnected: function () { return isConnected; },
    };
  }

  function createEventDelegator(log, send, fragmentPatcher) {
    var inputTimers = {};
    var listeners = [];
    var config = {};

    function mount() {
      EVENT_TYPES.forEach(function (eventType) {
        var listener = function (e) { handleEvent(e); };
        document.addEventListener(eventType, listener, false);
        listeners.push({ type: eventType, listener: listener });
      });
      log.debug('Event delegation mounted for: ' + EVENT_TYPES.join(', '));
    }

    function unmount() {
      listeners.forEach(function (entry) {
        document.removeEventListener(entry.type, entry.listener, false);
      });
      listeners = [];

      for (var key in inputTimers) {
        if (inputTimers.hasOwnProperty(key) && inputTimers[key].timer) {
          clearTimeout(inputTimers[key].timer);
        }
      }
      inputTimers = {};
      log.debug('Event delegation unmounted');
    }

    function applyPrediction(componentEl, componentId) {
      var raw = componentEl.getAttribute('data-optimistic');
      if (!raw) return;
      var pred;
      try {
        pred = JSON.parse(raw);
      } catch (e) {
        log.warn('invalid data-optimistic json on #' + componentId);
        return;
      }
      if (!Array.isArray(pred)) {
        log.warn('data-optimistic payload is not an array on #' + componentId);
        return;
      }
      fragmentPatcher.patch(pred, null, true);
    }

    function effectiveTypes(event) {
      var types = [event.type];
      if (event.type === 'focusin') types.push('focus');
      if (event.type === 'focusout') types.push('blur');
      return types;
    }

    function handleEvent(event) {
      // Hermes parity (Sep 2026): a click anywhere outside an open composer
      // dropdown (.dd-pop) dismisses it — including clicks on other
      // components. The server closes the popover via the dd-dismiss wire.
      if (event.type === 'click') {
        var t0 = event.target;
        var outsideDD = !(t0 && t0.closest && t0.closest('.dd'));
        if (outsideDD && document.querySelector('.dd-pop:not(.hidden)')) {
          send({
            type: 'event',
            component: 'dd-dismiss',
            event: 'click',
            data: { targetId: 'dd-dismiss', value: '' },
          });
        }
      }

      var componentEl = findComponent(event);
      if (!componentEl) return;

      var componentId = componentEl.getAttribute('data-component-id');
      if (!componentId) return;

      var declaredEvent = componentEl.getAttribute('data-event');
      if (declaredEvent && effectiveTypes(event).indexOf(declaredEvent) === -1) return;
      if (!declaredEvent && (event.type === 'mouseover' || event.type === 'mouseout')) return;

      // Right-click: text controls keep the native menu (paste, spellcheck);
      // everything else is owned by the component, so suppress the browser
      // context menu and let the event flow to the server.
      if (event.type === 'contextmenu') {
        var t = event.target;
        var texty = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
        if (texty && declaredEvent !== 'contextmenu') return;
        event.preventDefault();
      }

      if (event.type === 'click') {
        if (event.metaKey || event.ctrlKey || event.shiftKey) return;
        var tEl = event.target;
        if (tEl && (tEl.tagName === 'INPUT' || tEl.tagName === 'TEXTAREA' || tEl.isContentEditable)) return;
        var link = event.target.closest('a');
        if (link) {

          if (link.hasAttribute('download')) return;
          if (link.getAttribute('href') && link.getAttribute('href').startsWith('#')) return;
          if (link.getAttribute('target') === '_blank') return;
          event.preventDefault();
        }
      }

      if (event.type === 'keydown' && event.key === 'Enter') {
        var editTarget = event.target && (event.target.tagName === 'TEXTAREA' || event.target.isContentEditable);
        if (editTarget && !event.shiftKey && event.target.getAttribute('data-prevent-enter') === 'send') {
          event.preventDefault();
          var f = event.target.closest('form');
          if (f && f.requestSubmit) { f.requestSubmit(); return; }
        }
        if (!editTarget && componentEl.getAttribute('data-prevent-enter') !== 'false') {
          event.preventDefault();
        }
      }

      if (event.type === 'submit') {
        event.preventDefault();
      }

      var eventData = extractEventData(event, componentEl);

      if (event.type === 'input') {
        debounceInput(componentId, event, eventData);
        return;
      }

      if (event.type === 'click') {
        applyPrediction(componentEl, componentId);
      }

      send({
        type: 'event',
        component: componentId,
        event: declaredEvent || event.type,
        data: eventData,
      });

      // Hermes parity: sending empties the composer immediately (the server
      // also clears the per-chat draft). Doing it here, before the fragment
      // re-render, keeps the input-state restore from putting the sent text
      // back into the same chat.
      if (event.type === 'submit' && componentId === 'composer-form') {
        var ta = componentEl.querySelector('#composer-input');
        if (ta) ta.value = '';
      }
    }


    function findComponent(event) {
      var path = [];
      if (typeof event.composedPath === 'function') {
        path = event.composedPath();
      } else {
        var el = event.target;
        while (el && el !== document) {
          path.push(el);
          el = el.parentElement;
        }
        path.push(document);
      }

      var maxDepth = 20;
      for (var i = 0; i < path.length && maxDepth > 0; i++) {
        var current = path[i];
        if (current && current.hasAttribute && current.hasAttribute('data-component-id')) {
          return current;
        }
        maxDepth--;
      }

      var target = event.target;
      if (target && target.nodeType === 1) {
        var labels = null;
        try {
          if (target.labels && target.labels.length) {
            labels = target.labels;
          }
        } catch (e) {
          labels = null;
        }
        if ((!labels || !labels.length) && target.id) {
          labels = document.querySelectorAll('label[for="' + target.id + '"]');
        }
        if (labels && labels.length) {
          for (var j = 0; j < labels.length; j++) {
            if (labels[j].hasAttribute && labels[j].hasAttribute('data-component-id')) {
              return labels[j];
            }
          }
        }
      }
      return null;
    }

    function clickTargetData(target, componentEl) {
      var data = {};
      // Prefer the clicked element's own id, but fall back to the resolved
      // component element (e.g. a row button) when the click landed on a
      // child such as a text span or meta line. Without this, clicks on the
      // content or padding of a row button were silently dropped because only
      // event.target.id was used.
      var idEl = (target && target.id) ? target : null;
      if (!idEl && componentEl && componentEl.tagName === 'BUTTON') idEl = componentEl;
      if (idEl && idEl.id) data.targetId = idEl.id;
      if (target && typeof target.className === 'string' && target.className) data.targetClass = target.className;
      var dColor = target && target.getAttribute ? target.getAttribute('data-color') : null;
      if (dColor) data.color = dColor;
      // Generic payload passthrough (e.g. queue drag-and-drop order).
      var dPayload = target && target.getAttribute ? target.getAttribute('data-payload') : null;
      if (dPayload) data.payload = dPayload;
      return data;
    }

    function extractEventData(event, componentEl) {
      var target = event.target;
      switch (event.type) {
        case 'click':
          return clickTargetData(target, componentEl);

        case 'input':
        case 'change':
          // Inputs/checkboxes must carry targetId too: many server wires
          // dispatch on event.targetId (e.g. sk-toggle-<enc>, ts-<enc>).
          // Checkboxes/radios stringify `checked` ([String:String] payload).
          var base = {};
          if (target && target.id) base.targetId = target.id;
          else if (componentEl && componentEl.id) base.targetId = componentEl.id;
          if (target.type === 'checkbox' || target.type === 'radio') {
            base.value = target.value;
            base.checked = target.checked ? 'true' : 'false';
            return base;
          }
          base.value = (target.value || '');
          return base;

        case 'submit':
          return extractFormData(target);

        case 'keydown':
        case 'keyup':
        case 'keypress':
          return {
            key: event.key,
            ctrlKey: String(event.ctrlKey),
            shiftKey: String(event.shiftKey),
            altKey: String(event.altKey),
            metaKey: String(event.metaKey),
          };

        case 'contextmenu': {
          var ctx = clickTargetData(target, componentEl);
          ctx.mouseX = String(event.clientX);
          ctx.mouseY = String(event.clientY);
          return ctx;
        }

        case 'focus':
        case 'blur':
        case 'mouseover':
        case 'mouseout':
        case 'mousedown':
        case 'mouseup':
          return {};

        default:
          return {};
      }
    }

    function extractFormData(form) {
      if (!form || typeof form.elements === 'undefined') return {};
      var data = {};
      for (var i = 0; i < form.elements.length; i++) {
        var el = form.elements[i];
        if (!el.name || el.disabled) continue;
        if (el.type === 'checkbox' || el.type === 'radio') {
          if (el.checked) {
            data[el.name] = el.value;
          }
        } else if (el.type === 'select-multiple') {
          var values = [];
          for (var j = 0; j < el.options.length; j++) {
            if (el.options[j].selected) values.push(el.options[j].value);
          }
          data[el.name] = values.join(',');
        } else if (el.type === 'file') {

          continue;
        } else {
          data[el.name] = el.value;
        }
      }
      return data;
    }

    function debounceInput(componentId, event, eventData) {
      var fieldKey = event.target.name || event.target.id || '';
      var key = componentId + ':' + fieldKey;
      var now = Date.now();

      if (!inputTimers[key]) {
        inputTimers[key] = { timer: null, data: eventData, eventType: event.type, lastSent: now };
      }
      var entry = inputTimers[key];
      entry.data = eventData;
      entry.eventType = event.type;

      var flush = function () {
        if (entry.timer) {
          clearTimeout(entry.timer);
          entry.timer = null;
        }
        entry.lastSent = Date.now();
        send({
          type: 'event',
          component: componentId,
          event: entry.eventType,
          data: entry.data,
        });
      };

      if (now - entry.lastSent >= config.debounceMaxWaitMs) {
        flush();
        return;
      }

      if (entry.timer) {
        clearTimeout(entry.timer);
      }
      entry.timer = setTimeout(flush, config.debounceInputMs);
    }

    function reset(config_) {
      config = config_;
    }

    return { mount: mount, unmount: unmount, reset: reset };
  }

  // ── Hermes-parity markdown post-render: KaTeX + enhanced tables ──────────
  // Mirrors hermes-webui ui.js `renderKatexBlocks` + messages.js table
  // enhancement: server-rendered <equation-inline>/<equation-block> elements
  // are typeset with KaTeX (lazy-loaded, rendered-source cached), and pipe
  // tables get per-column sort + a filter input.
  var _katexState = { loading: false, ready: false, cache: {} };

  function _katexPending(el, root) {
    // An equation that is the last descendant of the live body may still be
    // receiving TeX while streaming — skip it until the parser settles.
    var tag = (el && el.tagName || '').toLowerCase();
    if (tag !== 'equation-block' && tag !== 'equation-inline') return false;
    var node = el;
    while (node && node !== root) {
      if (node.nextSibling) return false;
      node = node.parentNode;
    }
    return node === root;
  }

  function renderKatexBlocks(container, opts) {
    var root = container || document;
    var streaming = !!(opts && opts.streaming);
    var blocks = root.querySelectorAll(
      '.katex-block:not([data-rendered]),.katex-inline:not([data-rendered]),' +
      'equation-block:not([data-rendered]),equation-inline:not([data-rendered])'
    );
    if (!blocks.length) return;
    if (!_katexState.ready) {
      if (!_katexState.loading) {
        _katexState.loading = true;
        var script = document.createElement('script');
        script.src = '/ui/vendor/katex/katex.min.js';
        script.onload = function () {
          if (typeof katex !== 'undefined') {
            _katexState.ready = true;
            renderKatexBlocks();
          }
        };
        document.head.appendChild(script);
      }
      return;
    }
    for (var i = 0; i < blocks.length; i++) {
      var el = blocks[i];
      if (streaming && _katexPending(el, root)) continue;
      var src = el.textContent || '';
      var tag = (el.tagName || '').toLowerCase();
      var displayMode = el.getAttribute('data-katex') === 'display' || tag === 'equation-block';
      var key = (displayMode ? 'd|' : 'i|') + src;
      el.setAttribute('data-rendered', 'true');
      if (_katexState.cache[key]) {
        el.innerHTML = _katexState.cache[key];
        continue;
      }
      try {
        katex.render(src, el, {
          displayMode: displayMode,
          throwOnError: false,
          trust: false,
          strict: 'ignore'
        });
        _katexState.cache[key] = el.innerHTML;
      } catch (e) {
        // Leave the raw source as a code span on failure (Hermes parity).
        var code = document.createElement('code');
        code.textContent = src;
        if (el.parentNode) el.parentNode.replaceChild(code, el);
      }
    }
  }

  function enhanceMarkdownTables(scope) {
    var tables = scope.querySelectorAll('.msg-body table:not([data-markdown-table-enhanced])');
    for (var t = 0; t < tables.length; t++) {
      (function (table) {
      table.setAttribute('data-markdown-table-enhanced', '1');
      var tbody = table.querySelector('tbody');
      var theadRow = table.querySelector('thead tr');
      if (!tbody || !theadRow) return;
      var bodyRows = tbody.querySelectorAll('tr');
      for (var r = 0; r < bodyRows.length; r++) {
        bodyRows[r].setAttribute('data-orig', String(r));
      }
      var headerCells = theadRow.querySelectorAll('th');
      for (var c = 0; c < headerCells.length; c++) {
        var th = headerCells[c];
        var headWrapper = document.createElement('div');
        headWrapper.className = 'markdown-table-head';
        var label = document.createElement('span');
        label.className = 'markdown-table-sort-label';
        label.textContent = th.textContent;
        var sort = document.createElement('button');
        sort.type = 'button';
        sort.className = 'markdown-table-sort';
        sort.title = 'Sort column';
        sort.textContent = '\u21C5';
        sort.addEventListener('click', (function (tbl, colIdx) {
          return function () {
            var asc = tbl.getAttribute('data-sort-col') === String(colIdx) &&
              tbl.getAttribute('data-sort-dir') === 'asc';
            var dir = asc ? 'desc' : 'asc';
            tbl.setAttribute('data-sort-col', String(colIdx));
            tbl.setAttribute('data-sort-dir', dir);
            var body = tbl.querySelector('tbody');
            if (!body) return;
            var rows = Array.prototype.slice.call(body.querySelectorAll('tr'));
            rows.sort(function (a, b) {
              var av = a.cells[colIdx] ? (a.cells[colIdx].textContent || '').toLowerCase() : '';
              var bv = b.cells[colIdx] ? (b.cells[colIdx].textContent || '').toLowerCase() : '';
              if (av < bv) return dir === 'asc' ? -1 : 1;
              if (av > bv) return dir === 'asc' ? 1 : -1;
              return Number(a.getAttribute('data-orig') || 0) - Number(b.getAttribute('data-orig') || 0);
            });
            for (var i = 0; i < rows.length; i++) body.appendChild(rows[i]);
            var sels = tbl.querySelectorAll('.markdown-table-sort');
            for (var s = 0; s < sels.length; s++) {
              sels[s].textContent = s === colIdx ? (dir === 'asc' ? '\u25B2' : '\u25BC') : '\u21C5';
            }
          };
        })(table, c));
        headWrapper.appendChild(label);
        headWrapper.appendChild(sort);
        th.textContent = '';
        th.appendChild(headWrapper);
      }
      var filter = document.createElement('input');
      filter.type = 'text';
      filter.className = 'markdown-table-filter';
      filter.placeholder = 'Filter table';
      // Delegated on the table so the handler survives any re-render that
      // replaces the input element.
      table.addEventListener('input', function (ev) {
        var inp = ev && ev.target;
        if (!inp || !inp.classList || !inp.classList.contains('markdown-table-filter')) return;
        var q = inp.value.toLowerCase();
        var rows = table.querySelectorAll('tbody tr');
        for (var r = 0; r < rows.length; r++) {
          rows[r].hidden = !!q && (rows[r].textContent || '').toLowerCase().indexOf(q) === -1;
        }
      });
      var frow = document.createElement('tr');
      frow.className = 'markdown-table-filter-row';
      var fcell = document.createElement('th');
      fcell.colSpan = headerCells.length;
      fcell.appendChild(filter);
      frow.appendChild(fcell);
      theadRow.parentNode.insertBefore(frow, theadRow.nextSibling);
      })(tables[t]);
    }
  }

  function createFragmentPatcher(log) {
    var lastSeq = -1;
    var pending = {};
    var settleMs = 5000;


    function patch(fragments, seq, optimistic) {
      if (!fragments || !fragments.length) return;

      // Fragment replacement destroys + recreates scroll containers, which
      // resets their scrollTop. Snapshot every tagged scroller before
      // applying and restore it after, so in-place updates (settings, list
      // views) don't jump to the top.
      var scrollState = captureScrollState();

      if (seq !== undefined && seq !== null) {
        if (seq <= lastSeq) {
          log.warn('Dropping duplicate/out-of-order update seq=' + seq + ' (last=' + lastSeq + ')');
          return;
        }
        lastSeq = seq;
      }

      log.debug('Patching ' + fragments.length + ' fragment(s)' + (seq !== undefined ? ' seq=' + seq : ''));

      for (var i = 0; i < fragments.length; i++) {
        var f = fragments[i];
        if (!f.id || f.html === undefined) {
          if (optimistic) continue;
          log.warn('Invalid fragment at index ' + i);
          continue;
        }
        if (optimistic) {
          armPending(f.id);
        } else {
          clearPending(f.id);
        }
        replaceElement(f.id, f.html);
      }

      restoreScrollState(scrollState);

      // Hermes parity: typeset math and add table controls after every patch.
      enhanceMarkdownTables(document);
      renderKatexBlocks(document, { streaming: true });
    }

    function captureScrollState() {
      var state = [];
      var scrollers = document.querySelectorAll('[data-scroll-key]');
      for (var i = 0; i < scrollers.length; i++) {
        var el = scrollers[i];
        if (el.scrollTop > 0 || el.scrollLeft > 0) {
          state.push({
            key: el.getAttribute('data-scroll-key'),
            top: el.scrollTop,
            left: el.scrollLeft
          });
        }
      }
      return state;
    }

    function restoreScrollState(state) {
      for (var i = 0; i < state.length; i++) {
        var s = state[i];
        var el = document.querySelector('[data-scroll-key="' + s.key + '"]');
        if (!el) continue;
        // A fresh chat open tags the scroller with data-follow="bottom":
        // restoring the previous chat's position would flash it, so let the
        // follow-to-bottom logic win instead.
        if (el.getAttribute('data-follow') === 'bottom') continue;
        el.scrollTop = s.top;
        el.scrollLeft = s.left;
      }
    }

    function armPending(id) {
      var el = document.getElementById(id);
      if (!el) return;
      clearPending(id);
      pending[id] = { html: el.outerHTML, timer: null };
      var record = pending[id];
      record.timer = setTimeout(function () {
        if (!pending[id]) return;
        var saved = pending[id].html;
        delete pending[id];
        replaceElement(id, saved);
        log.warn('optimistic patch for #' + id + ' rolled back (no confirmation)');
      }, settleMs);
    }

    function clearPending(id) {
      var record = pending[id];
      if (!record) return;
      if (record.timer) clearTimeout(record.timer);
      delete pending[id];
    }

    function sanitizeFragmentHTML(html) {

      html = html.replace(/&#(\d+);/g, function (_, n) { return String.fromCharCode(Number(n)); });
      html = html.replace(/&#x([0-9a-f]+);/gi, function (_, h) { return String.fromCharCode(parseInt(h, 16)); });
      html = html.replace(/&colon;/gi, ':');

      html = html.replace(new RegExp('<script[^<]*(?:<[^<]*)*' + '<' + '/script>', 'gi'), '');

      html = html.replace(new RegExp("\\s+on\\w+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", 'gi'), '');

      html = html.replace(new RegExp('\\s+(href|src|action|formaction|xlink:href)\\s*=\\s*"javascript:[^"]*"', 'gi'), ' $1=""');
      html = html.replace(new RegExp("\\s+(href|src|action|formaction|xlink:href)\\s*=\\s*'javascript:[^']*'", 'gi'), " $1=''");
      return html;
    }

    function replaceElement(id, html) {
      var el = document.getElementById(id);
      if (!el) {
        log.warn('Element not found: #' + id);
        return;
      }

      html = sanitizeFragmentHTML(html);

      var savedState = saveInputState(el);

      var range = document.createRange();
      range.selectNode(el);
      var fragment = range.createContextualFragment(html);
      el.parentNode.replaceChild(fragment, el);

      restoreInputState(id, savedState);

      log.debug('Replaced #' + id);
    }


    function saveInputState(root) {
      var state = {};
      var inputs = root.querySelectorAll('input, textarea, select');
      var active = null;
      try { active = document.activeElement; } catch (e) { active = null; }
      for (var i = 0; i < inputs.length; i++) {
        var el = inputs[i];
        var key = el.id || el.name || i;
        var record = { value: el.value, session: el.getAttribute('data-session') };
        if (el.type === 'checkbox' || el.type === 'radio') {
          record.checked = el.checked;
        }
        try {
          record.selectionStart = el.selectionStart;
          record.selectionEnd = el.selectionEnd;
        } catch (e) { }
        if (active === el) record.focused = true;
        state[key] = record;
        saveScroll(el, el.id || el.name || String(i), state);
      }
      var scrollers = root.querySelectorAll('div, section, ul, ol, main, aside, nav, [tabindex]');
      for (var j = 0; j < scrollers.length; j++) {
        var sc = scrollers[j];
        if (sc.tagName === 'TEXTAREA') continue;
        saveScroll(sc, sc.id || sc.name || '', state);
      }
      saveScroll(root, '__root', state);
      if (active && root.contains(active)) {
        var tag = active.tagName;
        var isForm = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || tag === 'BUTTON';
        if (!isForm && active.id) {
          state['focus:' + active.id] = { focus: true };
        }
      }
      return state;
    }

    function saveScroll(el, key, state) {
      if (!key) return;
      if (!el.scrollTop && !el.scrollLeft) return;
      state['scroll:' + key] = { sTop: el.scrollTop, sLeft: el.scrollLeft };
    }


    function safeSetSelectionRange(el, start, end) {
      try {
        if (typeof el.setSelectionRange === 'function') {
          el.setSelectionRange(start, end);
        }
      } catch (e) { }
    }

    function restoreInputState(fragmentId, state) {
      if (!state) return;
      var root = document.getElementById(fragmentId);
      if (!root) return;
      var inputs = root.querySelectorAll('input, textarea, select');
      var focusTarget = null;
      var focusState = null;
      for (var i = 0; i < inputs.length; i++) {
        var el = inputs[i];
        var key = el.id || el.name || i;
        var saved = state[key];
        if (saved) {
          // A session change means the fragment re-rendered for a different
          // chat: the server rendered THAT chat's composer draft, so the old
          // element's value must not be restored across the switch.
          if (saved.session !== el.getAttribute('data-session')) continue;
          if (saved.value !== undefined && el.value !== saved.value && !el.hasAttribute('data-no-restore')) {
            el.value = saved.value;
          }
          if (saved.checked !== undefined && (el.type === 'checkbox' || el.type === 'radio') && !el.hasAttribute('data-no-restore')) {
            el.checked = saved.checked;
          }
          if (saved.selectionStart !== undefined && saved.selectionEnd !== undefined) {
            safeSetSelectionRange(el, saved.selectionStart, saved.selectionEnd);
          }
          if (saved.focused) {
            focusTarget = el;
            focusState = saved;
          }
        }
        var scrollKey = 'scroll:' + (el.id || el.name || String(i));
        if (state[scrollKey]) {
          el.scrollTop = state[scrollKey].sTop;
          el.scrollLeft = state[scrollKey].sLeft;
        }
      }
      for (var sk in state) {
        if (sk.indexOf('scroll:') !== 0) continue;
        var targetId = sk.slice(7);
        if (targetId === '__root') {
          root.scrollTop = state[sk].sTop;
          root.scrollLeft = state[sk].sLeft;
          continue;
        }
        var target = document.getElementById(targetId);
        if (target) {
          target.scrollTop = state[sk].sTop;
          target.scrollLeft = state[sk].sLeft;
        }
      }
      for (var fk in state) {
        if (fk.indexOf('focus:') !== 0) continue;
        var focusEl = document.getElementById(fk.slice(6));
        if (focusEl && typeof focusEl.focus === 'function') {
          try { focusEl.focus(); } catch (e) { }
        }
        break;
      }
      if (focusTarget && typeof focusTarget.focus === 'function') {
        try {
          focusTarget.focus();
          if (focusState && focusState.selectionStart !== undefined && focusState.selectionEnd !== undefined) {
            safeSetSelectionRange(focusTarget, focusState.selectionStart, focusState.selectionEnd);
          }
        } catch (e) { }
      }
    }

    function reset() {
      lastSeq = -1;
      for (var id in pending) {
        if (pending.hasOwnProperty(id) && pending[id].timer) {
          clearTimeout(pending[id].timer);
        }
      }
      pending = {};
    }

    function setSettle(ms) {
      settleMs = ms;
    }

    return { patch: patch, reset: reset, setSettle: setSettle };
  }

  var UNSAFE_PROTOCOLS = /^(javascript|data|vbscript):/i;

  function stripUrlControlChars(url) {
    return String(url).replace(/[\u0000-\u0020\u007F]/g, '');
  }

  function isSafeUrl(url) {
    return !UNSAFE_PROTOCOLS.test(stripUrlControlChars(url));
  }

  function createRouter(log) {
    return {
      navigate: function (url) {
        if (!url) return;
        var clean = stripUrlControlChars(url);
        if (!isSafeUrl(clean)) { log.warn('Router.navigate: blocked unsafe URL'); return; }
        history.pushState(null, '', clean);
      },

      redirect: function (url, replace) {
        if (!url) return;
        var clean = stripUrlControlChars(url);
        if (!isSafeUrl(clean)) { log.warn('Router.redirect: blocked unsafe URL'); return; }
        if (replace) location.replace(clean);
        else location.href = clean;
      },

      reload: function () { location.reload(); },
    };
  }

  function createStateStore(log) {
    var store = {};
    var subscribers = {};

    var PROTO_DENY = { '__proto__': true, 'constructor': true, 'prototype': true };

    function isSafeKey(key) {
      return !PROTO_DENY.hasOwnProperty(key);
    }

    function get(path) {
      if (!path) return undefined;
      var parts = path.split('.');
      var current = store;
      for (var i = 0; i < parts.length; i++) {
        if (current === undefined || current === null) return undefined;
        if (!isSafeKey(parts[i])) return undefined;
        current = current[parts[i]];
      }
      return current;
    }

    function set(path, value) {
      if (!path) return;
      var parts = path.split('.');

      for (var i = 0; i < parts.length; i++) {
        if (!isSafeKey(parts[i])) {
          log.warn('State.set: denied key "' + parts[i] + '" in path "' + path + '"');
          return;
        }
      }
      var current = store;
      for (var i = 0; i < parts.length - 1; i++) {
        if (!current[parts[i]] || typeof current[parts[i]] !== 'object') {
          current[parts[i]] = {};
        }
        current = current[parts[i]];
      }
      current[parts[parts.length - 1]] = value;
      notify(path, value);
    }

    function subscribe(path, callback) {
      if (!path || typeof callback !== 'function') return function () {};
      if (!subscribers[path]) subscribers[path] = [];
      subscribers[path].push(callback);
      return function () {
        var subs = subscribers[path];
        if (subs) {
          var idx = subs.indexOf(callback);
          if (idx !== -1) subs.splice(idx, 1);
        }
      };
    }

    function notify(path, value) {
      var subs = subscribers[path];
      if (subs) {

        var copy = subs.slice();
        for (var i = 0; i < copy.length; i++) {
          try { copy[i](value, path); } catch (e) { log.error('State subscriber error: ' + e.message); }
        }
      }
    }

    function clear() { store = {}; subscribers = {}; }

    return { get: get, set: set, subscribe: subscribe, clear: clear };
  }

  function createMessageDispatcher(log, fragmentPatcher, stateStore, router) {
    return function handleMessage(msg) {
      if (!msg || !msg.type) {
        log.warn('Received message without type');
        return;
      }

      switch (msg.type) {
        case 'update':
          fragmentPatcher.patch(msg.fragments, msg.seq);
          break;

        case 'redirect':
          router.redirect(msg.url, msg.replace === true);
          break;

        case 'state':
          if (msg.path) stateStore.set(msg.path, msg.value);
          break;

        case 'reload':
          router.reload();
          break;

        case 'error':
          log.error('Server error [' + (msg.code || 'UNKNOWN') + ']: ' + (msg.message || 'No message'));
          break;

        case 'pong':

          break;

        default:
          log.warn('Unknown message type: ' + msg.type);
          break;
      }
    };
  }

  function dispatchEvent(name, detail) {
    try {
      document.dispatchEvent(new CustomEvent(name, { detail: detail }));
    } catch (e) {  }
  }

  var instance = null;


  function init(opts) {
    if (instance) {
      console.warn('[WebUIRuntime] Already initialized');
      return;
    }

    var config = {};
    for (var key in DEFAULTS) {
      if (DEFAULTS.hasOwnProperty(key)) {
        config[key] = (opts && opts[key] !== undefined) ? opts[key] : DEFAULTS[key];
      }
    }

    var log = createLogger(config.logLevel);
    log.info('Initializing WebUI Runtime v0.3');

    var stateStore = createStateStore(log);
    var fragmentPatcher = createFragmentPatcher(log);
    var router = createRouter(log);
    var handleMessage = createMessageDispatcher(log, fragmentPatcher, stateStore, router);
    var wsClient = createWSClient(log, handleMessage);
    var eventDelegator = createEventDelegator(log, wsClient.send, fragmentPatcher);

    wsClient.reset(config);
    eventDelegator.reset(config);
    fragmentPatcher.setSettle(config.optimisticSettleMs);

    eventDelegator.mount();

    // Hermes parity: the boot page renders markdown server-side, so run the
    // math/table post-render once on the initial document too (fragment
    // patches already trigger it inside createFragmentPatcher). The runtime
    // loads in <head>, so wait for the body to exist.
    var bootPostRender = function () {
      enhanceMarkdownTables(document);
      renderKatexBlocks(document, { streaming: false });
    };
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', bootPostRender);
    } else {
      bootPostRender();
    }

    wsClient.connect();

    var popstateHandler = function () {
      wsClient.send({ type: 'navigate', url: location.pathname + location.search });
    };
    window.addEventListener('popstate', popstateHandler);

    instance = {
      config: config,
      log: log,
      wsClient: wsClient,
      eventDelegator: eventDelegator,
      fragmentPatcher: fragmentPatcher,
      stateStore: stateStore,
      popstateHandler: popstateHandler,
    };

    log.info('WebUI Runtime initialized');
  }


  function destroy() {
    if (!instance) return;
    instance.log.info('Destroying WebUI Runtime');
    if (instance.popstateHandler) {
      window.removeEventListener('popstate', instance.popstateHandler);
    }
    instance.wsClient.disconnect();
    instance.eventDelegator.unmount();
    instance.fragmentPatcher.reset();
    instance.stateStore.clear();
    instance = null;
  }

  window.addEventListener('beforeunload', destroy);

  return {
    init: init,
    destroy: destroy,

    _reset: function () { instance = null; },
    _getInstance: function () { return instance; },
  };
})();

/* ── Composer flyout helpers (Hermes parity: approval + clarify cards) ── */
(function () {
  var COLLAPSE_JS = true;
  var countdownTimer = setInterval(function () {
    var el = document.getElementById('clarify-countdown');
    if (!el) return;
    var exp = parseInt(el.getAttribute('data-expires') || '0', 10);
    if (!exp) return;
    var ms = exp - Date.now();
    if (ms <= 0) {
      el.textContent = '0s';
      el.classList.add('urgent');
      return;
    }
    var s = Math.ceil(ms / 1000);
    el.textContent = s + 's';
    el.classList.toggle('urgent', s <= 10);
  }, 500);

  document.addEventListener('click', function (e) {
    if (!e.target.closest) return;
    var other = e.target.closest('#clarify-other');
    if (other) {
      var inp = document.getElementById('clarify-input');
      if (inp) inp.focus();
      return;
    }
    var col = e.target.closest('#approval-collapse');
    if (col) {
      var card = col.closest('.approval-card');
      if (card) card.classList.toggle('collapsed');
      return;
    }
    var ccl = e.target.closest('#clarify-collapse');
    if (ccl) {
      var ccard = ccl.closest('.clarify-card');
      if (ccard) ccard.classList.toggle('collapsed');
    }
  });

  document.addEventListener('keydown', function (e) {
    var inp = e.target;
    if (inp && inp.id === 'clarify-input' && e.key === 'Enter') {
      e.preventDefault();
      var f = document.getElementById('clarify-form');
      if (f && f.requestSubmit) f.requestSubmit();
      else {
        var btn = document.getElementById('clarify-submit');
        if (btn) btn.click();
      }
    }
  });

  // Focus the "Allow once" button when an approval card appears (Enter =
  // approve once, mirroring Hermes' keyboard shortcut).

      /* ── Run queue: drag-and-drop reordering ── */
  var queueSrcQid = null;
  var queueHover = null;
  function queueRowFrom(target) {
    return target && target.closest ? target.closest('#main .queue-row') : null;
  }
  function queueIndicatorClear() {
    var rows = document.querySelectorAll('#main .queue-row');
    for (var i = 0; i < rows.length; i++) {
      rows[i].classList.remove('drop-before');
      rows[i].classList.remove('drop-after');
    }
  }
  document.addEventListener('dragstart', function (e) {
    var row = queueRowFrom(e.target);
    if (!row) return;
    queueSrcQid = row.getAttribute('data-qid');
    queueHover = null;
    row.classList.add('dragging');
    if (e.dataTransfer) {
      e.dataTransfer.effectAllowed = 'move';
      try { e.dataTransfer.setData('text/plain', queueSrcQid || ''); } catch (err) {}
    }
  });
  document.addEventListener('dragover', function (e) {
    if (!queueSrcQid) return;
    e.preventDefault();
    if (e.dataTransfer) {
      try { e.dataTransfer.dropEffect = 'move'; } catch (err) {}
    }
    var hovered = queueRowFrom(e.target);
    queueIndicatorClear();
    if (!hovered || hovered.getAttribute('data-qid') === queueSrcQid) {
      queueHover = null;
      return;
    }
    var rect = hovered.getBoundingClientRect();
    var before = (e.clientY - rect.top) < rect.height / 2;
    hovered.classList.add(before ? 'drop-before' : 'drop-after');
    queueHover = { ref: hovered.getAttribute('data-qid'), before: before };
  });
  document.addEventListener('dragleave', function (e) {
    var row = queueRowFrom(e.target);
    if (row) {
      row.classList.remove('drop-before');
      row.classList.remove('drop-after');
    }
  });
  document.addEventListener('drop', function (e) {
    if (queueSrcQid) e.preventDefault();
  });
  document.addEventListener('dragend', function (e) {
    var row = queueRowFrom(e.target);
    if (row) row.classList.remove('dragging');
    queueIndicatorClear();
    var src = queueSrcQid;
    var hov = queueHover;
    queueSrcQid = null;
    queueHover = null;
    if (!src || !hov) return;
    var btn = document.getElementById('queue-reorder');
    if (!btn) return;
    btn.setAttribute('data-payload', 'move:' + src + ':' + (hov.before ? 'b' : 'a') + ':' + hov.ref);
    btn.click();
  });

// Focus the "Allow once" button when an approval card appears (Enter =
  var lookedFlyout = null;
  var mo = new MutationObserver(function () {
    var b = document.getElementById('approval-once');
    if (b && document.activeElement !== b) b.focus();
  });
  setInterval(function () {
    var f = document.getElementById('composer-flyout');
    if (f && f !== lookedFlyout) {
      if (lookedFlyout) mo.disconnect();
      lookedFlyout = f;
      mo.observe(f, { childList: true, subtree: true });
    }
  }, 800);

  // "Set category" flyout: position the submenu with fixed coordinates next
  // to the menu item (escapes .panel-body's overflow clip). Shows on hover or
  // focus; hides when the pointer/keyboard leaves the menu item.
  function catItemIn(el) {
    return el && el.closest && el.closest('.menu-item.has-sub') ? true : false;
  }
  function showCatSub() {
    var head = document.querySelector('.cat-set-head');
    if (!head) return;
    var item = head.closest('.menu-item.has-sub');
    var sub = item && item.querySelector('.cat-sub');
    if (!sub) return;
    var r = head.getBoundingClientRect();
    sub.style.position = 'fixed';
    sub.style.left = (r.right + 6) + 'px';
    sub.style.top = r.top + 'px';
    sub.style.zIndex = '80';
    sub.style.display = 'flex';
  }
  function hideCatSub() {
    var sub = document.querySelector('.cat-sub');
    if (sub) sub.style.display = '';
  }
  document.addEventListener('pointerover', function (e) {
    if (catItemIn(e.target)) showCatSub();
  });
  document.addEventListener('pointerout', function (e) {
    if (catItemIn(e.target) && !catItemIn(e.relatedTarget)) hideCatSub();
  });
  document.addEventListener('focusin', function (e) {
    if (e.target && e.target.closest && e.target.closest('.cat-set-head')) showCatSub();
  });
  document.addEventListener('focusout', function (e) {
    if (e.target && e.target.closest && e.target.closest('.cat-set-head')) {
      setTimeout(hideCatSub, 60);
    }
  });
})();



"""#
}

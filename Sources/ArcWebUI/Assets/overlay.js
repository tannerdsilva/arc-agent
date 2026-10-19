// The client is no-webui's ENGINE: HTMLDocument emits the
// `webui-config` meta and the engine script itself, so this page no
// longer boots or serves the legacy WebUIRuntime. What remains below is
// only the arc-specific overlay (composer, tables, slash menu,
// selection, outline, worklog) — everything it used to rely on the
// runtime for (transport, event dispatch, fragment patching, scroll and
// form-state restore, HTML sanitising) is the engine's job now.

(function () {
  try {
  // The engine restores input values across fragment replacements, so a
  // server-side empty textarea would be re-filled. Clear the composer after
  // the engine has read its value on submit — the ENGINE's delegated submit
  // listener lives on `document`, so this one registers on `window` (bubble
  // reaches window last): registering on `document` instead would clear the
  // field BEFORE the engine reads it, and every send would carry "".
  window.addEventListener('submit', function (e) {
    if (e.target && e.target.id === 'composer-form') {
      var t = document.getElementById('composer-input');
      if (t) t.value = '';
      // A send consumes the composed text; an open slash menu must not
      // linger over the next prompt.
      closeSlashMenu();
    }
  });

  // ---- Enter sends; Shift+Enter keeps the newline.
  // The engine only suppresses Enter's default on NON-textarea targets (its
  // `editTarget` guard), so `data-prevent-enter="send"` on the composer
  // textarea is inert and Enter used to insert a newline. Drive the form's own
  // submit path instead: the engine's delegated submit listener flushes pending
  // inputs and reads the live form values, so the server always sees the text
  // that is on screen. Empty composers fall through to the server, which
  // no-ops on blank text (same as clicking Send with nothing typed).
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Enter' || e.shiftKey || e.isComposing || e.keyCode === 229) return;
    var t = e.target;
    if (!t || t.id !== 'composer-input') return;
    // An open slash menu owns Enter: it inserts the highlighted command
    // (handled by the slash keydown listener) and must not also submit.
    if (slashMenuOpen()) return;
    var form = document.getElementById('composer-form');
    if (!form) return;
    e.preventDefault();
    if (typeof form.requestSubmit === 'function') {
      form.requestSubmit();
    } else {
      form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    }
  });

  // ---- Slash-command autocomplete (UX-01).
  // The markup and payload (`#cmd-dropdown`, `#slash-data`) are server-side;
  // the engine migration dropped the consumer that used to drive them, so `/`
  // in the composer statically rendered nothing. This overlay owns the menu:
  // it opens when `/` starts the first token, filters as that token grows,
  // ArrowUp/Down + Enter/Tab insert, Escape/outside-click/blur close. An
  // insert is a pure text edit — the server's builtin/skill expansion still
  // resolves the send, so the autocomplete never forks the wire.
  function slashItems() {
    var host = document.getElementById('slash-data');
    if (!host) return [];
    if (host.__parsed) return host.__parsed;
    var items = [];
    try {
      var data = JSON.parse(host.textContent || '{}');
      items = data.items || [];
    } catch (err) { items = []; }
    host.__parsed = items;
    return items;
  }

  // The first token typed: `"" | "he"` for `/he …`. null when the composer
  // does not start with `/`.
  function slashToken(value) {
    var m = /^\s*\/([^\s]*)/.exec(value || '');
    return m ? m[1] : null;
  }

  function slashFiltered(token) {
    var q = (token || '').toLowerCase();
    return slashItems().filter(function (it) {
      if (!q) return true;
      return (it.name || '').toLowerCase().indexOf(q) !== -1 ||
             (it.desc || '').toLowerCase().indexOf(q) !== -1;
    });
  }

  function slashDropdown() { return document.getElementById('cmd-dropdown'); }
  // T25: the rows live inside a borderless/paddingless `.cmd-list` wrapper so
  // the scroll region's border-box height IS its content height — sizing it to
  // an exact multiple of the row pitch clips flush at a row boundary.
  function slashList(dd) {
    var l = dd ? dd.querySelector('.cmd-list') : null;
    if (!l && dd) {
      l = document.createElement('div');
      l.className = 'cmd-list';
      dd.appendChild(l);
      if (!l.style.maxHeight) l.style.maxHeight = '460px';
    }
    return l;
  }
  function slashMenuOpen() {
    var dd = slashDropdown();
    return !!dd && dd.classList.contains('open');
  }
  function closeSlashMenu() {
    var dd = slashDropdown();
    if (dd) dd.classList.remove('open');
  }

  var slashSel = 0;
  // Once `/name ` has been inserted, do not immediately re-open the menu for
  // the same token the user is now typing arguments after (UX-01: an insert
  // completes the command; editing the token back re-opens it).
  var slashSuppressed = null;

  // T25: the dropdown's old fixed `max-height` sliced a row in half (a 232 px
  // box against 57.5 px rows showed 2 px of the 4th row). The scroll region is
  // now the borderless `.cmd-list` wrapper, so `max-height = N × row-pitch`
  // (border-box == content-box) lands exactly on a row boundary — the (N+1)th
  // row starts flush with the box edge, never sliced. The pitch is the mean of
  // the rendered float row-top deltas (sub-pixel line heights are the honest
  // unit: integer offsetTop would round 57.5 to 58 and re-slice the first
  // hidden row by the rounding error).
  function sizeSlashDropdown(dd, input) {
    var list = slashList(dd);
    if (!list) return;
    var rows = list.querySelectorAll('.cmd-item');
    if (!rows.length) return;
    var rowH;
    if (rows.length >= 2) {
      var first = rows[0].getBoundingClientRect().top;
      var last = rows[rows.length - 1].getBoundingClientRect().top;
      if (last > first) rowH = (last - first) / (rows.length - 1);
      else rowH = rows[0].getBoundingClientRect().height;
    } else {
      rowH = rows[0].getBoundingClientRect().height;
    }
    if (!(rowH > 0)) rowH = 57.5;
    var r = input ? input.getBoundingClientRect() : null;
    var composerTop = r ? r.top : window.innerHeight - 64;
    // UX-54: 240 px showed only ~4 of 10 commands while ~700 px sat unused
    // above the composer. Cap at 460 (~8 rows) so the common set is visible
    // and the tail is one obvious wheel away.
    var avail = Math.max(rowH, Math.min(460, composerTop - 12));
    var whole = Math.max(1, Math.floor(avail / rowH));
    // Round to the nearest quarter-pixel so the written max-height never
    // carries 0.0001 px dust that would resurface as a hairline sliver.
    list.style.maxHeight = (Math.round((whole * rowH) * 4) / 4) + 'px';
    list.style.overflowY = 'auto';
  }

  // Keep the highlighted row in view while moving the selection.
  function revealSlashRow(dd) {
    var list = slashList(dd);
    if (!list) return;
    var sel = dd.querySelector('.cmd-item.active');
    if (!sel) return;
    // Scroll the inner list so `sel` is fully inside it (block: 'nearest'
    // only guarantees SOME part visible — a half-revealed active row is
    // exactly the sliced-row symptom T25 exists to ban).
    var top = sel.offsetTop;
    var bottom = top + sel.offsetHeight;
    if (list.scrollTop > top) list.scrollTop = top;
    else if (list.scrollTop + list.clientHeight < bottom) {
      list.scrollTop = bottom - list.clientHeight;
    }
  }

  function renderSlashMenu(token) {
    var dd = slashDropdown();
    if (!dd) return;
    var wasOpen = dd.classList.contains('open');
    // T25: a fresh open highlights the FIRST row (Enter's target must be
    // unambiguous even after a previous interaction left slashSel elsewhere).
    if (!wasOpen) slashSel = 0;
    var list = slashList(dd);
    list.textContent = '';
    var items = slashFiltered(token);
    if (!items.length) { dd.classList.remove('open'); return; }
    for (var i = 0; i < items.length; i++) {
      (function (it, idx) {
        var b = document.createElement('button');
        b.type = 'button';
        b.className = 'cmd-item' + (idx === slashSel ? ' active' : '');
        b.setAttribute('role', 'option');
        b.setAttribute('aria-selected', idx === slashSel ? 'true' : 'false');
        var line1 = document.createElement('div');
        var name = document.createElement('span');
        name.className = 'cmd-item-name';
        name.textContent = '/' + it.name;
        line1.appendChild(name);
        if (it.arg) {
          var arg = document.createElement('span');
          arg.className = 'cmd-item-arg';
          arg.textContent = it.arg;
          line1.appendChild(arg);
        }
        var badge = document.createElement('span');
        badge.className = 'cmd-item-badge' + (it.kind === 'skill' ? ' cmd-item-badge-skill' : '');
        badge.textContent = it.kind === 'skill' ? 'Skill' : 'cmd';
        line1.appendChild(badge);
        var desc = document.createElement('div');
        desc.className = 'cmd-item-desc';
        desc.textContent = it.desc || '';
        b.appendChild(line1);
        b.appendChild(desc);
        b.addEventListener('mousedown', function (ev) { ev.preventDefault(); });
        b.addEventListener('click', function () { chooseSlash(it.name); });
        list.appendChild(b);
      })(items[i], i);
    }
    // Anchor the fixed dropdown just above the composer input.
    var input = document.getElementById('composer-input');
    var r = input ? input.getBoundingClientRect() : { left: 16, top: window.innerHeight - 64 };
    dd.style.left = Math.max(12, r.left) + 'px';
    dd.style.bottom = (window.innerHeight - r.top + 8) + 'px';
    dd.classList.add('open');
    sizeSlashDropdown(dd, input);
    revealSlashRow(dd);
  }

  function chooseSlash(name) {
    var t = document.getElementById('composer-input');
    if (!t) return;
    t.value = (t.value || '').replace(/^\s*\/[^\s]*/, '/' + name + ' ');
    slashSuppressed = name;
    t.dispatchEvent(new Event('input', { bubbles: true }));
    resizeComposer();
    closeSlashMenu();
    t.focus();
  }

  // Re-run on every input in the composer: open on `/`, filter as the token
  // grows, close when the `/` token goes away.
  function syncSlashMenu(value) {
    var tok = slashToken(value);
    if (tok === null) { closeSlashMenu(); return; }
    if (slashSuppressed === tok) return;
    renderSlashMenu(tok);
  }

  // Keyboard: ArrowUp/Down move the selection, Enter/Tab insert, Escape closes.
  // Only while the menu is open and the composer owns focus.
  document.addEventListener('keydown', function (e) {
    if (!slashMenuOpen()) return;
    var t = e.target;
    if (!t || t.id !== 'composer-input') return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      var list = slashFiltered(slashToken(t.value));
      var n = list.length;
      if (!n) return;
      slashSel = e.key === 'ArrowDown' ? (slashSel + 1) % n : (slashSel - 1 + n) % n;
      renderSlashMenu(slashToken(t.value));
      revealSlashRow(slashDropdown());
      return;
    }
    if (e.key === 'Enter' || e.key === 'Tab') {
      var candidates = slashFiltered(slashToken(t.value));
      if (!candidates.length) return;
      e.preventDefault();
      chooseSlash(candidates[Math.min(slashSel, candidates.length - 1)].name);
      return;
    }
    if (e.key === 'Escape') {
      e.preventDefault();
      closeSlashMenu();
    }
  });

  // Clicking anywhere outside the dropdown closes it — including clicks inside
  // the composer bar, which the shared outside-click handler deliberately
  // ignores. (Clicks land on mousedown-prevented items inside the menu, so
  // focus never leaves the composer while picking.)
  document.addEventListener('focusin', function (e) {
    if (!slashMenuOpen()) return;
    var dd = slashDropdown();
    if (dd && dd.contains(e.target)) return;
    closeSlashMenu();
  });

  // ---- Image paste (arc parity): pasting an image (or image file)
  // into the composer uploads it and attaches it via the existing
  // attach wire, so it flows through describeImage on send. Text
  // pastes are untouched.
  function attachUploadedPath(p) {
    var inp = document.getElementById('file-path-input');
    if (!inp) return;
    var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    setter.call(inp, p);
    inp.dispatchEvent(new Event('input', { bubbles: true }));
    // The runtime debounces input events (~80ms); wait for the path to
    // reach the server before clicking Attach, or the click wins the
    // race and the server sees an empty path.
    setTimeout(function () {
      var btn = document.getElementById('file-attach');
      if (btn) btn.click();
    }, 350);
  }
  document.addEventListener('paste', function (e) {
    if (!e.target || e.target.id !== 'composer-input') return;
    var cd = e.clipboardData;
    if (!cd) return;
    var imgs = [];
    var items = Array.prototype.slice.call(cd.items || []);
    var hasFileItem = false;
    items.forEach(function (it) {
      if (it.kind === 'file') hasFileItem = true;
    });
    if (hasFileItem) {
      // items covers files; reading both would double-attach.
      items.forEach(function (it) {
        if (it.kind === 'file' && it.type && it.type.indexOf('image/') === 0) {
          var f = it.getAsFile();
          if (f) imgs.push(f);
        }
      });
    } else {
      Array.prototype.slice.call(cd.files || []).forEach(function (f) {
        if (f.type && f.type.indexOf('image/') === 0) imgs.push(f);
      });
    }
    if (!imgs.length) return; // text paste: normal behavior
    e.preventDefault();
    // Keep any text that travelled with the clipboard.
    var txt = cd.getData ? (cd.getData('text') || '') : '';
    if (txt) {
      var t = document.getElementById('composer-input');
      if (t) {
        t.value = (t.value ? t.value + String.fromCharCode(10) : '') + txt;
        t.dispatchEvent(new Event('input', { bubbles: true }));
      }
    }
    imgs.forEach(function (f) {
      var ext = (f.type.split('/')[1] || 'png').replace(/[^a-z0-9]/gi, '').toLowerCase();
      if (!ext || ext.length > 8) ext = 'img';
      fetch('/api/upload?ext=' + encodeURIComponent(ext), {
        method: 'POST',
        headers: { 'Content-Type': 'application/octet-stream' },
        body: f
      }).then(function (r) { return r.json(); }).then(function (j) {
        if (j && j.ok && j.path) attachUploadedPath(j.path);
      }).catch(function (err) { console.warn('image upload failed', err); });
    });
  });

  // ---- Composer autogrow (arc parity): the textarea expands with
  // content up to 7 visible lines, then scrolls internally.
  function resizeComposer() {
    var t = document.getElementById('composer-input');
    if (!t) return;
    var cs = getComputedStyle(t);
    var lh = parseFloat(cs.lineHeight) || 22;
    var pad = (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.paddingBottom) || 0);
    var max = Math.round(lh * 7 + pad);
    t.style.height = 'auto';
    var h = Math.min(t.scrollHeight, max);
    t.style.height = h + 'px';
    t.style.overflowY = t.scrollHeight > max ? 'auto' : 'hidden';
  }
  // Fragments replace the textarea node on re-renders; resize only when
  // a fresh node appears (keystrokes use the input listener below).
  function resizeComposerIfNew() {
    var t = document.getElementById('composer-input');
    if (t && !t.__rsz) { t.__rsz = true; resizeComposer(); }
  }
  document.addEventListener('input', function (e) {
    if (e.target && e.target.id === 'composer-input') {
      resizeComposer();
      syncSlashMenu(e.target.value);
    }
  });

  // ---- Scroll-to-bottom. Follows new content while the user is at the
  // bottom, and always jumps to the bottom when a fresh chat is opened
  // (the server tags #chat-scroll with data-follow="bottom" on open).
  //
  // The stick is USER INTENT, not distance. A wheel-up, a reading key
  // (Up/PageUp/Home), a touch drag, or any net upward movement releases it —
  // even one line from the bottom — and only arriving back at the very bottom
  // re-engages. The old distance-only rule (release only beyond a 120px pad)
  // made a short scroll-up impossible mid-stream: the next push snapped the
  // viewport back to the live text (measured: 80px up -> +309px re-pin).
  // Distance still guards the degenerate case: a content-shrink clamp must
  // not read as a scroll-up, so the bottom test runs first.
  var RESTICK_EPS = 6;   // px from the bottom that re-engages follow
  var KEY_STEP = 48;     // ArrowUp/ArrowDown step
  function chatScroller() { return document.getElementById('chat-scroll'); }
  function atBottom(s) { return s.scrollHeight - s.scrollTop - s.clientHeight <= RESTICK_EPS; }
  var stick = true;
  var lastTop = null;
  var seenChatScroll = null;
  // Round-4 scroll/draft memory (UX-39/40/41): a rail switch re-renders the
  // chat and panel fragments, and the engine's input preservation keeps the
  // old chat's composer text across the swap. These maps live for the page's
  // lifetime so a return can put the reader back where they were.
  var chatScrollMemory = {};
  var panelScrollMemory = {};
  var panelSeen = {};
  var lastComposerSession = null;
  var focusComposerWanted = false;
  // ---- Pipe-table enhancement (arc-specific).
  // Lived in the forked runtime until that fork was deleted; it belongs in the
  // overlay and is driven from the engine's afterPatch seam below — pipe tables
  // get per-column sort + a filter input.

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
          // UX-08: the glyph alone ('⇅') was the whole accessible name. The
          // button must name the column it sorts, and the header must expose
          // the applied sort order via aria-sort.
          sort.setAttribute('aria-label', 'Sort by ' + (th.textContent || 'this column'));
          sort.textContent = '\u21C5';
          sort.addEventListener('click', (function (tbl, colIdx) {
            return function () {
              var asc = tbl.getAttribute('data-sort-col') === String(colIdx) &&
                tbl.getAttribute('data-sort-dir') === 'asc';
              var dir = asc ? 'desc' : 'asc';
              tbl.setAttribute('data-sort-col', String(colIdx));
              tbl.setAttribute('data-sort-dir', dir);
              var hdr = tbl.querySelector('thead tr');
              if (hdr) {
                for (var h = 0; h < hdr.children.length; h++) {
                  var hc = hdr.children[h];
                  if (!hc || !hc.removeAttribute) continue;
                  if (hc.removeAttribute) hc.removeAttribute('aria-sort');
                }
                var target = hdr.children[colIdx];
                if (target && target.setAttribute) {
                  target.setAttribute('aria-sort', dir === 'asc' ? 'ascending' : 'descending');
                }
              }
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
                sels[s].setAttribute('aria-label', 'Sort by ' + (sels[s].closest ? (sels[s].closest('th').textContent || '') : ''));
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
        // UX-08: the filter field is icon/placeholder-only; a placeholder is
        // not an accessible name.
        filter.setAttribute('aria-label', 'Filter table rows');
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

  // ---- Post-patch seam. The engine hands `afterPatch` the array of elements a
  // fragment batch replaced, so enhancement is scoped to what actually changed
  // instead of rescanning the whole document on every mutation — the old
  // MutationObserver also fired on the overlay's own edits, so it thrashed while
  // a turn streamed. `ready` only fires for hooks registered before the engine
  // boots; this overlay is a separate script that runs first, so registration
  // happens on DOMContentLoaded (after the engine's synchronous boot) and the
  // initial pass is invoked directly. Every pass is idempotent — rendered blocks
  // and enhanced tables are marked, the scroll listener is bound once — which is
  // what makes the extra call safe.
  function stickToChat() {
    var s = chatScroller();
    if (!s) return;
    if (!s.__bound) {
      s.__bound = true;
      s.addEventListener('scroll', function () {
        var top = s.scrollTop;
        var prev = lastTop === null ? top : lastTop;
        lastTop = top;
        var sid = s.getAttribute('data-session') || '';
        if (sid) chatScrollMemory[sid] = top; // per-session position (UX-39)
        if (atBottom(s)) {
          // Back at the very bottom (a deliberate return, the jump button,
          // End, or a content-shrink clamp): follow again. Must run before
          // the up-move test — a clamp reads as "moved up".
          stick = true;
        } else if (top < prev - 1) {
          // Net upward movement without a wheel/key signal (scrollbar or
          // touch drag): the user is reading back.
          stick = false;
        }
        updateJumpBtn(s);
      });
      // Intent signals beat distance. Wheel events fire for wheels and
      // trackpad gestures; touch and scrollbar drags land in the up-move
      // rule above (they emit no wheel events).
      s.addEventListener('wheel', function (e) {
        if (e.deltaY < 0) { stick = false; updateJumpBtn(s); }
      }, { passive: true });
    }
    if (s !== seenChatScroll) {
      // The scroll container was (re)created — a chat open, a streaming
      // refresh, or a rail return. Respect data-follow only for chat opens.
      seenChatScroll = s;
      lastTop = s.scrollTop;
      if (s.getAttribute('data-follow') === 'bottom') {
        stick = true;
        var forceBottom = function () {
          var cur = chatScroller();
          if (cur === s) s.scrollTop = s.scrollHeight;
        };
        requestAnimationFrame(forceBottom);
        setTimeout(forceBottom, 60);
      } else if (stick) {
        s.scrollTop = s.scrollHeight;
      } else {
        // A rail return re-renders the chat fragment WITHOUT data-follow:
        // put the reader back where they were for THIS session instead of
        // at the top of the thread (UX-39). Clamped; re-applied after the
        // layout settles.
        var returnSid = s.getAttribute('data-session') || '';
        if (returnSid && chatScrollMemory[returnSid] != null) {
          var restoreTop = chatScrollMemory[returnSid];
          var restore = function () {
            var cur = chatScroller();
            if (cur !== s) return;
            var max = Math.max(0, s.scrollHeight - s.clientHeight);
            s.scrollTop = Math.min(restoreTop, max);
            lastTop = s.scrollTop;
          };
          restore();
          requestAnimationFrame(restore);
          setTimeout(restore, 60);
        }
      }
    } else if (stick) {
      s.scrollTop = s.scrollHeight;
    }
    // Re-evaluate the jump button on every (re)render, not just on scroll:
    // a finalize patch can shrink the thread under the fold, and the stale
    // "Jump to latest" must not linger with nowhere to jump (UX-42).
    updateJumpBtn(s);
  }

  // ---- Panel scroll memory (UX-41): a rail switch swaps the panel fragment,
  // so each keyed scroller forgets where it was. Remember it in the overlay
  // (per `data-scroll-key`) and restore it when a fresh node for the key
  // arrives. The chat scroller is exempt — stickToChat owns that one.
  function syncPanelScroll() {
    var els = document.querySelectorAll('[data-scroll-key]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var key = el.getAttribute('data-scroll-key');
      if (!key || key === 'chat') continue;
      if (panelSeen[key] !== el) {
        panelSeen[key] = el;
        if (!el.__scrollMemBound) {
          el.__scrollMemBound = true;
          el.addEventListener('scroll', (function (node, k) {
            return function () { panelScrollMemory[k] = node.scrollTop; };
          })(el, key));
        }
        var mem = panelScrollMemory[key];
        if (mem != null) {
          var max = Math.max(0, el.scrollHeight - el.clientHeight);
          el.scrollTop = Math.min(mem, max);
        }
      }
    }
  }

  // ---- Composer draft seam (UX-40): the engine preserves the pre-patch
  // textarea value across fragment patches, so a session switch used to keep
  // the OLD chat's text. The server renders the intended draft as
  // `data-draft` on #composer-input; when the composer's session actually
  // changes, re-assert it. Same-session patches (typing protected mid-turn,
  // chip toggles) are left strictly alone.
  function syncComposerDraft() {
    var el = document.getElementById('composer-input');
    if (!el) return;
    var sid = el.getAttribute('data-session') || '';
    if (sid === lastComposerSession) return;
    lastComposerSession = sid;
    var want = el.getAttribute('data-draft') || '';
    if (el.value !== want) el.value = want;
  }

  // ---- Confirmation dialog: focus, Escape, and a light focus trap.
  // The dialog is a server-rendered fragment the engine patches in, so nothing
  // moves focus into it and Escape had no owner. Land focus on Cancel, route
  // Escape to it, and keep Tab inside the card (no-webui's STABILITY.md lists a
  // framework modal focus trap as a known limitation, so arc owns its own).
  function modalCard() {
    return document.querySelector('.modal-overlay .modal-card');
  }

  // UX-08: remember the control whose activation opened the confirmation
  // dialog. Closing it (Cancel/confirm/Escape) is a fragment patch that
  // removes #modal-overlay and the browser drops focus to <body> — the
  // generic patch-restore alone cannot help because its lastFocusedControl is
  // overwritten by the modal's own focus moves (Cancel/Delete take focus
  // inside the dialog). Restoring from THIS memory puts the keyboard user
  // back on the trigger (or its re-rendered replacement).
  //
  // The trigger must be captured at POINTER time, not focus time: the very
  // fragment patch that ADDS the dialog also re-renders the chat header,
  // which disconnects the focused control, so by the time syncModalFocus
  // runs the browser has already dropped focus to <body> and there is
  // nothing left to record. A document-level capture-phase click listener
  // snapshots the activated control (its id plus the data-sid of the
  // sess-row that owns it) BEFORE the patch, and syncModalFocus adopts that
  // snapshot whenever it finds no live focus to record. Clicks inside the
  // dialog itself never overwrite the remembered trigger. The snapshots stay
  // keyed by id + data-sid because the patch replaces the trigger's node.
  //
  // The restore is keyed to a TRANSITION, not to the snapshot alone: the close
  // round-trip delivers several fragment patches in one batch and the runtime
  // calls enhancePatched for each. The old restoreModalFocus began with an
  // early guard (activeElement !== body → forget the trigger), and the very
  // first patch in the batch ran while the dialog was STILL in the DOM — with
  // focus on #modal-cancel — so the guard wiped the memory before the removal
  // patch arrived. syncModalFocus therefore tracks whether the dialog was open
  // on the previous pass (modalWasOpen) and performs the restore exactly once,
  // on the pass where the card is first gone — right after the DOM actually
  // reflects the removal. No other code path restores.
  var modalReturnFocus = null;
  var modalWasOpen = false;
  document.addEventListener('click', function (e) {
    var card = modalCard();
    if (card && card.contains(e.target)) return;
    var t = e.target && e.target.closest ? e.target.closest('[id]') : null;
    if (!t || !t.id) return;
    modalReturnFocus = { id: (t.id || '').trim(), sid: rowSidOf(t) };
  }, true);

  // Runs after every patch. While the dialog is present: adopt the pointer
  // snapshot if none is live, and land focus on Cancel. On the pass where the
  // dialog has just been removed, hand focus back to the trigger that opened
  // it — this is the single restore seam, and it fires only after the DOM
  // reflects the removal, so no earlier fragment in the batch can clear the
  // memory before it is used.
  function syncModalFocus() {
    var card = modalCard();
    if (!card) {
      if (modalWasOpen) {
        modalWasOpen = false;
        restoreFocusToTrigger();
      }
      return;
    }
    modalWasOpen = true;
    if (card.contains(document.activeElement)) return;
    // activeElement is usually <body> here (the modal patch just disconnected
    // the focused trigger) — fall back to the pointer-time snapshot. When a
    // live focus target does survive (programmatic open), record it directly.
    if (!modalReturnFocus && document.activeElement &&
        document.activeElement !== document.body) {
      modalReturnFocus = {
        id: (document.activeElement.id || '').trim(),
        sid: rowSidOf(document.activeElement)
      };
    }
    var target = card.querySelector('#modal-cancel') || card.querySelector('button');
    if (target) target.focus();
  }

  // The dialog is gone and was open on the previous pass: hand focus back to
  // the remembered trigger — re-queried by id (or by its session row's
  // data-sid) because the fragment patch may have replaced the node. The
  // memory is consumed once so the next open records a fresh trigger, and it
  // is never cleared while a card is present (this is the only caller and it
  // only ever runs with the card gone). A trigger that no longer resolves
  // (e.g. the session was actually deleted) leaves focus alone — no throw, no
  // jump.
  function restoreFocusToTrigger() {
    if (!modalReturnFocus) return;
    var mem = modalReturnFocus;
    modalReturnFocus = null;
    var id = (mem && mem.id) ? String(mem.id).trim() : '';
    var sid = (mem && mem.sid) ? String(mem.sid) : '';
    var nu = null;
    if (id) nu = document.getElementById(id);
    if (!nu && sid) {
      var rows = document.querySelectorAll('.sess-row[data-sid]');
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].getAttribute('data-sid') === sid) { nu = rows[i]; break; }
      }
    }
    if (!nu) return;
    if (sid) nu.setAttribute('tabindex', '0');
    if (nu.disabled || nu.getAttribute('aria-hidden') === 'true') return;
    if (getComputedStyle ? getComputedStyle(nu).display === 'none' : false) return;
    nu.focus({ preventScroll: true });
  }

  document.addEventListener('keydown', function (e) {
    var card = modalCard();
    if (!card) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      var cancel = card.querySelector('#modal-cancel');
      if (cancel) cancel.click();
      return;
    }
    if (e.key !== 'Tab') return;
    var f = card.querySelectorAll(
      'button:not([disabled]), [href], input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])'
    );
    if (!f.length) return;
    var first = f[0], last = f[f.length - 1];
    if (!card.contains(document.activeElement)) { e.preventDefault(); first.focus(); return; }
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });

  // ---- Dismiss the composer dropdowns on Escape or an outside click.
  // The panels are SERVER state (`wsSelectOpen`, `profileSelectOpen`, …) and
  // the server already has the close path: the `dd-dismiss` handler in
  // `Actions.wireAll` was written for exactly this ("fired by the runtime when a
  // click lands outside an open dropdown panel") — but nothing ever rendered the
  // boundary or fired it, so the popover stayed open until its trigger was
  // clicked again. The overlay renders the intent: nudge the server. The chat
  // row menu is client-side and closes itself.
  function dismissDropdowns() {
    // The slash menu closes with the rest of the transient composer surfaces;
    // idempotent when it is not open.
    closeSlashMenu();
    // The attach popover is server state too (`filePopOpen`), so closing it
    // is a re-click of its trigger — the same server round-trip the
    // `dd-dismiss` boundary performs for the selector popovers. Owned here
    // because `.file-pop` is not a `.dd-pop` and no boundary ever fired for it.
    var fp = document.getElementById('file-pop');
    if (fp && !fp.classList.contains('hidden')) {
      var trigger = document.getElementById('cb-file');
      if (trigger) trigger.click();
      return;
    }
    if (!document.querySelector('.dd-pop:not(.hidden)')) return;
    var b = document.getElementById('dd-dismiss');
    if (b) b.click();
  }

  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    // The responsive drawer owns Escape while it is open (topmost chrome
    // surface short of the modal): close it and hand focus back to the
    // toggle, so the keyboard path can leave the drawer without a mouse.
    if (isNarrow() && drawerOpen()) { closeDrawer(true); return; }
    dismissDropdowns();
    closeCatMenus();
    closeSlashMenu();
    // The workspace panel joins the Escape-close family: route through the
    // same `#w-close` (falling back to the collapse-tab `#w-dock`) click the
    // ✕ uses, so the exit transition and the server-side close both run.
    var wsPanel = document.getElementById('ws-panel');
    if (wsPanel && !wsPanel.classList.contains('hidden') && !wsPanel.classList.contains('ws-closing') && !wsAnimBusy) {
      var wsClose = document.getElementById('w-close') || document.getElementById('w-dock');
      if (wsClose) wsClose.click();
    }
    var outline = document.getElementById('outline-panel');
    if (outline && !outline.hidden) {
      var close = document.getElementById('outline-close');
      if (close) close.click();
    }
  });

  document.addEventListener('click', function (e) {
    if (!e.target || !e.target.closest) return;
    // Clicks inside the file popover itself (path input, recent buttons) must
    // not dismiss it — only an outside click or Escape does.
    if (e.target.closest('.composer-bar') || e.target.closest('.dd-pop') || e.target.closest('.file-pop')) return;
    dismissDropdowns();
  }, true);

  // ---- Responsive drawer sidebar (UX-19/T12).
  // Below 1024px the left panel is an overlay drawer. State is client-side
  // (`drawer-open` on #app, never on #panel — the panel is a server fragment
  // whose node the engine REPLACES on every patch, so a class on it would be
  // wiped mid-use). The engine still routes clicks inside the panel's wired
  // regions to the server; this overlay only flips the class and moves focus,
  // which needs no round-trip and never fights the patch cycle. Document
  // capture listeners fire before the engine's boundary handlers, so the
  // toggle (topbar is unwired), the scrim and the session-row close all work.
  function drawerApp() { return document.getElementById('app'); }
  function drawerOpen() {
    var a = drawerApp();
    return !!a && a.classList.contains('drawer-open');
  }
  function drawerToggle() { return document.getElementById('drawer-toggle'); }
  function isNarrow() {
    return window.matchMedia ? window.matchMedia('(max-width: 1023.98px)').matches : false;
  }
  function openDrawer() {
    var a = drawerApp();
    if (!a) return;
    a.classList.add('drawer-open');
    var t = drawerToggle();
    if (t) t.setAttribute('aria-expanded', 'true');
    // Focus moves INTO the drawer (first interactive control) so a keyboard
    // user lands in the panel they just opened, not back on the page body.
    // The panel's search field is the natural landing spot when it has one;
    // the settings sub-nav is anchor links, so `a[href]` rides the selector.
    var p = document.getElementById('panel');
    var first = p ? (p.querySelector('input') || p.querySelector('a[href], button, select, textarea, [tabindex]')) : null;
    if (first && first.focus) first.focus({ preventScroll: true });
    else if (p) {
      // A panel with nothing focusable (edge case): make the container itself
      // programmatically focusable so focus still lands inside the drawer.
      p.setAttribute('tabindex', '-1');
      p.focus({ preventScroll: true });
    }
  }
  function closeDrawer(returnFocus) {
    var a = drawerApp();
    if (!a) return;
    a.classList.remove('drawer-open');
    var t = drawerToggle();
    if (t) t.setAttribute('aria-expanded', 'false');
    if (returnFocus && t && t.focus) t.focus({ preventScroll: true });
  }
  document.addEventListener('click', function (e) {
    var t = e.target;
    if (!t || !t.closest) return;
    if (t.closest('#drawer-toggle')) {
      if (drawerOpen()) closeDrawer(true);
      else openDrawer();
      return;
    }
    if (!drawerOpen()) return;
    // Outside click: the scrim covers everything below the topbar but the
    // panel itself, so a click landing on it means "dismiss".
    if (t.closest('#drawer-scrim')) { closeDrawer(true); return; }
    // Picking a conversation (or minting a new one) closes the drawer so the
    // chat has the full canvas for the turn it just opened.
    if (t.closest('.sess-row') || t.closest('#chat-new')) { closeDrawer(true); return; }
    // A rail switch is a view change too: close the drawer so the chosen view
    // owns the canvas (the rail itself now stays visible beside the drawer —
    // see the UX-61 offset in the sheet — and these two together are what make
    // "tap another icon to leave Settings" work on a narrow window).
    if (t.closest('#iconbar')) { closeDrawer(false); return; }
  }, true);
  // Growing past the breakpoint with the drawer open must reset it: the CSS
  // ignores the class at >= 1024px, but aria-expanded would go stale (and a
  // shrink back would pop the panel open).
  (function () {
    if (!window.matchMedia || !window.matchMedia.addEventListener) return;
    var mq = window.matchMedia('(max-width: 1023.98px)');
    mq.addEventListener('change', function (e) {
      if (e.matches) return;
      var a = drawerApp();
      if (a && a.classList.contains('drawer-open')) {
        a.classList.remove('drawer-open');
        var t = drawerToggle();
        if (t) t.setAttribute('aria-expanded', 'false');
      }
    });
  })();

  // ---- T26 (UX-33): keep focus on the control you just activated. A settings
  // chip / segment / toggle is a server round-trip: the engine's fragment
  // patch REPLACES the control's node, and the browser drops focus to <body>,
  // so a keyboard user loses their place after every single change. This
  // overlay records the control that held focus when it blurred; if a later
  // patch removed that specific node (focus lost to <body> as a side effect of
  // replacement, not of intentional navigation) it re-focuses the equivalent
  // node — same id for settings controls, same data-sid for roving session
  // rows. Re-querying by id after the patch is mandatory: the cached element
  // reference is frozen/stale, the node was replaced.
  function rowSidOf(el) {
    if (!el || !el.closest) return null;
    var row = el.closest('.sess-row');
    return row && row.getAttribute ? row.getAttribute('data-sid') : null;
  }
  var lastFocusedControl = null;
  document.addEventListener('focusout', function (e) {
    var t = e.target;
    if (!t || t === document.body || t === document.documentElement) return;
    var id = (t.id || '').trim();
    var sid = rowSidOf(t);
    if (!id && !sid) return;
    lastFocusedControl = { el: t, id: id, sid: sid };
  }, true);

  function restoreFocusAfterPatch() {
    var rec = lastFocusedControl;
    if (!rec || !rec.el) return;
    // Only when focus actually fell back to <body> (target removed), and the
    // recorded node is genuinely gone — never yank focus from somewhere the
    // user moved it to on purpose.
    if (document.activeElement !== document.body) return;
    if (rec.el.isConnected) return;
    var nu = null;
    if (rec.id) nu = document.getElementById(rec.id);
    else if (rec.sid) {
      var rows = document.querySelectorAll('.sess-row[data-sid]');
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].getAttribute('data-sid') === rec.sid) { nu = rows[i]; break; }
      }
    }
    if (!nu) return;
    // Never leap focus onto something that just became inert.
    if (nu.disabled || nu.getAttribute('aria-hidden') === 'true') return;
    if (getComputedStyle ? getComputedStyle(nu).display === 'none' : false) return;
    if (rec.sid) nu.setAttribute('tabindex', '0');
    nu.focus({ preventScroll: true });
  }

  function enhanceAll() {
    resizeComposerIfNew();
    enhanceMarkdownTables(document);
    stickToChat();
    syncPanelScroll();
    syncComposerDraft();
    syncModalFocus();
    syncOutline();
    bootSettingsSpy();
    copyFromServerMarker();
  }

  function enhancePatched(changed) {
    resizeComposerIfNew();
    if (changed && changed.length) {
      for (var i = 0; i < changed.length; i++) {
        enhanceMarkdownTables(changed[i]);
      }
    } else {
      // A runtime that hands no subtree: fall back to a document pass.
      enhanceMarkdownTables(document);
    }
    stickToChat();
    syncPanelScroll();
    syncComposerDraft();
    syncModalFocus();
    syncOutline();
    bootSettingsSpy();
    copyFromServerMarker();
    // T26: a fragment patch may have just replaced the control the user
    // activated — return focus to its equivalent so the keyboard trail does
    // not reset to <body>.
    restoreFocusAfterPatch();
    // UX-08: focus return for the confirmation dialog rides syncModalFocus's
    // open→closed transition (above), which fires exactly when the removal
    // patch lands in the DOM — one restore path, no double-fire.
    // UX-45: `+` (new chat) leaves focus on the button; the app asked for the
    // composer and the new chat's fragment just landed — put the caret in it.
    if (focusComposerWanted) {
      var ci = document.getElementById('composer-input');
      if (ci) {
        focusComposerWanted = false;
        ci.focus();
        ci.setSelectionRange(ci.value.length, ci.value.length);
        resizeComposerIfNew();
      }
    }
  }

  // ---- Settings sub-nav: mark the section in view.
  // The Settings page is one long scroll container, so the anchor rows gave no
  // sense of place. An IntersectionObserver keeps the matching row highlighted;
  // sections with no nav row of their own (assistance, agent limits, agent
  // powers) leave the previous mark in place, which is where they belong.
  var settingsSpy = null;

  function bootSettingsSpy() {
    if (!window.IntersectionObserver) return;
    var wrap = document.querySelector('.settings-wrap');
    var panel = document.querySelector('#panel');
    if (!wrap || !panel) { settingsSpy = null; return; }
    if (settingsSpy && settingsSpy.wrap === wrap && wrap.isConnected) return;
    var rows = {};
    var anchors = panel.querySelectorAll('a[href^="#"]');
    for (var i = 0; i < anchors.length; i++) {
      var id = (anchors[i].getAttribute('href') || '').slice(1);
      var row = anchors[i].closest ? anchors[i].closest('.list-row') : null;
      if (id && row) rows[id] = row;
    }
    var sections = wrap.querySelectorAll('section[id]');
    if (!Object.keys(rows).length || !sections.length) return;
    var apply = function (id) {
      for (var k in rows) rows[k].classList.toggle('active', k === id);
    };
    var obs = new IntersectionObserver(function (entries) {
      var best = null;
      for (var n = 0; n < entries.length; n++) {
        var e = entries[n];
        if (!e.isIntersecting || !rows[e.target.id]) continue;
        if (!best || e.boundingClientRect.top < best.boundingClientRect.top) best = e;
      }
      if (best) apply(best.target.id);
    }, { root: wrap, rootMargin: '0px 0px -60% 0px', threshold: 0 });
    for (var j = 0; j < sections.length; j++) obs.observe(sections[j]);
    apply('appearance');
    settingsSpy = { wrap: wrap, observer: obs };
  }

  // UX-45: `+` (new chat) leaves focus on the button; remember the intent and
  // land the caret in the composer once the new chat's fragment arrives.
  document.addEventListener('click', function (e) {
    if (e.target && e.target.closest && e.target.closest('#chat-new')) {
      focusComposerWanted = true;
      setTimeout(function () { focusComposerWanted = false; }, 2500);
    }
  }, true);

  function bootOverlay() {
    if (window.WebUIEngine && WebUIEngine.on) {
      WebUIEngine.on.afterPatch(enhancePatched);
      WebUIEngine.on.ready(enhanceAll);
    }
    // Number inputs declare their range with min/max; a typed value outside
    // it used to sit in the field until a reload (the server clamped its copy
    // silently, the engine's input preservation kept the user's value on top).
    // Clamp in the capture phase, before the engine reads the value for its
    // change dispatch — the field corrects itself on Enter/blur, every time.
    document.addEventListener('change', function (e) {
      var el = e.target;
      if (!el || el.tagName !== 'INPUT' || el.type !== 'number') return;
      var min = el.getAttribute('min');
      var max = el.getAttribute('max');
      if (min === null && max === null) return;
      var v = parseFloat(el.value);
      if (!isFinite(v)) return;
      var lo = min === null ? -Infinity : parseFloat(min);
      var hi = max === null ? Infinity : parseFloat(max);
      if (v < lo) el.value = String(lo);
      else if (v > hi) el.value = String(hi);
    }, true);
    // The engine boots synchronously with its own script, which precedes this
    // handler, so `ready` may never fire — the initial pass runs here, and
    // covers anything that arrived before registration.
    enhanceAll();
    // A resize changes what fits under the fold; keep the jump button honest
    // about whether there is anywhere to jump (UX-42).
    window.addEventListener('resize', function () {
      var s = chatScroller();
      if (s) updateJumpBtn(s);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bootOverlay);
  } else {
    bootOverlay();
  }

  // ---- Jump-to-latest circle button (arc parity): appears the moment the
  // stick releases — not at some distance threshold, so a one-line scroll-up
  // surfaces it too; click returns to the end.
  function updateJumpBtn(s) {
    var b = document.getElementById('scroll-to-bottom');
    if (!b) return;
    b.hidden = stick || atBottom(s);
  }
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('#scroll-to-bottom') : null;
    if (!b) return;
    var s = chatScroller();
    if (!s) return;
    stick = true;
    s.scrollTo({ top: s.scrollHeight, behavior: 'smooth' });
    updateJumpBtn(s);
  });

  // ---- Reading keys: the transcript scrolls on Up/PageUp/Home and returns on
  // End/PageDown, with the stick following the intent. Never while a text
  // field has focus — the composer owns those keys.
  document.addEventListener('keydown', function (e) {
    if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
    var t = e.target;
    if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName || ''))) return;
    // A session row owns its arrows (UX-07 roving); never steal them to
    // scroll the transcript.
    if (t && t.closest && t.closest('.sess-row[tabindex]')) return;
    var s = chatScroller();
    if (!s) return;
    var k = e.key;
    var page = Math.round(s.clientHeight * 0.9);
    if (k === 'ArrowUp' || k === 'PageUp' || k === 'Home') {
      stick = false;
      s.scrollTop = k === 'Home' ? 0 : Math.max(0, s.scrollTop - (k === 'PageUp' ? page : KEY_STEP));
      updateJumpBtn(s);
      e.preventDefault();
    } else if (k === 'ArrowDown' || k === 'PageDown' || k === 'End') {
      s.scrollTop = k === 'End' ? s.scrollHeight
        : Math.min(s.scrollHeight, s.scrollTop + (k === 'PageDown' ? page : KEY_STEP));
      if (atBottom(s)) stick = true; // the scroll listener settles this too
      updateJumpBtn(s);
      e.preventDefault();
    }
  });

  // ---- Conversation outline (reference #2124): the toggle opens the panel;
  // entries are the open chat's user messages, built on demand from the
  // rendered anchors. Entries are plain client-side links: a click jumps to
  // the message anchor and keeps the panel open (no server round-trip, no
  // panel close). Jumping releases the stick — the reader is choosing a
  // position and must not be yanked back to the live text. Delegated, so it
  // survives every re-render.
  function buildOutline() {
    var entries = document.getElementById('outline-entries');
    if (!entries) return;
    entries.textContent = '';
    var msgs = document.querySelectorAll('.chat-inner .msg.user[id^="msg-user-"]');
    for (var i = 0; i < msgs.length; i++) {
      (function (m, idx) {
        var b = document.createElement('a');
        b.href = '#' + m.id;
        b.className = 'outline-entry';
        var num = document.createElement('span');
        num.className = 'outline-entry-num';
        num.textContent = '#' + (idx + 1);
        var txt = document.createElement('span');
        txt.className = 'outline-entry-text';
        var raw = (m.innerText || '').replace(/\s+/g, ' ').trim();
        txt.textContent = raw.slice(0, 90) + (raw.length > 90 ? '\u2026' : '');
        b.title = raw.slice(0, 240);
        b.appendChild(num);
        b.appendChild(txt);
        b.addEventListener('click', function (e) {
          e.preventDefault();
          stick = false;
          m.scrollIntoView({ block: 'start', behavior: 'smooth' });
          m.classList.remove('outline-jump-flash');
          void m.offsetWidth;
          m.classList.add('outline-jump-flash');
          setTimeout(function () { m.classList.remove('outline-jump-flash'); }, 1400);
          var s = chatScroller();
          if (s) updateJumpBtn(s);
          // Panel stays open: entries are client-side only now. The close
          // button is the only server-owned control in the panel.
        });
        entries.appendChild(b);
      })(msgs[i], i);
    }
    if (!msgs.length) {
      var empty = document.createElement('div');
      empty.className = 'outline-empty';
      empty.textContent = 'No user messages yet.';
      entries.appendChild(empty);
    }
  }

  // ---- The panel's shell (and its open/closed state) comes from the server;
  // the overlay only fills the entries once the shell is visible. Called from
  // the post-patch seam so a streamed turn keeps the list current.
  function syncOutline() {
    var panel = document.getElementById('outline-panel');
    if (!panel || panel.hidden) return;
    buildOutline();
  }

  // ---- Context window chip (UX-23): a <button> that responds to activation,
  // not just hover. Click toggles the tooltip (focus-within already opens it
  // for keyboard users via the CSS); touch gets a path too.
  document.addEventListener('click', function (e) {
    var chip = e.target && e.target.closest ? e.target.closest('.ctx-indicator') : null;
    if (!chip) return;
    var wrap = chip.closest('.ctx-indicator-wrap');
    if (!wrap) return;
    var open = wrap.classList.toggle('ctx-open');
    chip.setAttribute('aria-expanded', open ? 'true' : 'false');
  });

  // ---- Session group headers (Today / Last Week / Older): collapse
  // and expand entirely client-side.
  document.addEventListener('click', function (e) {
    var h = e.target && e.target.closest ? e.target.closest('.sess-group-head') : null;
    if (!h) return;
    var g = h.closest('.sess-group');
    if (g) g.classList.toggle('collapsed');
  });

  // ---- Session-row roving (UX-07). The row div is the single tab stop in
  // the conversation list: ArrowUp/Down roves focus between visible rows
  // (tabindex moves with focus), Enter/Space opens the session, and the Menu
  // key (or Shift+F10) opens the row's ⋮ menu. The inner open button and the
  // ⋮ dots are tabindex="-1" quiet utilities — out of the tab order but
  // still keyboard-reachable through the row. Collapsed groups are skipped
  // (their rows are display:none, which offsetParent detects).
  function visibleSessionRows() {
    return Array.prototype.filter.call(
      document.querySelectorAll('.sess-group-rows .sess-row[tabindex]'),
      function (r) { return r.offsetParent !== null; }
    );
  }

  function roveRowFocus(from, to) {
    if (!from || !to || from === to) return;
    from.setAttribute('tabindex', '-1');
    to.setAttribute('tabindex', '0');
    to.focus();
  }

  document.addEventListener('keydown', function (e) {
    // Only the row DIV itself drives roving — descendants (rename input,
    // menu buttons) keep their own keys.
    if (e.target && e.target.tagName !== 'DIV') return;
    var row = e.target && e.target.closest ? e.target.closest('.sess-row[tabindex]') : null;
    if (!row) return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      var rows = visibleSessionRows();
      var idx = rows.indexOf(row);
      if (idx === -1) return;
      var next = e.key === 'ArrowDown' ? (idx + 1) % rows.length : (idx - 1 + rows.length) % rows.length;
      if (rows.length > 1) roveRowFocus(row, rows[next]);
      e.preventDefault();
      return;
    }
    if (e.key === 'Enter' || e.key === ' ') {
      var open = row.querySelector('.sess-open');
      if (open) open.click();
      e.preventDefault();
      return;
    }
    if (e.key === 'Menu' || (e.shiftKey && e.key === 'F10')) {
      var dots = row.querySelector('.menu-dots');
      if (dots) {
        dots.click();
        // Move focus INTO the opened menu so the items are immediately
        // reachable (Tab/Enter), not stranded behind it.
        var menu = row.querySelector('.chat-menu');
        if (menu && menu.classList.contains('open')) {
          var items = menu.querySelectorAll('button');
          if (items[0]) items[0].focus();
        }
      }
      e.preventDefault();
    }
  });
  // ---- Icon rail roving (UX-07). The ACTIVE nav button is the single tab
  // stop in the rail; ArrowUp/ArrowDown (and for safety ArrowLeft/ArrowRight)
  // rove focus across the visible rail buttons, moving tabindex with focus so
  // the active item stays the one tab stop.
  function visibleRailButtons() {
    return Array.prototype.filter.call(
      document.querySelectorAll('#iconbar button.icon-btn[tabindex]'),
      function (b) { return b.offsetParent !== null; }
    );
  }
  document.addEventListener('keydown', function (e) {
    var t = e.target;
    if (!t || !t.closest || !t.closest('#iconbar button.icon-btn[tabindex]')) return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp' || e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      var btns = visibleRailButtons();
      var idx = btns.indexOf(t);
      if (idx === -1) return;
      var dir = (e.key === 'ArrowDown' || e.key === 'ArrowRight') ? 1 : -1;
      var next = btns[(idx + dir + btns.length) % btns.length];
      if (btns.length > 1 && next && next !== t) {
        t.setAttribute('tabindex', '-1');
        next.setAttribute('tabindex', '0');
        next.focus();
      }
      e.preventDefault();
    }
  });
  // ---- Skill category groups: click header to collapse/expand.
  document.addEventListener('click', function (e) {
    var h = e.target && e.target.closest ? e.target.closest('.skill-cat-head') : null;
    if (!h) return;
    var g = h.closest('.skill-group');
    if (g) g.classList.toggle('collapsed');
  });

  // ---- Sidebar-tab chips (Settings > Appearance): HTML5 drag to
  // reorder. The visible order is recomputed from the checked chips
  // (only visible tabs matter) and pushed through the hidden order
  // input so the server persists it.
  document.addEventListener('dragstart', function (e) {
    var chip = e.target && e.target.closest ? e.target.closest('.side-tab-chip') : null;
    if (!chip) return;
    e.dataTransfer.setData('text/plain', 'side-tab');
    e.dataTransfer.effectAllowed = 'move';
    chip.classList.add('drag-src');
  });
  document.addEventListener('dragover', function (e) {
    var chip = e.target && e.target.closest ? e.target.closest('.side-tab-chip') : null;
    if (!chip) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
  });
  document.addEventListener('drop', function (e) {
    var chip = e.target && e.target.closest ? e.target.closest('.side-tab-chip') : null;
    if (!chip) return;
    e.preventDefault();
    var src = document.querySelector('.side-tab-chip.drag-src');
    if (!src || src === chip) { if (src) src.classList.remove('drag-src'); return; }
    var moved = false;
    try {
      var after = (chip.compareDocumentPosition(src) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
      if (after) { chip.after(src); moved = true; }
      else { chip.before(src); moved = true; }
    } catch (err) { }
    src.classList.remove('drag-src');
    if (!moved) return;
    var container = chip.closest('.side-tab-chips') || chip.parentElement;
    // The full chip order is the canonical order (hidden chips keep
    // their slots), so every chip contributes a key.
    var order = [];
    container.querySelectorAll('.side-tab-chip').forEach(function (chip) {
      var id = chip.id || '';
      if (id.indexOf('st-') === 0) {
        try { order.push(atob(id.slice(3))); } catch (err) { }
      }
    });
    var hidden = document.getElementById('sidebar-tab-order');
    if (hidden) {
      hidden.value = order.join(',');
      hidden.dispatchEvent(new Event('change', { bubbles: true }));
    }
  });
  document.addEventListener('dragend', function (e) {
    var src = document.querySelector('.side-tab-chip.drag-src');
    if (src) src.classList.remove('drag-src');
  });

  // ---- Run queue (Todos → Run queue): HTML5 drag to reorder. The rows are
  // draggable; dropping moves the DOM node and pushes the new order through
  // the hidden #queue-order input (the queue wire reorders + persists it).
  document.addEventListener('dragstart', function (e) {
    var row = e.target && e.target.closest ? e.target.closest('.queue-row') : null;
    if (!row) return;
    e.dataTransfer.setData('text/plain', 'queue-row');
    e.dataTransfer.effectAllowed = 'move';
    row.classList.add('dragging');
  });
  document.addEventListener('dragover', function (e) {
    var list = e.target && e.target.closest ? e.target.closest('.queue-list') : null;
    if (!list) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    var row = e.target.closest ? e.target.closest('.queue-row') : null;
    clearQueueDragMarkers(list);
    if (!row) return;
    var src = list.querySelector('.queue-row.dragging');
    if (!src || src === row) return;
    var after = (row.compareDocumentPosition(src) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
    row.classList.add(after ? 'drop-before' : 'drop-after');
  });
  document.addEventListener('drop', function (e) {
    var list = e.target && e.target.closest ? e.target.closest('.queue-list') : null;
    if (!list) return;
    var target = e.target.closest ? e.target.closest('.queue-row') : null;
    e.preventDefault();
    var src = list.querySelector('.queue-row.dragging');
    var before = !!(target && target.classList.contains('drop-before'));
    if (src && src !== target) {
      try {
        if (!target) { list.appendChild(src); }
        else if (before) { target.before(src); }
        else { target.after(src); }
      } catch (err) { }
    }
    var markers = list.querySelectorAll('.queue-row.dragging, .queue-row.drop-before, .queue-row.drop-after');
    for (var i = 0; i < markers.length; i++) markers[i].classList.remove('dragging', 'drop-before', 'drop-after');
    var order = [];
    list.querySelectorAll('.queue-row').forEach(function (row) {
      if (row.getAttribute('data-qid')) order.push(row.getAttribute('data-qid'));
    });
    var hidden = document.getElementById('queue-order');
    if (hidden && order.length) {
      hidden.value = order.join(',');
      hidden.dispatchEvent(new Event('change', { bubbles: true }));
    }
  });
  function clearQueueDragMarkers(list) {
    var m = list.querySelectorAll('.queue-row.drop-before, .queue-row.drop-after');
    for (var i = 0; i < m.length; i++) m[i].classList.remove('drop-before', 'drop-after');
  }
  document.addEventListener('dragend', function (e) {
    var row = e.target && e.target.closest ? e.target.closest('.queue-row') : null;
    if (row) {
      row.classList.remove('dragging', 'drop-before', 'drop-after');
      var list = row.closest('.queue-list');
      if (list) clearQueueDragMarkers(list);
    }
  });

  // ---- Relative session times: refresh every 60s (arc parity).
  function relLabel(ms) {
    if (!ms) return '';
    var d = new Date(ms), now = new Date();
    var diff = Math.max(0, now - d);
    if (diff < 60000) return '1m';
    if (diff < 3600000) return Math.floor(diff / 60000) + 'm';
    if (diff < 86400000) return Math.floor(diff / 3600000) + 'h';
    var s0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    var s1 = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    var days = Math.round((s0 - s1) / 86400000);
    if (days < 7) return Math.max(days, 1) + 'd';
    var M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    var base = M[d.getMonth()] + ' ' + d.getDate();
    if (d.getFullYear() !== now.getFullYear()) base += ', ' + String(d.getFullYear()).slice(-2);
    return base;
  }
  setInterval(function () {
    var els = document.querySelectorAll('[data-reltime]');
    for (var i = 0; i < els.length; i++) {
      var ts = parseInt(els[i].getAttribute('data-reltime'), 10);
      if (!isNaN(ts)) els[i].textContent = relLabel(ts);
    }
  }, 60000);

  // ---- Streaming turn elapsed clock (arc parity): the live node re-renders on
  // every push, so the server stamps data-started (epoch ms) and this single
  // interval repaints the label from it — no per-push render, no layout work.
  function paintElapsed() {
    var els = document.querySelectorAll('[data-elapsed]');
    for (var i = 0; i < els.length; i++) {
      var start = parseInt(els[i].getAttribute('data-started'), 10);
      if (isNaN(start)) continue;
      var s = Math.max(0, Math.floor((Date.now() - start) / 1000));
      var text = Math.floor(s / 60) + ':' + (s % 60 < 10 ? '0' : '') + (s % 60);
      if (els[i].textContent !== text) els[i].textContent = text;
    }
  }
  setInterval(paintElapsed, 1000);

  // ---- Chat row "..." menu: open/close is client-side so the open
  // menu survives the click that opened it; edge actions still go to
  // the server through the normal runtime pipeline.
  function closeCatMenus() {
    var open = document.querySelectorAll('.chat-menu.open');
    for (var i = 0; i < open.length; i++) {
      var it = open[i].querySelector('.chat-menu-items');
      var pn = open[i].querySelector('.chat-menu-panel');
      if (it) it.hidden = false;
      if (pn) pn.hidden = true;
      open[i].classList.remove('open');
    }
  }
  // "Move to Category": swap the open menu's items for the category
  // panel (all client-side; picking a category still rides the wire).
  function setCatPanel(menu, show) {
    if (!menu) return;
    var it = menu.querySelector('.chat-menu-items');
    var pn = menu.querySelector('.chat-menu-panel');
    if (it) it.hidden = show;
    if (pn) pn.hidden = !show;
  }
  document.addEventListener('click', function (e) {
    var catBtn = e.target && e.target.closest ? e.target.closest('[id^="sm-catmenu-"]') : null;
    if (catBtn) { setCatPanel(catBtn.closest('.chat-menu'), true); return; }
    var backBtn = e.target && e.target.closest ? e.target.closest('[id^="sm-catback-"]') : null;
    if (backBtn) {
      setCatPanel(backBtn.closest('.chat-menu'), false);
      return;
    }
    var open = document.querySelectorAll('.chat-menu.open');
    var dot = e.target && e.target.closest ? e.target.closest('.menu-dots') : null;
    if (dot) {
      var wrap = dot.closest('.menu-wrap');
      var menu = wrap && wrap.querySelector('.chat-menu');
      var wasOpen = menu && menu.classList.contains('open');
      closeCatMenus();
      if (menu && !wasOpen) menu.classList.add('open');
      return;
    }
    closeCatMenus();
  });

  // ---- Copy conversation link (server-driven clipboard, UX-06).
  // The MENU's copy rides the server: the engine's wired `chat-menu` region
  // handles clicks server-side, and the server is the single owner of the
  // "copied" toast. The resolved URL comes back inside the #toasts fragment as
  // a hidden `#pending-copy[data-copy-url]` marker; this post-patch pass
  // consumes the marker, writes the URL to the clipboard, and drops it — a
  // one-shot handoff that cannot race a streamed re-render.
  // (T23 audit, Wave 2: capture/bubble/target probes inside every wired region
  // fired on this engine pair — the engine routes events server-side but does
  // NOT stop client propagation. Nothing client-side is dead; the seam exists
  // because the server owns the side effect, not because listeners are lost.)
  function copyFromServerMarker() {
    var m = document.getElementById('pending-copy');
    if (!m) return;
    var url = m.getAttribute('data-copy-url');
    m.remove();
    if (!url) return;
    var target = new URL(url, location.href).href;
    function writeFailed() {
      flashToast('Could not copy the link.', 'error');
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(target).then(function () {
        // The overlay owns the toast: exactly one, from the clipboard result.
        flashToast('Conversation link copied.');
      }).catch(writeFailed);
    } else {
      var ta = document.createElement('textarea');
      ta.value = target;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try {
        if (!document.execCommand('copy')) writeFailed();
        else flashToast('Conversation link copied.');
      } catch (err) { writeFailed(); }
      document.body.removeChild(ta);
    }
  }

  // ---- Rename conversation: inline edit of the row title, committed
  // through a hidden form that rides the normal runtime pipeline.
  // The row title lives inside a <button>, and an <input> must never
  // be nested inside one: browsers treat Space as the button's
  // activation key, steal focus from the nested input, blur it, and
  // commit the partially-typed name. While editing we therefore swap
  // the whole button for the input, then swap it back on commit or
  // cancel.
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('[id^="sm-rename-"]') : null;
    if (!b) return;
    var row = b.closest('.sess-row');
    var openBtn = row && row.querySelector('.sess-open');
    var sid = b.getAttribute('data-sid');
    if (!row || !openBtn || !sid) return;
    // Seed from the full stored title (data-full-title on the row, UX-06) —
    // never from the truncated 40-char row text, which would commit permanent
    // truncation when the rename is committed (UX-21). Fall back to the
    // rendered title for rows that predate the attribute.
    var current = (row.getAttribute('data-full-title') || '').trim()
        || ((openBtn.querySelector('.sess-title') || {}).textContent || '').trim();
    var input = document.createElement('input');
    input.type = 'text';
    input.className = 'rename-input';
    input.value = current;
    input.setAttribute('aria-label', 'Rename conversation');
    row.replaceChild(input, openBtn);
    input.focus();
    if (input.select) input.select();
    var settled = false;
    function finish(commitIt) {
      if (settled) return;
      settled = true;
      var val = input.value.trim();
      var newBtn = openBtn.cloneNode(true);
      var t = newBtn.querySelector('.sess-title');
      if (t && (commitIt || val === '')) t.textContent = val === '' ? current : val;
      row.replaceChild(newBtn, input);
      if (commitIt && val !== '' && val !== current) submitRename(sid, val);
    }
    input.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter') { ev.preventDefault(); finish(true); }
      else if (ev.key === 'Escape') { ev.preventDefault(); finish(false); }
    });
    input.addEventListener('blur', function () { finish(true); });
    input.addEventListener('click', function (ev) { ev.stopPropagation(); });
  });

  function submitRename(sid, name) {
    var f = document.getElementById('rename-form');
    if (!f) {
      f = document.createElement('form');
      f.id = 'rename-form';
      f.style.display = 'none';
      f.setAttribute('data-component-id', 'chat-menu');
      f.innerHTML = '<input type="hidden" name="rename-id"><input type="hidden" name="rename-name">';
      document.body.appendChild(f);
    }
    f.querySelector('[name="rename-id"]').value = sid;
    f.querySelector('[name="rename-name"]').value = name;
    try { f.requestSubmit(); } catch (err) { f.submit(); }
  }

  // ---- Color swatches: client-side selection that mirrors into the
  // hidden color field of the enclosing form before submit.
  document.addEventListener('click', function (e) {
    var sw = e.target && e.target.closest ? e.target.closest('.cat-swatch') : null;
    if (!sw) return;
    var form = sw.closest('form');
    var pick = form ? form.querySelector('.color-value') : null;
    var swatches = form ? form.querySelectorAll('.cat-swatch') : [];
    for (var i = 0; i < swatches.length; i++) swatches[i].classList.remove('sel');
    sw.classList.add('sel');
    if (pick) pick.value = sw.getAttribute('data-color') || pick.value;
  });

  // Small transient toast for client-side notices (server toasts still
  // own the #toasts stream, so this only fills the gap briefly). Errors and
  // explicit-feedback notices (UX-06: "Conversation link copied.") appear;
  // `quiet` requests stay silent.
  function flashToast(text, kind) {
    if (kind === 'quiet') return;
    var host = document.getElementById('toasts');
    if (!host) return;
    kind = kind || 'info';
    var el = document.createElement('div');
    el.className = 'toast ' + kind;
    el.innerHTML = '<span class="toast-dot"></span><span></span>';
    el.lastChild.textContent = text;
    host.appendChild(el);
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 2600);
  }

  // ---- Workspace panel: slide-out before the ✕/arrow close lands.
  // The runtime performs the real close (replacing the panel with the
  // closed fragment); we intercept the first click, play the exit
  // transition, then re-click so the server state stays in sync.
  var wsAnimBusy = false;
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('#w-close, #w-dock') : null;
    if (!b) return;
    var p = document.getElementById('ws-panel');
    if (!p || p.classList.contains('hidden') || p.classList.contains('ws-closing') || wsAnimBusy) return;
    wsAnimBusy = true;
    e.preventDefault();
    e.stopImmediatePropagation();
    void p.offsetWidth; // force reflow so the transition actually runs
    p.classList.add('ws-closing');
    setTimeout(function () {
      wsAnimBusy = false;
      var btn = document.getElementById('w-close') || document.getElementById('w-dock');
      if (btn) btn.click();
    }, 300);
  }, true);

  // ── Workspace panel: uploads (button picker + drag & drop) ────────
  // NOTE: init.js runs in <head>, so document.body is null at parse
  // time. Anything that touches the live DOM tree (creating the hidden
  // file input, binding drag handlers on #ws-panel) must wait until the
  // document is ready — otherwise a TypeError kills every later handler.
  var wsFileInput = null;

  function wsUploadForm() {
    var f = document.getElementById('ws-upload-form');
    if (!f) {
      f = document.createElement('form');
      f.id = 'ws-upload-form';
      f.style.display = 'none';
      f.setAttribute('data-component-id', 'workspace-upload');
      f.innerHTML = '<input type="hidden" name="upl-name"><input type="hidden" name="upl-path"><input type="hidden" name="upl-b64">';
      document.body.appendChild(f);
    }
    return f;
  }

  function readFileAsB64(file, cb) {
    var reader = new FileReader();
    reader.onload = function (ev) {
      var b64 = String(ev.target.result || '').split(',')[1] || '';
      cb(b64);
    };
    reader.onerror = function () { flashToast('Failed to read ' + file.name, 'error'); cb(null); };
    reader.readAsDataURL(file);
  }

  function sendUpload(file, relPath) {
    var LIMIT = 10 * 1024 * 1024;
    if (file.size > LIMIT) {
      flashToast('"' + file.name + '" is larger than 10 MB', 'error');
      return;
    }
    readFileAsB64(file, function (b64) {
      if (b64 === null) return;
      var f = wsUploadForm();
      f.querySelector('[name="upl-name"]').value = file.name;
      f.querySelector('[name="upl-path"]').value = relPath;
      f.querySelector('[name="upl-b64"]').value = b64;
      try { f.requestSubmit(); } catch (err) { f.submit(); }
    });
  }

  function collectEntry(entry, base, done) {
    if (entry.isFile) {
      entry.file(function (file) {
        done(file, base ? base + '/' + entry.name : entry.name);
      }, function () { done(null, null); });
    } else if (entry.isDirectory) {
      var reader = entry.createReader();
      var all = [];
      (function readBatch() {
        reader.readEntries(function (entries) {
          if (!entries.length) {
            all.forEach(function (e) { collectEntry(e, base ? base + '/' + entry.name : entry.name, done); });
          } else {
            all = all.concat(entries);
            readBatch();
          }
        }, function () { });
      })();
    }
  }

  function handleFiles(fileList) {
    for (var i = 0; i < fileList.length; i++) sendUpload(fileList[i], fileList[i].name);
  }

  function bootWorkspaceDom() {
    wsFileInput = document.getElementById('ws-file-input');
    if (!wsFileInput) {
      wsFileInput = document.createElement('input');
      wsFileInput.type = 'file';
      wsFileInput.id = 'ws-file-input';
      wsFileInput.multiple = true;
      wsFileInput.style.display = 'none';
      document.body.appendChild(wsFileInput);
    }
    wsFileInput.addEventListener('change', function () {
      if (wsFileInput.files) handleFiles(wsFileInput.files);
      wsFileInput.value = '';
    });

    // Drag & drop is delegated at DOCUMENT level: fragment re-renders
    // replace the #ws-panel element, and a listener bound to an old
    // node would be silently lost. The current panel is looked up on
    // every event instead.
    function currentPanel() {
      var p = document.getElementById('ws-panel');
      return (p && !p.classList.contains('hidden')) ? p : null;
    }
    document.addEventListener('dragover', function (e) {
      var p = currentPanel();
      if (!p || !e.target.closest || !e.target.closest('#ws-panel')) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
      p.classList.add('drag');
    });
    document.addEventListener('dragleave', function (e) {
      var p = document.getElementById('ws-panel');
      if (!p) return;
      if (e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest('#ws-panel')) return;
      p.classList.remove('drag');
    });
    document.addEventListener('drop', function (e) {
      var p = currentPanel();
      if (!p || !e.target.closest || !e.target.closest('#ws-panel')) return;
      e.preventDefault();
      p.classList.remove('drag');
      var items = e.dataTransfer && e.dataTransfer.items;
      if (items && items.length) {
        for (var i = 0; i < items.length; i++) {
          var entry = items[i].webkitGetAsEntry ? items[i].webkitGetAsEntry() : null;
          if (entry) {
            collectEntry(entry, '', function (file, path) { if (file) sendUpload(file, path); });
          } else if (items[i].kind === 'file') {
            // Fallback: non-filesystem-backed item (synthetic or
            // some browsers) exposes the raw File directly.
            var f = items[i].getAsFile ? items[i].getAsFile() : null;
            if (f) sendUpload(f, f.name);
          }
        }
      } else if (e.dataTransfer && e.dataTransfer.files) {
        handleFiles(e.dataTransfer.files);
      }
    });
  }

  function bootOnReady(fn) {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', fn);
    } else {
      fn();
    }
  }
  bootOnReady(bootWorkspaceDom);

  document.addEventListener('click', function (e) {
    // Upload button → open the native file picker.
    if (e.target && e.target.closest && e.target.closest('[id="w-upload"]')) {
      e.preventDefault();
      if (wsFileInput) wsFileInput.click();
      return;
    }
    // Workspace "⋮" menu toggle + click-outside close.
    var wsMenu = document.getElementById('ws-menu');
    if (wsMenu) {
      var wm = e.target && e.target.closest ? e.target.closest('[id="w-menu"]') : null;
      if (wm) {
        e.preventDefault();
        var open = wsMenu.classList.contains('open');
        document.querySelectorAll('.chat-menu.open').forEach(function (m) { if (m !== wsMenu) m.classList.remove('open'); });
        wsMenu.classList.toggle('open', !open);
        return;
      }
      if (wsMenu.classList.contains('open') &&
          !(e.target && e.target.closest && e.target.closest('#ws-menu'))) {
        wsMenu.classList.remove('open');
      }
    }
  });

  // ── Kanban: inline column rename / card title edit ──────────────
  document.addEventListener('click', function (e) {
    var rn = e.target && e.target.closest ? e.target.closest('[id^="kb-rencol-"]') : null;
    if (rn) {
      e.preventDefault();
      startInlineEdit(rn, { col: rn.getAttribute('data-colid') || '' });
      return;
    }
    var ed = e.target && e.target.closest ? e.target.closest('[id^="kb-edit-"]') : null;
    if (ed) {
      e.preventDefault();
      startInlineEdit(ed, { card: ed.getAttribute('data-cardid') || '' });
      return;
    }
  });

  function startInlineEdit(btn, key) {
    var host = btn.closest('.kb-col-head') || btn.closest('.kb-card');
    if (!host) return;
    var target = host.querySelector('.kb-col-name, .kb-card-title');
    if (!target) return;
    var cls = target.className;
    var current = (target.textContent || '').trim();
    var rect = target.getBoundingClientRect();
    var input = document.createElement('input');
    input.type = 'text';
    input.value = current;
    input.className = 'inline-edit';
    input.style.width = Math.max(120, rect.width + 20) + 'px';
    target.replaceWith(input);
    input.focus();
    var settled = false;
    function restore() {
      var back = document.createElement('span');
      back.className = cls;
      back.textContent = current;
      input.replaceWith(back);
    }
    function commit() {
      if (settled) return;
      settled = true;
      var val = input.value.trim();
      if (val === '' || val === current) { restore(); return; }
      var f = document.getElementById('kanban-inline-form');
      if (!f) {
        f = document.createElement('form');
        f.id = 'kanban-inline-form';
        f.style.display = 'none';
        f.setAttribute('data-component-id', 'kanban');
        f.innerHTML = '<input type="hidden" name="kb-col-id"><input type="hidden" name="kb-col-name"><input type="hidden" name="kb-card-id"><input type="hidden" name="kb-card-title">';
        document.body.appendChild(f);
      }
      if (key.col) {
        f.querySelector('[name="kb-col-id"]').value = key.col;
        f.querySelector('[name="kb-col-name"]').value = val;
      } else {
        f.querySelector('[name="kb-card-id"]').value = key.card;
        f.querySelector('[name="kb-card-title"]').value = val;
      }
      try { f.requestSubmit(); } catch (err) { f.submit(); }
    }
    function cancel() {
      if (settled) return;
      settled = true;
      restore();
    }
    input.addEventListener('keydown', function (ev) {
      if (ev.key === 'Enter') { ev.preventDefault(); commit(); }
      else if (ev.key === 'Escape') { ev.preventDefault(); cancel(); }
    });
    input.addEventListener('blur', commit);
    input.addEventListener('click', function (ev) { ev.stopPropagation(); });
  }
  } catch (err) {
    if (typeof console !== 'undefined' && console.error) {
      console.error('arc-agent init failed:', err);
    }
  }
  // ---- Blank-canvas CTA: focus the composer (delegated).
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('[data-focus-composer]') : null;
    if (!b) return;
    e.preventDefault();
    var ta = document.getElementById('composer-input');
    if (ta) ta.focus();
  });

  // ---- Copy code blocks + message responses (delegated). Copy buttons inside
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('[data-copy]') : null;
    if (!b) return;
    // Copy buttons inside <summary> must not toggle the disclosure.
    e.preventDefault();
    var text = b.getAttribute('data-copy') || '';
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () {
        var orig = b.innerHTML;
        b.innerHTML = '✓';
        setTimeout(function () { b.innerHTML = orig; }, 1500);
      }, function () { });
    }
  });


  // ---- Turn worklog "copy activity" buttons (delegated): copy the
  // expanded text of that tool round's detail block.
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('.tw-copy') : null;
    if (!b) return;
    e.stopPropagation();
    // Copy must not toggle the enclosing disclosure.
    e.preventDefault();
    var tgt = b.getAttribute('data-copy-target');
    var host = tgt ? document.getElementById(tgt) : null;
    var body = host ? host.querySelector('.wl-detail') : null;
    var text = (body ? body.innerText : '').trim();
    if (!text || !navigator.clipboard || !navigator.clipboard.writeText) return;
    navigator.clipboard.writeText(text).then(function () {
      var orig = b.innerHTML;
      b.innerHTML = '✓';
      b.classList.add('copied');
      setTimeout(function () { b.innerHTML = orig; b.classList.remove('copied'); }, 1500);
    }, function () { });
  });

  // ---- In-page `#` anchors must not navigate (UX-60).
  //
  // The Settings sub-nav rows (`#appearance` … `#about`) and the skip link
  // (`#composer-input`) are same-page jumps. Left to the browser, a hash jump
  // pushes a history entry and fires `popstate`; the engine answers popstate
  // with a `navigate` frame to the server, and a navigate re-render RESETS the
  // render session — dropping every handler arc registered at boot. The rail,
  // the settings chips and the composer then all go silent ("stuck in
  // Settings") until the server is restarted. So: intercept the jump, move
  // focus / scroll in place, and leave the URL (and the history stack) alone.
  document.addEventListener('click', function (e) {
    var a = e.target && e.target.closest ? e.target.closest('a[href^="#"]') : null;
    if (!a) return;
    var href = a.getAttribute('href') || '';
    if (href.length < 2) return;
    var target = document.getElementById(href.slice(1));
    if (!target) return;
    e.preventDefault();
    // A form control takes focus (that is the skip link's whole job); anything
    // else is scrolled into view.
    if (/^(INPUT|TEXTAREA|SELECT|BUTTON)$/.test(target.tagName) && target.focus) {
      try { target.focus({ preventScroll: true }); } catch (_) { target.focus(); }
    }
    if (target.scrollIntoView) {
      try { target.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
      catch (_) { target.scrollIntoView(true); }
    }
    // A section picked from the narrow-width drawer should reveal the content
    // it jumps to, not leave the drawer covering it.
    if (isNarrow() && drawerOpen()) closeDrawer(false);
  }, true);
})();

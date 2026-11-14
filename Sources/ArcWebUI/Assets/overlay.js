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
  // The submit clear below erases the composer, but the engine restores form
  // values across a fragment patch — and a local slash command echoes a message,
  // so a patch lands right after the clear and hands the command back to the
  // field. The user then sees `/help` still sitting there and the next Enter
  // runs it again (measured: two transcript rows for one command). Remember what
  // was submitted and clear it again only if the patch restored exactly that
  // text; a real edit is never touched.
  var submittedComposerText = null;

  function clearRestoredComposer() {
    if (submittedComposerText === null) return;
    var t = document.getElementById('composer-input');
    if (!t || t.value === '') {
      submittedComposerText = null;
      return;
    }
    if (t.value.trim() === String(submittedComposerText).trim()) {
      t.value = '';
      submittedComposerText = null;
    }
  }

  window.addEventListener('submit', function (e) {
    if (e.target && e.target.id === 'composer-form') {
      var t = document.getElementById('composer-input');
      if (t) {
        // Remembered so a fragment patch that restores the field can be
        // recognised as the echo of this submit (see clearRestoredComposer).
        submittedComposerText = t.value;
        t.value = '';
      }
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

  document.addEventListener('input', function (e) {
    if (e.target && e.target.id === 'composer-input') {
      syncSlashMenu(e.target.value);
    }
  });

  // Draft/focus memory for the post-patch seam (UX-40/45): both live for the
  // page's lifetime so a session switch and a new chat can be aimed.
  var lastComposerSession = null;
  var focusComposerWanted = false;
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

  // ---- Confirmation dialog. Focus is the ENGINE's (no-webui 2.14.0):
  // `autofocus` on the dialog's Cancel control enters it, `data-focus-return`
  // on Cancel names the opener focus goes back to when the removal patch
  // lands, and the `.modal-overlay` Tab trap is the engine's. arc emits the
  // attributes (`Views.modalHTML`) and keeps no client code.
  // ---- The workspace panel and the outline are the two ESCAPE surfaces the
  // engine does not own (no-webui 2.15.0's dismiss stack closes only a
  // `[data-open]` layer, and both of these are server-rendered `hidden`
  // regions, not layers). This listener runs in the CAPTURE phase so it still
  // sees the state the engine is about to change: when a modal or any
  // `data-open` layer is open, the key belongs to the engine and one Escape
  // closes exactly one surface (LIFO) — the drawer, a composer popover or the
  // row menu — never this panel as well.
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    if (document.querySelector('.modal-overlay, [data-open]')) return;
    // The workspace panel routes through the same `#w-close` (falling back to
    // the collapse-tab `#w-dock`) click the ✕ uses, so the exit transition and
    // the server-side close both run.
    var wsPanel = document.getElementById('ws-panel');
    if (wsPanel && !wsPanel.classList.contains('hidden') && !wsPanel.classList.contains('ws-closing')) {
      var wsClose = document.getElementById('w-close') || document.getElementById('w-dock');
      if (wsClose) wsClose.click();
    }
    var outline = document.getElementById('outline-panel');
    if (outline && !outline.hidden) {
      var close = document.getElementById('outline-close');
      if (close) close.click();
    }
  }, true);

  // the theme switch has two sources of truth: the engine keeps the
  // device-local choice in localStorage, the panel is rendered from the
  // server's saved mode. aria-pressed is the engine's (press() re-runs on
  // every insert); this pass carries only the `.active` class the sheet
  // paints, and A15 (2.17.0) retires the mirror.
  function syncThemePickers() {
    var mode = document.documentElement.getAttribute('data-theme');
    var picks = document.querySelectorAll('[data-theme-choice]');
    for (var i = 0; i < picks.length; i++) {
      var on = picks[i].getAttribute('data-theme-choice') === mode;
      if (on) picks[i].classList.add('active');
      else picks[i].classList.remove('active');
    }
  }

  function enhanceAll() {
    syncComposerDraft();
    syncThemePickers();
    // UX-06: the server stages a resolved copy URL as a `#pending-copy` marker
    // inside the toasts fragment; this pass is its only consumer. The engine
    // owns `[data-copy]` only — it has no server-staged handoff, so this stays.
    copyFromServerMarker();
  }

  function enhancePatched(changed) {
    clearRestoredComposer();
    syncComposerDraft();
    syncThemePickers();
    copyFromServerMarker();
    // UX-45: `+` (new chat) leaves focus on the button; the app asked for the
    // composer and the new chat's fragment just landed — put the caret in it.
    if (focusComposerWanted) {
      var ci = document.getElementById('composer-input');
      if (ci) {
        focusComposerWanted = false;
        ci.focus();
        ci.setSelectionRange(ci.value.length, ci.value.length);
      }
    }
    // Round-3 UX-34/35: a form fragment that just landed can ask for the caret
    // with [data-focus-after-patch] (the add-card form, the first invalid skill
    // field). Only take focus when nothing else holds it — never yank the caret
    // out of a field the user has already moved to.
    var ae = document.activeElement;
    if (!ae || ae === document.body) {
      var want = document.querySelector('[data-focus-after-patch]');
      if (want && want.focus) {
        want.removeAttribute('data-focus-after-patch');
        try { want.focus(); } catch (_) {}
        if (want.setSelectionRange && typeof want.value === 'string') {
          want.setSelectionRange(want.value.length, want.value.length);
        }
      }
    }
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
    document.addEventListener('webui:theme', syncThemePickers);
    // The engine boots synchronously with its own script, which precedes this
    // handler, so `ready` may never fire — the initial pass runs here, and
    // covers anything that arrived before registration.
    enhanceAll();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bootOverlay);
  } else {
    bootOverlay();
  }

  // ---- Disclosures (context chip, session groups, skill categories) are
  // native `<details>` elements now: the platform owns open/closed, and the
  // engine keeps `open` across a patch by id (`data-preserve-open`). Nothing
  // here flips a class for them.

  // ---- Chat row "..." menu: the open state is the SERVER's (no-webui
  // 2.15.0's `data-open`, one-render latch): the ⋮ dispatches `s-menu-<sid>`,
  // "Move to Category" is a server panel swap, and the engine's dismiss stack
  // closes it on Escape or an outside click. Nothing here flips it.

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

  // ---- Workspace panel: start the exit visual, then let the click through.
  // The runtime performs the real close by replacing the panel with the closed
  // fragment. This used to withhold the click for 300ms and re-dispatch it so
  // the slide finished first — but that put the server's close ~580ms out, and
  // a click landing in that window toggled against a state the server had not
  // applied yet: the handle did nothing right after closing. Adding the class
  // and letting the click continue keeps the slide (a 280ms transition outlives
  // the patch in the common case) and settles the control in one round trip.
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('#w-close, #w-dock') : null;
    if (!b) return;
    var p = document.getElementById('ws-panel');
    if (!p || p.classList.contains('hidden') || p.classList.contains('ws-closing')) return;
    void p.offsetWidth; // force reflow so the transition actually runs
    p.classList.add('ws-closing');
  }, true);

  function bootOnReady(fn) {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', fn);
    } else {
      fn();
    }
  }

  document.addEventListener('click', function (e) {
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

  // ---- Small transient toast for client-side notices (server toasts still
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

  // ---- Copy conversation link (server-driven clipboard, UX-06).
  // The MENU's copy rides the server: the engine's wired `chat-menu` region
  // handles clicks server-side. The resolved URL comes back inside the #toasts
  // fragment as a hidden `#pending-copy[data-copy-url]` marker; this post-patch
  // pass consumes the marker, writes the URL to the clipboard, and drops it — a
  // one-shot handoff that cannot race a streamed re-render.
  // The engine's `data-copy` behavior owns only a literal attribute value; it
  // cannot see this server-staged handoff, so this seam stays until S-series
  // gives a consequence access to a server-staged clipboard value.
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

  // ---- Workspace preview copy (UX-12): the preview's copy control copies a
  // sibling's rendered text at click time, which no attribute value can carry.
  // `innerText` gives the rendered text for a markdown preview and the raw text
  // for a <pre>.
  document.addEventListener('click', function (e) {
    var btn = e.target && e.target.closest ? e.target.closest('#ws-preview-copy') : null;
    if (!btn) return;
    var body = document.querySelector('.ws-preview-scroll .ws-preview-body');
    var text = body ? (body.innerText || body.textContent || '') : '';
    function copied() { flashToast('File content copied.'); }
    function failed() { flashToast('Could not copy the file.', 'error'); }
    if (!text.trim()) { failed(); return; }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(copied).catch(failed);
    } else {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try {
        if (!document.execCommand('copy')) failed();
        else copied();
      } catch (err) { failed(); }
      document.body.removeChild(ta);
    }
  });

  // ---- Turn worklog "copy activity" buttons (delegated): copy the expanded
  // text of that tool round's detail block, addressed by `data-copy-target`.
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

  // ---- in-page `#` anchors are left to the browser: `WebUIServer.answerNavigate`
  // re-renders with `begin(..., preservingRegistrations: true)` (a5fa7bb, 2026-10-14),
  // so a hash jump no longer drops the handlers arc registered at boot.
  // `AnchorJumpTests` pins both halves of that premise.
})();

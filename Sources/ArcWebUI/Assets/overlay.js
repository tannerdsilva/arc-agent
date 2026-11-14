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

  // ---- Confirmation dialog: focus, and the one Tab guard the engine lacks.
  // the dialog is patched in: no focus lands in it. the engine traps Tab on
  // `.modal-overlay` and closes a layer through its `[data-dismiss]` control,
  // but it holds a raw element ref for the opener, so a patch-replaced
  // trigger's `focus()` no-ops. arc re-queries by `id`/`data-sid`,
  // deliberately; no upstream limitation is the reason, and never was.
  // `ModalFocusContractTests` pins both halves.
  function modalCard() {
    return document.querySelector('.modal-overlay .modal-card') ||
      document.querySelector('.modal-overlay .ctx-pane-card');
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
  // calls enhancePatched for each. arc's old `restoreModalFocus` began with an
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

  // The in-dialog Escape and the Tab wrap are the engine's (`:1917-1924`,
  // `:1477-1486`); focus OUTSIDE the card is the case it cannot serve, kept here.
  document.addEventListener('keydown', function (e) {
    var card = modalCard();
    if (!card || card.contains(document.activeElement)) return;
    if (e.key === 'Escape') {
      var c = card.querySelector('#modal-cancel') || card.querySelector('#ctx-pane-close');
      if (c) c.click();
      return;
    }
    if (e.key !== 'Tab') return;
    var f = card.querySelectorAll(
      'button:not([disabled]), [href], input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])'
    );
    if (!f.length) return;
    e.preventDefault();
    f[0].focus();
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
    if (wsPanel && !wsPanel.classList.contains('hidden') && !wsPanel.classList.contains('ws-closing')) {
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
    // The row's ⋮ and the menu it opens are panel chrome, not a navigation
    // choice. Closing the drawer here meant the tap that opened the menu also
    // took the menu off-canvas with the panel — an open, still-armed menu at
    // x=-279 that nobody could see or dismiss. Let the menu own its taps; the
    // row underneath still closes the drawer.
    if (t.closest('.menu-dots') || t.closest('.chat-menu')) return;
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
    syncModalFocus();
    syncThemePickers();
    // UX-06: the server stages a resolved copy URL as a `#pending-copy` marker
    // inside the toasts fragment; this pass is its only consumer. The engine
    // owns `[data-copy]` only — it has no server-staged handoff, so this stays.
    copyFromServerMarker();
  }

  function enhancePatched(changed) {
    clearRestoredComposer();
    syncComposerDraft();
    syncModalFocus();
    syncThemePickers();
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

  // ---- Chat row "..." menu: open/close is client-side so the open
  // menu survives the click that opened it; edge actions still go to
  // the server through the normal runtime pipeline.
  // ---- Kanban top-bar add menus (+ Column / + Row): the trigger toggles a
  // .kb-pop popover client-side (chat-row-menu style), so naming a new
  // column or lane never shifts the board layout. Any outside click closes;
  // a submit re-renders the board and the popover comes back closed.
  function closeKbPops() {
    var open = document.querySelectorAll('.kb-pop.open');
    for (var i = 0; i < open.length; i++) open[i].classList.remove('open');
  }
  document.addEventListener('click', function (e) {
    var t = e.target;
    if (!t || !t.closest) return;
    var trig = t.closest('#kb-addcol-menu, #kb-addlane-menu');
    if (trig) {
      var pop = trig.parentElement.querySelector('.kb-pop');
      var was = pop && pop.classList.contains('open');
      closeKbPops();
      if (pop && !was) {
        pop.classList.add('open');
        var inp = pop.querySelector('input[type="text"]');
        if (inp) inp.focus();
      }
      return;
    }
    if (t.closest('#kb-addcol-cancel, #kb-addlane-cancel')) { closeKbPops(); return; }
    if (t.closest('.kb-pop')) return;
    closeKbPops();
  });

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

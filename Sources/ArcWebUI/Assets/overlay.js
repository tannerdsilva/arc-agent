// The client is no-webui's ENGINE: HTMLDocument emits the
// `webui-config` meta and the engine script itself, so this page no
// longer boots or serves the legacy WebUIRuntime. What remains below is
// only the arc-specific overlay (composer, tables, slash menu,
// selection, outline, worklog) — everything it used to rely on the
// runtime for (transport, event dispatch, fragment patching, scroll and
// form-state restore, HTML sanitising) is the engine's job now.

(function () {
  try {
  // The ENGINE owns the submit gesture and the clear (no-webui 2.17.0): the
  // composer's `data-submit-on-enter="plain"` submits on Enter (Shift+Enter
  // newlines, IME returns early) and `data-clear-on-submit` empties the field
  // on the submit event.
  //
  // One consequence is NOT the engine's, measured: its draft store
  // (`data-draft-id`) writes `webui-draft:<identity>` on every input and
  // `syncDrafts()` re-fills an EMPTY field from it on the next replacing patch,
  // so the patch that lands right after the clear hands the submitted text
  // back (an `[data-draft-id][data-clear-on-submit]` composer refilled ~1.3 s
  // after Enter on the live page; 2.17.0's `onDocSubmit` clears the control,
  // not the store). Remember what the submit carried — CAPTURE phase, before
  // the engine's own submit handler reads and clears the control — and clear
  // the field again whenever a patch restores exactly that text.
  var submittedComposerText = null;

  document.addEventListener('submit', function (e) {
    if (!e.target || e.target.id !== 'composer-form') return;
    var t = document.getElementById('composer-input');
    if (t) submittedComposerText = t.value;
  }, true);

  function clearRestoredComposer() {
    if (submittedComposerText === null) return;
    var t = document.getElementById('composer-input');
    if (!t) return;
    if (t.value !== '' && t.value.trim() === String(submittedComposerText).trim()) {
      t.value = '';
    }
  }

  // ---- Slash-command autocomplete: the ENGINE's `FilterList(token: "/")`
  // region (no-webui 3.1.0, A16d). The server renders the rows as
  // `[role=option]` inside `.combo__panel`; `data-filter-list="/|#composer-input"`
  // opens the panel only while the token before the caret starts with `/`,
  // filters on what follows it, and `data-filter-insert` + `data-filter-template`
  // replace the whole token. No client block: not the payload parse, not the
  // token regex, not the row construction, not the highlight or the keydown.

  // Focus memory for the post-patch seam (UX-45): it lives for the page's
  // lifetime so a new chat can be aimed.
  var focusComposerWanted = false;

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

  // ---- The post-patch seam (A16c): THREE consumers, each blocked on a
  // behaviour A16d ships — (1) `clearRestoredComposer`, the A15 draft-store
  // guard (2.17.0 clears the control, not `webui-draft:<identity>`); (2) the
  // new-chat caret (`focusComposerWanted` + the `#chat-new` capture click,
  // UX-45); (3) `[data-focus-after-patch]`, a form fragment that asks for the
  // caret when it lands. (2) and (3) wait on a focus-on-appearance behaviour —
  // `autofocus` is once per document (A12/F3). Everything else that used to
  // live here died with its owner; this registration is the only one left.
  function enhancePatched(changed) {
    clearRestoredComposer();
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

  // The one registration left. It has to wait for the engine: /ui/init.js is
  // the FIRST head script and /ui/webui-engine.js comes after it, so
  // `WebUIEngine` does not exist while this file is being parsed. That ordering
  // is the whole reason a deferral survives here — there is no load-time pass
  // and no `ready` registration any more.
  function registerSeam() {
    if (window.WebUIEngine && WebUIEngine.on) {
      WebUIEngine.on.afterPatch(enhancePatched);
    }
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', registerSeam);
  } else {
    registerSeam();
  }

  // ---- Disclosures (context chip, session groups, skill categories) are
  // native `<details>` elements now: the platform owns open/closed, and the
  // engine keeps `open` across a patch by id (`data-preserve-open`). Nothing
  // here flips a class for them.

  // ---- Chat row "..." menu: the open state is the SERVER's (no-webui
  // 2.15.0's `data-open`, one-render latch): the ⋮ dispatches `s-menu-<sid>`,
  // "Move to Category" is a server panel swap, and the engine's dismiss stack
  // closes it on Escape or an outside click. Nothing here flips it.

  // ---- Rename conversation: the dialog is the SERVER's (A16a). The row menu's
  // "Rename conversation" arms `#rename-overlay`, a `.modal-overlay` card whose
  // form posts `rename-id`/`rename-name` to the `chat-menu` wire — one round
  // trip, no client editor and no hidden form. Focus entry (`autofocus`) and
  // return (`data-focus-return` on Cancel, naming the row's ⋮) are the engine's
  // (no-webui 2.14.0).

  // ---- Color swatches: client-side selection that mirrors into the
  // hidden color field of the enclosing form before submit.
  // A16c: KEEP. The truth is that hidden input until submit (the server seeds
  // index 0 and reads the field); a native radio group would be a markup + sheet
  // rewrite of two forms for an interaction with no server state.
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
  //
  // A16c: KEEP — the last visual-only handler here. The close is server state,
  // but the outgoing region's class must be on the node BEFORE the replace
  // lands, and the engine has no leave-transition hook (`afterPatch` runs after
  // the node is gone). A framework `data-leave` hook is the way out.
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('#w-close, #w-dock') : null;
    if (!b) return;
    var p = document.getElementById('ws-panel');
    if (!p || p.classList.contains('hidden') || p.classList.contains('ws-closing')) return;
    void p.offsetWidth; // force reflow so the transition actually runs
    p.classList.add('ws-closing');
  }, true);

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

  // ---- Copy is the ENGINE's (A16b/F5): every control carries `data-copy` and
  // `webui-engine-ext.js` writes the clipboard and paints its
  // `[data-webui-toast]` pill. ---- The blank canvas' "Start typing" is the
  // engine's `data-skip-to` consequence (A16c): real focus into
  // `#composer-input`, the same behaviour the skip link uses.
})();

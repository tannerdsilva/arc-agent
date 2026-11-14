// ux-gates.js — in-page interaction-state probe for the arc web UI.
//
// Page-context IIFE exactly like Scripts/ux-probe.js and ux-contrast.js:
// paste this file into a browser console (or inject it via the driver) and
// window.uxGates appears. Reads only; never mutates app state; every
// function returns plain JSON.
//
// The driver (Scripts/ux-drive.mjs) performs the real interactions (Tab,
// Escape, Enter, coordinate clicks) and calls these snapshots to assert the
// resulting DOM state. Re-query by selector on every call — never cache DOM
// nodes across interactions, the server re-renders the chat panel between
// patches.

(() => {
  if (window.uxGates) return 'uxGates already installed';

  const $ = (s) => document.querySelector(s);
  const $$ = (s) => Array.from(document.querySelectorAll(s));
  // "Shown" means a person can see it: laid out, painted, and not faded out.
  // The workspace panel unmounts only when the server's close patch lands, but
  // its 280ms exit already leaves it at opacity 0 and translated past the edge
  // — counting that as open reports the panel as stuck open when the user has
  // watched it leave. `visibility`/`opacity` are part of visibility, not layout.
  const shown = (el) => {
    if (!el) return false;
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) <= 0.05) return false;
    if (el.getBoundingClientRect().width <= 0) return false;
    const hid = el.closest('[hidden]');
    return !(hid && hid.hidden === true);
  };
  const text = (el) => (el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : '');
  const activeEl = () => {
    const el = document.activeElement;
    if (!el || el === document.body) return { isBody: true, id: null, tag: 'BODY' };
    return {
      isBody: false,
      id: el.id || null,
      tag: el.tagName.toLowerCase(),
      cls: (el.className || '').toString().split(' ').slice(0, 4).join('.'),
      label: text(el).slice(0, 40),
      ariaCurrent: el.getAttribute('aria-current'),
      dataSid: el.getAttribute('data-sid'),
    };
  };

  const POPOVERS = ['file', 'workspace', 'profile', 'model', 'think', 'checkout'];
  const POP_SEL = {
    file: '#file-pop',
    workspace: '.dd-pop-ws',
    model: '.dd-pop-model',
  };
  // profile and think never carried an identifying class: their popover is the
  // `.dd-pop` inside the trigger's own `.dd` container. Resolve it structurally
  // rather than minting an unstyled class token — the stylesheet census pins
  // those as ARC-3 debt and calls growing that list a regression. This is a
  // selector fix, not a weakened assertion: open/escape/outside-click are
  // still checked for all four triggers.
  const POP_TRIGGER = { profile: '#cb-profile-toggle', think: '#cb-think-toggle' };
  const popEl = (name) => {
    if (POP_SEL[name]) return $(POP_SEL[name]);
    const t = POP_TRIGGER[name] ? $(POP_TRIGGER[name]) : null;
    const dd = t ? t.closest('.dd') : null;
    return dd ? dd.querySelector('.dd-pop') : null;
  };
  const TRIGGER = {
    file: '#cb-file',
    workspace: '#cb-ws-toggle',
    profile: '#cb-profile-toggle',
    model: '#cb-model-toggle',
    think: '#cb-think-toggle',
  };

  function popoverState() {
    const out = {};
    for (const name of POPOVERS) {
      if (name === 'checkout') continue;
      const el = popEl(name);
      out[name] = { present: !!el, open: shown(el) };
    }
    // the row menu's open state is the server's `data-open` (no-webui 2.15.0):
    // the ⋮ dispatches to the server and the engine's dismiss stack closes it.
    const menu = $$('.chat-menu').find((m) => m.hasAttribute('data-open'));
    out.sessionMenu = { present: !!menu, open: shown(menu) };
    const slash = $('#cmd-dropdown');
    out.slash = { present: !!slash, open: slash ? slash.classList.contains('open') && shown(slash) : false, rowCount: slash ? slash.querySelectorAll('.cmd-item').length : 0 };
    const wsPanel = $('#ws-panel');
    out.wsPanel = { present: !!wsPanel, open: shown(wsPanel), enter: wsPanel ? wsPanel.classList.contains('ws-enter') : false };
    return out;
  }

  const api = {
    ping: () => ({ ok: true, ts: Date.now() }),
    activeElement: activeEl,
    boot: () => ({ app: !!$('#app'), rail: !!$('#rail'), composer: !!$('#composer-input'), panel: !!$('#panel') }),
    state: () => ({
      view: document.querySelector('.chat-scroll') ? 'chat' : 'other',
      appClass: (document.getElementById('app').className || ''),
      // the drawer's open state is the engine's `data-open` on #app
      drawerOpen: !!document.getElementById('app') && document.getElementById('app').hasAttribute('data-open'),
      composerPresent: !!$('#composer-input'),
      composerValue: $('#composer-input') ? $('#composer-input').value : null,
      composerPlaceholder: $('#composer-input') ? $('#composer-input').getAttribute('placeholder') : null,
      sendIsStop: !!$('#cb-send.stop'),
      sidebarCount: $$('.sess-row').length,
      theme: document.documentElement.getAttribute('data-scheme') || '',
      bodyBg: getComputedStyle(document.body).backgroundColor,
    }),
    popovers: popoverState,
    // rect of a named composer popover (the driver needs one point that is
    // provably outside it for the outside-click assertion)
    popoverRect: (name) => {
      const el = popEl(name);
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { left: r.left, right: r.right, top: r.top, bottom: r.bottom };
    },
    slash: () => {
      const dd = $('#cmd-dropdown');
      if (!dd) return { present: false };
      const rows = Array.from(dd.querySelectorAll('.cmd-item')).map((r) => ({ text: text(r).slice(0, 60), active: r.classList.contains('active') }));
      return { present: true, open: dd.classList.contains('open') && shown(dd), rowCount: rows.length, activeCount: rows.filter((r) => r.active).length, rows };
    },
    sessions: () => ({
      count: $$('.sess-row').length,
      activeSid: (function () { const a = $('.sess-row.active'); return a ? a.getAttribute('data-sid') : null; })(),
      activeTitle: (function () { const a = $('.sess-row.active'); return a ? text(a).slice(0, 60) : null; })(),
      rows: $$('.sess-row').slice(0, 60).map((r) => ({ sid: r.getAttribute('data-sid'), active: r.classList.contains('active'), title: text(r).slice(0, 40) })),
    }),
    toast: () => {
      const host = $('#toasts');
      if (!host) return { present: false };
      const items = Array.from(host.querySelectorAll('.toast')).map((t) => ({
        kind: Array.from(t.classList).find((c) => c !== 'toast') || 'neutral',
        text: text(t).slice(0, 80),
        hasAction: !!t.querySelector('.toast-action'),
        actionLabel: text(t.querySelector('.toast-action')) || null,
      }));
      return { present: true, count: items.length, items };
    },
    modal: () => {
      const ov = $('#modal-overlay');
      return {
        open: shown(ov),
        title: text($('#modal-title')),
        hasCancel: !!$('#modal-cancel'),
        hasConfirm: !!$('#modal-confirm'),
        scrimBg: ov ? getComputedStyle(ov).backgroundColor : null,
        scrimRect: ov ? (() => { const r = ov.getBoundingClientRect(); return { l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom) }; })() : null,
        cardRect: (() => { const c = $('.modal-card'); if (!c) return null; const r = c.getBoundingClientRect(); return { l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom) }; })(),
      };
    },
    dock: () => {
      const anchor = $('#ws-dock');
      const b = $('#w-dock');
      const panel = $('#ws-panel');
      return {
        anchorPresent: !!anchor,
        anchorHasComponentId: anchor ? (anchor.getAttribute('data-component-id') === 'workspace') : false,
        buttonPresent: !!b && shown(b),
        buttonTitle: b ? b.getAttribute('title') : null,
        buttonOpenCls: b ? b.classList.contains('ws-dock-open') : false,
        panelOpen: shown(panel),
        panelHiddenCls: panel ? panel.classList.contains('hidden') : null,
        panelEnter: panel ? panel.classList.contains('ws-enter') : false,
      };
    },
    stream: () => {
      const lt = $('#live-turn');
      if (!lt) return { live: false };
      const cs = getComputedStyle(lt.querySelector('.stream-cursor') || lt, '::after');
      return {
        live: true,
        streamingCls: lt.classList.contains('streaming'),
        dataStreaming: lt.getAttribute('data-streaming'),
        hasAvatar: !!lt.querySelector('.msg-meta .role-icon.assistant'),
        status: text(lt.querySelector('.live-status')),
        textLen: text(lt.querySelector('#live-turn-text')).length,
        cursorAnimDuration: cs.animationDuration || '0s',
        cursorAnimName: cs.animationName || 'none',
      };
    },
    finishedTurn: () => {
      const turns = $$('.assistant-turn');
      return {
        turnCount: turns.length,
        lastHasAvatar: turns.length ? !!turns[turns.length - 1].querySelector(':scope > .msg-meta .role-icon.assistant') : null,
        anyStreaming: $$('[data-streaming], .streaming').length,
      };
    },
    workspace: () => {
      const p = $('#ws-panel');
      if (!p) return { present: false };
      const cs = getComputedStyle(p);
      return {
        present: true,
        open: shown(p),
        animationName: cs.animationName,
        animationDuration: cs.animationDuration,
        transitionDuration: cs.transitionDuration,
        transform: cs.transform,
        opacity: cs.opacity,
        x: Math.round(p.getBoundingClientRect().x),
      };
    },
    toastAnim: () => {
      const t = $('.toast');
      if (!t) return { present: false };
      const cs = getComputedStyle(t);
      return { present: true, count: $$('.toast').length, animationName: cs.animationName, animationDuration: cs.animationDuration, transitionDuration: cs.transitionDuration, visible: shown(t) };
    },
    // ---- drawer (no-webui 2.15.0) ------------------------------------------
    //
    // the state is `data-open` on #app; `data-drawer-toggle` on the topbar
    // button and on the scrim flips it with no round-trip, moves focus into
    // `.drawer__panel` and returns it to the opening toggle on close. below
    // 860px the panel is off-canvas and `visibility: hidden` (out of the tab
    // order); at 861px and wider it is the static rail and the toggle is gone.
    drawer: () => {
      const t = $('#drawer-toggle');
      const app = document.getElementById('app');
      const panel = $('#panel');
      const scrim = $('#drawer-scrim');
      const cs = panel ? getComputedStyle(panel) : null;
      const scs = scrim ? getComputedStyle(scrim) : null;
      const tr = t ? t.getBoundingClientRect() : null;
      const active = document.activeElement;
      const inPanel = !!(panel && active && panel.contains(active));
      return {
        present: !!t,
        open: !!app && app.hasAttribute('data-open'),
        toggleDisplay: t ? getComputedStyle(t).display : null,
        toggleWidth: tr ? Math.round(tr.width) : null,
        toggleHeight: tr ? Math.round(tr.height) : null,
        toggleNames: t ? t.getAttribute('data-drawer-toggle') : null,
        panelVisibility: cs ? cs.visibility : null,
        panelPosition: cs ? cs.position : null,
        panelShown: shown(panel),
        panelTabindex: panel ? panel.getAttribute('tabindex') : null,
        scrimPresent: !!scrim,
        scrimNames: scrim ? scrim.getAttribute('data-drawer-toggle') : null,
        scrimOpacity: scs ? Number(scs.opacity) : null,
        scrimPointer: scs ? scs.pointerEvents : null,
        scrimRect: scrim ? (() => { const r = scrim.getBoundingClientRect(); return { l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom), w: Math.round(r.width), h: Math.round(r.height) }; })() : null,
        focusInPanel: inPanel,
        focusID: active ? (active.id || null) : null,
        focusTag: active ? active.tagName.toLowerCase() : null,
        viewport: window.innerWidth,
      };
    },
    scrim: () => {
      const ov = $('#modal-overlay');
      if (!ov) return null;
      const cs = getComputedStyle(ov);
      const r = ov.getBoundingClientRect();
      const alpha = cs.backgroundColor.match(/rgba?\([^)]*,[^,)]*\)$/) ? parseFloat(cs.backgroundColor.replace(/^rgba?\([^,]*,[^,]*,[^,]*,?\s*/, '').replace(')', '')) : 1;
      return {
        bg: cs.backgroundColor,
        alpha,
        covers: r.left <= 0 && r.top <= 0 && r.right >= window.innerWidth - 1 && r.bottom >= window.innerHeight - 1,
        pos: cs.position,
        z: cs.zIndex,
        pointerEvents: cs.pointerEvents,
      };
    },
    focusables: () => Array.from(document.querySelectorAll('a[href], button, input, textarea, select, [tabindex]:not([tabindex="-1"])'))
      .filter((el) => shown(el))
      .map((el) => ({ id: el.id, tag: el.tagName.toLowerCase(), label: text(el).slice(0, 30) }))
      .slice(0, 40),

    // ---- upload zone (no-webui 2.11.0) -------------------------------------
    //
    // the engine owns the transport: `data-upload-into` binds drop/paste, posts
    // one XHR per file, paints `[data-webui-upload-tray]` rows with
    // `data-webui-upload-state`, and dispatches `upload-complete`. these helpers
    // only build real `File`s and read the result — no assertion lives here.

    /// the tray the engine paints, oldest row first. `state` is the row's
    /// `data-webui-upload-state` (`uploading|done|error|cancelled`).
    uploadTray: () => {
      const tray = document.querySelector('[data-webui-upload-tray]');
      if (!tray) return { present: false, count: 0, rows: [] };
      // `text` is the row's whole textContent (name + status); `status` is the
      // status span alone, which is where the route's refusal sentence lands
      // verbatim. a gate that compares the row's text would compare the name too.
      const rows = Array.from(tray.querySelectorAll('[data-webui-upload-state]')).map((r) => ({
        state: r.getAttribute('data-webui-upload-state'),
        name: text(r.querySelector('.upload-tray__name')) || null,
        text: text(r),
        status: text(r.querySelector('.upload-tray__status')) || null,
      }));
      return { present: true, count: rows.length, rows, last: rows[rows.length - 1] || null };
    },

    /// the composer's attachment chips, as `@path` text.
    uploadChips: () => {
      const host = document.querySelector('#attach-chips');
      if (!host) return { present: false, count: 0, chips: [] };
      const chips = Array.from(host.querySelectorAll('.chip')).map((c) => text(c));
      return { present: true, count: chips.length, chips };
    },

    /// the zones' attribute contract, read from the DOM rather than the source.
    uploadZones: () => {
      const pick = (id) => {
        const el = document.getElementById(id);
        if (!el) return { present: false };
        return {
          present: true,
          hasInto: el.hasAttribute('data-upload-into'),
          into: el.getAttribute('data-upload-into'),
          to: el.getAttribute('data-upload-to'),
          template: el.getAttribute('data-upload-name-template'),
          component: el.getAttribute('data-component-id'),
          event: el.getAttribute('data-event'),
        };
      };
      return { composer: pick('composer-form'), panel: pick('ws-panel'), dock: pick('ws-dock') };
    },

    /// drop real `File`s on `selector`. a synthetic `DataTransfer` item has no
    /// `webkitGetAsEntry`, so this exercises the engine's `getAsFile` fallback —
    /// the same branch a browser takes for a file with no filesystem backing.
    uploadDrop: (selector, specs) => {
      const el = document.querySelector(selector);
      if (!el) return { ok: false, reason: 'no ' + selector };
      const dt = new DataTransfer();
      for (const s of specs) {
        dt.items.add(new File([new Uint8Array(s.bytes || 8)], s.name, { type: s.type || 'application/octet-stream' }));
      }
      el.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt }));
      el.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt }));
      return { ok: true, names: specs.map((s) => s.name) };
    },

    /// paste an image `File` on `selector` (the composer input). the engine's
    /// paste binder only uploads `image/*`, and leaves a text-only paste alone.
    uploadPaste: (selector, name, type, bytes) => {
      const el = document.querySelector(selector);
      if (!el) return { ok: false, reason: 'no ' + selector };
      const dt = new DataTransfer();
      dt.items.add(new File([new Uint8Array(bytes || 64)], name, { type: type || 'image/png' }));
      el.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dt }));
      return { ok: true, name };
    },

    /// the engine's live render token — the upload credential. read/write so a
    /// gate can prove the route's refusal without a second page.
    uploadToken: () => {
      const engine = window.WebUIEngine && window.WebUIEngine._getInstance ? window.WebUIEngine._getInstance() : null;
      return engine && engine.config ? (engine.config.renderToken || null) : null;
    },
    setUploadToken: (value) => {
      const engine = window.WebUIEngine && window.WebUIEngine._getInstance ? window.WebUIEngine._getInstance() : null;
      if (!engine || !engine.config) return false;
      engine.config.renderToken = value;
      return true;
    },

    /// the workspace root the panel is showing (`#ws-tree[data-root]`), so a
    /// gate can name and clean the files it caused to land.
    workspaceRoot: () => {
      const tree = document.getElementById('ws-tree');
      return tree ? tree.getAttribute('data-root') : null;
    },

    // ---- scroll follow / reading keys (a11) --------------------------------
    // the engine owns all of it: `data-follow` (policy), `data-follow-state`
    // (its output), `data-reading-keys` (the keyboard region) and
    // `data-scroll-key` (the per-session offset). these helpers only read the
    // consequence, plus two fixtures: `scrollPad` gives the transcript room so
    // a follow test is not a no-op on an empty chat, and `scrollDelta` drives
    // the engine's OWN patch funnel (`capture` → DOM change → `restore`, the
    // same calls the socket patch path makes) so a text delta needs no model
    // turn.

    scrollState: () => {
      const s = document.getElementById('chat-scroll');
      if (!s) return { present: false };
      const btn = document.getElementById('scroll-to-bottom');
      const cs = btn ? getComputedStyle(btn) : null;
      const max = Math.max(0, s.scrollHeight - s.clientHeight);
      return {
        present: true,
        top: Math.round(s.scrollTop),
        max: Math.round(max),
        gap: Math.round(Math.max(0, s.scrollHeight - s.scrollTop - s.clientHeight)),
        away: s.getAttribute('data-follow-state'),
        follow: s.getAttribute('data-follow'),
        readingKeys: s.hasAttribute('data-reading-keys'),
        key: s.getAttribute('data-scroll-key'),
        tabindex: s.getAttribute('tabindex'),
        btnPresent: !!btn,
        btnDisplay: cs ? cs.display : null,
        btnVisible: !!(btn && cs && cs.display !== 'none' && btn.getClientRects().length > 0),
        active: (document.activeElement || {}).id || (document.activeElement || {}).tagName || null,
      };
    },

    /// pad `#chat-inner` until the scroller has `want` px of room. a gate
    /// fixture, not app state: the next server patch replaces the transcript,
    /// and the gate reloads before it hands the page back.
    scrollPad: (want) => {
      const s = document.getElementById('chat-scroll');
      const inner = document.getElementById('chat-inner');
      if (!s || !inner) return { ok: false, reason: 'no scroller' };
      let made = 0;
      for (let i = 0; i < 200 && (s.scrollHeight - s.clientHeight) < want; i++) {
        const p = document.createElement('p');
        p.className = 'msg gate-pad';
        p.textContent = `gate padding ${i + 1} — lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore.`;
        inner.appendChild(p);
        made++;
      }
      return { ok: true, made, room: Math.round(s.scrollHeight - s.clientHeight) };
    },

    /// one text delta through the engine's patch funnel. `capture` records the
    /// pre-patch follow memo, `restore` re-applies behaviors and runs
    /// `syncFollow` — exactly what a `{op:"text"}` frame does, without a
    /// websocket and without a model.
    scrollDelta: (label) => {
      const engine = window.WebUIEngine && window.WebUIEngine._getInstance ? window.WebUIEngine._getInstance() : null;
      const s = document.getElementById('chat-scroll');
      const inner = document.getElementById('chat-inner');
      if (!engine || !engine.behaviors || !s || !inner) return { ok: false, reason: 'no engine/scroller' };
      engine.behaviors.capture([{ op: 'text', id: 'chat-inner' }]);
      const p = document.createElement('p');
      p.className = 'msg gate-delta';
      p.textContent = `delta ${label || ''} — ${'streamed text '.repeat(12)}`;
      inner.appendChild(p);
      engine.behaviors.restore([p]);
      return {
        ok: true,
        top: Math.round(s.scrollTop),
        gap: Math.round(Math.max(0, s.scrollHeight - s.scrollTop - s.clientHeight)),
        away: s.getAttribute('data-follow-state'),
      };
    },

    /// arm a real, on-screen `[data-dismiss]` element through the engine's own
    /// binder, so `topLayer()` is exercised with focus still on the reader.
    /// arc's dropdowns take `data-dismiss` in A13; until then no persistent
    /// layer exists, and this is the engine's documented registration path
    /// (a visible element carrying the attribute, bound by `apply`).
    armLayer: () => {
      const engine = window.WebUIEngine && window.WebUIEngine._getInstance ? window.WebUIEngine._getInstance() : null;
      if (!engine || !engine.behaviors) return { ok: false, reason: 'no engine' };
      let el = document.getElementById('gate-layer');
      if (!el) {
        el = document.createElement('div');
        el.id = 'gate-layer';
        el.setAttribute('data-dismiss', '');
        el.style.cssText = 'position:fixed;left:8px;bottom:8px;width:60px;height:30px;background:rgba(0,0,0,.6);z-index:99999';
        // a real layer closes through its own dismiss control; the engine
        // fires a click on the first `[data-dismiss]` child (or the layer
        // itself), so the layer removes itself exactly as a server-rendered
        // panel would on its close patch.
        el.onclick = () => el.remove();
        document.body.appendChild(el);
      }
      engine.behaviors.apply(document);
      return { ok: true, onScreen: el.getClientRects().length > 0 };
    },
    disarmLayer: () => {
      const el = document.getElementById('gate-layer');
      if (el) el.remove();
      return { ok: true };
    },

    // ---- draft identity + seed (a14) ---------------------------------------
    // no-webui 2.16.0 owns the composer draft: `data-draft-id` names the
    // per-chat store and `data-draft-value` is the server-rendered text the
    // control starts from. the engine's `syncDrafts()` writes the seed when the
    // identity CHANGED and leaves the reader's keystrokes alone when it did
    // not. these helpers only read the consequence — never a client behaviour
    // of arc's own.

    /// the composer's draft contract, as the engine states it.
    draft: () => {
      const t = document.getElementById('composer-input');
      if (!t) return { present: false };
      const id = t.getAttribute('data-draft-id');
      let store = null;
      try { store = id === null ? null : sessionStorage.getItem('webui-draft:' + id); } catch (e) { store = 'unavailable'; }
      return {
        present: true,
        id,
        seed: t.getAttribute('data-draft-value'),
        session: t.getAttribute('data-session'),
        value: t.value,
        store,
        activeSid: (function () { const a = $('.sess-row.active'); return a ? a.getAttribute('data-sid') : null; })(),
      };
    },

    /// the composer selector the SERVER has armed: `sel-open` on the form names
    /// an open popover and `data-open` rides the popover itself, so this is
    /// server state, not the engine's DOM consequence of a dismiss.
    armedPopover: () => {
      const form = document.getElementById('composer-form');
      if (!form) return null;
      const pop = form.querySelector('.dd-pop[data-open]');
      if (!pop) return null;
      const dd = pop.closest('.dd');
      const trig = dd ? dd.querySelector('.dd-trigger') : null;
      return trig ? (trig.id || null) : null;
    },

    /// put `text` in the composer WITHOUT an input frame: the server never hears
    /// it, so the seed on the next patch is still the stored draft. this is how
    /// the gate separates "what the reader typed" from "what the server says".
    draftSilentSet: (text) => {
      const t = document.getElementById('composer-input');
      if (!t) return { ok: false, reason: 'no composer' };
      Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(t, text);
      return { ok: true, value: t.value };
    },

    /// plant a store value, so a later identity change has something to overwrite.
    draftPlantStore: (id, text) => {
      try { sessionStorage.setItem('webui-draft:' + id, text); return { ok: true }; } catch (e) { return { ok: false, reason: String(e) }; }
    },

    /// stamp the live textarea, so a patch that replaces it can be told apart
    /// from one that never touched it. the mark is DOM-only: the server never
    /// renders it, so it cannot survive a replacement.
    draftMark: () => {
      const t = document.getElementById('composer-input');
      if (!t) return { ok: false };
      t.setAttribute('data-gate-mark', 'a14');
      return { ok: true };
    },
    draftMarkIntact: () => {
      const t = document.getElementById('composer-input');
      return !!t && t.getAttribute('data-gate-mark') === 'a14';
    },

    // ---- focus contract (a12) ----------------------------------------------
    // no-webui 2.14.0 owns focus. `autofocus` is the entry flush on a
    // patched-in dialog, `data-focus-return` names where focus goes when the
    // control that DECLARED it is removed by a patch (and, around a focused
    // control, the T26 target to re-query), and `.modal-overlay` wraps Tab.
    // these helpers only read the consequence — the driver performs the input.

    focusState: () => {
      const a = document.activeElement;
      const dialog = document.querySelector('.modal-overlay');
      const close = document.getElementById('ctx-pane-close') || document.getElementById('modal-cancel');
      const chip = document.getElementById('ctx-chip-summary');
      return {
        active: a && a !== document.body ? (a.id || a.tagName) : null,
        activeIsBody: !a || a === document.body,
        activeInDialog: !!(a && dialog && dialog.contains(a)),
        dialog: dialog ? dialog.id : null,
        ctxPaneOpen: !!document.getElementById('ctx-pane-overlay'),
        modalOpen: !!document.getElementById('modal-overlay'),
        opener: chip ? { id: chip.id, tag: chip.tagName.toLowerCase() } : null,
        close: close ? {
          id: close.id,
          focusReturn: close.getAttribute('data-focus-return'),
          autofocus: close.hasAttribute('autofocus'),
          dismiss: close.hasAttribute('data-dismiss'),
        } : null,
      };
    },

    /// the open dialog's focusable controls, in document order — the set the
    /// engine's `.modal-overlay` keydown trap wraps over.
    dialogFocusables: () => {
      const d = document.querySelector('.modal-overlay');
      if (!d) return { ok: false, reason: 'no dialog' };
      const sel = 'button, [href], input, select, textarea, [tabindex], summary';
      const list = [];
      const all = d.querySelectorAll(sel);
      for (let i = 0; i < all.length; i++) {
        const el = all[i];
        if (!el.disabled && el.getAttribute('tabindex') !== '-1') list.push(el);
      }
      return { ok: true, count: list.length, ids: list.map((el) => el.id || el.tagName) };
    },

    /// T26 with a real replacing patch, driven through the engine's OWN funnel
    /// (`capture` → node replace → `restore`, the calls the socket patch path
    /// makes). `declared` gives the focused control a `data-focus-return`
    /// (empty value = the element itself) so the engine's memo has a target;
    /// the undeclared lap measures what arc's real surfaces do today.
    focusReplace: (declared) => {
      const engine = window.WebUIEngine && window.WebUIEngine._getInstance ? window.WebUIEngine._getInstance() : null;
      const live = document.getElementById('ctx-chip-summary');
      if (!engine || !engine.behaviors || !live || !live.parentNode) {
        return { ok: false, reason: 'no engine, or no focused control to replace' };
      }
      const had = !!live.closest('[data-focus-return]');
      if (declared && !had) live.setAttribute('data-focus-return', '');
      live.focus();
      engine.behaviors.capture([{ op: 'replace', id: 'ctx-chip' }]);
      const copy = live.cloneNode(true);
      live.parentNode.replaceChild(copy, live);
      engine.behaviors.restore([copy]);
      const active = document.activeElement;
      const out = {
        ok: true,
        declared: !!declared,
        hadDeclaration: had,
        replaced: !live.isConnected,
        kept: active === copy,
        active: active && active !== document.body ? (active.id || active.tagName) : null,
      };
      if (declared && !had) copy.removeAttribute('data-focus-return');
      return out;
    },

    // ---- composer submit contract (a15) ------------------------------------
    // no-webui 2.17.0 owns the submit gesture and the clear, and the theme
    // picker's `aria-pressed` is the selected-state contract. these helpers
    // only read the consequence off the live page; the driver performs input.

    /// the composer's declared consequence plus the transcript's witness: did a
    /// user message land with this text, and does the field now hold what?
    composerState: () => {
      const t = document.getElementById('composer-input');
      const users = Array.prototype.slice.call(document.querySelectorAll('.msg.user'));
      const dd = document.getElementById('cmd-dropdown');
      return {
        present: !!t,
        value: t ? t.value : null,
        submit: t ? t.getAttribute('data-submit-on-enter') : null,
        clear: t ? t.hasAttribute('data-clear-on-submit') : false,
        draftId: t ? t.getAttribute('data-draft-id') : null,
        userRows: users.length,
        lastUser: users.length ? (users[users.length - 1].textContent || '').trim().slice(0, 160) : null,
        live: !!document.getElementById('live-turn'),
        menuOpen: !!dd && dd.classList.contains('open'),
        menuRows: dd ? dd.querySelectorAll('.cmd-item').length : 0,
      };
    },

    /// the theme toggle as the ENGINE states it: `aria-pressed` per card, the
    /// root `data-theme`, and the computed border the sheet paints for a pressed
    /// card. `.active` is gone (A15), so this is the only selected contract.
    themeState: () => {
      const cards = Array.prototype.slice.call(document.querySelectorAll('[data-theme-choice]')).map((b) => {
        const cs = getComputedStyle(b);
        return {
          id: b.id,
          choice: b.getAttribute('data-theme-choice'),
          pressed: b.getAttribute('aria-pressed'),
          cls: b.className,
          borderColor: cs.borderTopColor,
          boxShadow: cs.boxShadow,
        };
      });
      return {
        theme: document.documentElement.getAttribute('data-theme'),
        cards,
        pressed: cards.filter((c) => c.pressed === 'true').map((c) => c.choice),
        classActive: cards.filter((c) => (' ' + c.cls + ' ').indexOf(' active ') >= 0).length,
      };
    },
  };
  window.uxGates = api;
  return 'uxGates installed — helpers on window.uxGates';
})()

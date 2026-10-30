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
    const menu = $$('.chat-menu').find((m) => m.classList.contains('open'));
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
      drawerOpen: (document.getElementById('app').className || '').includes('drawer-open'),
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
    drawer: () => {
      const t = $('#drawer-toggle');
      if (!t) return { present: false, display: 'none' };
      const r = t.getBoundingClientRect();
      return { present: true, width: Math.round(r.width), height: Math.round(r.height), display: getComputedStyle(t).display, open: (document.getElementById('app').className || '').includes('drawer-open') };
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
  };
  window.uxGates = api;
  return 'uxGates installed — helpers on window.uxGates';
})()

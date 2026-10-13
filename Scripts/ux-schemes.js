// ux-schemes.js — in-page scheme-contact-sheet probe for the arc web UI.
//
// Page-context IIFE like Scripts/ux-probe.js: paste into a browser console
// (or inject via the driver) and window.uxSchemes appears. Reads only; the
// driver performs the selection clicks.
//
//   uxSchemes.list()   -> schemes enumerated from the app's OWN settings grid
//                         (registry-driven: [data-scheme-choice] tiles), NOT
//                         a hardcoded list: [{id, label}]
//   uxSchemes.active() -> currently active scheme id
//   uxSchemes.tokens() -> computed key token values on :root for the active
//                         scheme: {bg, text, accent, border, accentStrong}
//                         plus a couple of derived sanity numbers (bg text
//                         luminance contrast) for the index record.

(() => {
  if (window.uxSchemes) return 'uxSchemes already installed';

  const $ = (s) => document.querySelector(s);
  const $$ = (s) => Array.from(document.querySelectorAll(s));

  function parseCss(str) {
    const m = /rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)(?:\s*,\s*([\d.]+))?\s*\)/.exec(str || '');
    if (m) return { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] };
    return null;
  }
  function lum(c) {
    const l = (v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * l(c.r) + 0.7152 * l(c.g) + 0.0722 * l(c.b);
  }
  function contrast(fg, bg) {
    const a = lum(fg), b = lum(bg);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  }

  const api = {
    ping: () => ({ ok: true, ts: Date.now() }),
    list() {
      const tiles = $$('[data-scheme-choice]');
      const out = tiles.map((t) => ({
        id: t.getAttribute('data-scheme-choice'),
        label: (t.querySelector('.scheme-name')?.textContent || t.getAttribute('title') || '').trim(),
        active: t.classList.contains('active'),
      }));
      const activeTile = tiles.find((t) => t.classList.contains('active'));
      return { count: out.length, activeId: activeTile ? activeTile.getAttribute('data-scheme-choice') : null, schemes: out };
    },
    active() {
      const t = $('[data-scheme-choice].active');
      return t ? t.getAttribute('data-scheme-choice') : null;
    },
    tokens() {
      const cs = getComputedStyle(document.documentElement);
      const read = (n) => (cs.getPropertyValue(n) || '').trim();
      const bg = read('--bg') || getComputedStyle(document.body).backgroundColor;
      const text = read('--text');
      const accent = read('--accent');
      const accentStrong = read('--accent-strong');
      const border = read('--border') || read('--border-strong');
      const fg = parseCss(text);
      const bgr = parseCss(bg);
      const acc = parseCss(accent || accentStrong);
      return {
        bg: bg || null,
        text: text || null,
        accent: accent || null,
        accentStrong: accentStrong || null,
        border: border || null,
        // sanity numbers for the index (0 if unresolvable)
        textOnBgRatio: fg && bgr ? +contrast(fg, bgr).toFixed(2) : 0,
        accentOnBgRatio: acc && bgr ? +contrast(acc, bgr).toFixed(2) : 0,
        scheme: document.documentElement.getAttribute('data-scheme') || '',
      };
    },
  };
  window.uxSchemes = api;
  return 'uxSchemes installed — call uxSchemes.list() / .tokens()';
})()

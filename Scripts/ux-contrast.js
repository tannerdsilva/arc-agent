// ux-contrast.js — in-page WCAG AA contrast probe for the arc web UI.
//
// Page-context IIFE exactly like Scripts/ux-probe.js: paste this file into a
// browser console (or inject it via the driver) and window.uxContrast
// appears. Reads only; never mutates app state.
//
//   uxContrast.sampleView({ root, view, theme, maxFailures }) -> {
//     view, theme, total, skipped, normalChecked, largeChecked,
//     failures: [{ text, tag, id, cls, fg, bg, alpha, ratio, required, large }],
//     failureCount, passCount, ratioDistribution
//   }
//
// Algorithm (WCAG 2.x):
//   - every text-bearing visible element (skips display:none, visibility
//     hidden, zero-area, opacity ~0, images, script/style/template/svg hosts)
//   - effective background = walk ancestors to the first non-transparent
//     background-color, alpha-compositing semi-transparent backgrounds onto
//     the next opaque one below (so text on a 50% tint over a solid surface
//     is measured against the real blended colour)
//   - ratio vs required: 4.5 normal text, 3.0 large text (>=24px, or >=18.66px
//     and font-weight >= 700)

(() => {
  if (window.uxContrast) return 'uxContrast already installed';

  // ---- colour parsing ------------------------------------------------------

  const P = {
    '#': (s) => {
      const h = s.slice(1);
      if (h.length === 3 || h.length === 6) {
        const full = h.length === 3 ? h.split('').map((c) => c + c).join('') : h;
        return { r: parseInt(full.slice(0, 2), 16), g: parseInt(full.slice(2, 4), 16), b: parseInt(full.slice(4, 6), 16), a: 1 };
      }
      if (h.length === 8) {
        return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16), a: parseInt(h.slice(6, 8), 16) / 255 };
      }
      return null;
    },
    rgb: (s) => {
      const m = /rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)/.exec(s);
      if (!m) return null;
      return { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] };
    },
    named: (s) => {
      // colour-mix() / named colours / hsl are not resolvable off-line; a
      // scratch canvas resolves any colour the browser accepts.
      const el = document.createElement('div');
      el.style.color = s;
      if (!el.style.color) return null;
      document.body.appendChild(el);
      const cs = getComputedStyle(el).color;
      const rgb = P.rgb(cs) || P.rgb(cs);
      el.remove();
      return rgb;
    },
  };

  function parseColor(str) {
    if (!str) return null;
    str = str.trim();
    if (!str || str === 'transparent') return { r: 0, g: 0, b: 0, a: 0 };
    if (str.startsWith('#')) return P['#'](str);
    const rgb = P.rgb(str);
    if (rgb) return rgb;
    // gradient / colour-mix / var() fallbacks: resolve via scratch element.
    try { return P.named(str); } catch { return null; }
  }

  // ---- WCAG math -----------------------------------------------------------

  function srgbLin(c) {
    c /= 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  }
  function luminance(c) {
    return 0.2126 * srgbLin(c.r) + 0.7152 * srgbLin(c.g) + 0.0722 * srgbLin(c.b);
  }
  function composite(fg, bg) {
    if (fg.a >= 0.999 && !bg) return fg;
    const a = fg.a + (bg ? bg.a : 0) * (1 - fg.a);
    if (a <= 0) return { r: 0, g: 0, b: 0, a: 0 };
    return {
      r: (fg.r * fg.a + (bg ? bg.r * bg.a * (1 - fg.a) : 0)) / a,
      g: (fg.g * fg.a + (bg ? bg.g * bg.a * (1 - fg.a) : 0)) / a,
      b: (fg.b * fg.a + (bg ? bg.b * bg.a * (1 - fg.a) : 0)) / a,
      a,
    };
  }
  function ratio(fg, bg) {
    const f = luminance(fg);
    const b = luminance(bg);
    const hi = Math.max(f, b);
    const lo = Math.min(f, b);
    return (hi + 0.05) / (lo + 0.05);
  }
  const fmt = (c) => `rgba(${Math.round(c.r)},${Math.round(c.g)},${Math.round(c.b)},${+(c.a || 1).toFixed(2)})`;

  // ---- element scan --------------------------------------------------------

  const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'TEMPLATE', 'NOSCRIPT', 'SVG', 'IMG', 'VIDEO', 'CANVAS', 'INPUT', 'TEXTAREA', 'SELECT', 'OPTION', 'METER', 'PROGRESS']);
  const ratio0 = (v) => Math.abs(v) < 0.001;

  function isVisible(el) {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || cs.visibility === 'collapse') return false;
    if (cs.opacity !== '' && parseFloat(cs.opacity) < 0.05) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    if (el.closest('[hidden]') && String(el.closest('[hidden]').hidden) === 'true') return false;
    return true;
  }

  function effBg(el) {
    let node = el;
    let acc = null;
    let chain = [];
    while (node && node !== document.documentElement) {
      let cs = getComputedStyle(node);
      let bg = parseColor(cs.backgroundColor);
      if (bg && bg.a > 0) {
        chain.push({ el: node, a: bg.a });
        acc = bg.a < 1 ? composite(bg, acc) : (acc ? composite(bg, acc) : bg);
        if (acc.a >= 0.99) break;
      }
      node = node.parentElement;
    }
    if (!acc || acc.a < 0.99) {
      for (const n of [document.body, document.documentElement]) {
        const bg = parseColor(getComputedStyle(n).backgroundColor);
        if (bg) {
          acc = bg.a >= 1 ? bg : composite(bg, acc);
          if (acc.a >= 0.99) break;
        }
      }
    }
    return acc || { r: 255, g: 255, b: 255, a: 1 };
  }

  const isLarge = (cs) => {
    const px = parseFloat(cs.fontSize) || 0;
    const w = parseInt(cs.fontWeight, 10) || 400;
    return px >= 24 || (px >= 18.66 && w >= 700);
  };

  function sampleView(opts = {}) {
    const root = (typeof opts.root === 'string' ? document.querySelector(opts.root) : opts.root) || document.body;
    const view = opts.view || 'unknown';
    const theme = opts.theme || 'unknown';
    const maxFailures = opts.maxFailures || 30;
    const failures = [];
    const counts = { total: 0, skipped: 0, normalChecked: 0, largeChecked: 0, pass: 0, fail: 0 };
    const dist = { n250: 0, n200: 0, n150: 0, n100: 0 }; // ratio buckets for the report

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const seen = new Set();
    let n = walker.nextNode();
    while (n) {
      const text = (n.textContent || '').replace(/\s+/g, ' ').trim();
      if (text) {
        counts.total++;
        const el = n.parentElement;
        const key = el;
        if (seen.has(key)) { counts.skipped++; n = walker.nextNode(); continue; }
        seen.add(key);
        if (SKIP_TAGS.has(el.tagName) || !isVisible(el)) { counts.skipped++; n = walker.nextNode(); continue; }
        const cs = getComputedStyle(el);
        const fg = parseColor(cs.color);
        if (!fg) { counts.skipped++; n = walker.nextNode(); continue; }
        const bg = effBg(el);
        const r = ratio(fg, bg);
        const large = isLarge(cs);
        const required = large ? 3.0 : 4.5;
        if (r >= 5) dist.n250++;
        else if (r >= 4) dist.n200++;
        else if (r >= 3) dist.n150++;
        else dist.n100++;
        if (large) counts.largeChecked++; else counts.normalChecked++;
        if (r < required) {
          counts.fail++;
          if (failures.length < maxFailures) {
            failures.push({
              view, theme,
              text: text.slice(0, 80),
              tag: el.tagName.toLowerCase(),
              id: el.id || '',
              cls: (typeof el.className === 'string' ? el.className : '').split(' ').slice(0, 3).join('.'),
              fg: fmt(fg), bg: fmt(bg),
              ratio: +r.toFixed(2),
              required,
              large,
              px: parseFloat(cs.fontSize),
            });
          }
        } else {
          counts.pass++;
        }
      }
      n = walker.nextNode();
    }
    return { view, theme, ...counts, failureCount: counts.fail, failures, ratioDistribution: dist };
  }

  const api = {
    parseColor,
    luminance,
    ratio,
    composite,
    isLarge,
    sampleView,
    ping: () => ({ ok: true, ts: Date.now() }),
  };
  window.uxContrast = api;
  return 'uxContrast installed — call uxContrast.sampleView({...})';
})()

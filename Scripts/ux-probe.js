// ux-probe.js — page-context UX acceptance probe for the arc web UI.
//
// The instrument behind the round-2 UX hardening plan: one self-contained
// script that measures DOM churn, layout shift, scroll/stick behaviour, the
// live-turn timeline, and detail-row identity — the evidence surface every
// wave's acceptance gate reads from.
//
// usage
//   inject the file's contents into the page console (browser console tool),
//   then from the console:
//     uxProbe.arm()                 // start observers (safe to call once)
//     uxProbe.stickProbe(80)        // scroll up 80px, sample 3s of re-pin/behaviour
//     uxProbe.turnWatch()           // snapshot of live-turn/composer state right now
//     uxProbe.report()              // JSON summary + counters reset
//     uxProbe.dump()                // raw accumulated events
//
// reads only; never mutates the app's state.

(() => {
  if (window.uxProbe) return 'uxProbe already installed';

  const S = {
    armed: false,
    t0: 0,
    churn: { childList: 0, added: 0, removed: 0, charData: 0, attrs: 0 },
    churnPerSec: {},           // second bucket -> mutations
    cls: 0,
    clsWorst: 0,
    clsSources: [],
    scrollSamples: [],         // {t, top, height, pinned}
    stickRuns: [],             // {delta, repinned, drift, samples}
    liveTimeline: [],          // {t, live, cursor, composerStop}
    detachEvents: [],          // {t, tag, keyHint} for removed detail rows
    openRowsSeen: new Set(),   // identity keys of open rows observed
    openRowsDropped: 0,        // open rows that detached (dropped open-state)
    mo: null,
    scrollIv: null,
    liveIv: null,
    po: null,
  };

  const now = () => (performance.now() / 1000).toFixed(3);
  const bucket = () => Math.floor(performance.now() / 1000);
  const nearest = () => {
    // the scroll container: the element that actually scrolls the transcript
    const cands = [document.getElementById('chat-scroll'), document.getElementById('chat-inner')?.parentElement, ...document.querySelectorAll('[data-scroll]')];
    for (const el of cands) if (el && el.scrollHeight > el.clientHeight + 8) return el;
    return document.scrollingElement;
  };
  const pinned = (el) => el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  const keyHint = (node) => {
    if (!(node instanceof Element)) return String(node?.nodeName || '?');
    const key = node.getAttribute?.('data-webui-key');
    const id = node.id || '';
    const cls = (node.className || '').toString().split(' ').slice(0, 2).join('.');
    return [node.tagName.toLowerCase(), id && '#' + id, cls && '.' + cls, key && 'key=' + key].filter(Boolean).join('');
  };

  function armScroll() {
    if (S.scrollIv) clearInterval(S.scrollIv);
    S.scrollIv = setInterval(() => {
      const el = nearest();
      if (!el) return;
      S.scrollSamples.push({ t: now(), top: el.scrollTop, height: el.scrollHeight, pinned: pinned(el) });
      if (S.scrollSamples.length > 4000) S.scrollSamples.splice(0, 1000);
    }, 250);
  }

  function armChurn() {
    const root = document.getElementById('chat-inner') || document.body;
    if (S.mo) S.mo.disconnect();
    S.mo = new MutationObserver((muts) => {
      const b = bucket();
      for (const m of muts) {
        S.churnPerSec[b] = (S.churnPerSec[b] || 0) + 1;
        if (m.type === 'childList') {
          S.churn.childList++;
          S.churn.added += m.addedNodes.length;
          S.churn.removed += m.removedNodes.length;
          for (const n of m.removedNodes) {
            const el = n instanceof Element ? n.querySelector?.('details[open], [open]') : null;
            const selfOpen = n instanceof Element && n.hasAttribute?.('open');
            if (selfOpen || el) {
              S.openRowsDropped++;
              S.detachEvents.push({ t: now(), row: keyHint(n), open: true });
            }
          }
        }
        if (m.type === 'characterData') S.churn.charData++;
        if (m.type === 'attributes') S.churn.attrs++;
      }
    });
    S.mo.observe(root, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['class', 'open', 'style', 'data-webui-key'] });
  }

  function armCLS() {
    try {
      S.po = new PerformanceObserver((list) => {
        for (const e of list.getEntries()) {
          if (e.hadRecentInput) continue;
          S.cls += e.value;
          if (e.value > S.clsWorst) S.clsWorst = e.value;
          const src = (e.sources || []).map((s) => keyHint(s.node)).slice(0, 3);
          S.clsSources.push({ t: now(), v: +e.value.toFixed(4), src });
          if (S.clsSources.length > 200) S.clsSources.splice(0, 100);
        }
      });
      S.po.observe({ type: 'layout-shift', buffered: true });
    } catch (_) { /* layout-shift unsupported */ }
  }

  function armLive() {
    if (S.liveIv) clearInterval(S.liveIv);
    let last = null;
    S.liveIv = setInterval(() => {
      const live = !!document.getElementById('live-turn');
      const cursor = !!document.querySelector('.stream-cursor');
      const composerStop = !!document.querySelector('[aria-label="Stop"], .btn-stop, [data-stop]');
      const cur = `${live}|${cursor}|${composerStop}`;
      if (cur !== last) {
        S.liveTimeline.push({ t: now(), live, cursor, composerStop });
        last = cur;
        if (S.liveTimeline.length > 500) S.liveTimeline.splice(0, 200);
      }
    }, 200);
  }

  const api = {
    arm() {
      S.armed = true;
      S.t0 = performance.now();
      armChurn(); armScroll(); armCLS(); armLive();
      return 'armed';
    },
    turnWatch() {
      return {
        live: !!document.getElementById('live-turn'),
        cursor: !!document.querySelector('.stream-cursor'),
        composerStop: !!document.querySelector('[aria-label="Stop"], .btn-stop, [data-stop]'),
        innerLen: (document.getElementById('chat-inner')?.innerText || '').length,
        t: now(),
      };
    },
    // scroll up by `delta` px and sample 3s: was the scroll re-pinned (snapped
    // back) on the next push, or respected?
    async stickProbe(delta = 80, ms = 3000) {
      const el = nearest();
      if (!el) return { error: 'no scroll container' };
      const start = { top: el.scrollTop, height: el.scrollHeight };
      el.scrollTop = Math.max(0, el.scrollTop - delta);
      const after = el.scrollTop;
      const samples = [];
      const t0 = performance.now();
      await new Promise((resolve) => {
        const iv = setInterval(() => {
          samples.push({ t: +((performance.now() - t0) / 1000).toFixed(2), top: el.scrollTop, height: el.scrollHeight, pinned: pinned(el) });
          if (performance.now() - t0 > ms) { clearInterval(iv); resolve(); }
        }, 250);
      });
      const end = el.scrollTop;
      const maxTop = Math.max(...samples.map((s) => s.top));
      const run = {
        delta,
        startTop: start.top,
        heightAtStart: start.height,
        afterScrollUp: after,
        repinned: maxTop > after + 30,
        snappedBackPx: +Math.max(0, maxTop - after).toFixed(1),
        driftPx: +(end - after).toFixed(1),
        samples,
      };
      S.stickRuns.push(run);
      return run;
    },
    report() {
      const el = nearest();
      const perSec = Object.entries(S.churnPerSec).sort((a, b) => a[0] - b[0]);
      const peaks = perSec.map(([, v]) => v);
      const summary = {
        armedFor: +((performance.now() - S.t0) / 1000).toFixed(1),
        churn: {
          ...S.churn,
          note: `${(S.churn.childList + S.churn.charData + S.churn.attrs)} mutations seen; ${S.churn.childList} childList; ${S.churn.removed} nodes removed`,
        },
        churnPerSec: { buckets: perSec.length, peak: peaks.length ? Math.max(...peaks) : 0, avg: peaks.length ? +(peaks.reduce((a, b) => a + b, 0) / peaks.length).toFixed(1) : 0 },
        cls: +S.cls.toFixed(4),
        clsWorst: +S.clsWorst.toFixed(4),
        clsTopSources: S.clsSources.slice(-8),
        openRowsDropped: S.openRowsDropped,
        detachEvents: S.detachEvents.slice(-8),
        scrollNow: el ? { top: el.scrollTop, height: el.scrollHeight, pinned: pinned(el) } : null,
        liveTimeline: S.liveTimeline.slice(-24),
        stickRuns: S.stickRuns.slice(-3),
      };
      return summary;
    },
    dump() { return S; },
    reset() {
      S.churn = { childList: 0, added: 0, removed: 0, charData: 0, attrs: 0 };
      S.churnPerSec = {}; S.cls = 0; S.clsWorst = 0; S.clsSources = [];
      S.scrollSamples = []; S.stickRuns = []; S.liveTimeline = [];
      S.detachEvents = []; S.openRowsDropped = 0;
      return 'reset';
    },
    stop() {
      if (S.mo) S.mo.disconnect();
      if (S.scrollIv) clearInterval(S.scrollIv);
      if (S.liveIv) clearInterval(S.liveIv);
      if (S.po) S.po.disconnect();
      return 'stopped';
    },
  };
  window.uxProbe = api;
  return 'uxProbe installed — call uxProbe.arm()';
})()
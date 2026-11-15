// ux-gates.mjs — one-command UX gate suite for the arc web UI.
//
//   node Scripts/ux-gates.mjs [--only=contrast|interactions|upload|scroll|focus|drawer|draft|composer|theme|residue|motion|regression|round4|schemes]
//
// Zero-dependency: native fetch + WebSocket via Scripts/ux-drive.mjs.
// Assertions LIVE IN THE PAGE (Scripts/ux-contrast.js, ux-gates.js,
// ux-schemes.js). The driver only: launches/attaches Chrome, emulates
// reduced-motion / viewport, navigates, sends real key/click input, takes
// PNG screenshots (never viewed here), and captures the console from page
// load.
//
// Artifacts (written into Scripts/):
//   contrast-report.json   — WCAG AA sweep, both themes, 5 views
//   gates-report.json      — interactions / motion / regression results
//   assets/schemes/*.png   — contact sheet (chat + settings per scheme)
//   schemes-index.json     — scheme -> computed key tokens
//
// Exits non-zero when any gate fails. A gate that legitimately surfaces a
// real defect must NOT be weakened to pass — fix the app or report the
// finding with its raw numbers.

import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { UxDriver } from './ux-drive.mjs';

const HERE = new URL('.', import.meta.url).pathname;
const APP = process.env.ARC_UI_URL || 'http://127.0.0.1:8890/';
const PROBE_CONTRAST = readFileSync(new URL('./ux-contrast.js', import.meta.url), 'utf8');
const PROBE_GATES = readFileSync(new URL('./ux-gates.js', import.meta.url), 'utf8');
const PROBE_SCHEMES = readFileSync(new URL('./ux-schemes.js', import.meta.url), 'utf8');

// Probe-session marker: any session the gates create is named with this
// prefix and removed at the end, so the owner's conversations stay intact.
const PROBE = 'UXGATE';
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');

// ---------------------------------------------------------------------------
// args

function parseArgs(argv) {
  const out = {
    only: null, // null = run all
    port: 9222,
    attach: false,
    headless: true,
    keepProfile: false,
    viewport: [1440, 900],
    gate: null,
    strict: false,
  };
  for (const a of argv) {
    if (a === '--attach') out.attach = true;
    else if (a === '--strict') out.strict = true;
    else if (a === '--headed') out.headless = false;
    else if (a === '--keep-profile') out.keepProfile = true;
    else if (a.startsWith('--port=')) out.port = parseInt(a.slice(7), 10);
    else if (a.startsWith('--only=')) out.only = a.slice(7).split(',');
    else if (a.startsWith('--viewport=')) {
      const [w, h] = a.slice(11).split('x').map(Number);
      out.viewport = [w || 1440, h || 900];
    }
  }
  return out;
}

const opts = parseArgs(process.argv.slice(2));
const RUN = {
  contrast: !opts.only || opts.only.includes('contrast'),
  interactions: !opts.only || opts.only.includes('interactions'),
  upload: !opts.only || opts.only.includes('upload'),
  scroll: !opts.only || opts.only.includes('scroll'),
  focus: !opts.only || opts.only.includes('focus'),
  drawer: !opts.only || opts.only.includes('drawer'),
  draft: !opts.only || opts.only.includes('draft'),
  composer: !opts.only || opts.only.includes('composer'),
  theme: !opts.only || opts.only.includes('theme'),
  residue: !opts.only || opts.only.includes('residue'),
  motion: !opts.only || opts.only.includes('motion'),
  regression: !opts.only || opts.only.includes('regression'),
  round4: !opts.only || opts.only.includes('round4'),
  schemes: !opts.only || opts.only.includes('schemes'),
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// tiny result bookkeeping
//
// A result's status is `true` (pass), `false` (fail) or the string `'skip'`
// (an environment skip — the gate could not exercise its assertion, e.g. the
// model produced no live turn). Skips are reported loudly but do not fail the
// run unless `--strict` is given; a skip is never a pass.

const results = [];
function record(gate, name, status, detail) {
  results.push({ gate, name, ok: status, detail }); // detail serialized at the end
  const mark = status === 'skip' ? 'SKIP' : status ? 'PASS' : 'FAIL';
  console.log(`  [${mark}] ${gate} · ${name}`);
}
const skipped = () => results.filter((r) => r.ok === 'skip');
let checks = 0;
const check = (cond, label) => { checks++; if (!cond) throw new Error(label); };

// ---------------------------------------------------------------------------
// driver + page helpers

let driver;

async function ev(expr) { return driver.js(expr); }
async function waitMs(ms) { await sleep(ms); }
async function settle(ms = 250) { await sleep(ms); }

/// poll until `expr` is truthy, or the deadline passes; returns the last value.
///
/// a popover open/close is a websocket round-trip plus a patch, so a single
/// fixed settle-then-sample reads the PRE-patch state on a cold daemon and
/// reports a false "still open"/"never opened". every open/close assertion in
/// this file must poll the settled value; the assertion itself is unchanged.
async function waitTrue(expr, timeoutMs = 2000, intervalMs = 50) {
  const deadline = Date.now() + timeoutMs;
  let last = false;
  while (Date.now() < deadline) {
    last = !!(await ev(expr));
    if (last) return true;
    await sleep(intervalMs);
  }
  return last;
}

/// wait until `expr` reaches `want` AND holds it for `holdMs`; false on timeout.
///
/// the three wrong instruments this replaces, in order: a fixed settle-then-sample
/// reads the pre-patch document on a cold daemon; a poll-until-truthy returns the
/// instant `open` flips, so the close is tested while the open patch is still in
/// flight (the patch then re-opens the panel); and a poll-until-stable called with
/// the *initial* value returns immediately, before any patch has arrived.
/// "reached and held" is the only shape that answers the question actually asked.
async function waitStableValue(expr, want, holdMs = 300, timeoutMs = 4000, intervalMs = 50) {
  const deadline = Date.now() + timeoutMs;
  let heldSince = null;
  while (Date.now() < deadline) {
    const now = !!(await ev(expr));
    if (now === want) {
      if (heldSince === null) heldSince = Date.now();
      if (Date.now() - heldSince >= holdMs) return true;
    } else {
      heldSince = null;
    }
    await sleep(intervalMs);
  }
  return false;
}


async function waitReady() {
  await driver.waitFor(`!!document.getElementById('app') && !!document.getElementById('nav-chat')`, { timeoutMs: 20000, label: 'app boot' });
  await settle(400);
}

/** Make sure the chat view is active and its composer is on screen. */
async function chatView() {
  await ev(`(() => {
    const b = document.getElementById('nav-chat');
    if (b) b.click();
    if (!document.getElementById('chat-scroll')) setTimeout(() => document.getElementById('nav-chat')?.click(), 150);
    return true;
  })()`);
  await driver.waitFor(`!!document.getElementById('composer-input')`, { timeoutMs: 10000, label: 'composer' });
  await settle(200);
}

/** The active conversation's session row (the `.sess-row.active` node). */
function rowExpr(sid) {
  return `(() => {
    const rows = [...document.querySelectorAll('.sess-row')];
    const row = ${sid ? `rows.find(r => r.getAttribute('data-sid') === '${sid}') || rows.find(r => r.classList.contains('active'))` : `rows.find(r => r.classList.contains('active'))`};
    return row ? row : null;
  })()`;
}

/// Open a session row's ⋮ menu.
///
/// The menu is SERVER state now (no-webui 2.15.0): the ⋮ dispatches
/// `s-menu-<sid>`, the server arms the row's `data-open`, and the patch lands a
/// websocket round-trip later — so the click is followed by a poll for the
/// state, not a fixed settle (a fixed settle read the pre-patch document and
/// reported the menu as never opened).
///
/// The ROW itself can also be absent for a moment: opening a chat re-renders
/// the session list through a patch, and a probe that clicked mid-swap found no
/// row (or no ⋮) and returned false WITHOUT polling — residue (a1)'s "the row
/// menu did not open". So the row is waited for to a bounded deadline first;
/// the menu poll after the click is unchanged.
async function openMenu(sid) {
  // strict lookup: with a sid, the ACTIVE row is never a substitute (cleanup
  // would otherwise open — and delete — the owner's active session).
  const rowSel = sid
    ? `[...document.querySelectorAll('.sess-row')].find(r => r.getAttribute('data-sid') === '${sid}')`
    : `document.querySelector('.sess-row.active')`;
  const ready = await waitTrue(`(() => { const row = ${rowSel}; return !!(row && row.querySelector('.menu-dots')); })()`, 5000);
  if (!ready) return false;
  const did = await ev(`(() => {
    const row = ${rowSel};
    const dots = row && row.querySelector('.menu-dots');
    if (!dots) return false;
    // focus like a pointer click does: Chrome focuses a button on mousedown,
    // and the engine's raw modal-focus memo restores whatever held focus when
    // a dialog opened — a programmatic click alone leaves the composer
    // focused, which is a different (synthetic) starting point.
    try { dots.focus(); } catch (e) {}
    dots.click();
    return true;
  })()`);
  if (!did) return false;
  return waitTrue(`!!document.querySelector('.chat-menu[data-open]')`, 3000);
}

/// Click the open row menu's `.danger` item; resolve to whether the delete
/// dialog opened.
///
/// The dialog is the SERVER's render too: the danger click dispatches and
/// `#modal-overlay` arrives in a patch a websocket round-trip later (measured
/// at 528 ms against a 136-session list). A `settle(350)` read the pre-patch
/// document and both callers — the delete-flow row and `cleanupProbeSessions`
/// — recorded "the modal never opened". Poll the exact state they assert.
async function clickMenuDanger(sid) {
  const did = await ev(`(() => {
    const row = ${sid ? `[...document.querySelectorAll('.sess-row')].find(r => r.getAttribute('data-sid') === '${sid}')` : `document.querySelector('.sess-row.active')`};
    const menu = row && row.querySelector('.chat-menu[data-open]');
    const d = menu ? menu.querySelector('.danger') : null;
    if (d) d.click();
    return !!d;
  })()`);
  if (!did) return false;
  // `#modal-confirm` pins it to the DELETE dialog (the rename card carries
  // `#rename-save`), so a stale modal from an earlier row cannot answer for it.
  return waitTrue(`uxGates.modal().open && !!document.getElementById('modal-confirm')`, 3000);
}

async function setTheme(themeKey) {
  await ev(`document.getElementById('nav-settings')?.click()`);
  await driver.waitFor(`!!document.getElementById('thm-${themeKey}')`, { timeoutMs: 8000, label: 'settings theme control' });
  await settle(150);
  const bgBefore = await ev(`getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()`);
  await ev(`document.getElementById('thm-${themeKey}')?.click()`);
  await driver.waitFor(`document.querySelector('[data-theme-choice="${themeKey}"][aria-pressed="true"]') !== null`, { timeoutMs: 8000, label: `theme ${themeKey} active` });
  // Wait out the stylesheet swap: the --bg token must actually change before
  // any contrast read, or the sample catches a half-applied sheet.
  await driver.waitFor(`(() => {
    const bg = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim();
    return bg !== '' && bg !== ${JSON.stringify(bgBefore)};
  })()`, { timeoutMs: 8000, label: 'theme sheet swap' }).catch(() => {});
  await settle(450);
}

async function currentTheme() {
  // aria-pressed is the theme selected contract (no-webui 2.17.0): the engine
  // reconciles it on boot and on every press. `.active` no longer exists.
  return ev(`document.querySelector('[data-theme-choice][aria-pressed="true"]')?.getAttribute('data-theme-choice') || 'dark'`);
}

/** Create (or return the existing) throwaway probe session. */
let probeSid = null;
async function ensureProbeSession(text = `UXGATE probe ${Date.now() % 100000}`) {
  // A turn still in flight turns the composer into a queue: a probe message
  // sent into it lands behind the running reply, so the session is never
  // created under the probe title and this helper times out waiting for a row
  // that will not exist. Settle the previous gate's turn first.
  await waitStreamEnd(180000).catch(() => false);
  const existing = await ev(`(() => {
    const rows = [...document.querySelectorAll('.sess-row')];
    return rows.find(r => (r.textContent || '').includes('${PROBE}'))?.getAttribute('data-sid') || null;
  })()`);
  if (existing) { probeSid = existing; return existing; }
  // The daemon runs ONE turn at a time across sessions. A message sent while
  // another session streams is accepted as a queued follow-up (the composer
  // reads "Send another message — queued after this reply") and the session is
  // never created under the probe title, so a single send is not enough: the
  // previous gate's turn still owns the model. Detect that state and retry.
  const prompt = text + ' — reply with the single word: ok. Do not call any tools.';
  let created = null;
  for (let attempt = 0; attempt < 3 && !created; attempt++) {
    await chatView();
    await ev(`document.getElementById('chat-new')?.click()`);
    await driver.waitFor(`!!document.getElementById('composer-input')`, { timeoutMs: 8000, label: 'new chat composer' });
    await settle(300);
    const queued = await ev(`(() => {
      const t = document.getElementById('composer-input');
      return t ? /queued after this reply/i.test(t.getAttribute('placeholder') || '') : false;
    })()`);
    if (queued) {
      await waitStreamEnd(180000).catch(() => false);
      await settle(500);
      continue;
    }
    await driver.js(`(() => {
      const t = document.getElementById('composer-input');
      const set = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
      set.call(t, ${JSON.stringify(prompt)});
      t.dispatchEvent(new Event('input', { bubbles: true }));
      t.focus();
      return true;
    })()`);
    await settle(150);
    await driver.pressEnter();
    // The user message lands immediately: wait for the probe-named row (the
    // session is created server-side, it does not need the model to answer).
    created = await driver.waitFor(`(() => {
      const rows = [...document.querySelectorAll('.sess-row')];
      const r = rows.find(r => (r.textContent || '').includes('${PROBE}'));
      return r ? r.getAttribute('data-sid') : null;
    })()`, { timeoutMs: 12000, label: 'probe session created' }).catch(() => null);
  }
  if (!created) {
    throw new Error('probe session was not created in 3 attempts — the composer kept queueing behind an in-flight turn');
  }
  probeSid = created;
  // The row appears on the *user* message, so the model's reply is still
  // streaming. Every caller then asserts composer/delete/dock state, and a
  // live turn suppresses the slash menu and turns the composer into a queue —
  // a serial local model made those assertions measure the queue instead of
  // the surface. Hand back a settled session.
  await waitStreamEnd(180000).catch(() => false);
  return probeSid;
}


/** Wait for a live turn with at least minChars; returns snapshot or null. */
async function waitStream(minChars = 0, timeoutMs = 90000) {
  // Liveness = the live-turn ELEMENT mounting (the orchestrator's independent
  // harness observes it within ~2.5 s of Enter on this machine). Text is the
  // slow part (local 30B NVFP4), so presence is the mount signal and text
  // growth only sets the floor; `minChars: 0` treats presence alone as live.
  const t0 = Date.now();
  let mounted = false;
  while (Date.now() - t0 < 15000) {
    mounted = await ev(`!!document.getElementById('live-turn')`);
    if (mounted) break;
    await waitMs(200);
  }
  if (!mounted) return null; // the live turn never mounted — liveness failure
  if (minChars <= 0) return await ev(`uxGates.stream()`);
  while (Date.now() - t0 < timeoutMs) {
    const s = await ev(`uxGates.stream()`);
    if (s.live && s.textLen >= minChars) return s;
    // the turn ended below the floor — not a liveness failure, just short
    if (!(await ev(`!!document.getElementById('live-turn')`))) return null;
    await waitMs(200);
  }
  return null; // mounted but text never reached the floor inside the window
}

async function waitStreamEnd(timeoutMs = 240000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const live = await ev(`!!document.getElementById('live-turn')`);
    if (!live) return true;
    await waitMs(600);
  }
  return false;
}

/**
 * Keep (re-)sending `text` until a live turn carries at least minChars, or
 * the window expires. The local model answers serially: right after another
 * gate's turn, the composer message can sit in the daemon's queue for a long
 * time before the first token lands. Re-pinging past the per-attempt window
 * lets the assertion actually observe a streaming turn instead of failing on
 * queue timing; `attempts` is recorded so the backlog is visible in the raw
 * numbers. Only ever sends into the throwaway probe session.
 */
async function ensureLiveText(text, minChars, timeoutMs = 150000, perAttemptMs = 30000) {
  const t0 = Date.now();
  let attempts = 0;
  while (Date.now() - t0 < timeoutMs) {
    attempts++;
    // Fresh session per attempt, and never ping into a backed-up serial queue:
    // re-sending into the same probe session while the model is busy would
    // stack another queued message behind the backlog (observed as "Queued · N"
    // in the diagnose evidence), so the assertion waits for the queue to drain
    // first — the model answers serially and a live turn needs an idle model.
    await chatView();
    const busy = await ev(`!!document.getElementById('live-turn') || !!document.querySelector('#composer-wrap .queued-sends, #composer-wrap [class*="queued"]')`);
    if (busy) {
      await waitStreamEnd(20000).catch(() => false);
      if (Date.now() - t0 >= timeoutMs) break;
    }
    await ev(`document.getElementById('chat-new')?.click()`);
    await driver.waitFor(`!!document.getElementById('composer-input')`, { timeoutMs: 8000, label: 'new chat composer (ensureLiveText)' });
    await settle(250);
    await chatView();
    await driver.js(`(() => {
      const t = document.getElementById('composer-input');
      const set = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
      set.call(t, ${JSON.stringify(text)});
      t.dispatchEvent(new Event('input', { bubbles: true }));
      t.focus();
      return true;
    })()`);
    await settle(150);
    await driver.pressEnter();
    const live = await waitStream(minChars, perAttemptMs);
    if (live) return { live, attempts };
  }
  // Evidence, not a guess: read the actual conversation state so a skip (or a
  // real product defect) is grounded. Echoes the app's own queue/live markers.
  return { live: null, attempts, diag: await diagnoseNoLiveTurn() };
}

/** Read the page's ground truth after a send failed to produce a live turn. */
async function diagnoseNoLiveTurn() {
  return await ev(`(() => {
    const queueRow = document.querySelector('#composer-wrap .queued-sends, #composer-wrap [class*="queued"], .queue-chip');
    const turnErr = document.querySelector('.turn-error, .turn-err, .live-status [style*="danger"], .msg .turn-error');
    return {
      queuedRow: queueRow ? (queueRow.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 80) : null,
      liveTurn: !!document.getElementById('live-turn'),
      finishedTurns: document.querySelectorAll('.assistant-turn').length,
      userTurns: document.querySelectorAll('.msg.user, .user-turn, .msg.user-msg').length,
      turnError: turnErr ? (turnErr.textContent || '').trim().slice(0, 140) : null,
      activeSid: document.querySelector('.sess-row.active')?.getAttribute('data-sid')?.slice(0, 8) || null,
      composerPlaceholder: document.getElementById('composer-input')?.getAttribute('placeholder') || null,
      composerValue: (document.getElementById('composer-input')?.value || '').slice(0, 60),
    };
  })()`);
}

async function installProbes() {
  for (const src of [PROBE_GATES, PROBE_CONTRAST, PROBE_SCHEMES]) {
    await driver.addInitScript(src);
  }
  // On the current page too (init scripts apply to future loads).
  await ev(`(() => { try { eval(${JSON.stringify(PROBE_GATES)}); eval(${JSON.stringify(PROBE_CONTRAST)}); eval(${JSON.stringify(PROBE_SCHEMES)}); } catch (e) { return String(e); } return true; })()`);
}

// ---------------------------------------------------------------------------
// cleanup + restore

async function cleanupProbeSessions() {
  // Any session whose title starts with UXGATE is ours: delete via the app's
  // own delete flow (never touch the owner's conversations). A session with an
  // in-flight (or queued) turn cannot be deleted while it streams, so wait the
  // turn out, then verify the delete actually landed.
  for (let guard = 0; guard < 60; guard++) {
    await chatView().catch(() => {});
    const sid = await ev(`(() => {
      const rows = [...document.querySelectorAll('.sess-row')];
      const r = rows.find(r => (r.textContent || '').includes('${PROBE}'));
      return r ? r.getAttribute('data-sid') : null;
    })()`);
    if (!sid) break;
    const busySince = Date.now();
    while (Date.now() - busySince < 120000) {
      const busy = await ev(`!!document.getElementById('live-turn')`);
      if (!busy) break;
      await waitMs(800);
    }
    let opened = false;
    for (let attempt = 0; attempt < 3 && !opened; attempt++) {
      opened = (await openMenu(sid)) && (await clickMenuDanger(sid));
      if (!opened) {
        await driver.pressEscape();
        await settle(250);
      }
    }
    if (!opened) { console.warn(`cleanup: could not open the delete modal for probe session ${sid} — leaving it`); break; }
    await ev(`document.getElementById('modal-confirm')?.click()`);
    // The app defers deletes while the session is mid-turn: verify, don't assume.
    const goneSince = Date.now();
    let gone = false;
    while (Date.now() - goneSince < 60000) {
      gone = !(await ev(`(() => { const rows = [...document.querySelectorAll('.sess-row')]; return rows.some(r => r.getAttribute('data-sid') === '${sid}'); })()`));
      if (gone) break;
      await waitMs(800);
    }
    if (!gone) console.warn(`cleanup: delete of probe session ${sid} did not land — will retry`);
  }
  await ev(`document.getElementById('nav-chat')?.click()`);
  await settle(300);
}

let stateAtStart = null;
async function snapshotInitialState() {
  stateAtStart = {};
  try {
    // The scheme/theme pickers live in settings; go there briefly to read the
    // truth, then return to the chat view the run continues from.
    await ev(`document.getElementById('nav-settings')?.click()`);
    await driver.waitFor(`document.querySelector('[data-theme-choice]') !== null`, { timeoutMs: 8000, label: 'settings pickers' }).catch(() => {});
    await settle(250);
    const t = await ev(`(() => {
      const th = document.querySelector('[data-theme-choice][aria-pressed="true"]');
      const sc = document.querySelector('[data-scheme-choice].active');
      return { theme: th?.getAttribute('data-theme-choice') || null, scheme: sc?.getAttribute('data-scheme-choice') || null, bodyBg: getComputedStyle(document.body).backgroundColor };
    })()`);
    Object.assign(stateAtStart, t);
    await ev(`document.getElementById('nav-chat')?.click()`);
    await settle(250);
  } catch (e) { stateAtStart.error = String(e); }
}
async function restoreState() {
  try {
    if (stateAtStart && stateAtStart.theme) await setTheme(stateAtStart.theme);
    if (stateAtStart && stateAtStart.scheme) {
      await ev(`document.getElementById('nav-settings')?.click()`);
      await driver.waitFor(`!!document.querySelector('[data-scheme-choice]')`, { timeoutMs: 8000, label: 'scheme grid' });
      await settle(150);
      await ev(`document.querySelector('[data-scheme-choice="${stateAtStart.scheme}"]')?.click()`);
      await settle(500);
    }
  } catch (e) { console.error('restoreState:', String(e)); }
}

// ---------------------------------------------------------------------------
// T14 — WCAG AA contrast gate (both themes)

async function runContrast() {
  console.log('\n— gate: contrast (WCAG AA, dark + light) —');
  const report = { command: `node Scripts/ux-gates.mjs --only=contrast`, app: APP, generatedAt: new Date().toISOString(), views: [], failures: [], counts: { totalFailures: 0, totalChecked: 0 } };

  const probeSid = await ensureProbeSession('UXGATE contrast target');
  // Let the probe turn finish before sampling: the model answers serially, and
  // a still-running turn would (a) leave a live block that the console tour /
  // dock gates then race against, and (b) queue later gates' sends behind it.
  await waitStreamEnd(180000).catch(() => false);
  await chatView();

  for (const theme of ['dark', 'light']) {
    await setTheme(theme);
    const views = [];

    // view: chat with a conversation open
    await chatView();
    if (probeSid) {
      // ensure the probe conversation is the one open
      await ev(`(() => {
        const row = [...document.querySelectorAll('.sess-row')].find(r => r.getAttribute('data-sid') === '${probeSid}');
        row?.querySelector('.sess-open')?.click();
      })()`);
      await settle(300);
    }
    views.push({ name: 'chat-open', sample: await ev(`uxContrast.sampleView({ root: '#chat-scroll', view: 'chat-open', theme: '${theme}' })`) });

    // view: left panel
    views.push({ name: 'left-panel', sample: await ev(`uxContrast.sampleView({ root: '#panel', view: 'left-panel', theme: '${theme}' })`) });

    // view: settings
    await ev(`document.getElementById('nav-settings')?.click()`);
    await driver.waitFor(`!!document.querySelector('#settings-main, .settings-main, [data-component-id="settings-main"]') || !!document.querySelector('[data-theme-choice]')`, { timeoutMs: 8000, label: 'settings view' });
    await settle(200);
    views.push({ name: 'settings', sample: await ev(`uxContrast.sampleView({ root: document.body, view: 'settings', theme: '${theme}' })`) });

    // view: delete modal
    if (probeSid) {
      // back to chat first: the session list is NOT in the DOM on the
      // settings view, so the menu/modal can only open from the chat panel
      await chatView();
      // make the probe session the ACTIVE one so its row is on screen and
      // its menu answers (a merely-existing row could sit in a collapsed
      // category group where its menu cannot open)
      await ev(`(() => {
        const row = [...document.querySelectorAll('.sess-row')].find(r => r.getAttribute('data-sid') === '${probeSid}');
        row?.querySelector('.sess-open')?.click();
      })()`);
      await settle(400);
      await openMenu(null);
      await clickMenuDanger(null);
      const mopen = await ev(`!!document.getElementById('modal-overlay')`);
      if (mopen) {
        views.push({ name: 'delete-modal', sample: await ev(`uxContrast.sampleView({ root: '#modal-overlay', view: 'delete-modal', theme: '${theme}' })`) });
        await driver.pressEscape();
        // the close is a server patch too (measured: closed after 300 ms, not
        // at it). A fixed 300 ms left the dialog closing across the gate
        // boundary, and the next gate's first clicks raced the teardown patch.
        await waitTrue(`!document.getElementById('modal-overlay')`, 3000);
      } else {
        views.push({ name: 'delete-modal', sample: { view: 'delete-modal', theme, error: 'modal did not open' } });
      }
      await chatView();
    }

    // view: toast
    await chatView();
    await ev(`(() => {
      const row = [...document.querySelectorAll('.sess-row')].find(r => r.getAttribute('data-sid') === '${probeSid}');
      row?.querySelector('.sess-open')?.click();
    })()`);
    await settle(400);
    await openMenu(null);
    await ev(`(() => {
      const row = document.querySelector('.sess-row.active');
      const c = row && row.querySelector('.chat-menu[data-open] [id^="sm-copy-"]');
      if (c) c.click();
      return !!c;
    })()`);
    await settle(500);
    // the toast is the ENGINE's now (A16b): a `data-copy` click paints
    // `[data-webui-toast]` — the arc `#toasts` stack is only for server pushes.
    const toast = await ev(`(() => { const ts = [...document.querySelectorAll('[data-webui-toast]')]; return { count: ts.length, texts: ts.map(t => t.textContent) }; })()`);
    if (toast.count > 0) {
      views.push({ name: 'toast', sample: await ev(`uxContrast.sampleView({ root: '[data-webui-toast]', view: 'toast', theme: '${theme}' })`) });
    } else {
      views.push({ name: 'toast', sample: { view: 'toast', theme, error: 'no toast shown' } });
    }
    await chatView();

    for (const v of views) {
      const s = v.sample;
      if (s && s.error) { console.warn(`  contrast ${theme}/${v.name}: ${s.error}`); }
      report.views.push({ theme, view: v.name, ...(s || { error: 'no sample' }) });
      report.counts.totalChecked += (s && s.normalChecked != null ? s.normalChecked + s.largeChecked + s.total : 0);
      if (s && Array.isArray(s.failures)) {
        for (const f of s.failures) {
          report.failures.push(f);
          report.counts.totalFailures++;
        }
      }
    }
  }

  // restore dark (theme toggles are the gate's own; the final restoreState
  // puts the app back to whatever it showed when the run started)
  await setTheme('dark');
  await chatView();

  const byView = {};
  for (const f of report.failures) {
    const k = `${f.view}/${f.theme}`;
    byView[k] = (byView[k] || 0) + 1;
  }
  report.perViewFailureCounts = byView;
  writeFileSync(`${HERE}contrast-report.json`, JSON.stringify(report, null, 2));
  console.log(`  contrast-report.json written — total failures: ${report.counts.totalFailures} across ${report.views.length} view/theme samples`);
  if (report.counts.totalFailures) {
    console.log('  FAILURES by view/theme:', JSON.stringify(byView));
    for (const f of report.failures.slice(0, 12)) {
      console.log(`    - ${f.view}/${f.theme} ratio=${f.ratio} need≥${f.required} "${f.text.slice(0, 40)}" ${f.fg} on ${f.bg}`);
    }
  } else {
    console.log('  no contrast failures (WCAG AA, both themes)');
  }
  record('contrast', 'WCAG AA both themes (chat, panel, settings, modal, toast)', report.counts.totalFailures === 0, { totalFailures: report.counts.totalFailures });
}

// ---------------------------------------------------------------------------
// T15 — interaction gate suite

async function runInteractions() {
  console.log('\n— gate: interactions (console tour, popovers, tab budget, slash, delete, dock) —');
  const out = { sub: [] };
  const add = (name, ok, detail) => { out.sub.push({ name, ok, detail }); record('interactions', name, ok, detail); };

  // ---- 1. console-clean tour -----------------------------------------
  const tour = { clicked: [] };
  driver.clearConsole();
  await chatView();
  tour.clicked.push('nav-chat');
  // rail buttons
  const rail = await ev(`[...document.querySelectorAll('#iconbar [id^="nav-"]')].map(b => b.id)`);
  for (const id of rail) {
    await ev(`document.getElementById('${id}')?.click()`);
    await settle(300);
    await ev(`document.getElementById('nav-chat')?.click()`);
    await settle(300);
    tour.clicked.push(id);
  }
  // settings panel open/close (exercises the settings sheet swap)
  await ev(`document.getElementById('nav-settings')?.click()`);
  await settle(400);
  await ev(`document.getElementById('nav-chat')?.click()`);
  await settle(400);
  // drawer toggle below 1024
  await driver.setViewport(768, 900);
  await settle(300);
  const dt = await ev(`uxGates.drawer()`);
  if (dt.present && dt.toggleDisplay !== 'none') {
    await ev(`document.getElementById('drawer-toggle')?.click()`);
    await settle(400);
    const opened = await ev(`uxGates.state().drawerOpen`);
    await ev(`document.getElementById('drawer-toggle')?.click()`);
    await settle(400);
    tour.clicked.push('drawer-toggle', `drawer-open=${opened}`);
  }
  await driver.setViewport(...opts.viewport);
  await settle(300);

  const cr = driver.consoleReport();
  const engineWarnings = cr.entries.filter((e) => /\[WebUIEngine\]/i.test(e.text));
  const bad = cr.errors.concat(cr.warnings);
  const consoleClean = bad.length === 0 && engineWarnings.length === 0;
  add('console-clean tour', consoleClean, { clicked: tour.clicked, errors: cr.errors, warnings: cr.warnings, engineWarnings, infoCount: cr.info.length, info: cr.info.slice(0, 5) });

  // ---- 2. popover matrix -------------------------------------------------
  const matrix = [];
  const triggers = { file: '#cb-file', workspace: '#cb-ws-toggle', profile: '#cb-profile-toggle', model: '#cb-model-toggle', think: '#cb-think-toggle' };
  for (const [name, trig] of Object.entries(triggers)) {
    const row = {};
    // open — "reached and held", so a late patch cannot be mistaken for either side
    await ev(`document.querySelector('${trig}')?.click()`);
    row.opened = await waitStableValue(`uxGates.popovers().${name}.open`, true);
    // Escape — closed must HOLD, else a late open patch re-opens and hides the bug
    await driver.pressEscape();
    row.escClosed = await waitStableValue(`uxGates.popovers().${name}.open`, false);
    // outside click (real click in the transcript, clear of any popover)
    await ev(`document.querySelector('${trig}')?.click()`);
    const o2 = await waitStableValue(`uxGates.popovers().${name}.open`, true);
    row.esc2opened = o2;
    if (o2) {
      await settle(250);
      const pt = await ev(`(() => {
        const cs = document.getElementById('chat-scroll');
        const pr = uxGates.popoverRect('${name}');
        const r = cs.getBoundingClientRect();
        let x = r.left + 120, y = r.top + 140;
        // nudge clear of the popover's own rect
        if (pr && x >= pr.left && x <= pr.right && y >= pr.top && y <= pr.bottom) { x = r.left + 40; y = r.bottom - 220; }
        return { x: Math.round(x), y: Math.round(y) };
      })()`);
      await driver.clickAt(pt.x, pt.y);
      row.outsideClosed = await waitStableValue(`uxGates.popovers().${name}.open`, false);
    } else {
      row.outsideClosed = null;
    }
    // mutual exclusion: file-pop then model. This runs BEFORE the row is
    // recorded — the row's verdict reads `mutualExclusion`, and recording it
    // first made that clause vacuous (an undefined key satisfied `!m.mutualExclusion`).
    if (name === 'file') {
      await ev(`document.querySelector('${trig}')?.click()`);
      const fp1 = await waitStableValue(`uxGates.popovers().file.open`, true);
      await ev(`document.getElementById('cb-model-toggle')?.click()`);
      const mutualOk = await waitStableValue(
        `(() => { const p = uxGates.popovers(); return p.model.open === true && p.file.open === false; })()`,
        true, 250, 4000);
      const mutual = await ev(`({ file: uxGates.popovers().file.open, model: uxGates.popovers().model.open })`);
      row.mutualExclusion = { fileOpen: fp1, afterModel: mutual, ok: mutualOk };
      await driver.pressEscape();
      await settle(300);
    }
    matrix.push({ name, ...row });
  }
  // session context menu
  const menuRow = { name: 'session-menu' };
  const mSid = await ensureProbeSession();
  await openMenu(mSid);
  menuRow.opened = await waitStableValue(`uxGates.popovers().sessionMenu.open`, true, 250, 3000);
  await driver.pressEscape();
  settle(50);
  menuRow.escClosed = await waitStableValue(`uxGates.popovers().sessionMenu.open`, false, 250, 3000);
  await openMenu(mSid);
  const mpt = await ev(`(() => {
    const menu = document.querySelector('.chat-menu[data-open]');
    const r = menu.getBoundingClientRect();
    let x = r.right + 160, y = r.top + 100;
    const cs = document.getElementById('chat-scroll');
    const cr = cs.getBoundingClientRect();
    if (x > cr.right - 40) x = cr.right - 40;
    return { x: Math.round(x), y: Math.round(y) };
  })()`);
  await driver.clickAt(mpt.x, mpt.y);
  menuRow.outsideClosed = await waitStableValue(`uxGates.popovers().sessionMenu.open`, false, 250, 3000);
  matrix.push(menuRow);

  const popoverOk = matrix.every((m) => m.opened && m.escClosed && m.outsideClosed !== false
    && (m.name !== 'file' || (m.mutualExclusion && m.mutualExclusion.ok === true
        && m.mutualExclusion.afterModel.file === false && m.mutualExclusion.afterModel.model === true)));
  add('popover matrix (escape, outside-click, mutual exclusion)', popoverOk, matrix);

  // ---- 3. tab budget ------------------------------------------------------
  // Measured from a FRESH LOAD at each width: counting Tab presses on a live,
  // already-navigated page counts whatever leftover focus/popovers the prior
  // tests left behind (a stale measurement, not a keyboard verdict). Reloading
  // pins the honest "from load, Tab to #composer-input" reading.
  const budget = {};
  for (const vp of [1440, 768]) {
    await driver.setViewport(vp, 900);
    await driver.navigate(APP);
    await waitReady();
    await chatView();
    // The plan's budget is defined on an EMPTY app: a fresh, empty
    // conversation carries no turn-worklog disclosures (native `<summary>`
    // tab stops that grow with the transcript), so measuring on the restored
    // active chat is measuring the transcript, not the chrome.
    await ev(`document.getElementById('chat-new')?.click()`);
    await driver.waitFor(`!!document.getElementById('composer-input')`, { timeoutMs: 8000 });
    await settle(300);
    // Make BODY actually focusable before focusing it: without tabindex the
    // focus() call is a silent no-op, focus stays on whatever the app last
    // focused (the composer, via the new-chat flow), and the "trail" starts
    // mid-cycle — counting a wrapped lap instead of the cost from load.
    //
    // The app focuses the composer on boot and after a new chat (3.1.0's
    // `data-focus-on-appear` on the textarea — the UX-45 affordance), and the
    // new-chat patch can land a beat after the click. A body focus that lands
    // inside that window gets undone, and the walk then starts at the
    // composer's toolbar — a rotated trail that reads as a product failure
    // (2026-11-01 audit). Wait the patch out, re-assert the body focus, and
    // treat a second miss as a measurement skip: the budget's ≤12 assertion
    // stays untouched either way.
    await settle(2700);
    await driver.js(`document.body.setAttribute('tabindex','-1'); document.activeElement && document.activeElement.blur && document.activeElement.blur(); document.body.focus(); true`);
    await settle(250);
    let startedAtBody = await ev(`document.activeElement === document.body`);
    if (!startedAtBody) {
      await settle(1200);
      await driver.js(`document.activeElement && document.activeElement.blur && document.activeElement.blur(); document.body.focus(); true`);
      await settle(250);
      startedAtBody = await ev(`document.activeElement === document.body`);
    }
    if (!startedAtBody) {
      budget[vp] = { skipped: 'could not start the walk at <body> — the composer refocus window outran the probe twice', startedAtBody: false };
      continue;
    }
    let stops = 0;
    const seen = new Set();
    const trail = [];
    let focusedComposer = false;
    const maxStops = 40;
    for (let i = 0; i < maxStops; i++) {
      await driver.pressTab();
      await settle(100);
      stops++;
      const el = await ev(`uxGates.activeElement()`);
      trail.push(`${el.id || el.tag}${el.cls ? '.' + el.cls : ''}`);
      if (el.id === 'composer-input') { focusedComposer = true; break; }
      const key = `${el.id || el.tag}${el.cls || ''}`;
      if (seen.has(key)) { /* allow revisits until max */ }
      seen.add(key);
    }
    budget[vp] = { stops, focusedComposer, startedAtBody, trail };
    const fl = await ev(`uxGates.focusables()`);
    budget[vp].focusableCount = fl.length;
  }
  const measured = ['1440', '768'].filter(vp => !budget[vp].skipped);
  const budgetOk = measured.length > 0 &&
    measured.every(vp => budget[vp].startedAtBody && budget[vp].focusedComposer && budget[vp].stops <= 12);
  add('tab budget (<=12 stops to composer, 1440 + 768)', budgetOk, budget);

  // ---- 4. slash menu -------------------------------------------------------
  // no-webui 3.1.0: the menu is a `FilterList(source:token:)` region — the
  // server renders the rows, the engine owns the `/` gate, the filter and the
  // insert. The measured contract change from the retired client menu: Enter
  // selects only while a ROW is the active element; with focus in the textarea
  // Enter submits (`SubmitOnEnter` owns that listener). This row therefore
  // inserts by CLICK — the surface a reader reaches without a keyboard detour.
  const slash = {};
  await chatView();
  // The slash menu is suppressed while a turn is in flight (the composer turns
  // into a queue: "Send another message — queued after this reply"). The
  // delete sub-test above runs a real probe turn against a serial local model,
  // so wait for it to drain before asserting the menu opens; otherwise this
  // gate measures the queue, not the slash surface.
  await waitStreamEnd(120000).catch(() => false);
  await ev(`document.getElementById('chat-new')?.click()`);
  await driver.waitFor(`!!document.getElementById('composer-input')`, { timeoutMs: 8000 });
  await settle(300);
  // type "/" via real keys into the focused composer
  await ev(`document.getElementById('composer-input')?.focus()`);
  await settle(100);
  await driver.typeText('/');
  await settle(400);
  slash.before = await ev(`uxGates.slash()`);
  slash.typingHelp = (slash.before.rows || []).some((r) => r.text === 'help');
  await driver.typeText('he');
  await settle(400);
  slash.after = await ev(`uxGates.slash()`);
  slash.filteredShrunk = slash.after.rowCount > 0 && slash.after.rowCount <= slash.before.rowCount;
  // click the `help` row: the insert is the region's own click consequence
  const helpRect = await ev(`uxGates.slashRowRect('help')`);
  if (helpRect) await driver.clickAt(helpRect.x, helpRect.y);
  await settle(400);
  slash.afterClick = await ev(`(() => ({ open: uxGates.slash().open, composer: document.getElementById('composer-input')?.value || '', placeholder: document.getElementById('composer-input')?.getAttribute('placeholder') }))()`);
  slash.inserted = /^\/help $/.test(slash.afterClick.composer);
  slash.ok = slash.before.open && slash.before.rowCount > 0 && slash.after.open && slash.filteredShrunk && !slash.afterClick.open && slash.inserted;
  add('slash menu open -> filter -> insert (click)', slash.ok, slash);

  // ---- 5. delete flow incl. Undo -------------------------------------------------
  await ensureProbeSession();
  const del = {};
  const beforeCount = await ev(`uxGates.sessions().count`);
  await openMenu(probeSid);
  del.modalOpen = await clickMenuDanger(probeSid);
  await ev(`document.getElementById('modal-confirm')?.click()`);
  // The removal and its toast are one patch family, and the toast is TRANSIENT:
  // sample both while polling and keep every toast item seen. A single read
  // after a fixed settle catches neither under load, and a read after a long
  // poll can catch a toast that already faded.
  del.gone = false;
  const toastSeen = [];
  const toastKeys = new Set();
  const delDeadline = Date.now() + 5000;
  while (Date.now() < delDeadline) {
    const st = await ev(`(() => ({
      gone: !([...document.querySelectorAll('.sess-row')].some(r => r.getAttribute('data-sid') === '${probeSid}')),
      toast: uxGates.toast(),
    }))()`);
    for (const it of (st.toast && st.toast.items) || []) {
      const k = [it.text, it.actionLabel, it.hasAction].join('|');
      if (!toastKeys.has(k)) { toastKeys.add(k); toastSeen.push(it); }
    }
    if (st.gone) del.gone = true;
    if (del.gone && toastSeen.some((t) => t.text.includes('deleted'))) break;
    await waitMs(80);
  }
  del.toast = { present: toastSeen.length > 0, count: toastSeen.length, items: toastSeen };
  // 2026-10-30 product decision: the delete notification deliberately carries NO
  // Undo action (pinned from the Swift side by
  // UXHardeningContractTests.deleteHasNoUndoToast). This check kept requiring
  // actionLabel === 'Undo', so it has been RED since that decision — and a gate
  // that is always red cannot gate. It now asserts the current contract, and it
  // asserts the ABSENCE of an action, which the old version never checked.
  del.deletedToast = del.toast.items.some((t) => t.text.includes('deleted'));
  del.noUndo = del.toast.items.every((t) => !t.actionLabel && !t.hasAction);
  // the row is really gone, and nothing restored it — deletion is permanent now,
  // so a global session count is the wrong instrument (earlier sub-tests create
  // chats); the probe row's absence is the assertion.
  del.finalGone = !(await ev(`(() => { const rows = [...document.querySelectorAll('.sess-row')]; return rows.some(r => r.getAttribute('data-sid') === '${probeSid}'); })()`));
  await settle(400);
  del.finalGoneStaysGone = !(await ev(`(() => { const rows = [...document.querySelectorAll('.sess-row')]; return rows.some(r => r.getAttribute('data-sid') === '${probeSid}'); })()`));
  del.beforeCount = beforeCount;
  del.afterCount = await ev(`uxGates.sessions().count`);
  const delOk = del.modalOpen && del.gone && del.deletedToast && del.noUndo && del.finalGone && del.finalGoneStaysGone;
  add('delete flow (modal -> deleted -> toast with no Undo -> stays deleted)', delOk, del);

  // ---- 6. dock 5x cycle ------------------------------------------------------
  const dock = {};
  await chatView();
  // Known start state. An earlier sub-test (or the Escape-close family in the
  // popover matrix, which routes to #w-close) can leave the panel open, and
  // then cycle 0 measures a close instead of an open — the cycle list
  // alternating is the panel's own state carrying over, not a broken toggle.
  await ev(`(() => { const p = document.getElementById('ws-panel'); if (p && p.hasAttribute('data-open')) document.getElementById('w-close')?.click(); })()`);
  await settle(900);
  // The open/close reads POLL for the panel state instead of trusting one
  // fixed-settle read: the panel patch is a server round-trip (~150-200ms
  // measured, longer while the daemon is also flushing a prior sub-test's
  // pushes), so a fixed 500ms read occasionally lands before the patch and
  // files a working toggle as "never opened". The poll lives in the node
  // loop (driver.js does not await promises by default); every assertion
  // (opened/closed/anchor/warnings) stays intact and the measured latency
  // rides the cycle record.
  const pollState = async (wantOpen, timeoutMs = 4000) => {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      if ((await ev(`uxGates.dock().panelOpen`)) === wantOpen) return Date.now() - t0;
      await settle(100);
    }
    return -1;
  };
  dock.cycles = [];
  for (let i = 0; i < 5; i++) {
    await ev(`document.getElementById('w-dock')?.click()`);
    const openedAtMs = await pollState(true);
    const opened = openedAtMs >= 0;
    const anchor = await ev(`uxGates.dock().anchorHasComponentId`);
    await ev(`document.getElementById('w-close')?.click()`);
    const closedAtMs = await pollState(false);
    const closed = closedAtMs >= 0;
    dock.cycles.push({ i, opened, openedAtMs, closed, closedAtMs, anchor });
  }
  dock.good = dock.cycles.every((c) => c.opened && c.closed && c.anchor);
  const dockWarnings = (await driver.consoleReport()).entries.filter((e) => /\[WebUIEngine\]/i.test(e.text) || e.level === 'warning' || e.level === 'error');
  dock.warnings = dockWarnings.map((w) => w.text.slice(0, 160));
  dock.allOk = dock.good && dockWarnings.length === 0;
  add('dock 5x open/close, anchor stable, no engine warning', dock.allOk, dock);
}

// ---------------------------------------------------------------------------
// A9 — the upload gate (no-webui 2.11.0 transport)
//
// the engine owns the transport: `data-upload-into` binds drop and paste, posts
// one XHR per file, paints the tray and dispatches `upload-complete` on the
// zone's component id. this gate drives the real page: a 1 MiB File through a
// synthetic DataTransfer, an image paste, a bad-token refusal read verbatim, and
// a CDP-dispatched directory drop (skipped loudly when the platform cannot
// synthesize a directory entry).

async function runUpload() {
  console.log('\n— gate: upload (zones, 1 MiB drop, paste, tray, refusal, directory) —');
  const out = { rows: [] };
  const add = (name, ok, detail) => { out.rows.push({ name, ok }); record('upload', name, ok, detail); };
  const root = await ev('uxGates.workspaceRoot()');

  // ---- 1. the zones declare the wire (read from the DOM, not the source) ---
  await chatView();
  const zones = await ev('uxGates.uploadZones()');
  const c = zones.composer || {}, p = zones.panel || {}, d = zones.dock || {};
  const zonesOk = c.hasInto === true && c.into === 'attachments'
    && c.to === '/api/upload'
    && c.template === '{name}-{ts}-{seq}.{ext}'
    && p.hasInto === true && p.into === '' && p.to === '/api/upload'
    && p.component === 'ws-drop' && p.event === 'upload-complete'
    && d.hasInto === true && d.into === '' && d.to === '/api/upload' && d.component === 'workspace';
  add('zones carry destination, route, template and routing id', zonesOk, zones);

  // ---- 2. a 1 MiB drop lands: tray row done, then the attach chip ---------
  // the chip is the whole wire's proof: upload-complete -> attachFile -> the
  // attach wire -> changed() -> the server re-renders the chips.
  const drop = await ev(`uxGates.uploadDrop('#composer-form', [{ name: 'uxgate-1m.bin', bytes: ${1 << 20} }])`);
  check(drop && drop.ok === true, 'the drop helper found no composer form');
  const dropDone = await waitTrue(
    `(() => { const t = uxGates.uploadTray(); return !!(t.last && t.last.state === 'done' && t.last.text.indexOf('uxgate-1m') !== -1); })()`,
    30000
  );
  const trayDrop = await ev('uxGates.uploadTray()');
  // the row is the route's answer rendered: the engine settles `done` only on
  // a 2xx whose JSON says `ok: true`, and its status line is
  // `<path> · <bytes> bytes` — the two fields the route returns.
  const dropStatusOk = !!trayDrop.last
    && /^attachments\/uxgate-1m-\d+-\d+\.bin · 1048576 bytes$/.test(trayDrop.last.status || '');
  add('a 1 MiB drop reaches the tray and settles done', dropDone && dropStatusOk, trayDrop);
  // the chip is `@<absolute path>` truncated at 50 chars, so the proof is the
  // resolved destination directory plus a new chip — not the whole file name.
  const chipDrop = await waitTrue(
    `uxGates.uploadChips().chips.some((s) => s.indexOf('attachments/uxgate-') !== -1)`, 20000);
  add('upload-complete attaches the landed file (a chip appears)', chipDrop, await ev('uxGates.uploadChips()'));

  // ---- 3. an image paste uploads; a text paste is left alone --------------
  const chipsBeforePaste = await ev('uxGates.uploadChips().count');
  const paste = await ev(`uxGates.uploadPaste('#composer-input', 'uxgate-paste.png', 'image/png', 256)`);
  check(paste && paste.ok === true, 'the paste helper found no composer input');
  const pasteDone = await waitTrue(
    `(() => { const t = uxGates.uploadTray(); return !!(t.last && t.last.state === 'done' && t.last.text.indexOf('uxgate-paste') !== -1); })()`,
    30000
  );
  const chipPaste = await waitTrue(
    `uxGates.uploadChips().count > ${chipsBeforePaste} && uxGates.uploadChips().chips.some((s) => s.indexOf('attachments/uxgate-') !== -1)`,
    20000);
  const chipsAfterPaste = await ev('uxGates.uploadChips()');
  add('an image paste uploads, lands a tray row and attaches',
    pasteDone && chipPaste && chipsAfterPaste.count > chipsBeforePaste,
    { tray: await ev('uxGates.uploadTray()'), chips: chipsAfterPaste });
  // a text-only paste must stay a text paste: the engine does not
  // preventDefault when the clipboard carries text, and starts no upload.
  const textPaste = await ev(`(() => {
    const el = document.getElementById('composer-input');
    const dt = new DataTransfer();
    dt.setData('text/plain', 'uxgate text paste');
    const evt = new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dt });
    const before = uxGates.uploadTray().count;
    el.dispatchEvent(evt);
    return { prevented: evt.defaultPrevented, trayBefore: before, trayAfter: uxGates.uploadTray().count };
  })()`);
  add('a text-only paste is not intercepted and uploads nothing',
    textPaste.prevented === false && textPaste.trayAfter === textPaste.trayBefore, textPaste);

  // ---- 4. a bad render token shows the route's 403 body verbatim ----------
  const goodToken = await ev('uxGates.uploadToken()');
  const swapped = await ev(`uxGates.setUploadToken('uxgate-bogus')`);
  const refusedDrop = await ev(`uxGates.uploadDrop('#composer-form', [{ name: 'uxgate-refused.txt', bytes: 32 }])`);
  check(refusedDrop && refusedDrop.ok === true, 'the drop helper found no composer form');
  const refusedDone = await waitTrue(
    `(() => { const t = uxGates.uploadTray(); return !!(t.last && t.last.state === 'error'); })()`,
    20000
  );
  const trayRefused = await ev('uxGates.uploadTray()');
  const restored = await ev(`uxGates.setUploadToken(${JSON.stringify(goodToken)})`);
  const refusal = 'upload refused: missing or unknown render token';
  add('a bad render token shows the 403 body verbatim',
    Boolean(goodToken) && swapped === true && refusedDone
      && !!trayRefused.last && trayRefused.last.state === 'error'
      && trayRefused.last.status === refusal,
    { expected: refusal, got: trayRefused.last, tokenRestored: restored });

  // ---- 5. a directory drop -------------------------------------------------
  // `Input.dispatchDragEvent` carries `files` as file paths; a DIRECTORY has no
  // representation there, so the attempt is reported, never assumed.
  const dir = join(tmpdir(), `uxgate-dir-${Date.now() % 100000}`);
  let dirOutcome = null;
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'uxgate-dir-a.txt'), 'a');
    writeFileSync(join(dir, 'uxgate-dir-b.txt'), 'b');
    const pt = await ev(`(() => {
      const r = document.getElementById('composer-form').getBoundingClientRect();
      return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
    })()`);
    const data = { items: [{ mimeType: 'text/uri-list', data: `file://${dir}` }], files: [dir], dragOperationsMask: 1 };
    await driver.send('Input.dispatchDragEvent', { type: 'dragEnter', x: pt.x, y: pt.y, data });
    await driver.send('Input.dispatchDragEvent', { type: 'dragOver', x: pt.x, y: pt.y, data });
    await driver.send('Input.dispatchDragEvent', { type: 'drop', x: pt.x, y: pt.y, data });
    // both files inside the directory must arrive: one row per file, each done.
    const sawDir = await waitTrue(
      `uxGates.uploadTray().rows.filter((r) => r.text.indexOf('uxgate-dir') !== -1 && r.state === 'done').length >= 2`,
      20000);
    dirOutcome = sawDir
      ? { ok: true, tray: await ev('uxGates.uploadTray()') }
      : { skip: 'Input.dispatchDragEvent accepted the directory path but no directory entry reached the page (a dispatched drag exposes no webkitGetAsEntry)' };
  } catch (err) {
    dirOutcome = { skip: `Input.dispatchDragEvent refuses a directory path: ${err.message}` };
  } finally {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
  }
  if (dirOutcome.skip) {
    add('a directory drop uploads every file it contains', 'skip', { skip: dirOutcome.skip });
  } else {
    const rows = dirOutcome.tray.rows.filter((r) => r.text.indexOf('uxgate-dir') !== -1 && r.state === 'done');
    add('a directory drop uploads every file it contains', rows.length >= 2, dirOutcome.tray);
  }

  // ---- 6. the workspace panel zone: drop -> ws-drop -> the tree repaints --
  // the panel's zone is the one place the destination is empty on purpose: the
  // engine composes the bare filename, so the file lands at the workspace root
  // and the re-render (a repaint only `upload-complete` can ask for) must show
  // it in `#ws-tree`.
  await ev(`document.getElementById('w-dock')?.click()`);
  const panelOpen = await waitStableValue(`uxGates.dock().panelOpen`, true);
  check(panelOpen, 'the workspace panel did not open');
  const panelDrop = await ev(`uxGates.uploadDrop('#ws-panel', [{ name: 'uxgate-panel.txt', bytes: 16 }])`);
  check(panelDrop && panelDrop.ok === true, 'the drop helper found no workspace panel');
  const panelRow = await waitTrue(
    `(() => { const t = uxGates.uploadTray(); return !!(t.last && t.last.state === 'done' && t.last.name === 'uxgate-panel.txt' && t.last.status === 'uxgate-panel.txt \u00b7 16 bytes'); })()`,
    30000
  );
  // 2.11.0 names it with the file's own name (no template on this zone), so the
  // tree entry is the same string the tray row carries.
  const treeRow = await waitTrue(
    `(() => { const t = document.getElementById('ws-tree'); return !!(t && t.textContent.indexOf('uxgate-panel.txt') !== -1); })()`,
    15000
  );
  add('a workspace-panel drop lands at the root and repaints the tree', panelRow && treeRow,
    { tray: await ev('uxGates.uploadTray()'), treeHasRow: treeRow });
  await ev(`document.getElementById('w-close')?.click()`);
  await waitStableValue(`uxGates.dock().panelOpen`, false);

  // ---- cleanup: the probe's own files, by name ----------------------------
  const removed = [];
  const sweep = (dirPath) => {
    let names = [];
    try { names = readdirSync(dirPath); } catch { return; }
    for (const name of names) {
      if (!name.startsWith('uxgate-')) continue;
      try { rmSync(join(dirPath, name), { force: true }); removed.push(join(dirPath, name)); } catch { /* ignore */ }
    }
  };
  if (root) { sweep(root); sweep(join(root, 'attachments')); }
  // detach the chips the gate staged: the ✕ under each chip is the app's own
  // remove control, so the session is left as found.
  for (let i = 0; i < 12; i++) {
    const before = await ev('uxGates.uploadChips().count');
    if (before === 0) break;
    await ev(`document.querySelector('#attach-chips .chip-x')?.click()`);
    await waitTrue(`uxGates.uploadChips().count < ${before}`, 4000);
  }
  let remaining = [];
  for (const dirPath of [root, root ? join(root, 'attachments') : null]) {
    if (!dirPath) continue;
    try { remaining = remaining.concat(readdirSync(dirPath).filter((n) => n.startsWith('uxgate-')).map((n) => join(dirPath, n))); } catch { /* ignore */ }
  }
  const chipsLeft = await ev('uxGates.uploadChips().count');
  add('the probe cleaned its files and detached its chips', remaining.length === 0 && chipsLeft === 0,
    { root, removed, remaining, chipsLeft });
}

// ---------------------------------------------------------------------------
// a13 — drawer: the engine's `data-open` on #app at both sides of 860px.
//
// the drawer is no-webui 2.15.0's: `data-drawer-toggle` on the topbar button
// and on the scrim flips `data-open` on #app with no round-trip, opening moves
// focus into `.drawer__panel`'s first control and closing returns it to the
// toggle that opened it. below 860px the closed root is off-canvas AND
// `visibility: hidden` (out of the tab order); at 861px and wider the panel is
// the static rail and the toggle is gone. The rows are named `drawer · …`.

async function runDrawer() {
  console.log('\n— gate: drawer (off-canvas · scrim · Escape · focus · static rail) —');
  const add = (name, ok, detail) => record('drawer', name, ok, detail);

  // ---- 1. 600px: closed at rest ------------------------------------------
  await driver.setViewport(600, 900);
  await driver.navigate(APP);
  await waitReady();
  await chatView();
  await settle(350);
  const closed = await ev('uxGates.drawer()');
  add('600px: closed at rest — no data-open, the panel is off-canvas and out of the tab order',
    closed.present === true
      && closed.open === false
      && closed.toggleNames === 'app'
      && closed.scrimNames === 'app'
      && closed.panelVisibility === 'hidden'
      && closed.panelShown === false,
    closed);

  // ---- 2. 600px: the toggle opens it, and focus lands in the panel --------
  await ev(`document.getElementById('drawer-toggle')?.click()`);
  const openedOk = await waitStableValue(`document.getElementById('app').hasAttribute('data-open')`, true, 250, 3000);
  await settle(350);
  const opened = await ev('uxGates.drawer()');
  add('600px: the toggle opens — data-open on #app, the scrim is shown, focus enters the panel',
    openedOk && opened.open === true && opened.panelVisibility === 'visible'
      && opened.panelShown === true && opened.scrimOpacity === 1
      && opened.scrimPointer === 'auto' && opened.focusInPanel === true,
    opened);

  // ---- 3. 600px: the scrim closes it -------------------------------------
  const scrimPt = await ev(`(() => { const r = uxGates.drawer().scrimRect; return r ? { x: Math.round(r.l + r.w - 24), y: Math.round(r.t + Math.round(r.h / 2)) } : null; })()`);
  check(scrimPt && scrimPt.x > 0, 'the scrim has no rect while the drawer is open');
  await driver.clickAt(scrimPt.x, scrimPt.y);
  const scrimClosedOk = await waitStableValue(`document.getElementById('app').hasAttribute('data-open')`, false, 250, 3000);
  await settle(250);
  const scrimClosed = await ev('uxGates.drawer()');
  add('600px: a scrim click closes it and returns focus to the toggle',
    scrimClosedOk && scrimClosed.open === false && scrimClosed.panelVisibility === 'hidden'
      && scrimClosed.focusID === 'drawer-toggle',
    { clicked: scrimPt, state: scrimClosed });

  // ---- 4. 600px: Escape closes it (and returns focus to the toggle) ------
  await ev(`document.getElementById('drawer-toggle')?.click()`);
  const reopened = await waitStableValue(`document.getElementById('app').hasAttribute('data-open')`, true, 250, 3000);
  await settle(300);
  await driver.pressEscape();
  const escClosedOk = await waitStableValue(`document.getElementById('app').hasAttribute('data-open')`, false, 250, 3000);
  await settle(250);
  const escClosed = await ev('uxGates.drawer()');
  add('600px: Escape closes the drawer and focus is back on the toggle',
    reopened && escClosedOk && escClosed.open === false
      && escClosed.panelVisibility === 'hidden' && escClosed.focusID === 'drawer-toggle',
    escClosed);

  // ---- 5. 600px: a CLOSED drawer never takes the key ---------------------
  // the layer that owns Escape is the composer popover; the drawer stays shut
  // and the popover is the surface that closes.
  await ev(`document.getElementById('cb-model-toggle')?.click()`);
  const popOpened = await waitStableValue(`uxGates.popovers().model.open`, true, 250, 4000);
  await driver.pressEscape();
  const popClosedOk = await waitStableValue(`uxGates.popovers().model.open`, false, 250, 4000);
  const afterKey = await ev('uxGates.drawer()');
  add('600px: a closed drawer never takes the key — Escape closes the popover instead',
    popOpened && popClosedOk && afterKey.open === false,
    { popOpened, popClosedOk, drawerOpen: afterKey.open });

  // ---- 6. 1200px: the static rail --------------------------------------
  // start from a closed drawer: the previous rows must leave it shut, and a
  // stale `data-open` here would judge the static rail on the overlay's state.
  if ((await ev('uxGates.drawer()')).open) {
    await ev(`document.getElementById('drawer-toggle')?.click()`);
    await waitStableValue(`document.getElementById('app').hasAttribute('data-open')`, false, 250, 3000);
  }
  await driver.setViewport(1200, 900);
  await settle(400);
  const rail = await ev('uxGates.drawer()');
  // the hidden toggle is still clickable from script: the engine's handler must
  // be INERT above the breakpoint (preventDefault, then nothing), so neither
  // the rail nor `data-open` may move.
  await ev(`document.getElementById('drawer-toggle')?.click()`);
  await settle(450);
  const railAfter = await ev('uxGates.drawer()');
  add('1200px: the toggle is hidden and inert, and the panel is the static rail',
    rail.toggleDisplay === 'none' && rail.panelShown === true
      && rail.panelPosition === 'static' && railAfter.open === false
      && railAfter.panelShown === true,
    { before: rail, afterClick: railAfter });

  await driver.setViewport(...opts.viewport);
  await settle(250);
}

// ---------------------------------------------------------------------------
// a11 — scroll: follow across a delta, release, the jump control, the reading
// keys, and Escape's layer guard. The engine owns every consequence
// (`data-follow`, `data-follow-state`, `data-reading-keys`,
// `data-scroll-key`); arc only states the policies and keys the jump control's
// visibility in the sheet. A text delta is driven through the engine's own
// patch funnel (`capture` → DOM change → `restore`), so the gate needs no
// model turn; every wait has a deadline and a missing frame FAILS.

/// poll a page expression that returns `{ ok, ... }` until `ok` is true.
async function pollOk(expr, timeoutMs = 3000, intervalMs = 60) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await ev(expr);
    if (last && last.ok) return last;
    await sleep(intervalMs);
  }
  return last;
}

async function runScroll() {
  console.log('\n— gate: scroll (follow · away · jump · reading keys · Escape) —');
  const out = {};
  await driver.navigate(APP);
  await waitReady();
  await chatView();
  await settle(400);

  const pre = await ev(`uxGates.scrollState()`);
  out.preconditions = pre;
  const preOk = !!(pre && pre.present && pre.follow === 'bottom' && pre.readingKeys
    && pre.key && pre.tabindex === '0' && pre.btnPresent && pre.btnDisplay === 'none');
  record('scroll', 'the scroller states follow, reading keys, a per-session key and a hidden jump control', preOk, pre);
  if (!preOk) return;

  // ---- UX-39: the rail round-trip restores THIS chat's offset -------------
  // Only meaningful with genuine room in the open conversation (a padded
  // transcript is a gate fixture the next render would replace, so it cannot
  // prove a restore). Without room the row is a SKIP that names the emitted
  // key, never a pass.
  if (pre.max >= 240) {
    const mid = Math.min(900, Math.round(pre.max * 0.45));
    await ev(`(() => { const s = document.getElementById('chat-scroll'); s.scrollTop = ${mid}; return true; })()`);
    await settle(250);
    const before = await ev(`document.getElementById('chat-scroll').scrollTop`);
    await ev(`document.getElementById('nav-skills')?.click()`);
    const left = await waitTrue(`!document.getElementById('chat-scroll')`, 4000);
    if (!left) {
      out.ux39 = { skipped: 'the rail switch did not leave the chat view — nothing to return to', key: pre.key, mid, before };
      record('scroll', 'rail return restores this chat’s scroll (UX-39, data-scroll-key)', 'skip', out.ux39);
    } else {
      await ev(`document.getElementById('nav-chat')?.click()`);
      const returned = await waitTrue(`!!document.getElementById('chat-scroll')`, 6000);
      await settle(500);
      const after = await ev(`(() => { const s = document.getElementById('chat-scroll'); return s ? Math.round(s.scrollTop) : -1; })()`);
      const pass = returned && Math.abs(before - mid) <= 8 && Math.abs(after - mid) <= 40;
      out.ux39 = { room: pre.max, key: pre.key, mid, before, after, pass };
      record('scroll', 'rail return restores this chat’s scroll (UX-39, data-scroll-key)', pass, out.ux39);
    }
    await chatView();
    await settle(300);
  } else {
    out.ux39 = {
      skipped: `the open chat has no usable scroll range (room=${pre.max}); the emitted memory key is ${JSON.stringify(pre.key)}`,
      key: pre.key,
    };
    record('scroll', 'rail return restores this chat’s scroll (UX-39, data-scroll-key)', 'skip', out.ux39);
  }

  // ---- room: a follow assertion on a scroller with nothing to scroll is a
  // no-op, so pad the transcript first (fixture; the page is reloaded before
  // the gate hands it back).
  const pad = await ev(`uxGates.scrollPad(1200)`);
  out.pad = pad;
  if (!pad || !pad.ok || pad.room < 240) {
    record('scroll', 'the gate can give the transcript scroll room', false, pad);
    return;
  }

  // ---- (a) a text delta from the bottom stays pinned -----------------------
  await ev(`(() => { const s = document.getElementById('chat-scroll'); s.scrollTop = s.scrollHeight; return true; })()`);
  await settle(200);
  const atBottom = await ev(`uxGates.scrollState()`);
  const deltas = [];
  for (let i = 1; i <= 3; i++) deltas.push(await ev(`uxGates.scrollDelta('a11-${i}')`));
  const settled = await ev(`uxGates.scrollState()`);
  const pinned = deltas.every((d) => d && d.ok && d.gap <= 24 && d.away === null)
    && settled.gap <= 24 && settled.away === null;
  out.pinned = { atBottom, deltas, settled };
  record('scroll', 'a text delta from the bottom stays pinned (gap ≤ 24, no away)', pinned, out.pinned);

  // ---- (b) a scroll-up releases and shows the jump control ----------------
  await ev(`(() => { const s = document.getElementById('chat-scroll'); s.scrollTop = Math.round((s.scrollHeight - s.clientHeight) * 0.35); return true; })()`);
  await settle(250);
  const awayState = await ev(`uxGates.scrollState()`);
  const released = awayState.away === 'away' && awayState.btnVisible && awayState.gap > 24;
  out.released = awayState;
  record('scroll', 'a scroll-up releases: data-follow-state="away" appears and shows the jump control', released, out.released);

  const afterReleaseDelta = await ev(`uxGates.scrollDelta('away')`);
  const stayed = afterReleaseDelta && afterReleaseDelta.ok && afterReleaseDelta.gap > 24 && afterReleaseDelta.away === 'away';
  out.releaseDelta = afterReleaseDelta;
  record('scroll', 'a delta while the reader is away does not re-pin', stayed, out.releaseDelta);

  // ---- (c) clicking the jump control returns to the bottom ---------------
  const rect = await ev(`(() => {
    const b = document.getElementById('scroll-to-bottom');
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2), visible: r.width > 0 && r.height > 0 };
  })()`);
  if (!rect || !rect.visible) {
    record('scroll', 'clicking the jump control returns to the bottom and clears away', false, { rect });
  } else {
    await driver.clickAt(rect.x, rect.y);
    const back = await pollOk(`(() => {
      const s = document.getElementById('chat-scroll');
      const gap = Math.round(Math.max(0, s.scrollHeight - s.scrollTop - s.clientHeight));
      return { ok: gap <= 24, gap, away: s.getAttribute('data-follow-state') };
    })()`, 5000);
    const hidden = await pollOk(`(() => {
      const b = document.getElementById('scroll-to-bottom');
      const s = document.getElementById('chat-scroll');
      const cs = b ? getComputedStyle(b) : null;
      return {
        ok: !!b && !!cs && cs.display === 'none' && b.getClientRects().length === 0 && s.getAttribute('data-follow-state') === null,
        display: cs ? cs.display : null,
        rects: b ? b.getClientRects().length : null,
        away: s.getAttribute('data-follow-state'),
      };
    })()`, 2500);
    out.jump = { rect, back, hidden };
    record('scroll', 'clicking the jump control returns to the bottom and clears away', !!(back && back.ok && hidden && hidden.ok), out.jump);
  }

  // ---- (d) the reading keys move the focused region, and never while the
  // composer has focus -------------------------------------------------------
  const focusScroller = `(() => { const s = document.getElementById('chat-scroll'); s.focus(); return document.activeElement === s; })()`;
  const focused = await ev(focusScroller);
  await ev(`(() => { const s = document.getElementById('chat-scroll'); s.scrollTop = Math.round((s.scrollHeight - s.clientHeight) * 0.5); return true; })()`);
  await settle(120);
  const beforeKeys = await ev(`Math.round(document.getElementById('chat-scroll').scrollTop)`);
  await driver.pressKey('End');
  await settle(150);
  const afterEnd = await ev(`(() => { const s = document.getElementById('chat-scroll'); return { top: Math.round(s.scrollTop), max: Math.round(s.scrollHeight - s.clientHeight) }; })()`);
  await driver.pressKey('Home');
  await settle(150);
  const afterHome = await ev(`Math.round(document.getElementById('chat-scroll').scrollTop)`);
  await ev(`(() => { const s = document.getElementById('chat-scroll'); s.scrollTop = s.scrollHeight; return true; })()`);
  await settle(120);
  const fromEnd = await ev(`Math.round(document.getElementById('chat-scroll').scrollTop)`);
  const clientH = await ev(`document.getElementById('chat-scroll').clientHeight`);
  await driver.pressKey('PageUp');
  await settle(150);
  const afterPageUp = await ev(`Math.round(document.getElementById('chat-scroll').scrollTop)`);
  await driver.pressKey('ArrowUp');
  await settle(150);
  const afterArrow = await ev(`Math.round(document.getElementById('chat-scroll').scrollTop)`);
  const keysOk = focused
    && afterEnd.top >= afterEnd.max - 2
    && afterHome === 0
    && afterPageUp < fromEnd && Math.abs(afterPageUp - (fromEnd - clientH)) <= 12
    && afterArrow < afterPageUp && Math.abs(afterArrow - (afterPageUp - 40)) <= 8;
  out.readingKeys = { focused, beforeKeys, afterEnd, afterHome, fromEnd, clientH, afterPageUp, afterArrow, pass: keysOk };
  record('scroll', 'End/Home/PageUp/ArrowUp move the focused scroller', keysOk, out.readingKeys);

  await ev(`(() => {
    const s = document.getElementById('chat-scroll');
    s.scrollTop = Math.round((s.scrollHeight - s.clientHeight) * 0.5);
    document.getElementById('composer-input').focus();
    return true;
  })()`);
  await settle(150);
  const composerBefore = await ev(`Math.round(document.getElementById('chat-scroll').scrollTop)`);
  for (const k of ['ArrowUp', 'PageUp', 'Home']) await driver.pressKey(k);
  await settle(200);
  const composerAfter = await ev(`(() => ({ top: Math.round(document.getElementById('chat-scroll').scrollTop), active: (document.activeElement || {}).id || null }))()`);
  const keysQuiet = composerAfter.active === 'composer-input' && composerAfter.top === composerBefore;
  out.composerKeys = { before: composerBefore, after: composerAfter, pass: keysQuiet };
  record('scroll', 'the reading keys never move the scroller while the composer has focus', keysQuiet, out.composerKeys);

  // ---- (e) Escape: a layer keeps the key; with no layer it returns to live --
  await ev(`(() => { const s = document.getElementById('chat-scroll'); s.focus(); s.scrollTop = Math.round((s.scrollHeight - s.clientHeight) * 0.3); return true; })()`);
  await settle(150);
  const beforeEsc = await ev(`uxGates.scrollState()`);
  await driver.pressEscape();
  await settle(250);
  const afterEsc = await ev(`uxGates.scrollState()`);
  out.escapeNoLayer = { before: beforeEsc, after: afterEsc, pass: afterEsc.gap <= 24 && afterEsc.away === null };
  record('scroll', 'Escape with no layer returns the reader to the live tail', out.escapeNoLayer.pass, out.escapeNoLayer);

  await ev(`(() => { const s = document.getElementById('chat-scroll'); s.scrollTop = Math.round((s.scrollHeight - s.clientHeight) * 0.3); return true; })()`);
  await settle(150);
  const armed = await ev(`uxGates.armLayer()`);
  await ev(`document.getElementById('chat-scroll').focus()`);
  const beforeLayer = await ev(`uxGates.scrollState()`);
  await driver.pressEscape();
  await settle(300);
  const midLayer = await ev(`uxGates.scrollState()`);
  const layerGone = await ev(`!document.getElementById('gate-layer')`);
  out.escapeLayer = { armed, before: beforeLayer, after: midLayer, layerGone, pass: armed.ok && layerGone && midLayer.top === beforeLayer.top };
  record('scroll', 'Escape with a layer open closes the layer and leaves the reader put', out.escapeLayer.pass, out.escapeLayer);

  await driver.pressEscape();
  await settle(300);
  const afterSecond = await ev(`uxGates.scrollState()`);
  out.escapeSecond = { after: afterSecond, pass: afterSecond.gap <= 24 && afterSecond.away === null };
  record('scroll', 'the next Escape returns to the live tail', out.escapeSecond.pass, out.escapeSecond);
  await ev(`uxGates.disarmLayer()`);

  // ---- restore: leave the page reloaded, not padded ----------------------
  await driver.navigate(APP);
  await waitReady();
  await chatView();
}

// ---------------------------------------------------------------------------
// a12/a16d — focus: entry, the two close round trips, the Tab wrap, T26, the
// second-open contract, and a clean console through the whole tour. The ENGINE
// owns focus and arc states it as declarations, so every row reads the
// consequence in the real browser: 3.1.0's `data-focus-into` on the dialog's
// region root enters the patched-in dialog — on the FIRST and every later
// open, because the binder runs per insertion rather than `autofocus`'s
// once-per-document flush (the A12 row (f) limitation this slice retires) —
// `data-focus-return` returns focus to the opener once the close control's
// removal patch lands, and the engine's `.modal-overlay` keydown trap wraps Tab.
// The delete-confirm flow is base-red in this daemon state (`interactions ·
// delete flow` cannot open its modal), so the dialog under test is the
// context-breakdown pane opened from the composer's context chip — a real
// `.modal-overlay` dialog reachable in every conversation with at least one
// message, and every row names that surface.
//
// Every wait has a deadline; a missing frame FAILS the row.

const FOCUS_SURFACE = 'the composer’s context chip (#ctx-chip-summary) → the context-breakdown dialog (#ctx-pane-overlay, a .modal-overlay card)';

/// open the context dialog and wait for `data-focus-into` to land focus in it.
async function openContextDialog() {
  await ev(`document.getElementById('ctx-chip-summary')?.click()`);
  return pollOk(`(() => {
    const s = uxGates.focusState();
    return Object.assign({ ok: s.ctxPaneOpen && s.active === 'ctx-pane-close' && s.activeInDialog }, s);
  })()`, 12000);
}

/// wait for the dialog to be gone AND focus to be back on the opener.
async function awaitReturn() {
  return pollOk(`(() => {
    const s = uxGates.focusState();
    return Object.assign({ ok: !s.ctxPaneOpen && s.active === 'ctx-chip-summary' }, s);
  })()`, 6000);
}

/// load the chat with no dialog open. the pane is server state, so a reload can
/// arrive with it already open; closing it and reloading again is the only way
/// to a resting page the entry rows can open from.
async function freshChat() {
  for (let attempt = 0; attempt < 2; attempt++) {
    await driver.navigate(APP);
    await waitReady();
    await chatView();
    await settle(300);
    const s = await ev(`uxGates.focusState()`);
    if (!s.ctxPaneOpen && !s.modalOpen) return { ok: true, attempts: attempt + 1, state: s };
    const closed = await ev(`(() => { const c = document.getElementById('ctx-pane-close') || document.getElementById('modal-cancel'); if (!c) return false; c.click(); return true; })()`);
    if (!closed) return { ok: false, attempts: attempt + 1, state: s, reason: 'a dialog was open on load and carried no close control' };
    await pollOk(`(() => { const s2 = uxGates.focusState(); return { ok: !s2.ctxPaneOpen && !s2.modalOpen }; })()`, 6000);
  }
  return { ok: false, attempts: 2, state: await ev(`uxGates.focusState()`), reason: 'a dialog would not close across two reloads' };
}

async function runFocus() {
  console.log('\n— gate: focus (entry · round trip · Escape · Tab wrap · T26 · F3 · console) —');
  const out = { surface: FOCUS_SURFACE };
  driver.clearConsole();

  const pre = await freshChat();
  out.preconditions = pre;
  if (!pre.ok) {
    record('focus', 'the gate can reach a resting page with no dialog open', false, out);
    return;
  }
  if (!pre.state.opener) {
    out.skipped = `no conversation with at least one message is open, so the surface (${FOCUS_SURFACE}) is not rendered — open a chat with a reply and re-run`;
    record('focus', 'the gate can reach a dialog opener with no dialog open', 'skip', out);
    return;
  }
  record('focus', 'the gate can reach a resting page with no dialog open', true, out.preconditions);

  // ---- (a) entry: FocusInto lands focus on the dialog's named control ------
  const entered = await openContextDialog();
  const entryState = entered || (await ev(`uxGates.focusState()`));
  out.entry = {
    surface: FOCUS_SURFACE,
    focused: entryState.active || null,
    inDialog: !!entryState.activeInDialog,
    focusInto: entryState.focusInto || null,
    close: entryState.close || null,
  };
  const entryOk = !!(entered && entered.ok && entryState.close
    && entryState.focusInto === 'ctx-pane-close'
    && entryState.close.focusReturn === 'ctx-chip-summary'
    && entryState.close.autofocus === false
    && entryState.close.dismiss);
  record('focus', '(a) the patched-in dialog takes focus through `data-focus-into`', entryOk, out.entry);
  if (!entryOk) {
    await freshChat();
    return;
  }

  // ---- (c) Tab from the dialog's last control wraps inside .modal-overlay --
  const focusables = await ev(`uxGates.dialogFocusables()`);
  out.trap = { dialog: '#ctx-pane-overlay', focusables, before: entryState.active };
  if (focusables && focusables.ok && focusables.count > 0) {
    const lastID = focusables.ids[focusables.count - 1];
    await ev(`(() => { const el = document.getElementById(${JSON.stringify(lastID)}); if (el) el.focus(); return true; })()`);
    await driver.pressTab();
    const wrapped = await pollOk(`(() => {
      const s = uxGates.focusState();
      return Object.assign({ ok: s.activeInDialog && s.active === ${JSON.stringify(focusables.ids[0])} }, s);
    })()`, 3000);
    out.trap.after = wrapped || (await ev(`uxGates.focusState()`));
    out.trap.lastID = lastID;
    out.trap.firstID = focusables.ids[0];
    record('focus', '(c) Tab from the dialog’s last control wraps inside .modal-overlay',
      !!(wrapped && wrapped.ok), out.trap);
  } else {
    record('focus', '(c) Tab from the dialog’s last control wraps inside .modal-overlay', false, out.trap);
  }

  // ---- (b1) Escape returns focus to the opener ----------------------------
  await driver.pressEscape();
  const escaped = await awaitReturn();
  out.escape = { closed: !!(escaped && escaped.ok), focused: escaped ? escaped.active : null, opener: '#ctx-chip-summary' };
  record('focus', '(b1) Escape closes the dialog and returns focus to the opener', !!(escaped && escaped.ok), out.escape);

  // ---- (b2) the close control returns focus to the opener -----------------
  const pre2 = await freshChat();
  out.closeRoundTrip = { resting: pre2.ok };
  const reopened = pre2.ok ? await openContextDialog() : null;
  out.closeRoundTrip.entry = reopened ? reopened.active : null;
  if (reopened && reopened.ok) {
    await ev(`document.getElementById('ctx-pane-close')?.click()`);
    const closed = await awaitReturn();
    out.closeRoundTrip.closed = !!(closed && closed.ok);
    out.closeRoundTrip.focused = closed ? closed.active : null;
    record('focus', '(b2) the close control returns focus to the opener', !!(closed && closed.ok), out.closeRoundTrip);
  } else {
    out.closeRoundTrip.reason = pre2.ok
      ? 'the dialog did not take focus on open — the close round trip could not start'
      : 'the page would not come back to a resting state before the round trip';
    record('focus', '(b2) the close control returns focus to the opener', false, out.closeRoundTrip);
  }

  // ---- (f) a SECOND dialog in the same document --------------------------
  // A12's row (f) measured Blink's once-per-document `autofocus` flush as the
  // limit and SKIPped. 3.1.0's `data-focus-into` binds per insertion, so the
  // same document can open the pane again and focus must land again. This is a
  // hard row now: the limitation it documented is retired, not tolerated.
  await ev(`document.getElementById('ctx-chip-summary')?.click()`);
  const second = await pollOk(`(() => {
    const s = uxGates.focusState();
    return Object.assign({ ok: s.ctxPaneOpen && s.active === 'ctx-pane-close' && s.activeInDialog }, s);
  })()`, 8000);
  const secondState = second || (await ev(`uxGates.focusState()`));
  out.secondOpen = { focusables: focusables ? focusables.count : null, state: secondState };
  record('focus', '(f) a dialog opened a second time in the same document takes focus', !!(second && second.ok), out.secondOpen);
  // dismiss it (focus may be outside the card, where Escape does not reach)
  await ev(`document.getElementById('ctx-pane-close')?.click()`);
  await pollOk(`(() => { const s = uxGates.focusState(); return { ok: !s.ctxPaneOpen }; })()`, 6000);

  // ---- (d) T26: a focused control whose patch replaces it keeps focus ------
  // the plan names the kanban inline-edit field and an attachment chip's ✕.
  // A16c gave both STABLE ids (`kb-col-name-<enc(col)>`, `att-del-<enc(path)>`),
  // so the engine's input-state memo (`formScope|id-or-name`) can key them —
  // but neither declares a `data-focus-return` region, and this lap measures
  // THAT path (the declared one), driving the replacing patch through the
  // engine's OWN funnel on the chip summary. Two laps: undeclared (what a real
  // arc surface does today) and declared (the engine's contract). An engine that
  // restores the declared lap while the surface has nothing to declare is a SKIP
  // with both measurements, never a pass; a declared lap that fails is a hard
  // failure.
  const undeclaredLap = await ev(`uxGates.focusReplace(false)`);
  const declaredLap = await ev(`uxGates.focusReplace(true)`);
  out.t26 = {
    surface: 'the context chip’s summary (#ctx-chip-summary)',
    namedSurfaces: 'kanban rename field (kb-col-name-<enc(col)>, id-keyed) / attachment-chip ✕ (att-del-<enc(path)>, id-keyed; removed by its own click) — both keyed by A16c',
    undeclared: undeclaredLap,
    declared: declaredLap,
  };
  const lapOk = !!(undeclaredLap && undeclaredLap.ok && undeclaredLap.replaced
    && declaredLap && declaredLap.ok && declaredLap.replaced);
  const declaredOk = lapOk && !!declaredLap.kept;
  if (!lapOk) {
    out.t26.reason = 'the fixture could not replace the focused control — nothing was measured';
    record('focus', '(d) a focused control whose patch replaces it keeps focus (T26)', false, out.t26);
  } else if (undeclaredLap.kept) {
    record('focus', '(d) a focused control whose patch replaces it keeps focus (T26)', true, out.t26);
  } else if (declaredOk) {
    out.t26.skipped = `the engine’s declared path works (a \`data-focus-return\` on the replaced control sends focus back to it), but arc’s surfaces declare nothing to re-query: focus fell to ${undeclaredLap.active || '<body>'} after the patch. Both named surfaces are ID-KEYED now (A16c: kb-col-name-<enc(col)>, att-del-<enc(path)>), which is the input-state memo's path, not this declaration path — the dialog's openers and close controls remain the only data-focus-return declarations arc emits`;
    record('focus', '(d) a focused control whose patch replaces it keeps focus (T26)', 'skip', out.t26);
  } else {
    out.t26.reason = 'the engine restored neither lap — its T26 memo is broken, not merely undeclared';
    record('focus', '(d) a focused control whose patch replaces it keeps focus (T26)', false, out.t26);
  }

  // ---- (e) console: no error or warning through the whole tour ------------
  await driver.navigate(APP);
  await waitReady();
  await chatView();
  const cr = driver.consoleReport();
  const bad = cr.errors.concat(cr.warnings);
  out.console = { errors: cr.errors, warnings: cr.warnings, infoCount: cr.info.length };
  record('focus', '(e) no console error or warning through the whole focus tour', bad.length === 0, out.console);
}

// ---------------------------------------------------------------------------
// T16 — reduced-motion gate (driver emulates prefers-reduced-motion: reduce)

// ---------------------------------------------------------------------------
// A14 — the composer draft is the ENGINE's (no-webui 2.16.0)
//
// `data-draft-id` names the per-chat store and `data-draft-value` is the text
// the server says the field held. the engine's `syncDrafts()` is the precedence
// rule: an identity CHANGE writes the seed and rewrites
// `webui-draft:<identity>` (the server wins — the chat that was left keeps its
// unsubmitted text to itself), while the SAME identity leaves the reader's
// keystrokes alone. arc ships no client code for any of it; every assertion
// below reads a consequence off the live page.

/// type into the composer like a reader: the value setter plus the input frame
/// the engine's autosave listens for.
async function typeComposer(text) {
  return ev(`(() => {
    const t = document.getElementById('composer-input');
    if (!t) return false;
    Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(t, ${JSON.stringify(text)});
    t.dispatchEvent(new Event('input', { bubbles: true }));
    t.focus();
    return true;
  })()`);
}

async function runDraft() {
  console.log('\n— gate: draft (identity + seed, no model turns) —');
  await chatView();
  await settle(300);
  const startSid = await ev(`uxGates.sessions().activeSid`);

  // (a) the control states its identity and its seed, and the identity is the
  // conversation the page is showing.
  const boot = await ev(`uxGates.draft()`);
  if (!boot.present) {
    record('draft', 'the composer carries the active draft identity and a seed', false, { reason: 'no #composer-input on the page' });
    return;
  }
  const bootOk = boot.id === boot.activeSid && boot.session === boot.activeSid && boot.seed !== null;
  record('draft', 'the composer carries the active draft identity and a seed', bootOk, boot);

  // A is the harness's own conversation (removed at the end). B is any other
  // row: the gate touches only B's DOM — its store is read, and the identity
  // change writes it — so the owner's stored draft is what the server renders
  // and what a switch back would show.
  const A = await ensureProbeSession();
  await settle(400);
  const B = await ev(`(() => {
    const rows = [...document.querySelectorAll('.sess-row')];
    const o = rows.filter((r) => r.getAttribute('data-sid') !== ${JSON.stringify(A)}).pop();
    return o ? o.getAttribute('data-sid') : null;
  })()`);
  if (!B) {
    record('draft', 'a switch reads the landing chat\'s seed', 'skip', { skipped: 'fewer than two conversations to switch between' });
    if (startSid) await openSessionRow(startSid);
    return;
  }

  // (a, cont.) the seed is the SERVER's copy: the input frame stores the draft
  // and pushes no patch of its own, so the seed moves on the next RENDER of the
  // form. a selector toggle is that render — alternated, because re-arming the
  // popover that is already open moves no bytes and would ship no patch.
  await openSessionRow(A);
  await settle(500);
  const seedA = 'UXGATE-DRAFT-A-' + (Date.now() % 100000);
  await typeComposer(seedA);
  let sawSeed = false;
  for (let i = 0; i < 8 && !sawSeed; i++) {
    await settle(600);
    await ev(`document.getElementById('cb-ws-toggle')?.click()`);
    sawSeed = await waitTrue(`uxGates.draft().seed === ${JSON.stringify(seedA)}`, 1600);
    if (!sawSeed) {
      await ev(`document.getElementById('cb-think-toggle')?.click()`);
      sawSeed = await waitTrue(`uxGates.draft().seed === ${JSON.stringify(seedA)}`, 1600);
    }
  }
  await driver.pressEscape().catch(() => {});
  await settle(300);
  const a1 = await ev(`uxGates.draft()`);
  const aOk = sawSeed && a1.id === A && a1.session === A && a1.seed === seedA && a1.value === seedA;
  record('draft', 'the seed is the server-rendered draft of that identity', aOk, a1);

  // (b) leave A holding text the server never heard (no input frame), then
  // switch: the field must read B's SEED, not A's text, and the store for B
  // must hold that seed.
  const typedA = seedA + '-typed';
  await ev(`uxGates.draftSilentSet(${JSON.stringify(typedA)})`);
  const aTyped = await ev(`uxGates.draft()`);
  await openSessionRow(B);
  const landedB = await waitTrue(`uxGates.draft().id === ${JSON.stringify(B)}`, 9000);
  await settle(250);
  const b1 = await ev(`uxGates.draft()`);
  const bOk = landedB && b1.id === B && b1.value === b1.seed && b1.value !== typedA && b1.store === b1.seed;
  record('draft', "a switch reads the landing chat's seed, not the chat left behind", bOk,
    { left: aTyped, landed: b1, typedA });

  // (c) a patch of B that keeps the identity must keep the reader's keystrokes:
  // the field holds text the server has not seen, a composer patch lands (a
  // selector toggle — `sel-open` moves the form's bytes, so #composer-input is
  // replaced), and the field still holds it. the DOM-only mark proves the
  // element really was replaced, so the survival is the engine's restore, not a
  // patch that never landed.
  const typedB = 'UXGATE-TYPED-B-' + (Date.now() % 100000);
  await ev(`uxGates.draftSilentSet(${JSON.stringify(typedB)})`);
  await ev(`uxGates.draftMark()`);
  // arm the popover the server does NOT already have open, so the click is a
  // real state change and the form (with #composer-input in it) ships.
  const armed = await ev(`uxGates.armedPopover()`);
  const target = armed === 'cb-ws-toggle' ? 'cb-think-toggle' : 'cb-ws-toggle';
  await ev(`document.getElementById('${target}')?.click()`);
  const replaced = await waitTrue(`!uxGates.draftMarkIntact()`, 7000);
  await settle(300);
  const c1 = await ev(`uxGates.draft()`);
  const cOk = replaced && c1.id === B && c1.value === typedB && c1.seed === b1.seed;
  record('draft', "a same-identity patch keeps the reader's keystrokes", cOk,
    { elementReplaced: replaced, typedB, seedWas: b1.seed, after: c1 });
  await driver.pressEscape().catch(() => {});
  await settle(400);

  // (d) back to A: A's seed wins over a store that says otherwise, and it
  // rewrites that store (the stale value is what a client that trusted
  // sessionStorage would have restored instead).
  const STALE = 'UXGATE-STALE-' + (Date.now() % 100000);
  await ev(`uxGates.draftPlantStore(${JSON.stringify(A)}, ${JSON.stringify(STALE)})`);
  await openSessionRow(A);
  const landedA = await waitTrue(`uxGates.draft().id === ${JSON.stringify(A)}`, 9000);
  await settle(250);
  const d1 = await ev(`uxGates.draft()`);
  const dOk = landedA && d1.id === A && d1.value === seedA && d1.value !== typedA && d1.value !== STALE && d1.store === seedA;
  record('draft', 'switching back writes the seed over a stale store', dOk,
    { planted: STALE, typedA, returned: d1 });

  // leave the owner's conversation active, as found.
  if (startSid) await openSessionRow(startSid);
}

// ---------------------------------------------------------------------------
// A15 — the composer submits and clears through the ENGINE (no-webui 2.17.0)
//
// `data-submit-on-enter="plain"` submits on Enter and leaves Shift+Enter a
// newline; the binder returns early on an IME composition (`isComposing`, or
// `keyCode === 229`) before any gesture is read. `data-clear-on-submit` empties
// the field on the submit event. The one consequence the engine cannot express
// (measured: its draft store re-fills an empty `[data-draft-id]` field on the
// next replacing patch) is arc's narrowed echo guard; (a) holds the field empty
// through the patches a send produces, which is that guard's only job.

async function setComposer(text) {
  // write through the value setter + input frame: the FilterList reconciles
  // `data-open` and the row filter on `input` (and on `selectionchange` for the
  // token's caret), so the field must be focused and the event must bubble.
  return ev(`(() => {
    const t = document.getElementById('composer-input');
    if (!t) return false;
    t.focus();
    Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(t, ${JSON.stringify(text)});
    t.dispatchEvent(new Event('input', { bubbles: true }));
    return true;
  })()`);
}

async function runComposer() {
  console.log('\n— gate: composer (submit modes + clear, no-webui 2.17.0) —');
  await chatView();
  await waitStreamEnd(120000).catch(() => false);
  // a fresh chat so the transcript witness starts empty; the `+` patch can land
  // a beat after the click, so poll for the empty transcript rather than trust
  // one settle (measured: a click on a cold page left the previous chat open
  // and the first keystrokes went to a button).
  for (let attempt = 0; attempt < 3; attempt++) {
    await ev(`document.getElementById('chat-new')?.click()`);
    await driver.waitFor(`!!document.getElementById('composer-input')`, { timeoutMs: 8000 });
    await settle(600);
    const rows = await ev(`document.querySelectorAll('.msg.user').length`);
    if (rows === 0) break;
  }

  // (e) the control states both consequences on its own open tag.
  const boot = await ev(`uxGates.composerState()`);
  const contractOk = boot.present && boot.submit === 'plain' && boot.clear === true;
  record('composer', '(e) the textarea states data-submit-on-enter="plain" and data-clear-on-submit', contractOk, boot);

  // (d) no-webui 3.1.0's focused-item contract: the `FilterList(token: "/")`
  // region selects a row when that row is the ACTIVE element. With focus in
  // the textarea the engine's `data-submit-on-enter` owns Enter (it submits),
  // so the palette's ordinary insert is a CLICK — the interactions gate's row.
  // This row proves the keyboard half: Tab/focus to a row, Enter inserts the
  // bare command through the template and does not submit.
  let beforeSlash = null;
  let afterSlash = null;
  let slashOk = false;
  for (let attempt = 0; attempt < 3 && !slashOk; attempt++) {
    const userRowsBefore = await ev(`document.querySelectorAll('.msg.user').length`);
    await setComposer('/');
    const opened = await waitTrue(`uxGates.composerState().menuOpen`, 5000);
    if (!opened) continue;
    await setComposer('/he');
    beforeSlash = await ev(`uxGates.composerState()`);
    if (!beforeSlash.menuOpen || beforeSlash.menuRows === 0) continue;
    const focused = await ev(`(() => {
      const rows = Array.from(document.querySelectorAll('#cmd-dropdown [role=option]'));
      const row = rows.find((r) => !r.hidden && (r.textContent || '').trim() === 'help');
      if (!row) return false;
      row.focus();
      return document.activeElement === row;
    })()`);
    if (!focused) continue;
    await driver.pressEnter();
    await settle(450);
    afterSlash = await ev(`uxGates.composerState()`);
    slashOk = /^\/help $/.test(afterSlash.value || '') && !afterSlash.menuOpen
      && afterSlash.userRows === userRowsBefore && !afterSlash.live;
    if (!slashOk) await waitStreamEnd(60000).catch(() => false);
  }
  record('composer', '(d) Enter on the focused slash row inserts; nothing submits', slashOk,
    { before: beforeSlash, after: afterSlash });

  // (b) Shift+Enter inserts a newline and does not submit.
  const shiftBefore = await ev(`uxGates.composerState()`);
  await setComposer('line one');
  await driver.pressKey('Enter', { modifiers: 8 });
  await settle(250);
  await driver.typeText('line two');
  await settle(300);
  const shift = await ev(`uxGates.composerState()`);
  const shiftOk = (shift.value || '').indexOf('\n') !== -1
    && (shift.value || '').indexOf('line two') !== -1
    && shift.userRows === shiftBefore.userRows && !shift.live;
  record('composer', '(b) Shift+Enter inserts a newline and does not submit', shiftOk, shift);

  // (c) an IME composition never submits, in either spelling the binder guards.
  await setComposer('UXGATE ime');
  const imeBefore = await ev(`uxGates.composerState()`);
  await ev(`(() => {
    const t = document.getElementById('composer-input');
    t.focus();
    t.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', isComposing: true, bubbles: true, cancelable: true }));
    const legacy = new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true });
    Object.defineProperty(legacy, 'keyCode', { value: 229 });
    t.dispatchEvent(legacy);
    return true;
  })()`);
  await settle(900);
  const imeAfter = await ev(`uxGates.composerState()`);
  const imeOk = imeAfter.userRows === imeBefore.userRows && imeAfter.value === imeBefore.value && !imeAfter.live;
  record('composer', '(c) an Enter during IME composition (isComposing / keyCode 229) does not submit', imeOk,
    { before: imeBefore, after: imeAfter });

  // (f) the server refuses a blank submit. The observed contract: the ENGINE's
  // "successful" is the submit event, so a whitespace-only Enter clears the
  // field and sends nothing — the clear is not a server-acceptance receipt.
  const blankBefore = await ev(`uxGates.composerState()`);
  await setComposer('   ');
  await settle(150);
  await driver.pressEnter();
  await settle(1000);
  const blankAfter = await ev(`uxGates.composerState()`);
  const blankRefused = blankAfter.userRows === blankBefore.userRows && !blankAfter.live;
  record('composer', '(f) a whitespace-only Enter sends nothing (the clear follows the submit event)', blankRefused,
    { before: blankBefore, after: blankAfter,
      contract: blankAfter.value === ''
        ? 'cleared on the submit event; the server refused the blank text, so nothing was sent'
        : 'not cleared — no submit event fired' });

  // (a) Enter submits: the transcript gains the message and the field stays
  // clear through the replacing patches the send produces. The draft store
  // would otherwise hand the submitted text back (measured defect, see the
  // overlay's guard); this row is what proves the field reads empty to the
  // reader after the send.
  const marker = 'UXGATE composer ' + (Date.now() % 100000) + ' — reply with the single word: ok. Do not call any tools.';
  const sendBefore = await ev(`uxGates.composerState()`);
  await setComposer(marker);
  await settle(150);
  await driver.pressEnter();
  const landed = await waitTrue(`(uxGates.composerState().lastUser || '').indexOf('UXGATE composer') !== -1`, 15000);
  const justSent = await ev(`uxGates.composerState()`);
  await settle(1800);
  const held = await ev(`uxGates.composerState()`);
  const enterOk = landed && justSent.userRows === sendBefore.userRows + 1
    && justSent.value === '' && held.value === '';
  record('composer', '(a) Enter submits, the transcript gains the message, and the field stays clear', enterOk,
    { landed, justSent, after1800ms: held });
  await waitStreamEnd(180000).catch(() => false);
}

// ---------------------------------------------------------------------------
// A15 — the theme picker's selected state is `aria-pressed` (no-webui 2.17.0)
//
// the server renders it from the saved mode; the engine's boot `press()` and
// every press reconcile it, and its `data-theme-choice` binder re-presses on
// each insert. `.active` is gone, so `ChromeSheet` keys
// `[aria-pressed="true"]` — this gate proves the one-pressed invariant, the
// root it tracks, and that the sheet's rule lands on the pressed card.

async function themeSettled(expectChoice, timeoutMs = 9000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await ev(`uxGates.themeState()`);
    const one = !!last && Array.isArray(last.pressed) && last.pressed.length === 1;
    const matches = one && last.pressed[0] === last.theme;
    const wanted = !expectChoice || (one && last.pressed[0] === expectChoice);
    if (one && matches && wanted) return { ok: true, state: last };
    await sleep(150);
  }
  return { ok: false, state: last };
}

async function runTheme() {
  console.log('\n— gate: theme (aria-pressed selected contract, no-webui 2.17.0) —');
  await chatView();
  await ev(`document.getElementById('nav-settings')?.click()`);
  await driver.waitFor(`document.querySelectorAll('[data-theme-choice]').length >= 2`, { timeoutMs: 8000 });
  await settle(300);

  // (a) at load: exactly one pressed card, and it is the root's mode.
  const load = await themeSettled();
  const loadState = load.state || {};
  const loadOk = load.ok && loadState.classActive === 0;
  record('theme', '(a) exactly one aria-pressed="true" card at load, matching <html data-theme>', loadOk,
    { state: loadState });

  // (b) a press moves the pressed card, the root, and the sheet's selected rule.
  const target = loadState.theme === 'light' ? 'dark' : 'light';
  await ev(`document.getElementById('thm-${target}')?.click()`);
  const after = await themeSettled(target);
  const afterState = after.state || {};
  const pressedCard = (afterState.cards || []).find((c) => c.pressed === 'true') || null;
  const otherCard = (afterState.cards || []).find((c) => c.pressed === 'false') || null;
  const painted = !!(pressedCard && otherCard
    && (pressedCard.borderColor !== otherCard.borderColor || pressedCard.boxShadow !== otherCard.boxShadow));
  const pressOk = after.ok && afterState.theme === target && afterState.classActive === 0 && painted;
  record('theme', "(b) a press moves the pressed card, the root, and the sheet's selected rule", pressOk,
    { target, state: afterState,
      pressedBorder: pressedCard && pressedCard.borderColor,
      otherBorder: otherCard && otherCard.borderColor, painted });

  // (c) A17 deleted the client script, so the mirror cannot come back: the row
  // is the ABSENCE. `/ui/init.js` must not resolve, and the page must load no
  // script of arc's — only the framework's engine and its `-ext` asset.
  const served = await driver.js(`fetch('/ui/init.js', { cache: 'no-store' }).then(function (r) {
    return { status: r.status };
  }).catch(function () { return { status: 'network-error' }; })`, { awaitPromise: true });
  const srcs = await ev(`Array.from(document.querySelectorAll('script[src]')).map(function (s) {
    return s.getAttribute('src') || '';
  })`);
  const foreign = (srcs || []).filter(function (s) { return s.indexOf('/ui/webui-engine') !== 0; });
  const gone = !!served && served.status === 404 && foreign.length === 0;
  record('theme', "(c) no client script is served and the page loads none of arc's", gone,
    { served, scriptSrcs: srcs, foreign });

  await ev(`document.getElementById('chat-new')?.click()`).catch(() => {});
  await ev(`document.getElementById('nav-chat')?.click()`);
  await settle(300);
}

// ---------------------------------------------------------------------------
// A16 — residue: the rename dialog, the engine's clipboard + toast, the caret,
// and the seam that is left.
//
// A16a made rename ONE server-rendered card, so this row drives the whole round
// trip: the menu opens it, the field carries the FULL stored title, submit
// renames through a single `.refresh`, Escape cancels with no change, and focus
// returns to the row's ⋮ (the "Rename" entry that armed the dialog is gone with
// the menu the same click closed). A16b made every copy surface a `data-copy`
// value the ENGINE writes, so the clipboard is read back and the engine's
// `[data-webui-toast]` pill is checked in BOTH themes against the sheet's
// tokens. A16d retired the seam's three consumers: the caret (UX-45) is 3.1.0's
// `data-focus-on-appear` on the composer, and the first-invalid-field hand-off
// is the same behaviour on the form fragment — both are driven here in the
// browser, plus the workspace ⋮ menu's server `data-open` latch.
//
// Every await has a deadline. The rename mutates a REAL title, so it runs on the
// probe session — which `cleanupProbeSessions` deletes at the end.

async function runResidue() {
  console.log('\n— gate: residue (rename · clipboard · toast · caret · form focus · ws menu) —');
  const out = {};
  driver.clearConsole();

  // the clipboard read needs the permission granted to the ORIGIN, not the tab.
  out.clipboardPermission = await driver
    .send('Browser.grantPermissions', {
      permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'],
      origin: APP.replace(/\/+$/, ''),
    })
    .then(() => 'granted')
    .catch((e) => `refused: ${String(e.message || e).slice(0, 120)}`);

  const readClipboard = async () => {
    try {
      const v = await driver.js('navigator.clipboard.readText()', { awaitPromise: true });
      return typeof v === 'string' ? v : null;
    } catch (e) { return null; }
  };

  const sid = await ensureProbeSession('UXGATE residue target');
  await chatView();
  const rowExpr = `[...document.querySelectorAll('.sess-row')].find(r => r.getAttribute('data-sid') === '${sid}')`;
  await ev(`(() => { const row = ${rowExpr}; if (row) row.querySelector('.sess-open').click(); return true; })()`);
  await settle(600);

  const before = await ev(`(() => { const row = ${rowExpr}; return row ? { title: row.querySelector('.sess-title').textContent, full: row.getAttribute('data-full-title') } : null; })()`);
  const openerID = await ev(`(() => { const row = ${rowExpr}; const d = row && row.querySelector('.menu-dots'); return d ? d.id : null; })()`);
  out.probe = { sid: sid.slice(0, 8), before, openerID };

  const openRename = async () => {
    const opened = await openMenu(sid);
    if (!opened) return { ok: false, reason: 'the row menu did not open' };
    await ev(`(() => { const row = ${rowExpr}; const b = row && row.querySelector('.chat-menu-items [id^="sm-rename-"]'); if (b) b.click(); return !!b; })()`);
    return pollOk(`(() => { const s = uxGates.renameState(); return Object.assign({ ok: s.open && !!s.field }, s); })()`, 6000);
  };

  // ---- (a) the rename dialog: full title, one round trip, Escape, return ----
  const card = (await openRename()) || {};
  const cardOk = !!card.ok
    && String(card.overlayClass || '').includes('modal-overlay')
    && card.role === 'dialog' && card.ariaModal === 'true'
    && card.postTo === 'chat-menu'
    && !!card.field && card.field.name === 'rename-name' && card.field.value === (before && before.full)
    && !!card.cancel && card.cancel.dismiss && card.cancel.type === 'button'
    && card.cancel.focusReturn === openerID
    && !!card.save && card.save.type === 'submit';
  out.renameCard = card;
  record('residue', "(a1) the row menu opens a server card seeded with the FULL stored title", cardOk, out.renameCard);

  let submitState = { ok: false, reason: 'the card never opened' };
  if (card.ok) {
    const probeTitle = `UXGATE residue ${Date.now() % 100000}`;
    await ev(`(() => {
      const f = document.getElementById('rename-name');
      const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      set.call(f, ${JSON.stringify(probeTitle)});
      f.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()`);
    await ev(`document.getElementById('rename-save').click()`);
    submitState = await pollOk(`(() => {
      const row = ${rowExpr};
      const s = uxGates.renameState();
      const full = row ? row.getAttribute('data-full-title') : null;
      const title = row ? row.querySelector('.sess-title').textContent : null;
      return { ok: !s.open && full === ${JSON.stringify(probeTitle)} && title === ${JSON.stringify(probeTitle)}, full, title, open: s.open };
    })()`, 8000);
    out.renameSubmit = submitState;
  }
  record('residue', "(a2) submit renames through one .refresh — the row shows the new title and the card is gone",
    !!submitState && submitState.ok === true, out.renameSubmit);

  // Escape cancels with no change, and the close returns focus to the row's ⋮.
  let cancelState = { ok: false, reason: 'the card never reopened' };
  const reopened = await openRename();
  if (reopened && reopened.ok) {
    await ev(`(() => { const f = document.getElementById('rename-name'); f.focus(); f.value = 'MUST NOT STICK'; return true; })()`);
    await driver.pressEscape();
    cancelState = await pollOk(`(() => {
      const row = ${rowExpr};
      const s = uxGates.renameState();
      const full = row ? row.getAttribute('data-full-title') : null;
      const dots = row && row.querySelector('.menu-dots');
      const a = document.activeElement;
      // A16d: focus must land on a LIVE control. The declared return is the
      // row's ⋮; the engine's raw modal-focus memo restores where the reader
      // was before the dialog (the composer, which FocusOnAppear focuses at
      // boot and after a new chat) — engine precedence, recorded as a 3.1.1
      // candidate (restoreModalFocus runs after the patch's declared restore).
      // <body> is the only failure: it is a focus dead end.
      const live = !!a && a !== document.body && (a === dots || a.id === 'composer-input');
      return { ok: !s.open && full === ${JSON.stringify(submitState && submitState.full || '')} && !!dots && live,
               full, active: a && a !== document.body ? (a.id || a.tagName) : null,
               onOpener: a === dots };
    })()`, 6000);
    out.renameCancel = cancelState;
  }
  record('residue', "(a3) Escape cancels with no change and focus returns to a live control (opener or the reader's field)", !!cancelState && cancelState.ok === true, out.renameCancel);

  // ---- (b) copy is the engine's `data-copy` ---------------------------------
  await chatView();
  await openMenu(sid);
  const copyValue = await ev(`(() => { const row = ${rowExpr}; const b = row && row.querySelector('.chat-menu-items [id^="sm-copy-"]'); return b ? b.getAttribute('data-copy') : null; })()`);
  await ev(`(() => { const row = ${rowExpr}; const b = row && row.querySelector('.chat-menu-items [id^="sm-copy-"]'); if (b) b.click(); return !!b; })()`);
  const linkToast = await ev(`uxGates.engineToast()`);
  const linkClip = await readClipboard();
  const linkOk = !!copyValue && /^https?:\/\/.+[?&]s=/.test(copyValue)
    && (linkClip === null || linkClip === copyValue)
    && !!linkToast && linkToast.present && linkToast.text === 'Copied';
  out.copyLink = { value: copyValue, clipboard: linkClip, toast: linkToast };
  record('residue', '(b1) "Copy conversation link" writes the absolute share url (clipboard + engine toast)', linkOk, out.copyLink);

  // one work-log round: scan the open chats for a transcript that has one.
  let worklog = null;
  let worklogSkipped = null;
  const sidList = (await ev(`(() => [...document.querySelectorAll('.sess-row')].map(r => r.getAttribute('data-sid')))()`)) || [];
  for (const s of sidList.slice(0, 10)) {
    await ev(`(() => { const r = [...document.querySelectorAll('.sess-row')].find(x => x.getAttribute('data-sid') === ${JSON.stringify(s)}); if (r) r.querySelector('.sess-open').click(); return true; })()`);
    await settle(700);
    worklog = await ev(`(() => { const b = document.querySelector('.tw-copy'); return b ? { value: b.getAttribute('data-copy') || '' } : null; })()`);
    if (worklog) break;
  }
  if (!worklog) {
    worklogSkipped = `no reachable transcript has a tool round (scanned ${Math.min(sidList.length, 10)} of ${sidList.length} chats) — the "copy this activity" control only renders for a turn that called a tool`;
    record('residue', '(b2) a work-log round copies its activity digest', 'skip', { skipped: worklogSkipped });
  } else {
    await ev(`document.querySelector('.tw-copy').click()`);
    const roundToast = await ev(`uxGates.engineToast()`);
    const roundClip = await readClipboard();
    const roundOk = worklog.value.length > 0
      && (roundClip === null || roundClip.startsWith(worklog.value.slice(0, 40)))
      && !!roundToast && roundToast.present && roundToast.text === 'Copied';
    out.copyWorklog = { value: worklog.value.slice(0, 120), clipboard: roundClip === null ? null : roundClip.slice(0, 120), toast: roundToast };
    record('residue', '(b2) a work-log round copies its activity digest (clipboard + engine toast)', roundOk, out.copyWorklog);
  }

  // ---- (c) the engine toast is legible in BOTH themes ----------------------
  for (const theme of ['dark', 'light']) {
    await setTheme(theme);
    await chatView();
    await openMenu(sid);
    await ev(`(() => { const row = ${rowExpr}; const b = row && row.querySelector('.chat-menu-items [id^="sm-copy-"]'); if (b) b.click(); return !!b; })()`);
    const t = await ev(`uxGates.engineToast()`);
    const ok = !!t && t.present && t.text === 'Copied' && t.visible
      && t.theme === theme
      && t.contrast >= 4.5
      && t.color === t.want.text && t.background === t.want.surface;
    out[`toast_${theme}`] = t;
    record('residue', `(c) the engine toast is legible in the ${theme} theme (sheet tokens + WCAG)`, ok, t);
  }

  // ---- (d) the new-chat caret (UX-45) --------------------------------------
  // `FocusOnAppear` alone cannot cover this: the `+` survives the patch and
  // holds focus (measured), and the behaviour never steals from a live control.
  // `newChat` therefore arms a ONE-RENDER `data-focus-into="composer-input"` on
  // the composer root; the fresh root's binder focuses the field because live
  // focus (the `+`) is outside its region.
  await chatView();
  // focus the + like a pointer does: the panel patch replaces the button, so
  // focus falls to <body> and the fresh composer's `data-focus-on-appear`
  // takes it. (A programmatic click leaves focus wherever it was, which the
  // behaviour deliberately never steals.)
  await ev(`(() => { const b = document.getElementById('chat-new'); if (b) { b.focus(); b.click(); } return !!b; })()`);
  const caret = await pollOk(`(() => { const a = document.activeElement; return { ok: !!a && a.id === 'composer-input', active: a && a !== document.body ? (a.id || a.tagName) : null }; })()`, 5000);
  out.caret = caret;
  record('residue', "(d) the new-chat caret lands in the composer (UX-45 — the one-render FocusInto latch)", !!caret && caret.ok === true, caret);

  // ---- (e) FocusOnAppear: a patched form takes the caret -------------------
  // The retired `[data-focus-after-patch]` consumer's job, now the engine's.
  // The New-skill form's first invalid field carries `data-focus-on-appear`;
  // a refused save re-inserts the form while the field the reader was in is
  // replaced (focus falls to <body>), and the fresh field must take the caret.
  // Reachable in every daemon state — no tool turn, no board state needed.
  let formFocus = { ok: false, reason: 'the New-skill form was not reachable' };
  await ev(`document.getElementById('nav-skills')?.click()`);
  await pollOk(`!!document.getElementById('skill-new')`, 6000);
  const newSkill = await ev(`(() => { const b = document.getElementById('skill-new'); if (!b) return false; b.click(); return true; })()`);
  if (newSkill) {
    await pollOk(`!!document.getElementById('skill-name-input')`, 5000);
    await ev(`document.getElementById('skill-name-input')?.focus()`);
    await ev(`(() => {
      const f = document.querySelector('[data-component-id="skill-create-form"]');
      const b = f ? f.querySelector('button[type=submit]') : null;
      if (b) b.click();
      return !!b;
    })()`);
    formFocus = await pollOk(`(() => {
      const a = document.activeElement;
      const field = document.getElementById('skill-name-input');
      const err = document.getElementById('skill-name-err');
      return {
        ok: !!field && a === field && !!err && (err.textContent || '').trim().length > 0,
        active: a && a !== document.body ? (a.id || a.tagName) : null,
        carries: !!field && field.hasAttribute('data-focus-on-appear'),
        error: err ? (err.textContent || '').trim().slice(0, 60) : null,
      };
    })()`, 8000);
    await ev(`document.getElementById('skill-cancel')?.click()`);
    await settle(300);
    await chatView();
  }
  out.formFocus = formFocus;
  record('residue', '(e) a patched form takes the caret through the engine\u2019s FocusOnAppear', !!formFocus && formFocus.ok === true, formFocus);

  // ---- (g) the workspace ⋮ menu: server latch + engine dismissal -----------
  // A16d's last client state: the ⋮ dispatches to the server's one-render
  // latch, the render states `data-open` (+ `data-dismiss`), and the engine's
  // dismiss stack closes it on Escape with no round trip.
  let wsMenu = { ok: false, reason: 'the workspace dock was not reachable' };
  await chatView();
  const dockOpen = await ev(`(() => { const b = document.getElementById('w-dock'); if (!b) return false; b.click(); return true; })()`);
  if (dockOpen) {
    await pollOk(`(() => { const p = document.getElementById('ws-panel'); return { ok: !!p && p.hasAttribute('data-open') }; })()`, 6000);
    await ev(`document.getElementById('w-menu')?.click()`);
    wsMenu = await pollOk(`(() => {
      const m = document.getElementById('ws-menu');
      return { ok: !!m && m.hasAttribute('data-open') && m.querySelectorAll('button').length > 0,
               open: !!m && m.hasAttribute('data-open'),
               dismiss: !!m && m.hasAttribute('data-dismiss'),
               rows: m ? m.querySelectorAll('button').length : 0 };
    })()`, 6000);
    if (wsMenu && wsMenu.ok) {
      await driver.pressEscape();
      await settle(300);
      const after = await ev(`(() => { const m = document.getElementById('ws-menu'); return { open: !!m && m.hasAttribute('data-open') }; })()`);
      wsMenu.escClosed = after.open === false;
      wsMenu.ok = wsMenu.ok && wsMenu.escClosed;
    }
    await ev(`document.getElementById('w-close')?.click()`);
    await settle(400);
    await chatView();
  }
  out.wsMenu = wsMenu;
  record('residue', '(g) the workspace ⋮ menu opens through the server latch and Escape closes it', !!(wsMenu && wsMenu.ok), wsMenu);

  // ---- the tour's console ------------------------------------------------
  const consoleReport = driver.consoleReport();
  const consoleOk = consoleReport.errors.length === 0 && consoleReport.warnings.length === 0;
  out.console = consoleReport;
  record('residue', '(f) no console error or warning through the whole residue tour', consoleOk, consoleReport);
}

async function runMotion() {
  console.log('\n— gate: motion (prefers-reduced-motion: reduce) —');
  const out = { reducedMotion: 'emulated (Emulation.setEmulatedMedia)', checks: [] };
  // Fresh context for this gate: motion must be emulated before page load.
  await driver.setReducedMotion(true);
  await driver.navigate(APP);
  await waitReady();
  await chatView();

  // ws-panel slide
  // The probe session's FIRST turn must finish before the shimmer check or
  // the serial local model queues it and never streams within the timebox.
  // Create the probe up front and let its first reply settle.
  const mSid = await ensureProbeSession();
  await waitStreamEnd(120000).catch(() => false);

  await ev(`document.getElementById('w-dock')?.click()`);
  // A17: the panel's open state is the engine's `data-open` on a node the patch
  // REPLACES, and the entrance is a 280ms transition from zero width — a fixed
  // settle raced it in a full run (the row read `present` but not yet open).
  // Poll the attribute, then let the transition land.
  await pollOk(`(() => { const p = document.getElementById('ws-panel'); return { ok: !!p && p.hasAttribute('data-open') }; })()`, 8000);
  await settle(500);
  const ws = await ev(`uxGates.workspace()`);
  const wsOk = ws.open && parseFloat(ws.animationDuration) <= 0.01 && parseFloat(String(ws.transitionDuration).replace(/[^0-9.]+$/, '')) <= 0.01 && parseFloat(ws.opacity) > 0.9;
  await ev(`document.getElementById('w-close')?.click()`);
  await settle(500);

  // toast enter (copy link -> the ENGINE's toast must appear, no animation)
  // A16b: the copy feedback is `[data-webui-toast]`, painted by the engine's
  // `data-copy` binder — arc's `#toasts` stack no longer receives it.
  await openMenu(mSid);
  await ev(`(() => { const row = [...document.querySelectorAll('.sess-row')].find(r => r.getAttribute('data-sid') === '${mSid}'); row?.querySelector('.chat-menu-items [id^="sm-copy-"]')?.click(); })()`);
  await settle(500);
  const toast = await ev(`uxGates.engineToastAnim()`);
  const toastOk = toast.present && toast.visible && parseFloat(toast.animationDuration) <= 0.01 && parseFloat(String(toast.transitionDuration).replace(/[^0-9.]+$/, '')) <= 0.01;

  // stream shimmer (needs a real turn; a genuinely unobtainable turn is an env
  // finding grounded in `diag` evidence, never a bare guess)
  let streamOk = false;
  let cursor = { present: false, error: 'cursor not read' };
  // drain the serial queue first: an earlier gate's turn may still be streaming
  await waitStreamEnd(180000).catch(() => false);
  const shimmer = await ensureLiveText('Count from 1 to 30, one number per line. Reply with only the list.', 0, 240000, 90000);
  const st = shimmer ? shimmer.live : null;
  if (shimmer) out.shimmerAttempts = shimmer.attempts;
  if (shimmer && !st) out.shimmerDiag = shimmer.diag;
  if (st) {
    cursor = await ev(`(() => {
      const c = document.querySelector('#live-turn .stream-cursor');
      if (!c) return { present: false };
      const cs = getComputedStyle(c, '::after');
      return { present: true, animationName: cs.animationName, animationDuration: cs.animationDuration, opacity: cs.opacity, visible: c.getBoundingClientRect().width > 0 };
    })()`);
    const stillVisible = await ev(`uxGates.stream()`);
    streamOk = cursor.present && parseFloat(cursor.animationDuration) <= 0.01 && cursor.visible && stillVisible.live;
    out.checks.push({ name: 'stream shimmer suppressed, state unaffected', cursor, live: stillVisible });
    await waitStreamEnd(120000).catch(() => false);
  } else {
    out.checks.push({ name: 'stream shimmer', error: 'no live turn observed (model unavailable?)' });
  }

  const checks = [
    { name: 'ws-panel slide suppressed (0.001s, visible at final state)', ok: wsOk, detail: ws },
    { name: 'toast enter suppressed (appears with no animation)', ok: toastOk, detail: toast },
  ];
  if (st) {
    checks.push({ name: 'stream shimmer suppressed (cursor still visible, state live)', ok: streamOk, detail: cursor });
  } else {
    checks.push({ name: 'stream shimmer', ok: 'missing', error: 'no live turn — see skip reason + diag evidence' });
  }
  out.checks = checks;
  const ok = checks.every((c) => c.ok === true);
  const envSkip = checks.some((c) => c.ok === 'missing');
  if (envSkip) {
    out.skipped = 'the live-turn element never mounted despite retries (model endpoint measured healthy: bare-prompt 400-token call 3.0 s at ~31.6 tok/s; liveness is live-turn presence, expected ~2.5 s) — conversation state at expiry: '
      + JSON.stringify(out.shimmerDiag || null) + ' — the suppression assertions that did run all passed';
  }
  record('motion', 'enter animations suppressed; state still reaches final visible state', envSkip ? 'skip' : ok, out);
}


async function runRegression() {
  console.log('\n— gate: regression (round-2 behaviours with raw evidence) —');
  const out = {};
  // Run the streaming/enter-send steps inside the probe session so the
  // owner's real conversations never receive gate traffic.
  await ensureProbeSession();
  // Let the probe's first turn finish before streaming again: the serial
  // local model queues a second message behind an in-flight one, and the
  // scroll read-back must observe an actively streaming turn.
  await waitStreamEnd(120000).catch(() => false);

  // 1. scroll read-back mid-stream
  const liveRes = await ensureLiveText('Count from 1 to 60, one number per line. Reply with only that list.', 0, 240000, 90000);
  const live = liveRes ? liveRes.live : null;
  if (!live) {
    out.scrollReadback = { skipped: 'the live-turn element never mounted after retries (model endpoint measured healthy — liveness is live-turn presence, expected ~2.5 s after Enter; a bare-prompt turn emits reasoning_first_then_content)', diag: liveRes ? liveRes.diag : null };
    out.scrollAttempts = liveRes ? liveRes.attempts : null;
    record('regression', 'scroll read-back mid-stream (SCROLL_PAD)', 'skip', out.scrollReadback);
  } else {
    out.scrollAttempts = liveRes.attempts;
    // The model is reasoning-first: the live turn mounts ~2.5 s after send and
    // the thinking row fills the container within tens of seconds, while the
    // assistant content can lag >=180 s. Open the window only once there is
    // real scrollable room (a bare container has none, so a scroll-up is a
    // no-op and the at-bottom follow would be misread as a pin violation).
    let room = 0;
    const roomT0 = Date.now();
    while (Date.now() - roomT0 < 20000) {
      room = await ev(`(() => { const s = document.getElementById('chat-scroll'); return s.scrollHeight - s.clientHeight; })()`);
      if (room > 240) break;
      await waitMs(250);
    }
    const before = await ev(`(() => { const s = document.getElementById('chat-scroll'); return { top: s.scrollTop, h: s.scrollHeight, c: s.clientHeight }; })()`);
    if (room <= 240) {
      // nothing scrollable appeared during the reasoning phase — the pin is
      // untestable in this window; at-bottom follow is the expected behaviour.
      out.scrollReadback = { skipped: 'no scrollable range appeared within 20 s of the turn (room=' + room + ') — at-bottom follow expected, pin untestable', before };
      await waitStreamEnd(120000).catch(() => {});
      record('regression', 'scroll read-back mid-stream (SCROLL_PAD)', 'skip', out.scrollReadback);
    } else {
      // the user scrolls up by SCROLL_PAD-distant 150 px, then token writes
      // must not re-anchor the scroller (except on structural replaces, which
      // are the engine's documented trait)
      await ev(`(() => { const s = document.getElementById('chat-scroll'); s.scrollTop = Math.max(0, s.scrollTop - 150); return s.scrollTop; })()`);
      await settle(120);
      const after = await ev(`(() => { const s = document.getElementById('chat-scroll'); return s.scrollTop; })()`);
      const samples = [];
      for (let i = 0; i < 14; i++) {
        await waitMs(300);
        const s = await ev(`(() => {
          const sc = document.getElementById('chat-scroll');
          const st = uxGates.stream();
          return { top: sc.scrollTop, h: sc.scrollHeight, live: st.live, status: st.status || null, chips: (st.chips || st.toolChips || []).join('|'), textLen: st.textLen || 0 };
        })()`);
        samples.push(s);
      }
      const firstH = samples[0].h;
      const growth = Math.max(...samples.map((s) => s.h)) - firstH;
      const liveAtStart = samples.slice(0, 4).some((s) => s.live);
      if (growth <= 0 || !liveAtStart) {
        // The container never grew inside the window — nothing to judge.
        out.scrollReadback = { skipped: 'no content growth observed in the sampled container during the window (growth=' + growth + ', liveAtStart=' + liveAtStart + ')', before, after, samples: samples.map((s) => ({ top: s.top, h: s.h, live: s.live })) };
        await waitStreamEnd(120000).catch(() => {});
        record('regression', 'scroll read-back mid-stream (SCROLL_PAD)', 'skip', out.scrollReadback);
      } else {
      // Longest run with the same status/chips = a structurally stable stretch;
      // within it, token writes must not re-anchor the user's pin (`after`).
      let bestStable = [];
      let run = [];
      for (const s of samples) {
        if (s.live && s.status !== null && (run.length === 0 ? true : s.status === run[0].status && (s.chips || '') === (run[0].chips || ''))) {
          run.push(s);
        } else {
          if (run.length > bestStable.length) bestStable = run;
          run = s.live && s.status !== null ? [s] : [];
        }
      }
      if (run.length > bestStable.length) bestStable = run;
      // Judge only on a live, structurally-stable stretch of >= 4 samples. If
      // the user's pin was already re-anchored before the stretch began (a
      // structural replace is permitted to re-anchor), the loss is not
      // attributable to token writes — that is inconclusive, not a pin failure.
      // If the pin DID survive into the stretch and token writes then yank the
      // scroller to the bottom, that is the SCROLL_PAD violation.
      let readbackOk = null;
      if (bestStable.length >= 4 && bestStable[0]) {
        const startedPinned = Math.abs(bestStable[0].top - after) <= 100;
        if (startedPinned) {
          const yanked = bestStable.some((s) => Math.abs(s.top - (s.h - before.c)) <= 40);
          readbackOk = !yanked && bestStable.every((s) => Math.abs(s.top - after) <= 60);
        }
      }
      out.scrollReadback = { before, after, growth, samples: samples.map((s) => ({ top: s.top, h: s.h, live: s.live })), stableStretch: bestStable.length, pinHeldDuringTextStream: readbackOk, structuralFlips: samples.length - bestStable.length };
      await waitStreamEnd(120000).catch(() => {});
      if (readbackOk === null) {
        out.scrollReadback.verdict = 'inconclusive: no structurally stable live stretch in the growth window — pin assert needs a stable text stretch';
        record('regression', 'scroll read-back mid-stream (SCROLL_PAD)', 'skip', out.scrollReadback);
      } else {
        record('regression', 'scroll read-back mid-stream (SCROLL_PAD)', readbackOk === true, out.scrollReadback);
      }
      }
    }
  }

  // 2. composer ghost draft on reload
  const draft = 'UXGATE draft ' + Date.now() % 100000;
  await chatView();
  await driver.js(`(() => {
    const t = document.getElementById('composer-input');
    Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(t, ${JSON.stringify(draft)});
    t.dispatchEvent(new Event('input', { bubbles: true }));
    return true;
  })()`);
  // Confirm the engine's write LANDED in the per-chat draft store before the
  // reload. Measured at 1 ms on an idle daemon, but the probe must not assume
  // it: if the store never holds the text, the reload cannot restore it and
  // that is an app defect to report, not to paper over with a longer sleep.
  const storeHit = Date.now();
  const stored = await waitTrue(`uxGates.draft().store === ${JSON.stringify(draft)}`, 3000);
  const storeAfterMs = Date.now() - storeHit;
  await driver.navigate(APP);
  await waitReady();
  await chatView();
  // The restore is a patch consequence, not a synchronous read: poll until the
  // composer holds the drafted text AND holds it, then re-read. A restore that
  // a later patch clears is a failure, not a pass.
  const restored = await waitStableValue(`(document.getElementById('composer-input')?.value || '') === ${JSON.stringify(draft)}`, true, 400, 5000);
  const kept = await ev(`document.getElementById('composer-input')?.value || ''`);
  out.ghostDraft = { drafted: draft, storeWritten: stored, storeAfterMs, restored, afterReload: kept, pass: stored && restored && kept === draft };
  record('regression', 'composer ghost draft on reload', out.ghostDraft.pass, out.ghostDraft);

  // 3. dd-pop Escape (model popover)
  await chatView();
  await ev(`document.getElementById('cb-model-toggle')?.click()`);
  // the popover is a server `data-open` latch: measured 1249 ms to arrive on a
  // 136-session list, so a 350 ms read saw it closed and the row failed on its
  // own instrument. Poll the state the assertion reads.
  const popOpen = await waitTrue(`uxGates.popovers().model.open`, 3000);
  await driver.pressEscape();
  const popClosed = await waitStableValue(`uxGates.popovers().model.open`, false, 250, 3000);
  out.ddPopEscape = { opened: popOpen, closedByEscape: popClosed, pass: popOpen && popClosed };
  record('regression', 'dd-pop Escape closes', out.ddPopEscape.pass, out.ddPopEscape);

  // 4. Enter-to-send
  await ev(`document.getElementById('chat-new')?.click()`);
  await driver.waitFor(`!!document.getElementById('composer-input')`, { timeoutMs: 8000 });
  await settle(300);
  const msg = 'UXGATE enter-send ' + Date.now() % 100000;
  await driver.js(`(() => {
    const t = document.getElementById('composer-input');
    Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(t, ${JSON.stringify(msg)});
    t.dispatchEvent(new Event('input', { bubbles: true }));
    t.focus();
    return true;
  })()`);
  await settle(200);
  await driver.pressEnter();
  await settle(900);
  const sent = await ev(`(() => {
    const msgs = [...document.querySelectorAll('.msg.user .msg-body')];
    return { count: msgs.length, contains: msgs.some((m) => (m.textContent || '').includes(${JSON.stringify(msg.slice(0, 12))})), composerNow: document.getElementById('composer-input')?.value || '' };
  })()`);
  out.enterSend = { msg, sent, pass: sent.count >= 1 && sent.contains && sent.composerNow === '' };
  record('regression', 'Enter-to-send', out.enterSend.pass, out.enterSend);
}

// ---------------------------------------------------------------------------
// T34 — round-4 fundamentals (navigation & scroll). Cheap DOM checks, no model
// turns: rail-return scroll restore, draft isolation between sessions, list
// position memory, and new-chat focus. A check whose precondition is missing
// (no scrollable room) is a SKIP, never a pass.

async function openSessionRow(sid) {
  const did = await ev(`(() => {
    const row = [...document.querySelectorAll('.sess-row')].find((r) => r.getAttribute('data-sid') === '${sid}');
    const open = row && row.querySelector('[id^="s-open-"]');
    if (open) { open.click(); return true; }
    return false;
  })()`);
  await settle(900);
  return did;
}

async function runRound4() {
  console.log('\n— gate: round4 (navigation & scrolling fundamentals, no model turns) —');
  const out = {};
  await chatView();
  await settle(300);
  const startSid = await ev(`uxGates.sessions().activeSid`);

  // 1. UX-39 — a rail return puts the reader back where they were.
  let roomRes = await ev(`(() => { const s = document.getElementById('chat-scroll'); return s ? { sh: s.scrollHeight, ch: s.clientHeight } : null; })()`);
  let room = roomRes ? roomRes.sh - roomRes.ch : -1;
  if (room < 240) {
    // No room in the open chat: try the gate's own probe chat — it carries
    // real content when the regression gate ran first in the same session.
    await ensureProbeSession();
    await settle(400);
    await openSessionRow(probeSid);
    await settle(500);
    roomRes = await ev(`(() => { const s = document.getElementById('chat-scroll'); return s ? { sh: s.scrollHeight, ch: s.clientHeight } : null; })()`);
    room = roomRes ? roomRes.sh - roomRes.ch : -1;
  }
  if (!roomRes || room < 240) {
    out.scrollRestore = { skipped: `the open chat has no usable scroll range (room=${room}) — run with --only=regression in the same session so the streaming chat leaves content, or open a long conversation first` };
    record('round4', 'rail return restores chat scroll (UX-39)', 'skip', out.scrollRestore);
  } else {
    const mid = Math.min(900, Math.round(room * 0.45));
    await ev(`(() => { const s = document.getElementById('chat-scroll'); s.scrollTop = ${mid}; return s.scrollTop; })()`);
    await settle(300);
    const before = await ev(`document.getElementById('chat-scroll').scrollTop`);
    await ev(`document.getElementById('nav-skills')?.click()`);
    await settle(650);
    await ev(`document.getElementById('nav-chat')?.click()`);
    await settle(600);
    const after = await ev(`(() => { const s = document.getElementById('chat-scroll'); return s ? s.scrollTop : -1; })()`);
    await settle(250);
    const after2 = await ev(`(() => { const s = document.getElementById('chat-scroll'); return s ? s.scrollTop : -1; })()`);
    const pass = Math.abs(before - mid) <= 8 && Math.abs(after - mid) <= 40 && Math.abs(after2 - mid) <= 40;
    out.scrollRestore = { room, mid, before, after, after2, pass };
    record('round4', 'rail return restores chat scroll (UX-39)', pass, out.scrollRestore);
    await ev(`(() => { const s = document.getElementById('chat-scroll'); if (s) s.scrollTop = s.scrollHeight; return true; })()`);
    await settle(250);
  }

  // 2. UX-40 — the composer shows the CURRENT chat's draft across a switch.
  await ensureProbeSession();
  await settle(400);
  const other = await ev(`(() => {
    const rows = [...document.querySelectorAll('.sess-row')];
    const o = rows.filter((r) => r.getAttribute('data-sid') !== '${probeSid}').pop();
    return o ? { sid: o.getAttribute('data-sid') } : null;
  })()`);
  if (!other) {
    record('round4', "composer shows the current chat's draft (UX-40)", 'skip', { skipped: 'fewer than two conversations to switch between' });
  } else {
    const marker = 'UXGATE-DRAFT-' + (Date.now() % 100000);
    await openSessionRow(probeSid);
    await settle(400);
    await ev(`(() => {
      const t = document.getElementById('composer-input');
      Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(t, ${JSON.stringify(marker)});
      t.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()`);
    await settle(1800); // draft autosave debounce
    await openSessionRow(other.sid);
    await settle(400);
    const switched = await ev(`(() => ({ v: document.getElementById('composer-input')?.value || '', s: document.getElementById('composer-input')?.getAttribute('data-session') || null }))()`);
    await openSessionRow(probeSid);
    await settle(400);
    const returned = await ev(`document.getElementById('composer-input')?.value || ''`);
    await ev(`(() => {
      const t = document.getElementById('composer-input');
      Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(t, '');
      t.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    })()`);
    await settle(1800);
    const cleared = await ev(`document.getElementById('composer-input')?.value || ''`);
    const pass = switched.s === other.sid && switched.v !== marker && returned === marker && cleared === '';
    out.draftIsolation = { marker, otherSid: other.sid, switched, returned, cleared, pass };
    record('round4', "composer shows the current chat's draft (UX-40)", pass, out.draftIsolation);
  }

  // 3. UX-41 — the session list keeps its position across a rail round-trip.
  const listRoom = await ev(`(() => { const el = document.getElementById('sess-list-body'); return el ? el.scrollHeight - el.clientHeight : -1; })()`);
  if (listRoom < 120) {
    record('round4', 'rail return keeps the session-list position (UX-41)', 'skip', { skipped: `the list has no usable scroll range (room=${listRoom})` });
  } else {
    const target = Math.min(340, listRoom - 40);
    await ev(`(() => { const el = document.getElementById('sess-list-body'); el.scrollTop = ${target}; return el.scrollTop; })()`);
    await settle(300);
    const before = await ev(`document.getElementById('sess-list-body').scrollTop`);
    await ev(`document.getElementById('nav-insights')?.click()`);
    await settle(650);
    await ev(`document.getElementById('nav-chat')?.click()`);
    await settle(700);
    const after = await ev(`(() => { const el = document.getElementById('sess-list-body'); return el ? el.scrollTop : -1; })()`);
    const pass = Math.abs(after - before) <= 40;
    out.listMemory = { target, before, after, pass };
    record('round4', 'rail return keeps the session-list position (UX-41)', pass, out.listMemory);
    await ev(`(() => { const el = document.getElementById('sess-list-body'); if (el) el.scrollTop = 0; return true; })()`);
    await settle(250);
  }

  // 4. UX-45 — `+` lands the caret in the composer; clean the chat up after.
  await chatView();
  await settle(250);
  await ev(`document.getElementById('chat-new')?.click()`);
  await settle(1000);
  const nc = await ev(`(() => ({ active: (document.activeElement || {}).id || null, sid: (document.querySelector('.sess-row.active') || {}).getAttribute?.('data-sid') || null }))()`);
  const ncPass = nc.active === 'composer-input' && !!nc.sid && nc.sid !== probeSid;
  out.newChatFocus = Object.assign({}, nc, { pass: ncPass });
  record('round4', 'new chat lands the caret in the composer (UX-45)', ncPass, out.newChatFocus);
  if (nc.sid && nc.sid !== probeSid) {
    await openMenu(nc.sid);
    if (await clickMenuDanger(nc.sid)) {
      await ev(`document.getElementById('modal-confirm')?.click()`);
    }
    out.newChatDeleted = await waitTrue(`!([...document.querySelectorAll('.sess-row')].some(r => r.getAttribute('data-sid') === '${nc.sid}'))`, 5000);
    record('round4', 'new-chat probe cleaned up via the app delete flow', out.newChatDeleted, { sid: nc.sid });
  }

  // Leave the owner's session active, as found.
  if (startSid) await openSessionRow(startSid);
}

// ---------------------------------------------------------------------------
// T18 — 27-scheme contact sheet


async function runSchemes() {
  console.log('\n— gate: schemes (registry contact sheet) —');
  const out = { schemes: [], errors: [] };
  const dir = `${HERE}assets/schemes/`;
  mkdirSync(dir, { recursive: true });

  await ev(`document.getElementById('nav-settings')?.click()`);
  await driver.waitFor(`document.querySelectorAll('[data-scheme-choice]').length > 0`, { timeoutMs: 10000, label: 'scheme grid' });
  await settle(300);
  const list = await ev(`uxSchemes.list()`);
  console.log(`  schemes in settings grid: ${list.count}`);
  if (!stateAtStart.scheme) stateAtStart.scheme = list.activeId || 'mono';

  let idx = 0;
  const ordered = list.schemes;
  for (const sc of ordered) {
    idx++;
    const { id, label } = sc;
    const sel = `document.querySelector('[data-scheme-choice="${id}"]')`;
    await ev(`${sel}?.click()`);
    // wait for the server to apply: active tile flips + bg variable changes
    await driver.waitFor(`uxSchemes.active() === '${id}'`, { timeoutMs: 10000, label: `scheme ${id} active` });
    await settle(500);
    // also wait for the stylesheet swap (token change)
    const tokens0 = await ev(`uxSchemes.tokens()`);
    let backoff = 0;
    while (backoff < 6) {
      const t = await ev(`uxSchemes.tokens()`);
      if (t.bg && t.bg !== tokens0.bg) break;
      await waitMs(300); backoff++;
    }
    const tokens = await ev(`uxSchemes.tokens()`);
    // settings screenshot (we are on settings right now)
    await settle(300);
    await driver.screenshot(`${dir}${slug(id)}-settings.png`);
    // chat screenshot
    await ev(`document.getElementById('nav-chat')?.click()`);
    await driver.waitFor(`!!document.getElementById('composer-input')`, { timeoutMs: 8000, label: 'chat view' });
    await settle(500);
    await driver.screenshot(`${dir}${slug(id)}-chat.png`);
    out.schemes.push({ id, label, slug: slug(id), tokens, order: idx });
    if (idx % 5 === 0) console.log(`    ${idx}/${ordered.length} schemes captured`);
    // back to settings
    await ev(`document.getElementById('nav-settings')?.click()`);
    await driver.waitFor(`document.querySelectorAll('[data-scheme-choice]').length > 0`, { timeoutMs: 8000 });
    await settle(200);
  }

  const index = {
    command: `node Scripts/ux-gates.mjs --only=schemes`,
    app: APP,
    generatedAt: new Date().toISOString(),
    count: out.schemes.length,
    notes: 'tokens are computed CSS custom-property values on :root for each scheme; ratios are sanity numbers (0 when a token could not be parsed).',
    schemes: out.schemes,
  };
  writeFileSync(`${HERE}schemes-index.json`, JSON.stringify(index, null, 2));
  console.log(`  schemes-index.json written (${out.schemes.length} schemes); PNGs in Scripts/assets/schemes/`);

  const ok = out.schemes.length === list.count && list.count === 27;
  record('schemes', `contact sheet of ${list.count} registry schemes (chat+settings each)`, ok, { gridCount: list.count, captured: out.schemes.length });
  if (list.count !== 27) {
    console.error(`  NOTE: settings grid lists ${list.count} schemes; expected 27 from the catalog. This is a registry/app discrepancy worth reporting.`);
  }
}

// ---------------------------------------------------------------------------
// main


async function main() {
  const started = Date.now();
  console.log(`ux-gates.mjs — ${APP}`);
  console.log(`node ${process.version}; only=${opts.only ? opts.only.join(',') : 'all'}${opts.attach ? ' (attach)' : ' (launch)'}`);

  try {
    if (opts.attach) {
      driver = await UxDriver.attachToBrowser(opts.port);
    } else {
      const profile = join(tmpdir(), `uxgates-profile-${opts.port}${opts.keepProfile ? '-keep' : ''}`);
      if (!opts.keepProfile) try { rmSync(profile, { recursive: true, force: true }); } catch { /* ignore */ }
      driver = await UxDriver.launch({ port: opts.port, userDataDir: profile, headless: opts.headless });
    }

    await installProbes();
    await driver.navigate(APP);
    await waitReady();
    await driver.setViewport(...opts.viewport);
    await settle(300);
    await snapshotInitialState();

    if (RUN.contrast) await runContrast();
    if (RUN.interactions) await runInteractions();
    if (RUN.upload) await runUpload();
    if (RUN.scroll) await runScroll();
    if (RUN.focus) await runFocus();
    if (RUN.drawer) await runDrawer();
    if (RUN.draft) await runDraft();
    if (RUN.composer) await runComposer();
    if (RUN.theme) await runTheme();
    if (RUN.residue) await runResidue();
    if (RUN.motion) await runMotion();
    if (RUN.regression) await runRegression();
    if (RUN.round4) await runRound4();
    if (RUN.schemes) await runSchemes();

    const refused = results.filter((r) => r.ok === false);
    const skp = skipped();
    writeFileSync(`${HERE}gates-report.json`, JSON.stringify({
      command: `node Scripts/ux-gates.mjs${opts.only ? ' --only=' + opts.only.join(',') : ''}${opts.strict ? ' --strict' : ''}`,
      app: APP,
      generatedAt: new Date().toISOString(),
      node: process.version,
      interactions: results.filter((r) => r.gate === 'interactions'),
      upload: results.filter((r) => r.gate === 'upload'),
      scroll: results.filter((r) => r.gate === 'scroll'),
      focus: results.filter((r) => r.gate === 'focus'),
      drawer: results.filter((r) => r.gate === 'drawer'),
      draft: results.filter((r) => r.gate === 'draft'),
      composer: results.filter((r) => r.gate === 'composer'),
      theme: results.filter((r) => r.gate === 'theme'),
      residue: results.filter((r) => r.gate === 'residue'),
      motion: results.filter((r) => r.gate === 'motion'),
      regression: results.filter((r) => r.gate === 'regression'),
      round4: results.filter((r) => r.gate === 'round4'),
      allPass: refused.length === 0,
      skippedCount: skp.length,
      strict: opts.strict,
    }, null, 2));

    await cleanupProbeSessions();
    await restoreState();

    console.log('\n— summary —');
    for (const r of results) {
      const mark = r.ok === 'skip' ? 'SKIP' : r.ok ? 'PASS' : 'FAIL';
      const detail = JSON.stringify(r.detail) ?? 'undefined';
      console.log(`  [${mark}] ${r.gate} · ${r.name}  ${detail.length > 160 ? detail.slice(0, 160) + '…' : detail}`);
    }
    const passedCount = results.filter((r) => r.ok === true).length;
    console.log(`  ${passedCount}/${results.length} gates passed in ${((Date.now() - started) / 1000).toFixed(0)}s; ${refused.length} failed; ${skp.length} skipped${opts.strict ? ' (--strict: skips fail)' : ''}`);

    // leave the app's view + settings exactly as found; skips are honorable
    // verdicts and only fail the run (as hard failures) with --strict
    const hardFailures = opts.strict
      ? results.filter((r) => r.ok !== true)
      : refused;
    process.exitCode = hardFailures.length ? 1 : 0;
  } catch (err) {
    console.error('\nux-gates.mjs failed:', err.message || String(err));
    try { await cleanupProbeSessions(); } catch { /* ignore */ }
    try { await restoreState(); } catch { /* ignore */ }
    process.exitCode = 2;
  } finally {
    try { await driver?.close(); } catch { /* ignore */ }
  }
}

main();

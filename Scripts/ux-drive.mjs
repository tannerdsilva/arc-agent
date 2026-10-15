// ux-drive.mjs — zero-dependency CDP driver for the arc web UI gates.
//
// Native Node APIs ONLY: global fetch + global WebSocket. No npm, no
// package.json, no node_modules, no CI config. Node >= 22 is required
// (that is when global fetch/WebSocket are stable).
//
// Capabilities used by Scripts/ux-gates.mjs:
//   - assert node >= 22 with a clear error
//   - attach to a Chrome already exposing http://127.0.0.1:9222/json, OR
//     launch /Applications/Google Chrome.app/.../Google Chrome headless with
//     --remote-debugging-port + a temp --user-data-dir
//   - Runtime.enable BEFORE navigation (console from page load is captured
//     via Runtime.consoleAPICalled + Log.entryAdded)
//   - Page.enable + navigate + wait for load
//   - Runtime.evaluate {returnByValue, awaitPromise}
//   - Emulation.setEmulatedMedia (prefers-reduced-motion)
//   - Emulation.setDeviceMetricsOverride (width/height/dpr)
//   - Page.captureScreenshot -> PNG written to a path
//   - Page.addScriptToEvaluateOnNewDocument (inject probe files pre-load)
//   - CDP-level input (Tab/Escape/Enter keys, mouse clicks at coordinates)
//
// The driver itself never opens .png files; screenshots are written for the
// orchestrator to eyeball. All assertions are numeric/DOM reads via
// Runtime.evaluate.

import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const NODE_OK = (() => {
  const m = /^v(\d+)\./.exec(process.version);
  return m && parseInt(m[1], 10) >= 22;
})();
if (!NODE_OK) {
  console.error(`ux-drive.mjs: requires Node >= 22 (native fetch + WebSocket); running ${process.version}`);
  process.exit(2);
}

const CHROME_PATH = process.env.ARC_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function flattenArg(arg) {
  if (arg === undefined || arg === null) return arg;
  if (typeof arg.value !== 'undefined') {
    // Objects come back as value:[...].(JSON) for deep objects; unwrap the
    // common JSON-wrapped shape so error stacks / objects are readable.
    const v = arg.value;
    if (typeof v === 'object' && v && typeof v.description === 'string' && v.description.startsWith('[')) {
      try { return JSON.parse(v.description.slice(1, -1)); } catch { /* keep v */ }
    }
    return v;
  }
  if (typeof arg.description === 'string') return arg.description;
  return String(arg);
}

export class UxDriver {
  constructor() {
    this.ws = null;
    this.id = 0;
    this.pending = new Map(); // id -> {resolve, reject, method}
    this.consoleLog = []; // {kind, level, text, ts}
    this.child = null;
    this.ready = false;
  }

  // ---- static constructors -------------------------------------------------

  /** Attach to an existing page's WebSocket debugger URL. */
  static async attach(wsUrl, { timeoutMs = 10000 } = {}) {
    const d = new UxDriver();
    const ws = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`attach timeout to ${wsUrl}`)), timeoutMs);
      ws.addEventListener('open', () => { clearTimeout(t); resolve(); }, { once: true });
      ws.addEventListener('error', () => { clearTimeout(t); reject(new Error(`attach failed to ${wsUrl}`)); }, { once: true });
    });
    d.ws = ws;
    ws.addEventListener('message', (ev) => d._onMessage(ev.data));
    await d.send('Runtime.enable');
    await d.send('Page.enable');
    await d.send('Log.enable');
    await d._installConsole();
    d.ready = true;
    return d;
  }

  /** Attach to the first *page* target exposed by a browser on :port/json. */
  static async attachToBrowser(port = 9222, { timeoutMs = 15000, mintTab = true } = {}) {
    let list = null;
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      try {
        const res = await fetch(`http://127.0.0.1:${port}/json`);
        if (res.ok) {
          list = await res.json();
          const page = list.find((t) => t.type === 'page' && !t.url.startsWith('devtools:'));
          if (page) return UxDriver.attach(page.webSocketDebuggerUrl);
        }
      } catch { /* retry */ }
      await sleep(250);
    }
    // Browser is up but exposes no page target yet — mint a fresh tab
    // (launch passes about:blank, which can race the window registration).
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const res = await fetch(`http://127.0.0.1:${port}/json/new?about%3Ablank`, { method: 'PUT' });
        if (res.ok) {
          const page = await res.json();
          if (page && page.webSocketDebuggerUrl) return UxDriver.attach(page.webSocketDebuggerUrl);
        }
      } catch { /* retry */ }
      await sleep(300);
    }
    throw new Error(`:${port} never exposed a page target (${list ? list.length : 0} targets)`);
  }

  /**
   * Launch Chrome headless and attach. `userDataDir` should be a throwaway
   * path (the gates use a fresh temp dir unless --keep-profile is passed).
   */
  static async launch({ port = 9222, userDataDir, headless = true, windowSize = '1440,900', timeoutMs = 20000 } = {}) {
    if (!userDataDir) throw new Error('launch(): userDataDir is required');
    const args = [
      '--remote-debugging-port=' + port,
      `--user-data-dir=${userDataDir}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-sync',
      '--metrics-recording-only',
      '--mute-audio',
      '--window-size=' + windowSize,
      'about:blank',
    ];
    if (headless) args.unshift('--headless=new');
    const child = spawn(CHROME_PATH, args, { stdio: 'ignore' });
    child.on('error', (err) => {
      throw new Error(`failed to spawn Chrome at ${CHROME_PATH} (${err.message}) — set ARC_CHROME if Chrome lives elsewhere`);
    });
    let driver;
    try {
      driver = await UxDriver.attachToBrowser(port, { timeoutMs });
    } catch (err) {
      try { child.kill('SIGKILL'); } catch { /* ignore */ }
      throw err;
    }
    driver.child = child;
    return driver;
  }

  // ---- core CDP plumbing ---------------------------------------------------

  send(method, params = {}) {
    const id = ++this.id;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      const t = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP timeout: ${method} (${JSON.stringify(params).slice(0, 120)})`));
      }, 30000);
      const entry = this.pending.get(id);
      entry.timer = t;
    });
  }

  _onMessage(raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    if (msg.id && this.pending.has(msg.id)) {
      const p = this.pending.get(msg.id);
      this.pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(`${p.method} :: ${msg.error.message}`));
      else p.resolve(msg.result || {});
      return;
    }
    if (msg.method) this._onEvent(msg.method, msg.params || {});
  }

  _onEvent(method, params) {
    if (method === 'Runtime.consoleAPICalled') {
      const text = (params.args || []).map(flattenArg).map((a) => (typeof a === 'object' ? JSON.stringify(a) : String(a))).join(' ');
      this.consoleLog.push({ kind: 'console', level: params.type || 'log', text, ts: params.timestamp });
    } else if (method === 'Log.entryAdded') {
      const e = params.entry || {};
      this.consoleLog.push({ kind: 'log', level: e.level || 'info', text: e.text || '', source: e.source || '', url: e.url || '', ts: Date.now() });
    } else if (method === 'Runtime.exceptionThrown') {
      const d = params.exceptionDetails || {};
      let text = d.text || 'Uncaught exception';
      try {
        if (d.exception?.description) text = d.exception.description;
        else if (d.exception?.value) text = String(d.exception.value);
      } catch { /* ignore */ }
      this.consoleLog.push({ kind: 'exception', level: 'error', text, ts: Date.now() });
    } else if (method === 'Network.loadingFailed') {
      const e = params;
      this.consoleLog.push({ kind: 'network', level: e.canceled ? 'info' : 'warning', text: `${e.type} ${e.errorText} ${e.canceled ? '(canceled)' : ''}`.trim(), url: (e.requestId || ''), ts: Date.now() });
    }
  }

  async _installConsole() {
    await this.send('Network.enable');
  }

  enableBeforeNav() {
    // Runtime/Log/Page already enabled in attach(); console buffer starts here.
    this.consoleLog = [];
  }

  clearConsole() { this.consoleLog = []; }
  get console() { return this.consoleLog.slice(); }

  /**
   * Classify captured console into gate-meaningful buckets. Errors/warnings
   * (including the engine's own console-api warnings and uncaught exceptions)
   * are the hard failures; verbose/info/log are reported but never fail.
   */
  consoleReport() {
    const out = { entries: this.consoleLog, errors: [], warnings: [], info: [] };
    for (const e of this.consoleLog) {
      const lvl = String(e.level || '');
      const isErr = lvl === 'error' || lvl === 'assert' || e.kind === 'exception';
      const isWarn = lvl === 'warning' || (lvl === 'log' && e.level === undefined ? false : lvl === 'log' && /warning/i.test(e.text)) || /\[WebUIEngine\]/i.test(e.text);
      if (e.kind === 'network' && !e.canceled && e.level === 'warning') { out.errors.push(e); continue; }
      if (isErr) out.errors.push(e);
      else if (isWarn) out.warnings.push(e);
      else out.info.push(e);
    }
    return out;
  }

  // ---- navigation / evaluation --------------------------------------------

  async navigate(url, { waitLoad = true, timeoutMs = 20000 } = {}) {
    await this.send('Page.navigate', { url });
    if (!waitLoad) return;
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      const st = await this.js(`({ readystate: document.readyState, hasApp: !!document.getElementById('app') })`);
      if (st && st.readystate === 'complete' && st.hasApp) return;
      await sleep(250);
    }
    throw new Error(`navigate(): page did not reach app-ready in ${timeoutMs}ms`);
  }

  async waitFor(expr, { timeoutMs = 15000, label = expr } = {}) {
    const t0 = Date.now();
    let last = null;
    while (Date.now() - t0 < timeoutMs) {
      try {
        last = await this.js(expr);
        if (last) return last;
      } catch (e) { last = String(e); }
      await sleep(150);
    }
    throw new Error(`waitFor(${label}) timed out; last=${JSON.stringify(last)}`);
  }

  async js(expr, opts = {}) {
    const res = await this.send('Runtime.evaluate', {
      expression: expr,
      returnByValue: opts.returnByValue !== false,
      awaitPromise: !!opts.awaitPromise,
    });
    if (res.exceptionDetails) {
      const d = res.exceptionDetails;
      const txt = d.exception?.description || d.text || 'evaluate threw';
      throw new Error(`evaluate threw: ${txt.slice(0, 300)}`);
    }
    return res.result ? res.result.value : undefined;
  }

  /** Evaluate and require a truthy JSON value (throws describing the expr). */
  async mustTrue(expr, label = expr) {
    const v = await this.js(expr);
    if (!v) throw new Error(`assertion failed: ${label}\nexpr: ${expr.slice(0, 200)}`);
    return v;
  }

  // ---- emulation -----------------------------------------------------------

  async setReducedMotion(reduce = true) {
    await this.send('Emulation.setEmulatedMedia', {
      media: '',
      features: [{ name: 'prefers-reduced-motion', value: reduce ? 'reduce' : 'no-preference' }],
    });
  }

  async setViewport(width, height, { dpr = 1, mobile = false } = {}) {
    await this.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: dpr, mobile, screenWidth: width, screenHeight: height });
  }

  // ---- screenshots ---------------------------------------------------------

  async screenshot(path) {
    const res = await this.send('Page.captureScreenshot', { format: 'png', fromSurface: true });
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, Buffer.from(res.data, 'base64'));
    return path;
  }

  // ---- init scripts --------------------------------------------------------

  async addInitScript(source) {
    await this.send('Page.addScriptToEvaluateOnNewDocument', { source });
  }

  // ---- input ---------------------------------------------------------------

  async pressKey(key, opts = {}) {
    // key: 'Tab' | 'Escape' | 'Enter' | 'ArrowUp' | 'ArrowDown' | 'Backspace'
    const keyMap = {
      Enter: { code: 'Enter', key: 'Enter', text: '\r', vk: 13 },
      Tab: { code: 'Tab', key: 'Tab', vk: 9 },
      Escape: { code: 'Escape', key: 'Escape', vk: 27 },
      ArrowUp: { code: 'ArrowUp', key: 'ArrowUp', vk: 38 },
      ArrowDown: { code: 'ArrowDown', key: 'ArrowDown', vk: 40 },
      ArrowLeft: { code: 'ArrowLeft', key: 'ArrowLeft', vk: 37 },
      ArrowRight: { code: 'ArrowRight', key: 'ArrowRight', vk: 39 },
      Backspace: { code: 'Backspace', key: 'Backspace', vk: 8 },
      Home: { code: 'Home', key: 'Home', vk: 36 },
    };
    const k = keyMap[key];
    if (!k) throw new Error(`pressKey: unknown key ${key}`);
    if (k.text !== undefined) {
      await this.send('Input.dispatchKeyEvent', { type: 'keyDown', key: k.key, code: k.code, windowsVirtualKeyCode: k.vk, text: k.text, unmodifiedText: k.text });
      await this.send('Input.dispatchKeyEvent', { type: 'keyUp', key: k.key, code: k.code, windowsVirtualKeyCode: k.vk });
    } else {
      await this.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: k.key, code: k.code, windowsVirtualKeyCode: k.vk });
      await this.send('Input.dispatchKeyEvent', { type: 'keyUp', key: k.key, code: k.code, windowsVirtualKeyCode: k.vk });
    }
  }

  /** Dispatch a real Tab keypress (needed for focus-trail / tab-budget work). */
  async pressTab() { await this.pressKey('Tab'); }
  async pressEscape() { await this.pressKey('Escape'); }
  async pressEnter() { await this.pressKey('Enter'); }

  async typeText(text) {
    for (const ch of text) {
      await this.send('Input.dispatchKeyEvent', { type: 'char', text: ch });
    }
  }

  async clickAt(x, y) {
    await this.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: Math.round(x), y: Math.round(y), button: 'left', clickCount: 1 });
    await this.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: Math.round(x), y: Math.round(y), button: 'left', clickCount: 1 });
  }

  async close() {
    try { await this.send('Page.close'); } catch { /* ignore */ }
    if (this.child) {
      try { this.child.kill('SIGKILL'); } catch { /* ignore */ }
      this.child = null;
    }
    try { this.ws && this.ws.close(); } catch { /* ignore */ }
  }
}

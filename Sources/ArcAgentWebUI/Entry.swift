import ArcAgentCore
import ArgumentParser
import CryptoKit
import Foundation
import Logging
import ServiceLifecycle
import WebUI
import WebUIServer

// MARK: - Entry point

@main
struct ArcAgentWebUI: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "arc-agent-webui",
        abstract: "ARC Agent web UI (no-webui engine).",
        discussion: """
        Serves the ARC Agent interface: chat, skills, profiles, tools,
        workspaces and settings — built entirely on the no-webui Swift
        library. Sessions and memory use the same stores as the CLI.
        """
    )

    @Option(name: .shortAndLong, help: "Host to bind.")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Port to bind.")
    var port: Int = 8890

    @Flag(name: .long, help: "Use file storage instead of Tessera.")
    var tesseraOff: Bool = false

    /// `data-scheme`/`data-theme` for `<html>`, escaped like every other attribute the
    /// framework emits.
    static func themeAttrs(_ theme: (scheme: String, mode: String)) -> String {
        "data-scheme=\"\(esc(theme.scheme))\" data-theme=\"\(esc(theme.mode))\""
    }

    /// A url that changes when the bytes do: `/ui/style.css?v=<sha256 prefix>`.
    ///
    /// The hand-maintained `?v=47` counter was both forgettable and pointless: the assets
    /// were registered bare and served `no-store`, so the query was a cache key for a
    /// response that never cached, and the 250 kb sheet was re-fetched on every navigation.
    /// Deriving the stamp from the content means a rebuild changes the url by construction,
    /// which is what makes a year-long cache safe: unchanged bytes keep their url, changed
    /// bytes cannot be served under the old one.
    static func stamped(_ path: String, _ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        let stamp = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        return "\(path)?v=\(stamp)"
    }

    func run() async throws {
        // Route every swift-log line into the in-app ring buffer instead of
        // stdout, so logs stop appearing in the terminal and surface in the
        // web UI's Logs section. Must run before any Logger is created.
        LoggingSystem.bootstrap { label in
            WebUILogHandler(label: label)
        }
        let logger = Logger(label: "arc-agent.webui")
        logger.info("starting (pid \(ProcessInfo.processInfo.processIdentifier))")

        let app = try AppState()
        if tesseraOff {
            await app.overrideTesseraOff(true)
        }

        // Timeboxed boot: a Tessera tunnel that never handshakes must not
        // wedge the whole UI — fall back to file storage after 12s.
        // Implemented as an AsyncStream race: a TaskGroup's next() never
        // delivers a timer child's throw while the boot child is suspended
        // forever (Swift 6.3 behavior, observed live), which turns the
        // timeout into a deadlock.
        struct BootTimeout: Error {}
        let stream = AsyncStream<Result<Void, Error>>.makeStream()
        let c = stream.continuation
        // Hold the boot task handle so a timed-out first boot can be CANCELLED
        // before the fallback runs — otherwise it finishes last (~45-70s) and
        // overwrites the store state the fallback just built, blanking the
        // sidebar, and leaks the tunnel it spawned.
        let bootTask = Task {
            do {
                await app.boot()
                c.yield(.success(())); c.finish()
            } catch {
                c.yield(.failure(error)); c.finish()
            }
        }
        Task {
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch {}
            c.yield(.failure(BootTimeout())); c.finish()
        }
        switch await stream.stream.first(where: { _ in true }) {
        case .success:
            await app.crumb("entry: boot race completed cleanly")
        case .failure:
            await app.crumb("entry: boot timeout — fallback to file")
            logger.warning("boot timed out (Tessera unreachable?) — using file storage")
            bootTask.cancel()
            await app.forceTesseraOff()
            await app.boot()
            await app.crumb("entry: fallback boot done")
        case nil:
            await app.crumb("entry: boot race stream ended empty")
        }
        await app.crumb("entry: boot block done")
        logger.info("boot complete")
        let storageDesc = await app.storageDescription()
        logger.info("storage=\(storageDesc)")
        let boot = (
            sessions: await app.sessionCount(),
            skills: await app.skillCount(),
            profiles: await app.profileCount(),
            tools: await app.toolCount()
        )
        logger.info("sessions=\(boot.sessions) skills=\(boot.skills) profiles=\(boot.profiles) tools=\(boot.tools)")

        // Pick a chat to open: the active one if set, else the newest, else a
        // fresh starter chat on a completely empty store.
        if let active = await app.activeSessionIDValue() {
            await app.reloadSessions(selecting: active)
        } else if let newest = await app.newestSessionID() {
            await app.setActiveSession(newest)
        } else {
            await app.ensureRuntime()
            if let store = await app.storeRef() {
                let s = Session()
                try? await store.create(s)
                await app.reloadSessions(selecting: s.id)
            }
        }

        // Wire the router (hand-written fixed component ids). The controller is
        // created further down, once the server that carries its pushes exists.
        let router = EventRouter()

        // The sheet is a build product (`ArcAssetTool theme-sheet`): rendered from
        // `Sources/ArcTheme/`, stamped with the sha256 its url carries, and gzipped at build
        // time. Nothing here renders or hashes 271 kb at boot, and the url, the bytes and the
        // hash cannot disagree — a test pins the product against the source it came from.
        let sheet = ThemeSheetAssets.sheet
        let sheetPath = "/ui/style.css?v=\(ThemeSheetAssets.stamp)"

        // Assemble the page (external /ui/* assets keep each response small).
        // The document template wraps whatever body the app currently renders,
        // so a refresh ALWAYS reflects live store state (a boot-cached page
        // would show sessions deleted after startup).
        // The theme attributes belong on `<html>`, not on `#app`: the engine writes them on
        // `documentElement` and the theme is scoped to `:root`. `themeAttrs` is the server's
        // default, which the engine overrides from storage before first paint.
        let makeDocument: (String, String, String) -> WebUI.HTMLDocument = { body, themeAttrs, initPath in
            WebUI.HTMLDocument(
                title: "ARC Agent",
                body: body,
                rawStyles: [],
                head: """
                <link rel="stylesheet" href="\(sheetPath)">
                <script src="\(initPath)"></script>
                """,
                htmlAttributes: themeAttrs,
                devMode: false,
                // Extras, not a restated policy: a full policy names no nonce source, and
                // `HTMLDocument` then suppresses the pre-paint theme prelude rather than
                // emit an inline script the browser refuses (a stored scheme would flash
                // on every load). This directive is all arc needs beyond the framework
                // default — remote images in rendered markdown.
                contentSecurityPolicyExtras: "img-src 'self' data: https: blob:"
            )
        }
        // The overlay's url is stamped from its bytes, which only exist after the literal
        // below — so the factory takes the path as an argument rather than capturing a
        // variable out of order, and every call site passes the stamped value.
        let pageProvider: @Sendable (String?, String) async -> String = { [app] deepLink, initPath in
            if let sid = deepLink, !sid.isEmpty {
                await app.openDeepLink(sid)
            }
            await app.armScrollToBottom()
            let shell = await app.appShell()
            return makeDocument(shell, Self.themeAttrs(await app.themeDefaults()), initPath).render()
        }

        let initJS = """
        // The client is no-webui's ENGINE: HTMLDocument emits the
        // `webui-config` meta and the engine script itself, so this page no
        // longer boots or serves the legacy WebUIRuntime. What remains below is
        // only the arc-specific overlay (composer, tables, slash menu,
        // selection, outline, worklog) — everything it used to rely on the
        // runtime for (transport, event dispatch, fragment patching, scroll and
        // form-state restore, HTML sanitising) is the engine's job now.

        (function () {
          try {
          // The runtime restores input values across fragment replacements, so a
          // server-side empty textarea would be re-filled. Clear the composer
          // synchronously on submit (after the runtime has read its value).
          document.addEventListener('submit', function (e) {
            if (e.target && e.target.id === 'composer-form') {
              var t = document.getElementById('composer-input');
              if (t) t.value = '';
            }
          });

          // ---- Image paste (arc parity): pasting an image (or image file)
          // into the composer uploads it and attaches it via the existing
          // attach wire, so it flows through describeImage on send. Text
          // pastes are untouched.
          function attachUploadedPath(p) {
            var inp = document.getElementById('file-path-input');
            if (!inp) return;
            var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            setter.call(inp, p);
            inp.dispatchEvent(new Event('input', { bubbles: true }));
            // The runtime debounces input events (~80ms); wait for the path to
            // reach the server before clicking Attach, or the click wins the
            // race and the server sees an empty path.
            setTimeout(function () {
              var btn = document.getElementById('file-attach');
              if (btn) btn.click();
            }, 350);
          }
          document.addEventListener('paste', function (e) {
            if (!e.target || e.target.id !== 'composer-input') return;
            var cd = e.clipboardData;
            if (!cd) return;
            var imgs = [];
            var items = Array.prototype.slice.call(cd.items || []);
            var hasFileItem = false;
            items.forEach(function (it) {
              if (it.kind === 'file') hasFileItem = true;
            });
            if (hasFileItem) {
              // items covers files; reading both would double-attach.
              items.forEach(function (it) {
                if (it.kind === 'file' && it.type && it.type.indexOf('image/') === 0) {
                  var f = it.getAsFile();
                  if (f) imgs.push(f);
                }
              });
            } else {
              Array.prototype.slice.call(cd.files || []).forEach(function (f) {
                if (f.type && f.type.indexOf('image/') === 0) imgs.push(f);
              });
            }
            if (!imgs.length) return; // text paste: normal behavior
            e.preventDefault();
            // Keep any text that travelled with the clipboard.
            var txt = cd.getData ? (cd.getData('text') || '') : '';
            if (txt) {
              var t = document.getElementById('composer-input');
              if (t) {
                t.value = (t.value ? t.value + String.fromCharCode(10) : '') + txt;
                t.dispatchEvent(new Event('input', { bubbles: true }));
              }
            }
            imgs.forEach(function (f) {
              var ext = (f.type.split('/')[1] || 'png').replace(/[^a-z0-9]/gi, '').toLowerCase();
              if (!ext || ext.length > 8) ext = 'img';
              fetch('/api/upload?ext=' + encodeURIComponent(ext), {
                method: 'POST',
                headers: { 'Content-Type': 'application/octet-stream' },
                body: f
              }).then(function (r) { return r.json(); }).then(function (j) {
                if (j && j.ok && j.path) attachUploadedPath(j.path);
              }).catch(function (err) { console.warn('image upload failed', err); });
            });
          });

          // ---- Composer autogrow (arc parity): the textarea expands with
          // content up to 7 visible lines, then scrolls internally.
          function resizeComposer() {
            var t = document.getElementById('composer-input');
            if (!t) return;
            var cs = getComputedStyle(t);
            var lh = parseFloat(cs.lineHeight) || 22;
            var pad = (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.paddingBottom) || 0);
            var max = Math.round(lh * 7 + pad);
            t.style.height = 'auto';
            var h = Math.min(t.scrollHeight, max);
            t.style.height = h + 'px';
            t.style.overflowY = t.scrollHeight > max ? 'auto' : 'hidden';
          }
          // Fragments replace the textarea node on re-renders; resize only when
          // a fresh node appears (keystrokes use the input listener below).
          function resizeComposerIfNew() {
            var t = document.getElementById('composer-input');
            if (t && !t.__rsz) { t.__rsz = true; resizeComposer(); }
          }
          document.addEventListener('input', function (e) {
            if (e.target && e.target.id === 'composer-input') resizeComposer();
          });

          // ---- Scroll-to-bottom. Follows new content while the user is at the
          // bottom, and always jumps to the bottom when a fresh chat is opened
          // (the server tags #chat-scroll with data-follow="bottom" on open).
          var SCROLL_PAD = 120;
          function chatScroller() { return document.getElementById('chat-scroll'); }
          function nearBottom(s) { return s.scrollHeight - s.scrollTop - s.clientHeight < SCROLL_PAD; }
          var stick = true;
          var seenChatScroll = null;
          // ---- Pipe-table enhancement (arc-specific).
          // Lived in the forked runtime until that fork was deleted; it belongs in the
          // overlay and is driven from the engine's afterPatch seam below — pipe tables
          // get per-column sort + a filter input.

            function enhanceMarkdownTables(scope) {
              var tables = scope.querySelectorAll('.msg-body table:not([data-markdown-table-enhanced])');
              for (var t = 0; t < tables.length; t++) {
                (function (table) {
                table.setAttribute('data-markdown-table-enhanced', '1');
                var tbody = table.querySelector('tbody');
                var theadRow = table.querySelector('thead tr');
                if (!tbody || !theadRow) return;
                var bodyRows = tbody.querySelectorAll('tr');
                for (var r = 0; r < bodyRows.length; r++) {
                  bodyRows[r].setAttribute('data-orig', String(r));
                }
                var headerCells = theadRow.querySelectorAll('th');
                for (var c = 0; c < headerCells.length; c++) {
                  var th = headerCells[c];
                  var headWrapper = document.createElement('div');
                  headWrapper.className = 'markdown-table-head';
                  var label = document.createElement('span');
                  label.className = 'markdown-table-sort-label';
                  label.textContent = th.textContent;
                  var sort = document.createElement('button');
                  sort.type = 'button';
                  sort.className = 'markdown-table-sort';
                  sort.title = 'Sort column';
                  sort.textContent = '\\u21C5';
                  sort.addEventListener('click', (function (tbl, colIdx) {
                    return function () {
                      var asc = tbl.getAttribute('data-sort-col') === String(colIdx) &&
                        tbl.getAttribute('data-sort-dir') === 'asc';
                      var dir = asc ? 'desc' : 'asc';
                      tbl.setAttribute('data-sort-col', String(colIdx));
                      tbl.setAttribute('data-sort-dir', dir);
                      var body = tbl.querySelector('tbody');
                      if (!body) return;
                      var rows = Array.prototype.slice.call(body.querySelectorAll('tr'));
                      rows.sort(function (a, b) {
                        var av = a.cells[colIdx] ? (a.cells[colIdx].textContent || '').toLowerCase() : '';
                        var bv = b.cells[colIdx] ? (b.cells[colIdx].textContent || '').toLowerCase() : '';
                        if (av < bv) return dir === 'asc' ? -1 : 1;
                        if (av > bv) return dir === 'asc' ? 1 : -1;
                        return Number(a.getAttribute('data-orig') || 0) - Number(b.getAttribute('data-orig') || 0);
                      });
                      for (var i = 0; i < rows.length; i++) body.appendChild(rows[i]);
                      var sels = tbl.querySelectorAll('.markdown-table-sort');
                      for (var s = 0; s < sels.length; s++) {
                        sels[s].textContent = s === colIdx ? (dir === 'asc' ? '\\u25B2' : '\\u25BC') : '\\u21C5';
                      }
                    };
                  })(table, c));
                  headWrapper.appendChild(label);
                  headWrapper.appendChild(sort);
                  th.textContent = '';
                  th.appendChild(headWrapper);
                }
                var filter = document.createElement('input');
                filter.type = 'text';
                filter.className = 'markdown-table-filter';
                filter.placeholder = 'Filter table';
                // Delegated on the table so the handler survives any re-render that
                // replaces the input element.
                table.addEventListener('input', function (ev) {
                  var inp = ev && ev.target;
                  if (!inp || !inp.classList || !inp.classList.contains('markdown-table-filter')) return;
                  var q = inp.value.toLowerCase();
                  var rows = table.querySelectorAll('tbody tr');
                  for (var r = 0; r < rows.length; r++) {
                    rows[r].hidden = !!q && (rows[r].textContent || '').toLowerCase().indexOf(q) === -1;
                  }
                });
                var frow = document.createElement('tr');
                frow.className = 'markdown-table-filter-row';
                var fcell = document.createElement('th');
                fcell.colSpan = headerCells.length;
                fcell.appendChild(filter);
                frow.appendChild(fcell);
                theadRow.parentNode.insertBefore(frow, theadRow.nextSibling);
                })(tables[t]);
              }
            }

          // ---- Post-patch seam. The engine hands `afterPatch` the array of elements a
          // fragment batch replaced, so enhancement is scoped to what actually changed
          // instead of rescanning the whole document on every mutation — the old
          // MutationObserver also fired on the overlay's own edits, so it thrashed while
          // a turn streamed. `ready` only fires for hooks registered before the engine
          // boots; this overlay is a separate script that runs first, so registration
          // happens on DOMContentLoaded (after the engine's synchronous boot) and the
          // initial pass is invoked directly. Every pass is idempotent — rendered blocks
          // and enhanced tables are marked, the scroll listener is bound once — which is
          // what makes the extra call safe.
          function stickToChat() {
            var s = chatScroller();
            if (!s) return;
            if (!s.__bound) {
              s.__bound = true;
              s.addEventListener('scroll', function () {
                stick = nearBottom(s);
                updateJumpBtn(s);
              });
            }
            if (s !== seenChatScroll) {
              // The scroll container was (re)created — a chat open or a
              // streaming refresh. Respect data-follow only for chat opens.
              seenChatScroll = s;
              if (s.getAttribute('data-follow') === 'bottom') {
                stick = true;
                var forceBottom = function () {
                  var cur = chatScroller();
                  if (cur === s) s.scrollTop = s.scrollHeight;
                };
                requestAnimationFrame(forceBottom);
                setTimeout(forceBottom, 60);
              } else if (stick) {
                s.scrollTop = s.scrollHeight;
              }
            } else if (stick) {
              s.scrollTop = s.scrollHeight;
            }
          }

          function enhanceAll() {
            resizeComposerIfNew();
            enhanceMarkdownTables(document);
            stickToChat();
          }

          function enhancePatched(changed) {
            resizeComposerIfNew();
            if (changed && changed.length) {
              for (var i = 0; i < changed.length; i++) {
                enhanceMarkdownTables(changed[i]);
              }
            } else {
              // A runtime that hands no subtree: fall back to a document pass.
              enhanceMarkdownTables(document);
            }
            stickToChat();
          }

          function bootOverlay() {
            if (window.WebUIEngine && WebUIEngine.on) {
              WebUIEngine.on.afterPatch(enhancePatched);
              WebUIEngine.on.ready(enhanceAll);
            }
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

          // ---- Jump-to-latest circle button (arc parity): appears when the
          // user has scrolled away from the bottom; click returns to the end.
          function updateJumpBtn(s) {
            var b = document.getElementById('scroll-to-bottom');
            if (!b) return;
            b.hidden = nearBottom(s);
          }
          document.addEventListener('click', function (e) {
            var b = e.target && e.target.closest ? e.target.closest('#scroll-to-bottom') : null;
            if (!b) return;
            var s = chatScroller();
            if (!s) return;
            stick = true;
            s.scrollTo({ top: s.scrollHeight, behavior: 'smooth' });
          });

          // ---- Session group headers (Today / Last Week / Older): collapse
          // and expand entirely client-side.
          document.addEventListener('click', function (e) {
            var h = e.target && e.target.closest ? e.target.closest('.sess-group-head') : null;
            if (!h) return;
            var g = h.closest('.sess-group');
            if (g) g.classList.toggle('collapsed');
          });
          // ---- Skill category groups: click header to collapse/expand.
          document.addEventListener('click', function (e) {
            var h = e.target && e.target.closest ? e.target.closest('.skill-cat-head') : null;
            if (!h) return;
            var g = h.closest('.skill-group');
            if (g) g.classList.toggle('collapsed');
          });

          // ---- Sidebar-tab chips (Settings > Appearance): HTML5 drag to
          // reorder. The visible order is recomputed from the checked chips
          // (only visible tabs matter) and pushed through the hidden order
          // input so the server persists it.
          document.addEventListener('dragstart', function (e) {
            var chip = e.target && e.target.closest ? e.target.closest('.side-tab-chip') : null;
            if (!chip) return;
            e.dataTransfer.setData('text/plain', 'side-tab');
            e.dataTransfer.effectAllowed = 'move';
            chip.classList.add('drag-src');
          });
          document.addEventListener('dragover', function (e) {
            var chip = e.target && e.target.closest ? e.target.closest('.side-tab-chip') : null;
            if (!chip) return;
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';
          });
          document.addEventListener('drop', function (e) {
            var chip = e.target && e.target.closest ? e.target.closest('.side-tab-chip') : null;
            if (!chip) return;
            e.preventDefault();
            var src = document.querySelector('.side-tab-chip.drag-src');
            if (!src || src === chip) { if (src) src.classList.remove('drag-src'); return; }
            var moved = false;
            try {
              var after = (chip.compareDocumentPosition(src) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
              if (after) { chip.after(src); moved = true; }
              else { chip.before(src); moved = true; }
            } catch (err) { }
            src.classList.remove('drag-src');
            if (!moved) return;
            var container = chip.closest('.side-tab-chips') || chip.parentElement;
            // The full chip order is the canonical order (hidden chips keep
            // their slots), so every chip contributes a key.
            var order = [];
            container.querySelectorAll('.side-tab-chip').forEach(function (chip) {
              var inp = chip.querySelector('input');
              var id = inp && inp.id || '';
              if (id.indexOf('st-') === 0) {
                try { order.push(atob(id.slice(3))); } catch (err) { }
              }
            });
            var hidden = document.getElementById('sidebar-tab-order');
            if (hidden) {
              hidden.value = order.join(',');
              hidden.dispatchEvent(new Event('change', { bubbles: true }));
            }
          });
          document.addEventListener('dragend', function (e) {
            var src = document.querySelector('.side-tab-chip.drag-src');
            if (src) src.classList.remove('drag-src');
          });

          // ---- Relative session times: refresh every 60s (arc parity).
          function relLabel(ms) {
            if (!ms) return '';
            var d = new Date(ms), now = new Date();
            var diff = Math.max(0, now - d);
            if (diff < 60000) return '1m';
            if (diff < 3600000) return Math.floor(diff / 60000) + 'm';
            if (diff < 86400000) return Math.floor(diff / 3600000) + 'h';
            var s0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
            var s1 = new Date(d.getFullYear(), d.getMonth(), d.getDate());
            var days = Math.round((s0 - s1) / 86400000);
            if (days < 7) return Math.max(days, 1) + 'd';
            var M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
            var base = M[d.getMonth()] + ' ' + d.getDate();
            if (d.getFullYear() !== now.getFullYear()) base += ', ' + String(d.getFullYear()).slice(-2);
            return base;
          }
          setInterval(function () {
            var els = document.querySelectorAll('[data-reltime]');
            for (var i = 0; i < els.length; i++) {
              var ts = parseInt(els[i].getAttribute('data-reltime'), 10);
              if (!isNaN(ts)) els[i].textContent = relLabel(ts);
            }
          }, 60000);

          // ---- Chat row "..." menu: open/close is client-side so the open
          // menu survives the click that opened it; edge actions still go to
          // the server through the normal runtime pipeline.
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

          // ---- Copy conversation link (client-side clipboard + toast).
          document.addEventListener('click', function (e) {
            var b = e.target && e.target.closest ? e.target.closest('[id^="sm-copy-"]') : null;
            if (!b) return;
            var sid = b.getAttribute('data-sid');
            if (!sid) return;
            var url = location.origin + location.pathname + '?s=' + encodeURIComponent(sid);
            function copied() { flashToast('Conversation link copied.'); }
            function failed() { flashToast('Could not copy the link.', 'error'); }
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(url).then(copied, failed);
            } else {
              var ta = document.createElement('textarea');
              ta.value = url;
              ta.style.position = 'fixed';
              ta.style.opacity = '0';
              document.body.appendChild(ta);
              ta.select();
              try { document.execCommand('copy'); copied(); } catch (err) { failed(); }
              document.body.removeChild(ta);
            }
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
            var current = ((openBtn.querySelector('.sess-title') || {}).textContent || '').trim();
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

          // Small transient toast for client-side notices (server toasts still
          // own the #toasts stream, so this only fills the gap briefly).
          function flashToast(text, kind) {
            if (kind !== 'error') return;   // only error notices appear (routine ones stay quiet)
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

          // ---- Workspace panel: slide-out before the ✕/arrow close lands.
          // The runtime performs the real close (replacing the panel with the
          // closed fragment); we intercept the first click, play the exit
          // transition, then re-click so the server state stays in sync.
          var wsAnimBusy = false;
          document.addEventListener('click', function (e) {
            var b = e.target && e.target.closest ? e.target.closest('#w-close, #w-dock') : null;
            if (!b) return;
            var p = document.getElementById('ws-panel');
            if (!p || p.classList.contains('hidden') || p.classList.contains('ws-closing') || wsAnimBusy) return;
            wsAnimBusy = true;
            e.preventDefault();
            e.stopImmediatePropagation();
            void p.offsetWidth; // force reflow so the transition actually runs
            p.classList.add('ws-closing');
            setTimeout(function () {
              wsAnimBusy = false;
              var btn = document.getElementById('w-close') || document.getElementById('w-dock');
              if (btn) btn.click();
            }, 300);
          }, true);

          // ── Workspace panel: uploads (button picker + drag & drop) ────────
          // NOTE: init.js runs in <head>, so document.body is null at parse
          // time. Anything that touches the live DOM tree (creating the hidden
          // file input, binding drag handlers on #ws-panel) must wait until the
          // document is ready — otherwise a TypeError kills every later handler.
          var wsFileInput = null;

          function wsUploadForm() {
            var f = document.getElementById('ws-upload-form');
            if (!f) {
              f = document.createElement('form');
              f.id = 'ws-upload-form';
              f.style.display = 'none';
              f.setAttribute('data-component-id', 'workspace-upload');
              f.innerHTML = '<input type="hidden" name="upl-name"><input type="hidden" name="upl-path"><input type="hidden" name="upl-b64">';
              document.body.appendChild(f);
            }
            return f;
          }

          function readFileAsB64(file, cb) {
            var reader = new FileReader();
            reader.onload = function (ev) {
              var b64 = String(ev.target.result || '').split(',')[1] || '';
              cb(b64);
            };
            reader.onerror = function () { flashToast('Failed to read ' + file.name, 'error'); cb(null); };
            reader.readAsDataURL(file);
          }

          function sendUpload(file, relPath) {
            var LIMIT = 10 * 1024 * 1024;
            if (file.size > LIMIT) {
              flashToast('"' + file.name + '" is larger than 10 MB', 'error');
              return;
            }
            readFileAsB64(file, function (b64) {
              if (b64 === null) return;
              var f = wsUploadForm();
              f.querySelector('[name="upl-name"]').value = file.name;
              f.querySelector('[name="upl-path"]').value = relPath;
              f.querySelector('[name="upl-b64"]').value = b64;
              try { f.requestSubmit(); } catch (err) { f.submit(); }
            });
          }

          function collectEntry(entry, base, done) {
            if (entry.isFile) {
              entry.file(function (file) {
                done(file, base ? base + '/' + entry.name : entry.name);
              }, function () { done(null, null); });
            } else if (entry.isDirectory) {
              var reader = entry.createReader();
              var all = [];
              (function readBatch() {
                reader.readEntries(function (entries) {
                  if (!entries.length) {
                    all.forEach(function (e) { collectEntry(e, base ? base + '/' + entry.name : entry.name, done); });
                  } else {
                    all = all.concat(entries);
                    readBatch();
                  }
                }, function () { });
              })();
            }
          }

          function handleFiles(fileList) {
            for (var i = 0; i < fileList.length; i++) sendUpload(fileList[i], fileList[i].name);
          }

          function bootWorkspaceDom() {
            wsFileInput = document.getElementById('ws-file-input');
            if (!wsFileInput) {
              wsFileInput = document.createElement('input');
              wsFileInput.type = 'file';
              wsFileInput.id = 'ws-file-input';
              wsFileInput.multiple = true;
              wsFileInput.style.display = 'none';
              document.body.appendChild(wsFileInput);
            }
            wsFileInput.addEventListener('change', function () {
              if (wsFileInput.files) handleFiles(wsFileInput.files);
              wsFileInput.value = '';
            });

            // Drag & drop is delegated at DOCUMENT level: fragment re-renders
            // replace the #ws-panel element, and a listener bound to an old
            // node would be silently lost. The current panel is looked up on
            // every event instead.
            function currentPanel() {
              var p = document.getElementById('ws-panel');
              return (p && !p.classList.contains('hidden')) ? p : null;
            }
            document.addEventListener('dragover', function (e) {
              var p = currentPanel();
              if (!p || !e.target.closest || !e.target.closest('#ws-panel')) return;
              e.preventDefault();
              e.dataTransfer.dropEffect = 'copy';
              p.classList.add('drag');
            });
            document.addEventListener('dragleave', function (e) {
              var p = document.getElementById('ws-panel');
              if (!p) return;
              if (e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest('#ws-panel')) return;
              p.classList.remove('drag');
            });
            document.addEventListener('drop', function (e) {
              var p = currentPanel();
              if (!p || !e.target.closest || !e.target.closest('#ws-panel')) return;
              e.preventDefault();
              p.classList.remove('drag');
              var items = e.dataTransfer && e.dataTransfer.items;
              if (items && items.length) {
                for (var i = 0; i < items.length; i++) {
                  var entry = items[i].webkitGetAsEntry ? items[i].webkitGetAsEntry() : null;
                  if (entry) {
                    collectEntry(entry, '', function (file, path) { if (file) sendUpload(file, path); });
                  } else if (items[i].kind === 'file') {
                    // Fallback: non-filesystem-backed item (synthetic or
                    // some browsers) exposes the raw File directly.
                    var f = items[i].getAsFile ? items[i].getAsFile() : null;
                    if (f) sendUpload(f, f.name);
                  }
                }
              } else if (e.dataTransfer && e.dataTransfer.files) {
                handleFiles(e.dataTransfer.files);
              }
            });
          }

          function bootOnReady(fn) {
            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', fn);
            } else {
              fn();
            }
          }
          bootOnReady(bootWorkspaceDom);

          document.addEventListener('click', function (e) {
            // Upload button → open the native file picker.
            if (e.target && e.target.closest && e.target.closest('[id="w-upload"]')) {
              e.preventDefault();
              if (wsFileInput) wsFileInput.click();
              return;
            }
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

          // ── Kanban: inline column rename / card title edit ──────────────
          document.addEventListener('click', function (e) {
            var rn = e.target && e.target.closest ? e.target.closest('[id^="kb-rencol-"]') : null;
            if (rn) {
              e.preventDefault();
              startInlineEdit(rn, { col: rn.getAttribute('data-colid') || '' });
              return;
            }
            var ed = e.target && e.target.closest ? e.target.closest('[id^="kb-edit-"]') : null;
            if (ed) {
              e.preventDefault();
              startInlineEdit(ed, { card: ed.getAttribute('data-cardid') || '' });
              return;
            }
          });

          function startInlineEdit(btn, key) {
            var host = btn.closest('.kb-col-head') || btn.closest('.kb-card');
            if (!host) return;
            var target = host.querySelector('.kb-col-name, .kb-card-title');
            if (!target) return;
            var cls = target.className;
            var current = (target.textContent || '').trim();
            var rect = target.getBoundingClientRect();
            var input = document.createElement('input');
            input.type = 'text';
            input.value = current;
            input.className = 'inline-edit';
            input.style.width = Math.max(120, rect.width + 20) + 'px';
            target.replaceWith(input);
            input.focus();
            var settled = false;
            function restore() {
              var back = document.createElement('span');
              back.className = cls;
              back.textContent = current;
              input.replaceWith(back);
            }
            function commit() {
              if (settled) return;
              settled = true;
              var val = input.value.trim();
              if (val === '' || val === current) { restore(); return; }
              var f = document.getElementById('kanban-inline-form');
              if (!f) {
                f = document.createElement('form');
                f.id = 'kanban-inline-form';
                f.style.display = 'none';
                f.setAttribute('data-component-id', 'kanban');
                f.innerHTML = '<input type="hidden" name="kb-col-id"><input type="hidden" name="kb-col-name"><input type="hidden" name="kb-card-id"><input type="hidden" name="kb-card-title">';
                document.body.appendChild(f);
              }
              if (key.col) {
                f.querySelector('[name="kb-col-id"]').value = key.col;
                f.querySelector('[name="kb-col-name"]').value = val;
              } else {
                f.querySelector('[name="kb-card-id"]').value = key.card;
                f.querySelector('[name="kb-card-title"]').value = val;
              }
              try { f.requestSubmit(); } catch (err) { f.submit(); }
            }
            function cancel() {
              if (settled) return;
              settled = true;
              restore();
            }
            input.addEventListener('keydown', function (ev) {
              if (ev.key === 'Enter') { ev.preventDefault(); commit(); }
              else if (ev.key === 'Escape') { ev.preventDefault(); cancel(); }
            });
            input.addEventListener('blur', commit);
            input.addEventListener('click', function (ev) { ev.stopPropagation(); });
          }
          } catch (err) {
            if (typeof console !== 'undefined' && console.error) {
              console.error('arc-agent init failed:', err);
            }
          }
          // ---- Copy code blocks + message responses (delegated).
          document.addEventListener('click', function (e) {
            var b = e.target && e.target.closest ? e.target.closest('[data-copy]') : null;
            if (!b) return;
            var text = b.getAttribute('data-copy') || '';
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(text).then(function () {
                var orig = b.innerHTML;
                b.innerHTML = '✓';
                setTimeout(function () { b.innerHTML = orig; }, 1500);
              }, function () { });
            }
          });


          // ---- Turn worklog "copy activity" buttons (delegated): copy the
          // expanded text of that tool round's detail block.
          document.addEventListener('click', function (e) {
            var b = e.target && e.target.closest ? e.target.closest('.tw-copy') : null;
            if (!b) return;
            e.stopPropagation();
            var tgt = b.getAttribute('data-copy-target');
            var host = tgt ? document.getElementById(tgt) : null;
            var body = host ? host.querySelector('.wl-detail') : null;
            var text = (body ? body.innerText : '').trim();
            if (!text || !navigator.clipboard || !navigator.clipboard.writeText) return;
            navigator.clipboard.writeText(text).then(function () {
              var orig = b.innerHTML;
              b.innerHTML = '" + CHECK + "';
              b.classList.add('copied');
              setTimeout(function () { b.innerHTML = orig; b.classList.remove('copied'); }, 1500);
            }, function () { });
          });
        })();
        """

        // The overlay's content-derived url, now that its bytes exist.
        let initPath = Self.stamped("/ui/init.js", initJS)

        let server = WebUIServer(
            requestRender: { request in
                // ?s=<id> opens that conversation directly (copy-link flow).
                await pageProvider(request.value("s"), initPath)
            },
            router: router,
            config: WebUIServerConfig(
                host: host,
                port: port,
                pagePath: "/",
                // Registered at the bare path — the server strips a request's query before
                // the asset lookup, so a stamped url resolves to the same bytes. The `?v=`
                // is the *client's* cache key: a rebuilt asset is a new url and cannot be
                // served from a year-long cache under the old one.
                assets: [
                    .text(
                        "/ui/style.css",
                        sheet,
                        contentType: "text/css; charset=utf-8",
                        cacheSeconds: 31_536_000,
                        gzip: ThemeSheetAssets.gzip.isEmpty ? nil : ThemeSheetAssets.gzip
                    ),
                    .text("/ui/init.js", initJS, contentType: "text/javascript; charset=utf-8", cacheSeconds: 31_536_000),
                ]
            ),
            logger: logger
        )

        let controller = Controller(app: app, push: { updates in
            await server.broadcast(updates)
        })
        controller.wireAll(router)

        // the boot page is rendered here, once the stamped asset urls exist, purely
        // so the log line reports a real byte count.
        let bootPageBytes = makeDocument(
            await app.appShell(),
            Self.themeAttrs(await app.themeDefaults()),
            initPath
        ).render().utf8.count
        logger.info("serving http://\(host):\(port) (page \(bootPageBytes) bytes)")
        await app.startCronEngine()

        // Live log stream: drain the ring buffer and push the log box to
        // connected clients while the server runs.
        let logStreamer = IntervalService(name: "log-stream", interval: .milliseconds(400)) { [app] in
            guard !LogCollector.shared.drainNew().isEmpty else { return }
            guard await app.isLogsView() else { return }
            await server.broadcast(await app.liveLogFragments())
        }
        // Live workspace tree: while the right-hand panel is open, re-scan on a
        // slow cadence and push a fragment only when the listing changed.
        let wsStreamer = IntervalService(name: "workspace-tree", interval: .seconds(3)) { [app] in
            guard await app.isWorkspaceOpen() else { return }
            guard await app.scanWorkspaceTree() else { return }
            await server.broadcast(await app.liveWorkspaceFragments())
        }

        // The UI is only reachable once the server binds; record it so the
        // profile card can show the "Gateway running" badge truthfully.
        await app.markGatewayUp()

        // Second Law: the server and both streamers are Services in one group,
        // so startup is ordered and shutdown is graceful — cancellation stops
        // the loops and the listener together instead of leaving ad-hoc Tasks.
        let group = ServiceGroup(
            services: [
                WebUIServerService(server: server, logger: logger),
                logStreamer,
                wsStreamer,
            ],
            logger: logger
        )
        try await group.run()
    }
}

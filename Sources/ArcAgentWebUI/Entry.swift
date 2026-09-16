import ArcAgentCore
import ArgumentParser
import Foundation
import Logging
import WebUI

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

    func run() async throws {
        // Route every swift-log line into the in-app ring buffer instead of
        // stdout, so logs stop appearing in the terminal and surface in the
        // web UI's Logs section. Must run before any Logger is created.
        LoggingSystem.bootstrap { label in
            WebUILogHandler(label: label)
        }
        let logger = Logger(label: "arc-agent.webui")
        logger.info("starting (pid \(ProcessInfo.processInfo.processIdentifier))")

        let hub = ClientHub()
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
        Task {
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

        // Wire the router (hand-written fixed component ids).
        let router = EventRouter()
        let controller = Controller(app: app, hub: hub)
        controller.wireAll(router)

        // Assemble the page (external /ui/* assets keep each response small).
        // The document template wraps whatever body the app currently renders,
        // so a refresh ALWAYS reflects live store state (a boot-cached page
        // would show sessions deleted after startup).
        let makeDocument: (String) -> WebUI.HTMLDocument = { body in
            WebUI.HTMLDocument(
                title: "ARC Agent",
                body: body,
                rawStyles: [],
                head: """
                <link rel="stylesheet" href="/ui/style.css?v=43">
                <link rel="stylesheet" href="/ui/vendor/katex/katex.min.css">
                <script src="/ui/runtime.js?v=33"></script>
                <script src="/ui/init.js?v=28"></script>
                """,
                devMode: false,
                includeRuntime: false,
                contentSecurityPolicy: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https: blob:; connect-src 'self' ws: wss:; font-src 'self' data:"
            )
        }
        let bootShell = await app.appShell()
        let bootPage = makeDocument(bootShell).render()
        let pageProvider: @Sendable (String?) async -> String = { [app] deepLink in
            if let sid = deepLink, !sid.isEmpty {
                await app.openDeepLink(sid)
            }
            await app.armScrollToBottom()
            let shell = await app.appShell()
            return makeDocument(shell).render()
        }

        // Patched runtime (embedded Swift asset generated from Assets/runtime.js).
        let runtimeJS = RuntimeAsset.patchedRuntimeJS

        let initJS = """
        WebUIRuntime.init({
          wsUrl: (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws',
          wsReconnect: true,
          wsMaxReconnectDelay: 8000,
          wsPingInterval: 25000,
          debounceInputMs: 80,
          debounceMaxWaitMs: 350,
          logLevel: 'warn'
        });

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

          // ---- Image paste (Hermes parity): pasting an image (or image file)
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

          // ---- Composer autogrow (Hermes parity): the textarea expands with
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
          new MutationObserver(function () {
            resizeComposerIfNew();
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
          }).observe(document, { childList: true, subtree: true });

          // ---- Jump-to-latest circle button (Hermes parity): appears when the
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

          // ---- Relative session times: refresh every 60s (Hermes parity).
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
          document.addEventListener('click', function (e) {
            var open = document.querySelectorAll('.chat-menu.open');
            var dot = e.target && e.target.closest ? e.target.closest('.menu-dots') : null;
            if (dot) {
              var wrap = dot.closest('.menu-wrap');
              var menu = wrap && wrap.querySelector('.chat-menu');
              var wasOpen = menu && menu.classList.contains('open');
              for (var i = 0; i < open.length; i++) open[i].classList.remove('open');
              if (menu && !wasOpen) menu.classList.add('open');
              return;
            }
            for (var i = 0; i < open.length; i++) open[i].classList.remove('open');
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

        let server = WebServer(
            logger: logger,
            router: router,
            hub: hub,
            bootPage: bootPage,
            pageProvider: pageProvider,
            runtimeJS: runtimeJS,
            initJS: initJS,
            styleCSS: Theme.css + Theme.schemeCSS
        )

        logger.info("serving http://\(host):\(port) (page \(bootPage.utf8.count) bytes)")
        await app.startCronEngine()

        // Live log stream: drain the ring buffer and broadcast the log box to
        // connected clients while the server runs.
        let logStreamer = Task { [hub, app] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !LogCollector.shared.drainNew().isEmpty else { continue }
                guard await app.isLogsView() else { continue }
                await hub.broadcast(await app.liveLogFragments())
            }
        }
        // Live workspace tree: while the right-hand panel is open, re-scan on a
        // slow cadence and push a fragment only when the listing changed.
        let wsStreamer = Task { [hub, app] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard await app.isWorkspaceOpen() else { continue }
                guard await app.scanWorkspaceTree() else { continue }
                await hub.broadcast(await app.liveWorkspaceFragments())
            }
        }
        // The UI is only reachable once the server binds; record it so the
        // profile card can show the "Gateway running" badge truthfully.
        await app.markGatewayUp()
        try await server.serve(host: host, port: port)
        logStreamer.cancel()
        wsStreamer.cancel()
    }
}

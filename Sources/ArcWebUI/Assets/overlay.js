// The client is no-webui's ENGINE: the document, the transport, fragment
// patching, scroll and form-state restore, the draft store, focus, the slash
// palette and sanitising are `/ui/webui-engine.js` + `-ext.js`. What remains
// is the residue the engine has no consequence for — three survivors, each
// named where it lives. The file itself dies at A17; nothing new may land here.

(function () {
  try {
    // 1. ESCAPE for the two server-`hidden` panels. The engine's dismiss stack
    //    closes `[data-open]` layers only; the workspace panel and the outline
    //    are class/attribute-hidden regions, not layers. CAPTURE phase, so it
    //    yields to a modal or any open layer: one Escape closes one surface.
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape') return;
      if (document.querySelector('.modal-overlay, [data-open]')) return;
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

    // 2. COLOUR SWATCHES: form-local selection mirrored into the hidden
    //    `.color-value` field before submit. The server reads that field; the
    //    swatches are presentation, so there is no per-swatch server state and
    //    no round trip to spend on one.
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

    // 3. WORKSPACE close's exit visual. The close is server state, but the
    //    outgoing region's class must be on the node BEFORE the replacing patch
    //    lands, and the engine has no leave-transition hook (its post-patch
    //    hooks run after the node is gone). KEEP until a `data-leave` exists.
    document.addEventListener('click', function (e) {
      var b = e.target && e.target.closest ? e.target.closest('#w-close, #w-dock') : null;
      if (!b) return;
      var p = document.getElementById('ws-panel');
      if (!p || p.classList.contains('hidden') || p.classList.contains('ws-closing')) return;
      void p.offsetWidth; // force reflow so the transition actually runs
      p.classList.add('ws-closing');
    }, true);
  } catch (err) {
    if (typeof console !== 'undefined' && console.error) {
      console.error('arc-agent init failed:', err);
    }
  }
})();

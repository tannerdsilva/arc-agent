// The client is no-webui's ENGINE: the document, the transport, fragment
// patching, scroll and form-state restore, the draft store, focus, the slash
// palette and sanitising are `/ui/webui-engine.js` + `-ext.js`.
//
// A17 emptied this file. The last three survivors — the two panels' Escape
// bridge, the colour-swatch mirror and the workspace close's exit visual — are
// the engine's consequences now: `data-open`/`data-dismiss` layers, a native
// radio group, and a CSS transition keyed on the layer attribute. Nothing may
// land here again; the file itself is deleted in the same slice.

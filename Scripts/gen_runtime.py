import pathlib
src = pathlib.Path(__file__).resolve().parent.parent / "Sources/ArcAgentWebUI/Assets/runtime.js"
out = pathlib.Path(__file__).resolve().parent.parent / "Sources/ArcAgentWebUI/RuntimeAsset.swift"
js = src.read_text(encoding="utf-8")
content = f"""// AUTO-GENERATED from Assets/runtime.js (the canonical patched no-webui
// runtime). Regenerate with: python3 Scripts/gen_runtime.py
import Foundation

enum RuntimeAsset {{
    /// The patched no-webui runtime (Enter-to-send + passive-event filter),
    /// embedded via Swift raw string — no bundle, no resource pipeline.
    static let patchedRuntimeJS = #\"\"\"
{js}
\"\"\"#
}}
"""
out.write_text(content, encoding="utf-8")
print("wrote", out, len(content), "bytes")

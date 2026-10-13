# Tool plugins

Custom tools written in **Python** or **Swift** (or any executable) integrate
with ARC Agent through tool plugins, mirroring the reference client' user-plugin structure
(`~/.reference/plugins/<name>/` + `plugin.yaml` + `__init__.py` + `register(ctx)`).

In a static binary there is no in-process Python host, so the reference contract
maps to runtime-discoverable JSON manifests: each plugin is a directory under
`~/.arc/plugins/<name>/` containing a `manifest.json` and one or more
executables. Tools are invoked once per call with the request on stdin and the
result on stdout.

## Layout

```
~/.arc/plugins/<name>/
├── manifest.json     # plugin + tool definitions (arc plugin.yaml form)
└── tool.py           # Python script (or a compiled Swift binary `tool`, or ./run.sh)
```

## manifest.json

```json
{
  "name": "arc-weather",
  "version": "1.0.0",
  "description": "Demo weather tool.",
  "tools": [
    {
      "name": "weather_now",
      "description": "Get current weather for a city.",
      "command": "python3",
      "entry": "tool.py",
      "args": [],
      "toolset": "weather",
      "requires_env": ["OPENWEATHER_API_KEY"],
      "schema": {
        "type": "object",
        "properties": {
          "city": {"type": "string", "description": "City name"}
        },
        "required": ["city"]
      }
    }
  ],
  "llm": {"provider": "custom", "model": "m", "base_url": "...", "api_key_env": "MY_KEY"}
}
```

| Field | Meaning |
|---|---|
| `name` | Plugin name (also the directory name). |
| `version`, `description` | Display metadata (Settings → Tool plugins). |
| `tools[]` | Tool definitions; `llm` is an optional provider override. |
| `command` | Executable: absolute path, path relative to the plugin directory, or a bare name resolved via `PATH` (e.g. `python3`). |
| `entry` | Optional script path (relative to the plugin dir) passed to `command` as its first argument. |
| `args` | Optional static arguments appended after `entry`. |
| `toolset` | Grouping shown in the Tools page and the enabled-toolsets switches (default `plugins`). |
| `requires_env` | reference `requires_env` parity: the tool is **not installed** while any listed variable is unset. |
| `schema` | OpenAI function parameters object shown to the model. The full `{"type": "function", "function": {...}}` shape (reference `register_tool(schema:)`) is also accepted. |

## Tool contract

Each tool receives one JSON document on stdin and writes one JSON document on
stdout, bounded to 60 seconds and 1 MB of output:

```
stdin:  {"tool": "weather_now", "args": {"city": "Austin"}}
stdout: {"result": "Weather in Austin: 21C partly cloudy (demo data)"}
```

`args` keys match the `schema` properties (in JSON-compatible types — strings,
numbers, booleans, arrays, objects). The `result` value is a string.

### Python tool (`tool.py`)

```python
import json, sys

payload = json.load(sys.stdin)
args = payload.get("args", {})
city = str(args.get("city", "")).strip()
if not city:
    print(json.dumps({"result": "Error: 'city' is required."}))
else:
    print(json.dumps({"result": f"Weather in {city}: 21C partly cloudy (demo data)"}))
```

### Swift tool (compiled binary)

```swift
// tool.swift — build with: swiftc -O -o tool tool.swift
import Foundation

let data = FileHandle.standardInput.readDataToEndOfFile()
guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let args = obj["args"] as? [String: Any],
      let values = args["values"] as? [Int]
else {
    print(#"{"result": "Error: expected {args: {values: [Int]}} on stdin"}"#)
    exit(0)
}
let sum = values.reduce(0, +)
let out = #"{"result": "sum = \#(sum) (0x\#(String(sum, radix: 16)))"}"#
FileHandle.standardOutput.write(Data(out.utf8))
```

Manifest for the binary: `"command": "./tool"` (relative to the plugin dir).

## Enablement

Plugins are governed by the `plugins.enabled` allow-list in
`~/.arc/config.json` (reference `plugins.enabled` parity):

- **Key absent** — all discovered plugins are enabled (grandfathered).
- **`[]`** — no plugins enabled.
- **`["arc-weather", ...]`** — exactly these plugins.

Toggling in **Settings → Tool plugins** writes this list; the CLI, gateway,
and webui all read the same list. New toolsets appear in the Preferences
enabled-toolsets switches and on the Tools page, with full parameter details.

## Discovery & wiring

`PluginRegistry` scans `~/.arc/plugins/` on agent startup; `MutableToolRegistry`
layers enabled plugin tools over the compile-time registry. Every tool — built-in
or plugin — is an **`AgentTool`** conformer (the single protocol behind
`ToolRegistry`): `PluginTool` is a first-class conformer, so plugin tools are
stored and dispatched through the same protocol path as built-ins (no closure
boxing). Tools with unmet `requires_env` are skipped (reference `check_fn`
parity). The Settings page rescan button re-reads the directory without
restarting the agent.

**Name collisions are refused at install:** a plugin tool whose name equals a
built-in or another plugin tool's name is skipped with a warning — a duplicate
function name in the schema array would make the model ambiguous and dispatch
unreachable. The built-in always wins dispatch.

## Deployment

Plugin discovery is **sidecar-parity**: separate process, `manifest.json` in
`~/.arc/plugins/<name>/`, discovered at boot, never blocking it.

- **Boot warm-up** — `ArcDaemon` scans plugins during startup and logs
  `tool plugins: N plugin(s), M tool(s) [...]`, so malformed installs surface
  in the daemon log immediately instead of on the first session.
- **Non-fatal issues** — a directory without a `manifest.json` is skipped
  silently; unreadable/malformed manifests or tool-less manifests are recorded
  (actor `discoveryIssues()`) and logged as warnings while every healthy
  install still loads.
- **Operator surface** — `arc plugins list` (installed plugins, their tools,
  and any discovery issues), `arc plugins test <plugin> <tool> '<json-args>'`
  (runs one tool through the exact agent path), and `arc doctor` renders a
  plugin status line (`✅`/`⚠️` + issue list).

### Deploy / verify recipe

```bash
# 1. Build the plugin binary (if compiled) and stage the install
cd <plugin-src> && swift build   # or: swiftc -O -o tool tool.swift
mkdir -p ~/.arc/plugins/<name>
cp <binary-or-script> ~/.arc/plugins/<name>/
# copy manifest.json next to it, then:

# 2. Operators
arc plugins list                       # discovery + issues
arc doctor                             # plugin status line
arc plugins test arc-hexsum hex_sum '{"values":[1,2,3]}'
arc plugins test arc-weather weather_now '{"city":"Austin"}'

# 3. Agent path (same exec contract, 60s/1MB bound, per-call subprocess)
arc tools | grep -A1 hex_sum           # tool is registered for sessions
```

### Execution model

Every call spawns the plugin's process with the payload on stdin (cwd = the
plugin directory), bounded to **60 seconds** and **1 MB** of output; the child
is killed as a process group on timeout. Executable resolution: absolute path,
plugin-relative path, then `PATH` (interpreters like `python3`). Failures
render as a `"Error: …"` tool result, never an agent-facing throw.

### Known limits

- No sandbox: plugin tools run with the daemon's privileges (same trust model
  as sidebar tab sidecars) — install only trusted plugins.
- Per-call spawn cost (~10–50 ms); long-lived state must live in the plugin
  directory, not in a resident process.

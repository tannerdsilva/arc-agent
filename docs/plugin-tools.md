# Tool plugins

Custom tools written in **Python** or **Swift** (or any executable) integrate
with ARC Agent through tool plugins, mirroring Hermes' user-plugin structure
(`~/.hermes/plugins/<name>/` + `plugin.yaml` + `__init__.py` + `register(ctx)`).

In a static binary there is no in-process Python host, so the Hermes contract
maps to runtime-discoverable JSON manifests: each plugin is a directory under
`~/.arc/plugins/<name>/` containing a `manifest.json` and one or more
executables. Tools are invoked once per call with the request on stdin and the
result on stdout.

## Layout

```
~/.arc/plugins/<name>/
├── manifest.json     # plugin + tool definitions (Hermes plugin.yaml form)
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
| `requires_env` | Hermes `requires_env` parity: the tool is **not installed** while any listed variable is unset. |
| `schema` | OpenAI function parameters object shown to the model. The full `{"type": "function", "function": {...}}` shape (Hermes `register_tool(schema:)`) is also accepted. |

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
`~/.arc/config.json` (Hermes `plugins.enabled` parity):

- **Key absent** — all discovered plugins are enabled (grandfathered).
- **`[]`** — no plugins enabled.
- **`["arc-weather", ...]`** — exactly these plugins.

Toggling in **Settings → Tool plugins** writes this list; the CLI, gateway,
and webui all read the same list. New toolsets appear in the Preferences
enabled-toolsets switches and on the Tools page, with full parameter details.

## Discovery & wiring

`PluginRegistry` scans `~/.arc/plugins/` on agent startup; `MutableToolRegistry`
layers enabled plugin tools over the compile-time registry (built-ins always
win on name collisions). Tools with unmet `requires_env` are skipped
(Hermes `check_fn` parity). The Settings page rescan button re-reads the
directory without restarting the agent.

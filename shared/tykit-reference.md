# Tykit Command Reference (for agents)

> ⚠️ **tykit channel only** — the project has `Temp/tykit.json` and no live Pipeline descriptor (`Library/Pipeline/.unity-pipeline-port`), or one but no `unity` CLI to drive it. Projects that use Unity's official CLI have none of the commands below: use [`unity-cli-reference.md`](./unity-cli-reference.md) there. Not sure which channel a project uses? See [`unity-live-state.md`](./unity-live-state.md). Since qq 1.18.0, qq no longer adds tykit to a project on its own; the tykit package is still published for projects that opt in.

**Purpose**: when an agent needs to drive the live Unity Editor (inspect scene, modify components, run tests, recover from hangs), consult this reference before assuming what tykit can do. Tykit evolves; always verify with `describe-commands`.

> This is a **reference doc**, not a user-facing skill. Agents load it when they need to decide *how* to interact with Unity. Users should not `/tykit` anything — they use `/qq:test`, `/qq:execute`, or just describe what they want.

> **Read first**: [`unity-live-state.md`](./unity-live-state.md) — *when* to query the live Editor vs read code, and which channel the project uses. The single most common Unity-agent failure mode is reaching for code-reading when the Editor would answer the question in 2 calls. That doc is short; this one is the tykit lookup table.

## Backend selection (read this first)

### 0. Official Unity CLI (not tykit)
If the project has `Library/Pipeline/.unity-pipeline-port` and the `unity` CLI is found (exact check: `qq-unity-cli.py channel --project "$PWD"`), the Editor is driven with `unity command` — stop here and use [`unity-cli-reference.md`](./unity-cli-reference.md). Never open or print that descriptor: it holds an eval token.

On the tykit channel, three mutually-exclusive paths. Detect which one is available at the start of every Unity task:

### A. Built-in `tykit_mcp` MCP tools (preferred)
Look for these tool names in the MCP tool list:
- `unity_health`, `unity_doctor`, `unity_compile`, `unity_run_tests`
- `unity_console`, `unity_editor`, `unity_query`, `unity_object`, `unity_assets`
- `unity_input`, `unity_visual`, `unity_ui`, `unity_animation`, `unity_screenshot`
- `unity_batch`, `unity_raw_command`
- **New in v0.5.0**: `unity_main_thread_health`, `unity_focus_window`, `unity_dismiss_dialog`

If these exist, use them. They handle project discovery, thread safety, and error formatting automatically.

### B. Third-party MCP (`mcp-unity` / `Unity-MCP`)
Look for tool names like `run_tests`, `tests-run`, `recompile_scripts`, `get_console_logs`, `console-get-logs`. These cover basic operations but **do NOT** cover:
- Runtime reflection (`call-method`, `get-field`, `set-field`)
- Serialized array editing (`get-array`, `array-insert`, `array-delete`, `array-move`)
- Recovery from stalled main thread (`focus-unity`, `dismiss-dialog`, `/health`)
- Batch operations (`batch`)

If a task needs any of the above and only a third-party MCP is present, **tell the user honestly** that the task requires tykit direct HTTP or built-in `tykit_mcp`.

### C. Direct tykit HTTP (fallback)
```bash
PORT=$(python -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")
curl -X POST http://localhost:$PORT/ -d '{"command":"<name>","args":{...}}' -H 'Content-Type: application/json'
```

## Command discovery

**Never guess a command exists from memory — tykit adds new commands frequently.** Always verify:

```bash
# List all command names
curl -X POST http://localhost:$PORT/ -d '{"command":"commands"}' -H 'Content-Type: application/json'

# Get full schemas (input parameters, descriptions)
curl -X POST http://localhost:$PORT/ -d '{"command":"describe-commands"}' -H 'Content-Type: application/json'
```

Or via MCP: `unity_raw_command` with `{"command":"describe-commands"}`.

## Common intent → command map

### Query scene state
| Intent | Command |
|---|---|
| Find by name | `find {"name":"X"}` |
| Find components in subtree | `find {"type":"Button","parentId":<N>}` |
| Find with inactive | `find {"type":"Foo","includeInactive":true}` |
| List children | `inspect {"id":<N>}` → `children` array |
| Walk subtree | `hierarchy {"id":<N>,"depth":3}` |
| Read component | `get-properties {"id":<N>,"component":"RectTransform","structured":true}` |
| Read array field | `get-array {"id":<N>,"component":"Foo","property":"items"}` |
| Read code field/property | `get-field {"id":<N>,"component":"Foo","field":"Bar"}` |

### Modify scene state
| Intent | Command |
|---|---|
| Move UI | `set-property {"id":<N>,"component":"RectTransform","property":"m_AnchoredPosition","value":[x,y]}` |
| Set TMP text | `set-text {"id":<N>,"text":"...","inChildren":true}` |
| Rename | `set-name {"id":<N>,"newName":"X"}` |
| Set code field | `set-field {"id":<N>,"component":"Foo","field":"Bar","value":42}` |
| Insert into list | `array-insert {"id":<N>,"component":"Foo","property":"items","value":...}` |
| Delete from list | `array-delete {"id":<N>,"component":"Foo","property":"items","index":2}` |
| Reorder list | `array-move {"id":<N>,"component":"Foo","property":"items","fromIndex":0,"toIndex":3}` |
| Invoke method | `call-method {"id":<N>,"component":"Foo","method":"Bar","params":[...]}` |
| Click button | `button-click {"id":<N>}` |
| Duplicate GameObject | `duplicate {"id":<N>}` |
| Copy component | `component-copy` → `component-paste` (with `asNew`) |

### Assets / prefabs
| Intent | Command |
|---|---|
| Find prefabs in folder | `find-assets {"type":"Prefab","path":"Assets/Prefabs/"}` |
| Load asset metadata | `load-asset {"path":"Assets/X.prefab"}` |
| Check if object is prefab instance | `prefab-source {"id":<N>}` |
| Apply prefab changes | `prefab-apply {"id":<N>}` |
| Revert prefab changes | `prefab-revert {"id":<N>}` |
| Edit inside prefab | `prefab-open {"assetPath":"..."}` → edit → `prefab-close` |
| Create ScriptableObject | `create-scriptable-object {"type":"ItemConfig","path":"Assets/Data/X.asset"}` |

### Physics queries
| Intent | Command |
|---|---|
| Raycast | `raycast {"origin":[x,y,z],"direction":[0,-1,0],"distance":100}` |
| All raycast hits | `raycast-all {...}` |
| Sphere overlap | `overlap-sphere {"center":[x,y,z],"radius":20}` |

### Editor control
| Intent | Command | Notes |
|---|---|---|
| Play | `play` | Auto-saves dirty scenes first |
| Stop | `stop` | |
| Switch scene | `open-scene {"path":"Assets/X.unity"}` | Auto-saves first |
| Save as | `save-scene-as {"path":"..."}` | |
| Select | `select {"id":<N>}` | Default pings too |
| Multi-select | `select {"ids":[...],"ping":false}` | |
| Highlight only | `ping {"id":<N>}` or `ping {"assetPath":"..."}` | No selection change |
| Run tests | `run-tests {"mode":"editmode"}` → `get-test-result` | |
| EditorPrefs | `editor-prefs {"key":"X","value":42}` | |
| PlayerPrefs | `player-prefs {"key":"X","value":"..."}` | |

### Recovery (when Unity hangs)

These are **special URL endpoints**, not commands — they run directly on tykit's HTTP listener thread and **bypass the main-thread queue**, so they work even when POST commands time out.

| Endpoint | What it does |
|---|---|
| `GET /ping` | Liveness check. Listener thread only. Returns port + pid. |
| `GET /health` | Main thread heartbeat + queue state. Tells you if main thread is blocked. |
| `GET /focus-unity` | Windows only. Brings Unity main window to foreground. Unsticks domain reload / package resolve that pause when unfocused. |
| `GET /dismiss-dialog` | Windows only. Sends `WM_CLOSE` to the foreground Unity window. Closes modal dialogs. |

**Built-in `tykit_mcp` equivalents**:
- `unity_main_thread_health` ← `/health`
- `unity_focus_window` ← `/focus-unity`
- `unity_dismiss_dialog` ← `/dismiss-dialog`

**Recovery workflow** when a command times out:

```
1. curl /ping                    — still alive?
2. curl /health                  — mainThreadBlocked?
3. curl /focus-unity             — solves ~90% of stalls (background throttle)
4. curl /dismiss-dialog          — if a modal is blocking
5. Still stuck? Tell user to check Unity window manually.
```

## Batching

For 3+ sequential commands, use `batch` to reduce round-trip latency:

```json
{"command":"batch","args":{"commands":[
  {"command":"find","args":{"type":"Button","parentId":123}},
  {"command":"set-text","args":{"id":456,"text":"外交"}},
  {"command":"set-property","args":{"id":456,"component":"RectTransform","property":"m_AnchoredPosition","value":[100,-200]}}
],"stopOnError":true}}
```

Or via MCP: `unity_batch` tool.

## Type coercion gotchas

- `set-property` value format:
  - Primitives: JSON literal (`42`, `"foo"`, `true`)
  - `Vector2/3/4`: array `[x,y,z]` OR object `{"x":1,"y":2,"z":3}`
  - `Color`: array `[r,g,b,a]` OR object `{"r":1,"g":0.5,"b":0,"a":1}`
  - `Rect`: array `[x,y,w,h]`
  - `Bounds`: object `{"center":[...],"size":[...]}`
  - `Enum`: integer index OR string name
  - `ObjectReference`: integer instanceId
- `call-method` param conversion uses `JToken.ToObject(T)` — JSON types usually coerce correctly; for complex types pass objects matching the target struct.
- `get-properties` without `structured:true` returns ugly strings like `"(1, 2, 3) (Vector3)"`. Always pass `structured:true` unless you need legacy format.

## When NOT to use tykit

- **New C# code / new features** → write code in the project, let Unity compile it
- **Tests that need to be committed** → write a proper test file, use `/qq:add-tests`
- **Anything version-controlled** → tykit operates on live editor state; changes aren't persisted until you call `save-scene`
- **Asset bulk-edit (100+ items)** → write a small Editor script with a menu item, then call `menu` or re-use `call-method`

## Known limitations

- `call-method` uses `JToken.ToObject`, which may fail on complex param types. Fall back to writing a wrapper method in code + calling that.
- `array-*` commands operate on SerializedProperty — they don't work on pure code-level `List<T>` fields without `[SerializeField]`. Use `get-field`/`set-field` + reflection for those.
- Reflection-based changes (`set-field`, `call-method`) bypass Unity's SerializedObject tracking. They **may not show in the Inspector until a refresh** and are **not recorded in Undo history**.
- `focus-unity` / `dismiss-dialog` are Windows-only (P/Invoke user32.dll). macOS/Linux users must recover manually.

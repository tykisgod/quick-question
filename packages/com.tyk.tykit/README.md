# tykit

Lightweight HTTP server inside Unity Editor. Any AI agent can control Unity via `curl` — compile, run tests, play/stop, read console, inspect GameObjects.

No SDK. No plugin API. No UI automation. Just HTTP.

> This repo is an automated mirror of [`tykisgod/quick-question/packages/com.tyk.tykit`](https://github.com/tykisgod/quick-question). Do not edit directly — changes are synced from the source on every push.

## Install

Add one line to your Unity project's `Packages/manifest.json`:

```json
"com.tyk.tykit": "https://github.com/tykisgod/tykit.git"
```

Open Unity — tykit starts automatically. Port is stored in `Temp/tykit.json`.

**Requirements:** Unity 2021.3+, Newtonsoft JSON (auto-resolved via UPM dependency).

## Quick Start

```bash
# Get port
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")

# Ping
curl -s http://localhost:$PORT/ping

# Send a command
curl -s -X POST http://localhost:$PORT/ \
  -d '{"command":"status"}' -H 'Content-Type: application/json'
```

## API Reference

### Read Commands

| Command | Args | Description |
|---------|------|-------------|
| `status` | — | Editor state (isPlaying, isCompiling, activeScene) |
| `compile-status` | — | Compilation state (isCompiling, isUpdating) |
| `get-compile-result` | — | Last compile result (state, errors, duration) |
| `console` | `count`, `filter` | Read console logs (last N entries, optional filter) |
| `find` | `name`, `type`, `tag` | Find GameObjects in scene |
| `inspect` | `id` or `name` | Inspect GameObject components and properties |
| `get-properties` | `id` | List serialized properties of a component |
| `hierarchy` | `depth` | Scene hierarchy tree (default depth 3) |
| `commands` | — | List all available commands |

### Write Commands

| Command | Args | Description |
|---------|------|-------------|
| `create` | `name`, `primitiveType`, `position` | Create GameObject |
| `instantiate` | `prefab`, `name` | Instantiate prefab |
| `destroy` | `id` | Destroy GameObject |
| `set-transform` | `id`, `position`, `rotation`, `scale` | Modify transform |
| `add-component` | `id`, `component` | Add component to GameObject |
| `set-property` | `id`, `component`, `property`, `value` | Set serialized property |

### Editor Control

| Command | Args | Description |
|---------|------|-------------|
| `play` | — | Enter Play Mode |
| `stop` | — | Exit Play Mode |
| `pause` | — | Pause Play Mode |
| `save-scene` | — | Save current scene |
| `open-scene` | `path` | Open scene by asset path |
| `refresh` | — | AssetDatabase.Refresh() |
| `clear-console` | — | Clear console buffer |
| `menu` | `item` | Execute menu item |

### Testing

| Command | Args | Description |
|---------|------|-------------|
| `run-tests` | `mode`, `filter`, `assemblyNames` | Start EditMode/PlayMode tests |
| `get-test-result` | `runId` (optional) | Poll test results |

### Batch

Execute multiple commands in one call:

```bash
curl -s -X POST http://localhost:$PORT/ -d '{
  "command": "batch",
  "args": {
    "commands": [
      {"command": "create", "args": {"name": "Sun", "primitiveType": "Sphere"}},
      {"command": "set-transform", "args": {"id": "$0", "scale": [3,3,3]}}
    ]
  }
}' -H 'Content-Type: application/json'
```

`$N` references the `instanceId` returned by the Nth command in the batch.

## CLI Tool

The included `Scripts~/unity-eval.sh` provides a convenient CLI:

```bash
./unity-eval.sh hierarchy                        # Scene hierarchy
./unity-eval.sh find '{"name":"Ship"}'           # Find by name
./unity-eval.sh --compile                        # Compile + wait + check
./unity-eval.sh --ping                           # Health check
./unity-eval.sh --help                           # All options
```

## How It Works

tykit uses `[InitializeOnLoad]` to start an `HttpListener` on a deterministic port (hashed from project path, range 8090-8153). Commands are received on a background thread and dispatched to the Unity main thread via `EditorApplication.update`.

- `/ping` responds directly from the listener thread (no main thread needed)
- All other commands are queued and processed on the main thread
- Port info is written to `Temp/tykit.json` (port, PID, project path)
- Server stops cleanly on domain reload and editor quit

## Use with quick-question

tykit is also bundled with [quick-question](https://github.com/tykisgod/quick-question), a Claude Code plugin for Unity development. When used with qq, tykit powers auto-compilation, test execution, and scene control behind the scenes.

## Security

tykit listens on **localhost only** with **no authentication**. Any local process can send commands. This is acceptable for development machines but not suitable for shared environments without network controls. See [SECURITY.md](SECURITY.md) for details.

## License

[MIT](LICENSE) &copy; Yukang Tian

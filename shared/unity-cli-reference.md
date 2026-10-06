# Official Unity CLI Reference (for agents)

**Applies when** the project has `Library/Pipeline/.unity-pipeline-port` (Unity's Pipeline server, package `com.unity.pipeline`) and the `unity` CLI is found. To pick the channel, and for *when* to query the Editor at all, read [`unity-live-state.md`](./unity-live-state.md) first. tykit projects: [`tykit-reference.md`](./tykit-reference.md).

> Observed on CLI 1.0.0-beta.6 with Pipeline 0.6.0-exp.1. The command surface comes from the Editor and changes between package versions: look a command's parameters up before using it rather than writing them from memory.

🔴 **Never open, `cat`, `grep` or print `Library/Pipeline/.unity-pipeline-port`.** It holds an eval token that grants arbitrary C# execution inside the Editor. Check only that it exists; qq's scripts read just its `port` / `pid` / `projectPath` fields.

## Discover commands and their parameters

```bash
unity command --project-path "$PWD" --query <keyword> --detail full --json --no-banner
```

- Lists the matching commands with their description, parameters (name, type, required, default, description) and JSON schema — on beta.6 under `data.commands[]`. The schema has `additionalProperties: false`, so a misspelled parameter fails with `INVALID_COMMAND_ARGS` (`menu` takes `--path`, not `--menu_path`).
- `--query` matches a substring of the name, description or tag, and it sees **less** than what exists: in Edit mode it does not list runtime-only commands (`simulate_*`, `set_timescale`, …), and a miss returns `count: 0`, not an error. For the full list, call a command name that does not exist — the error lists every available command. Don't conclude a command is missing because `--query` found nothing.
- `--query` / `--detail` mean "listing" only when no command name is given; after a command name they are forwarded to that command as parameters.

## Call shape

```bash
unity command --project-path "$PWD" --json --no-banner [--timeout <sec>] <command> -- --<param> <value> ...
```

1. **Always pass `--project-path`.** Without it the CLI picks *some* running Editor (another worktree's, say). `unity status --project-path` is a substring filter — don't use it to decide which Editor belongs to this project; `editor_status`'s `data.result.projectPath` is the authority.
2. CLI options (`--project-path`, `--json`, `--timeout`, `--detach`) go **before** the command name; the command's own parameters go **after exactly one `--`**. Without `--`, a parameter that shares its name with a CLI option (`--timeout`) is silently swallowed by the client, and the command runs with its default; a second `--` fails with `INVALID_COMMAND_ARGS`. The reply's `data.parameters` echoes what the server received — compare it when in doubt.
3. Object references (`--target`, `--prefab`, `--parent`) take a string: `Assets/…` or `Packages/…` = asset path; an integer = instanceId; 32 hex digits = asset GUID; anything else (`/Root/Child`, a bare name) = scene hierarchy path. Prefer the `instanceId` that `find_gameobjects` returned — a bare name is read as a hierarchy path and fails with `Could not resolve 'target'` unless it sits at the scene root.
4. JSON-valued parameters go in as one quoted string: `--properties '{"_speed":5}'`, `--position "[1,2,3]"`.
5. Windows Git Bash: `--project-path "$PWD"` works as is. A parameter value that starts with `/` (a hierarchy path) is rewritten by MSYS path conversion — prefer the integer `instanceId`, or run the call with `MSYS_NO_PATHCONV=1` and `--project-path "$(cygpath -m "$PWD")"`.

Detached jobs (`--detach`, used by `/qq:test` for EditMode) are followed with `unity job status <jobId>` / `unity job wait <jobId>` (same `--project-path` / `--json`). Jobs live in the Editor's memory: a domain reload drops them (`Job Not Found`). Never cancel a test job through `unity job` — it does not stop the run, and it marks a run that finished as canceled.

## Four different timeouts

| Where | Unit | Default | Notes |
|---|---|---|---|
| `unity command --timeout` (before the command name) | seconds | 30 | Client transport only: the client stops waiting, the Editor keeps executing |
| `run_tests -- --timeout` | seconds | 300 | When it fires, the Editor's whole CLI channel wedges; `/qq:test` passes 86400 — run tests through `/qq:test` |
| `eval -- --timeout` | **milliseconds** | 5000 | The code runs synchronously on the main thread; the client timeout cannot interrupt it |
| `unity job wait --timeout` | seconds | 0 = wait forever | |

## Reading replies

- **Envelope**: `{success, data, errors[], …}`. A call worked only when `success` is exactly `true`, `errors` is empty and `data` is non-null. **The exit code is not a signal on its own** — it has changed between CLI versions (`INVALID_COMMAND_ARGS` exited 0 on an earlier version and exits 2 on beta.6; `COMMAND_FAILED` and `Job Not Found` exit 6). Require both.
- The command's own result is at `data.result`. `recompile_status` and `test_status` return it **double-encoded** — `data.result` is a JSON string; parse it again.
- When `data.result` has its own `success` field (`menu`, `run_tests`, `list_tests`, and a few others such as `screenshot`), it is the real verdict — read it with `data.result.message`. For `menu`: a missing or disabled menu item comes back with envelope `success: true`, exit 0 and `data.result.success: false`; also check that `data.result.path` echoes the path you sent — a swallowed `--path` turns `menu` into "list every menu item", which also reports success. Most commands have no inner `success` (`get_console_logs` → `{total, returned, logs}`) — don't require one.
- `editor_status` → `data.result.{status, compiling, domainReloadInProgress, playMode, projectPath}`. `playMode` is a string (`stopped` / `playing` / `paused`); there is no `isPlaying` boolean.
- Failures: read `errors[].code` / `errors[].message`. `retryable: true` or a busy rejection → nothing ran, retry after ~2 s. `Network error` (usually a domain reload in progress) → retry read-only commands only; a command with side effects may already have run. `timed out after …` → see [Recovery](#recovery).

## Common intent → command

Each row is `unity command --project-path "$PWD" --json --no-banner <command> -- <params>`.

**Read-only** (fine for verification — code review, self-review, explain, add-tests):

| Intent | Command |
|---|---|
| Editor state | `editor_status` |
| Find scene objects | `find_gameobjects -- --name X` (also `--type`, `--tag`, `--hierarchy_path`, `--include_inactive`) → `data.result.gameObjects[].instanceId` |
| Scene tree | `get_scene_hierarchy` (`-- --path <scene>` for an open scene that is not active) |
| Open scenes | `list_open_scenes` |
| Read a component | `get_component_properties -- --target <instanceId> --type Rigidbody` → `data.result.properties` |
| Read serialized fields (component or asset) | `get_serialized_fields -- --target <instanceId or Assets/… path> --component Foo [--field items.Array.data[0]]` |
| Find assets | `find_assets -- --type Material --name X` (also `--label`, `--search_in`, `--limit`) |
| Selection | `get_selection` |
| Console | `get_console_logs -- --severity error --limit 50` — a ring buffer (1000 entries), no keyword filter: a clue, not proof of "no errors" |
| Screenshot | `capture_game_view -- --save_path Screenshots/x.png` (`--source screen` includes overlay UI, Play mode only) / `screenshot -- --view game` (check `data.result.success`) |
| Small C# query | `eval -- --code 'return UnityEngine.Application.unityVersion;'` — read-only and small (main thread, timeout in ms) |

**Changes Editor state** (only when the task is to change it — a `/qq:execute` step, a plan step marked for the Editor; never during verification):

| Intent | Command |
|---|---|
| Set component properties | `set_component_properties -- --target <instanceId> --type Foo --properties '{"_speed":5}'` (serialized names; one Undo step) |
| Set one serialized field | `set_serialized_field -- --target <instanceId or asset path> --component Foo --field speed --value 5` |
| Open a scene | `open_scene -- --path Assets/Scenes/X.unity` (`--additive true` to add) |
| Save | `save_all` — not `save_scene`, which misses additively loaded scenes. Save before `open_scene` / `editor_play` so no "save modified scene?" dialog blocks the Editor |
| Enter / leave Play mode | `editor_play` / `editor_stop` — `editor_play` returns before Play mode is ready: poll `editor_status` until `playMode` is `playing`; always `editor_stop` when done |
| Run a menu item | `menu -- --path "Tools/X"` — check `data.result.success` and the echoed `path` |

**Compile and tests: always through qq.** Auto-compile / `qq-compile.sh` triggers `recompile` without bringing Unity to the front and judges the result; `/qq:test` (`unity-test.sh`) submits `run_tests` with a safe timeout and judges by `Summary.Failed` and the skip count. Do not call `run_tests` yourself, and do not use the CLI's own test / build / run subcommands — they launch a second, batch-mode Editor on the same project.

## Recovery

| Symptom | Meaning | What to do |
|---|---|---|
| `No Pipeline instance found for project` (exit 6) | No Pipeline server for this project | The Editor is closed or its server is stopped: ask the user to open the project / run **Window/Pipeline/Start Server**. An Editor that is open with compile errors is in Safe Mode, where packages (the Pipeline included) do not load — `unity pipeline list` reports it; fix the compile errors and restart Unity |
| `timed out after …` | Either this command is slow, or the Editor's CLI execution gate is held | Triage with `unity command --project-path "$PWD" --json --no-banner --timeout 6 editor_status`. It answers → only your command was slow. It doesn't → the gate is held by a test run, a modal dialog, or a wedged command (the Editor GUI may still respond). Ask the user to look for a dialog in the Unity window; exiting Play mode or restarting the Editor frees a wedged gate (**Window/Pipeline/Stop Server** sent through the CLI goes through the same gate and will not get in). **Do not kill Unity yourself** |
| `busyReason: "blocked_by_dialog"` (Unity 6000.7+) | A modal dialog blocks the main thread | Report the `dialogs[]` titles and buttons to the user |
| `Network error` | Usually a domain reload | Wait a few seconds; retry read-only commands only |
| `INVALID_COMMAND_ARGS` | Wrong parameter name, or a second `--` | Look the schema up (see [Discover](#discover-commands-and-their-parameters)) |
| `Could not resolve 'target'` | A name was read as a hierarchy path | `find_gameobjects` first, then pass its `instanceId` |
| An edit to an existing `.cs` is not picked up; `recompile` says `up_to_date` | Auto Refresh is off: Unity does not notice external edits to existing scripts | Reimport the file in Unity (qq's compile step reports this case as exit 2 instead of a green) |
| A change does nothing while the game runs | Unity does not compile scripts in Play mode | `editor_stop` first |

This channel has **no** focus or dismiss-dialog endpoints (tykit's `/focus-unity` and `/dismiss-dialog` do not exist here), and none are needed for background work: the Pipeline server keeps ticking while the Editor is unfocused or minimized. Don't pass `--focus true` to `recompile`.

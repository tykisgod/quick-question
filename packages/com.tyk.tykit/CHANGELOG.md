# Changelog

All notable changes to tykit are documented here.

## [Unreleased]

### Fixed
- **`SimulatedInputCleaner` no longer ships in release player builds.** Its
  `[RuntimeInitializeOnLoadMethod]` was unguarded, so every shipping game built with tykit as a
  dependency created a `DontDestroyOnLoad` hidden GameObject and dispatched an empty `LateUpdate`
  every frame, forever. Input simulation is driven only by tykit's HTTP commands, which live in
  `Tykit.Editor` and cannot run in a player — so the cleaner had nothing to clean. Now gated to
  `UNITY_EDITOR || DEVELOPMENT_BUILD`. `SimulatedInput`'s own accessors are unchanged and still
  compile in every configuration (they pass through to real `Input` when nothing is simulating),
  so player-build behaviour is unaffected. Found by a release-build audit in a consuming project.

## [0.5.0] - 2026-04-06

### Added — resilience against blocked main thread
- **`GET /health`** HTTP endpoint (listener-thread, bypasses main thread) — returns queue depth, time since last main-thread tick, and `mainThreadBlocked` heuristic. Use this when POST commands time out to tell modal-dialog blocks from network issues.
- **`GET /focus-unity`** HTTP endpoint (listener-thread, Windows only) — brings Unity's main window to the foreground via `SetForegroundWindow`. Unsticks background-throttled operations like domain reload and `git` package resolve that Unity pauses when not focused. **Runs on the listener thread**, so it works even when main thread is blocked.
- **`GET /dismiss-dialog`** HTTP endpoint (listener-thread, Windows only) — posts `WM_CLOSE` to the foreground dialog owned by Unity. **Runs on the listener thread**, so it can recover from modals that block the main thread.
- Main thread heartbeat — `ProcessQueue` updates a timestamp every tick so the listener thread can detect main-thread stalls.
- `focus-unity` / `dismiss-dialog` commands (main-thread variants, POST body) — convenience wrappers for when the main thread is responsive. When main thread is blocked, use the GET endpoints instead.
- Auto-save dirty scenes before `play` and `open-scene` — prevents the "Save modified scenes?" dialog that previously blocked tykit main-thread indefinitely.

### Recovery workflow
When a POST command times out:
1. `curl /ping` → still OK? listener thread alive
2. `curl /health` → check `mainThreadBlocked`; if true, main thread is stalled
3. `curl /focus-unity` → for background-throttled operations (domain reload waiting for focus)
4. `curl /dismiss-dialog` → for modal dialogs (Save Scene? / compile error popup / etc.)

### Added — batch + scene + prefs (套餐 C/D)
- `batch` command — execute multiple commands in one request. Reduces round-trip latency for complex workflows (30+ calls → 1 call). Supports `stopOnError`.
- `save-scene-as` command — save the active scene to a new path via `EditorSceneManager.SaveScene(scene, path, false)`.
- `set-active-scene` command — switch active scene in multi-scene setups.
- `editor-prefs` / `player-prefs` commands — read/write/delete EditorPrefs and PlayerPrefs keys. Auto-detects value type from JSON (int/float/bool/string).

### Added — prefab workflow (套餐 C)
- `prefab-apply` / `prefab-revert` — commit or revert scene changes to the source prefab asset. Closes the prefab editing loop.
- `prefab-open` / `prefab-close` — enter and exit prefab edit mode for batch modifications to prefab contents.
- `prefab-source` — get the source prefab asset path of a prefab instance.

### Added — physics queries (套餐 C)
- `raycast` / `raycast-all` / `overlap-sphere` — run physics queries and return hits as structured JSON. Useful for testing visibility, pathfinding, and trigger detection.

### Added — asset management (套餐 C)
- `find-assets` command — `AssetDatabase.FindAssets` wrapper with type, folder, and name filters. Returns paths, GUIDs, and instanceIds.
- `create-scriptable-object` command — create and save a ScriptableObject instance as a project asset.
- `load-asset` command — resolve an asset by path into name/instanceId/type metadata.

### Added — UI automation (套餐 D)
- `button-click` command — simulate clicking a UI Button by invoking `onClick.Invoke()`. Respects `interactable` state.
- `component-copy` / `component-paste` commands — copy component values via `ComponentUtility.CopyComponent` and paste onto another GameObject (with `asNew: true` to add as new component).

### Changed
- `set-property` now accepts `LayerMask` and `ArraySize` types (stored as integers).

## [0.4.0] - 2026-04-06

### Added
- `call-method` command — invoke any public or non-public method on a component via reflection. Parameters passed as JSON array, return value serialized to JSON. Finally makes runtime testing viable without code scaffolding.
- `get-field` / `set-field` commands — read/write code-level fields or properties via reflection, bypassing SerializedProperty. Walks the type hierarchy for inherited private members. Solves the "I need to poke a non-SerializeField field" problem.
- `get-array` command — read an entire serialized array/list as a structured JSON array, with nested struct/class elements fully expanded. Previously you had to query each index separately.
- `array-move` command — reorder elements in a serialized array/list via `MoveArrayElement`.
- `ping` command — highlight a GameObject or asset in the editor without changing selection. Supports `assetPath` for project assets.
- `find` enhanced — new `parentId`, `path` (exact hierarchy match), and `includeInactive` parameters. Lets you scope searches to a subtree and locate inactive objects.
- `select` enhanced — new `ids` array parameter for multi-select, plus `ping: false` option to skip the default highlight.

### Changed
- `find` by `name`/`type` now correctly honors `parentId` scoping and `includeInactive` (previously only worked on the global scene root).

## [0.3.0] - 2026-04-06

### Added
- `set-property` now accepts JSON arrays/objects for `Vector2/3/4`, `Vector2Int/3Int`, `Quaternion`, `Color`, `Rect`, `Bounds` — e.g. `"value": [112.26, -256.55]` or `"value": {"x":1,"y":2}`. Previously these types errored with `InvalidCastException`.
- `set-name` command for renaming GameObjects (previously impossible via `set-property` since `name` isn't a component).
- `hierarchy` command supports `id`/`path`/`name` parameters to traverse a specific subtree instead of only scene roots.
- `inspect` command now returns a `children` array with each child's `name`, `instanceId`, and `active` state (previously only `childCount` was exposed).
- `array-size` command — read or set the size of a serialized array/list property.
- `array-insert` command — insert a new element at an index (or append), optionally assigning a value.
- `array-delete` command — delete an element from a serialized array/list.
- `set-text` command — set `text` on `TMP_Text`/`TextMeshProUGUI`/`Text` without needing to know the serialized property name. Supports `inChildren` for nested text.
- `get-properties` now supports `structured: true` — returns native JSON types (numbers, arrays, nested objects) for `Vector/Color/Quaternion/Rect/Bounds/ObjectReference` instead of the legacy stringified format.

### Changed
- `set-property` `value` parameter now accepts native JSON types (int/float/bool/array/object) instead of string-only. String scalars still work for backward compatibility.

## [0.2.0] - 2026-03-29

### Changed
- Renamed `EvalServer` to `TykitServer` (class, file, log tags)
- Renamed `eval_server.json` to `tykit.json` (port info file in `Temp/`)
- Log tags changed from `[EvalServer]` to `[tykit]`
- Repository set to public and configured as automated mirror from [quick-question](https://github.com/tykisgod/quick-question)

### Migration
If you have scripts referencing `Temp/eval_server.json`, update them to `Temp/tykit.json`.

## [0.1.0] - 2026-03-15

### Added
- Initial release as UPM package
- HTTP server with `[InitializeOnLoad]` auto-start
- Deterministic port from project path hash (range 8090-8153)
- Commands: status, compile-status, console, find, inspect, create, destroy, set-transform, add-component, set-property, play, stop, pause, save-scene, refresh, clear-console, run-tests, get-test-result, batch
- `/ping` endpoint (responds from listener thread, no main thread needed)
- `Scripts~/unity-eval.sh` CLI tool
- `Scripts~/e2e-test.sh` end-to-end test runner

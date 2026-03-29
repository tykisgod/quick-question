# Changelog

All notable changes to tykit are documented here.

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

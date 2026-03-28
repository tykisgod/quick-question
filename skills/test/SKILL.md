---
description: "Run Unity unit/integration tests and check for runtime errors."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Run Unity unit/integration tests and check for runtime errors.

> **EvalServer:** This skill uses tykit's EvalServer (HTTP server in Unity Editor). If you need to discover available commands, run `curl -s -X POST http://localhost:$PORT/ -d '{"command":"commands"}' -H 'Content-Type: application/json'` where PORT comes from `Temp/eval_server.json`.

Arguments: $ARGUMENTS
- (no arguments): Run both EditMode and PlayMode
- `editmode` / `edit`: EditMode only
- `playmode` / `play`: PlayMode only
- `--filter "TestName"`: Filter by test name (semicolon-separated for multiple)
- `--assembly "Asm.Tests"`: Filter by assembly (semicolon-separated for multiple)
- `--timeout 300`: Custom timeout in seconds

Examples:
- `/qq:test` → Run EditMode + PlayMode
- `/qq:test play` → PlayMode only
- `/qq:test editmode --filter "Health"` → Filter by name
- `/qq:test --assembly "Game.PlayerSystem.Tests"` → Filter by assembly

## Steps

### 1. Clear Console + Mark Editor.log position

```bash
BASELINE=$(wc -l < ~/Library/Logs/Unity/Editor.log)
PORT=$(python3 -c "import json; print(json.load(open('Temp/eval_server.json'))['port'])" 2>/dev/null)
if [ -n "$PORT" ]; then
  curl -s --connect-timeout 5 --max-time 15 -X POST http://localhost:$PORT/ \
    -d '{"command":"clear-console"}' -H 'Content-Type: application/json'
fi
```

### 2. Run tests

Select command based on arguments:

| Argument | Command |
|----------|---------|
| (none) | `./scripts/unity-unit-test.sh` |
| `editmode` | `./scripts/unity-test.sh editmode --timeout 180` |
| `playmode` | `./scripts/unity-test.sh playmode --timeout 180` |
| with filter/assembly | `./scripts/unity-test.sh <mode> --filter "X" --assembly "Y" --timeout Z` |

- With no arguments, run `unity-unit-test.sh` (EditMode → PlayMode in sequence; skip PlayMode if EditMode fails)
- With arguments, call `unity-test.sh` and pass all arguments through
- On failure, analyze the cause and determine whether it was introduced by the current changes or was pre-existing

### 3. Check runtime errors

Even if all tests pass, runtime errors may still occur. Check via Editor.log (not dependent on the console API buffer):

```bash
tail -n +$((BASELINE + 1)) ~/Library/Logs/Unity/Editor.log | \
  grep -iE "NullReferenceException|Exception:|Error\b" | \
  grep -v "^UnityEngine\.\|^Cysharp\.\|^System\.Threading\.\|^  at \|CompilerError\|StackTrace" | \
  sort -u
```

**Show all errors to the user — do not filter or omit any.** For each error, include a source assessment (e.g., "exception from TaskEdgeCaseTests safety test, likely expected behavior"), and let the user decide whether action is needed.

## On test failure

1. Analyze the failure output and identify the failing test name and assertion
2. Read the failing test's source file and the code under test
3. Propose a concrete fix
4. Ask the user whether to apply the fix automatically

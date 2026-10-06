---
description: "Author Unity EditMode, PlayMode, or regression tests for the current change without conflating that with test execution."
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `qq-project-state.py` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Add or update Unity tests for the current change. This skill is for **writing tests**, not for running them. After authoring coverage, hand off to `/qq:test`.

> **Before deciding what to assert** (component layouts, serialized values, runtime state), read the actual values from the live Editor instead of guessing from source, read-only, through the project's channel: `${CLAUDE_PLUGIN_ROOT}/bin/qq-unity-cli.py channel --project "$PWD"` prints `unity-cli`, `tykit` or `none` ([`shared/unity-live-state.md`](../../shared/unity-live-state.md)).
> - **Official Unity CLI**: `unity command --project-path "$PWD" --json --no-banner find_gameobjects -- --name X`, then `get_component_properties -- --target <instanceId> --type Foo` or `get_serialized_fields` ([`shared/unity-cli-reference.md`](../../shared/unity-cli-reference.md)).
> - **tykit**: `unity_query`, `unity_object`, `get-field`, `get-array` ([`shared/tykit-reference.md`](../../shared/tykit-reference.md)).
> - **Neither**: derive the expected values from source and say they are unverified.

Arguments: $ARGUMENTS
- A file path, symbol, bug description, or plan step that needs coverage
- `editmode` / `edit`: force EditMode coverage
- `playmode` / `play`: force PlayMode coverage
- `regression`: force the smallest regression-focused test
- `--assembly "Asm.Tests"`: prefer a specific test assembly
- `--auto`: skip prompts and continue into `/qq:test --auto` after tests are written

## 0. Read qq project state first when available

```bash
${CLAUDE_PLUGIN_ROOT}/bin/qq-project-state.py --pretty
```

- `work_mode` and `policy_profile`: expected verification pressure
- `changed_runtime_files`: the code under test when the user did not specify a target
- `last_test_status`: whether coverage is missing vs. failing

## 1. Determine the target

Pick scope in this order:

1. Explicit user input (file path, bug description, plan step, or test type)
2. A known failing bug / regression path from the current conversation
3. The active implementation plan step and its done criteria; if the plan has a Tests step, implement that step
4. Current uncommitted runtime changes
5. Ask the user one concise question if the target is still ambiguous

Narrow broad input: one system over the whole feature, one regression path over a full suite rewrite, one test assembly over new scattered files.

## 2. Fit the existing test layout

Read the existing tests and test `.asmdef` files near the code under test, reuse their helpers, fixtures, scene setup and naming, and prefer extending an existing test file. If no tests exist yet, use `Assets/Tests/EditMode/` for pure logic or editor-side behavior and `Assets/Tests/PlayMode/` for scene/lifecycle/integration behavior.

## 3. Choose the right test kind

Unless the user forced a mode, choose the lightest one that still proves the behavior:

- **EditMode**: pure logic, data transforms, orchestration, deterministic calculations — anything that needs no scene frames
- **PlayMode**: MonoBehaviour lifecycle, scene wiring, frame progression, physics, animation
- **Regression**: the smallest test that proves a bug stays fixed; prefer this for `fix` mode when feasible

## 4. Write the tests

- cover the intended behavior, not every branch in the file
- add the highest-risk edge case or regression assertion
- avoid tests that merely duplicate production implementation line by line
- take expected values from an independent source: hand-calculated literals, worked examples in the design, or real-world data, never the same formula, code path, or config the code under test uses
- where it matters, check both directions: the thing happens when it should, and does not when it should not
- for values designers will keep tuning, assert relations (greater than, monotonic, conserved) instead of literals; keep independent literals for rules that should not change
- name the bug each test catches: a one-line change to the code under test that would make it fail. If you cannot name one, the test checks nothing

For a bug fix, write the regression first when the repro is clear; if the architecture makes the repro impossible to express cleanly, say so and write the next-best narrow guardrail.

## 5. Stop at authored coverage

- Summarize which files changed and which behavior is now covered
- Recommend the exact `/qq:test` command to run next, using `editmode`, `playmode`, `--assembly`, or `--filter` when that would keep validation narrow
- For a test guarding a bug fix or a high-risk rule, also suggest proving it can fail: apply that one-line change, confirm the test fails, then revert it
- If the expected behavior is ambiguous, ask one short question before writing more code

**`--auto` mode:** after writing the tests, continue directly to `/qq:test --auto` with the narrowest appropriate scope.

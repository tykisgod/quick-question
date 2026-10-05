---
description: "Author Unity EditMode, PlayMode, or regression tests for the current change without conflating that with test execution."
---

> **Script path fallback**: qq scripts are invoked as bare commands (e.g. `unity-test.sh`). If "command not found", use `${CLAUDE_PLUGIN_ROOT}/bin/<command>` instead.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Add or update Unity tests for the current change. This skill is for **writing tests**, not for running them. After authoring coverage, hand off to `/qq:test`.

> **Querying live scene/component state while authoring tests**: before deciding what to assert (component layouts, serialized values, runtime state), check the actual values in the live Editor instead of guessing from source code — through the project's channel ([`shared/unity-live-state.md`](../../shared/unity-live-state.md)):
> - **Official Unity CLI** (`Library/Pipeline/.unity-pipeline-port` exists): `unity command --project-path "$PWD" --json --no-banner find_gameobjects -- --name X`, then `get_component_properties -- --target <instanceId> --type Foo` or `get_serialized_fields`; look up parameters with `unity command --project-path "$PWD" --query <keyword> --detail full --json` ([`shared/unity-cli-reference.md`](../../shared/unity-cli-reference.md)).
> - **tykit** (`Temp/tykit.json`): `unity_query`, `unity_object`, `get-field`, `get-array` ([`shared/tykit-reference.md`](../../shared/tykit-reference.md)).
> - **Neither**: derive the expected values from source and say they are unverified.
>
> Read-only queries only — this skill writes tests; it does not change Editor state or run tests (`/qq:test` does). Never open or print `Library/Pipeline/.unity-pipeline-port` — it holds an eval token.

Arguments: $ARGUMENTS
- A file path, symbol, bug description, or plan step that needs coverage
- `editmode` / `edit`: force EditMode coverage
- `playmode` / `play`: force PlayMode coverage
- `regression`: force the smallest regression-focused test
- `--assembly "Asm.Tests"`: prefer a specific test assembly
- `--auto`: skip prompts and continue into `/qq:test --auto` after tests are written

## 0. Read qq project state first when available

If `qq-project-state.py` is available, read it before choosing scope:

```bash
qq-project-state.py --pretty
```

Use it for:

- `work_mode` and `policy_profile` to understand expected verification pressure
- `changed_runtime_files` to identify the code under test when the user did not specify a target
- `last_test_status` to understand whether coverage is missing vs. failing

Rules:

- Explicit user scope always wins
- Prefer the smallest meaningful coverage for the current task
- Do not turn this into a whole-project test rewrite

## 1. Determine the target

Pick scope in this order:

1. Explicit user input (file path, bug description, plan step, or test type)
2. A known failing bug / regression path from the current conversation
3. The active implementation plan step and its done criteria
4. Current uncommitted runtime changes
5. Ask the user one concise question if the target is still ambiguous

When the input is broad, narrow it:

- one system over the whole feature
- one regression path over a full suite rewrite
- one test assembly over new scattered files

## 2. Inspect the existing test layout

Before writing tests:

- read existing test files near the code under test
- inspect any nearby test `.asmdef` files
- reuse existing helpers, fixtures, scene setup, and naming patterns
- prefer extending an existing test file when it keeps the suite coherent

If no tests exist yet, create the smallest conventional home that fits the repo:

- `Assets/Tests/EditMode/` for pure logic or editor-side behavior
- `Assets/Tests/PlayMode/` for scene/lifecycle/integration behavior

## 3. Choose the right test kind

- **EditMode**: pure logic, data transforms, orchestration, deterministic calculations, and code that does not need scene frames to prove correctness
- **PlayMode**: MonoBehaviour lifecycle, scene wiring, frame progression, physics, animation, or behavior that only makes sense in play
- **Regression**: the smallest test that proves a bug stays fixed; prefer this for `fix` mode when feasible

If the user did not force a mode, choose the lightest mode that still proves the behavior.

## 4. Write the tests

Author the smallest useful coverage:

- cover the intended behavior, not every branch in the file
- add the highest-risk edge case or regression assertion
- avoid tests that merely duplicate production implementation line by line
- take expected values from an independent source: hand-calculated literals, worked examples in the design, or real-world data, never the same formula, code path, or config the code under test uses
- where it matters, check both directions: the thing happens when it should, and does not when it should not
- for values designers will keep tuning, assert relations (greater than, monotonic, conserved) instead of literals; keep independent literals for rules that should not change
- name the bug each test catches: a one-line change to the code under test that would make it fail. If you cannot name one, the test checks nothing
- keep setup minimal; extract helpers only when repetition is real
- if adding a new test assembly, keep references minimal and consistent with repo conventions

When this work is tied to a bug fix:

- prefer writing the regression first when the repro is clear
- if the current architecture makes the repro impossible to express cleanly, state that explicitly and write the next-best narrow guardrail

## 5. Stop at authored coverage

By default, this skill stops after the test files are written.

- Summarize which files changed
- State which behavior is now covered
- Recommend the exact `/qq:test` command to run next, using `editmode`, `playmode`, `--assembly`, or `--filter` when that would keep validation narrow
- For a test guarding a bug fix or a high-risk rule, also suggest proving it can fail: apply that one-line change, confirm the test fails, then revert it

**`--auto` mode:** after writing the tests, continue directly to `/qq:test --auto` with the narrowest appropriate scope.

## Handoff

- **Tests authored cleanly** → "Coverage is in place. Want to run `/qq:test` now?"
- **Tests authored in `--auto` mode** → continue to `/qq:test --auto`
- **Blocked by ambiguous expected behavior** → ask one short question before writing more code

## Notes

- Keep `/qq:add-tests` separate from `/qq:test`; one authors coverage, the other executes it
- Prefer modifying existing test files over spawning a brand-new structure for every change
- If a plan already contains a Tests step, implement that step here instead of inventing a different coverage target

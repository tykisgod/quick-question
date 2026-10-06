# Live Unity Editor State (for agents)

**Default heuristic in a Unity project**: when you need to *understand current runtime state*, **ask the live Editor first, read code second**. Reading source tells you what *could* happen; the Editor shows you what *is* happening.

A project reaches its open Editor through **one** channel, and the commands differ per channel — find out which one before you write a command.

## Which channel does this project use?

Decide by which files **exist** — do not read them:

| Project has | Channel | Command reference |
|---|---|---|
| `Library/Pipeline/.unity-pipeline-port` (Unity's Pipeline server, package `com.unity.pipeline`) and the `unity` CLI on PATH | **official Unity CLI** (`unity command` / `unity job`) | [`unity-cli-reference.md`](./unity-cli-reference.md) |
| `Temp/tykit.json` (and no live Pipeline descriptor, or no `unity` CLI to drive it) | **tykit** (HTTP, or the `tykit_mcp` tools) | [`tykit-reference.md`](./tykit-reference.md) |
| neither | **none** — no live Editor channel | verify from source, and say so |

```bash
[ -e Library/Pipeline/.unity-pipeline-port ] && echo "Pipeline descriptor present"
[ -e Temp/tykit.json ] && echo "tykit.json present"
# Exact answer: the descriptor is readable, belongs to this project, its Editor pid is alive, and the CLI is found
qq-unity-cli.py channel --project "$PWD"      # prints "<unity-cli|tykit|none><TAB><reason>"
```

🔴 **Never open, `cat`, `grep` or print `Library/Pipeline/.unity-pipeline-port`.** It holds an eval token that grants arbitrary C# execution inside the Editor. Check only that it exists; qq's scripts read just its `port` / `pid` / `projectPath` fields.

- The descriptor outlives a closed Editor, and it travels with `Library/` when a project is copied. `qq-unity-cli.py channel` catches both. With only the existence check, the first call answers for you: `unity command --project-path "$PWD" --json --no-banner editor_status` failing with `No Pipeline instance found for project` means there is no live Editor for this project.
- `QQ_UNITY_CHANNEL=unity-cli|tykit|none` forces the answer — the same variable qq's compile and test scripts honor.
- **Compile and test always go through qq** on every channel (auto-compile / `qq-compile.sh`, `/qq:test`). Those scripts pick the channel themselves and carry safeguards a hand-written command does not (see [Safety](#safety)).

## The decision rule

| Want to know about | Best tool |
|---|---|
| **State** (what's the value, what's running, what's selected) | **the live Editor**, through the project's channel |
| **Structure** (how is the code organized, what calls what, what's the type hierarchy) | **read source / Grep / Glob** |
| **Behavior** (what does this method do step by step) | **read source first, then the live Editor to verify** |
| **History** (who changed this, when, why) | **`git log` / `git blame`** |

When state and structure are tangled ("what does this state machine do when X happens"), read source to find the code paths, then use the Editor to *test the hypothesis*.

## The same question on each channel

Official Unity CLI calls below are written short: each one is `unity command --project-path "$PWD" --json --no-banner <command> -- <params>` (command parameters after a single `--`). Look a command's parameters up before using it: `unity command --project-path "$PWD" --query <keyword> --detail full --json`.

| Question | Lazy instinct | Official Unity CLI | tykit |
|---|---|---|---|
| "Why is this NPC stuck?" | Read the AI code, guess the state | `find_gameobjects -- --name NPC_X` → `get_component_properties -- --target <instanceId> --type AIController` (serialized fields; a non-serialized field needs a small read-only `eval`) | `find {name:"NPC_X"}` → `get-field {component:"AIController",field:"_currentState"}` |
| "What's the value of property Y on prefab Z?" | Open the .prefab YAML | `find_assets -- --type GameObject --name Z` → `get_serialized_fields -- --target <asset path> --component <Type> --field Y` | `find-assets {type:"Prefab",name:"Z"}` → `load-asset` → `get-properties {structured:true}` |
| "This component should be 5 but I see 3" | Re-read every assignment | `get_component_properties` confirms in one call; then bisect why | `get-properties` |
| "How many ships are in the harbor right now?" | Read spawn logic | `find_gameobjects -- --type Ship --include_inactive false` → count `data.result.gameObjects` | `find {type:"Ship",includeInactive:false}` |
| "Is this UI button wired correctly?" | Trace OnClick listeners in code | `get_serialized_fields -- --target <instanceId> --component Button --field m_OnClick` (persistent listeners) | `find {type:"Button",name:"X"}` → `button-click` → `console` |
| "What does the scene tree under X look like?" | Read the .unity YAML | `get_scene_hierarchy` (nodes carry `instanceId` + `hierarchyPath`) | `hierarchy {id:<N>,depth:3}` |
| "What's selected in the Editor?" | (no good code path) | `get_selection` | `get-selection` |
| "Which errors were logged?" | Add `Debug.Log`, recompile | `get_console_logs -- --severity error --limit 50` | `console` |
| "Does this raycast hit the wall?" | Mental simulation | small read-only `eval` (`Physics.Raycast(...)`) — there is no dedicated command | `raycast {origin:[...],direction:[...]}` |
| "If I change Y to 10, does the bug go away?" *(changes state — only where the skill allows it)* | Edit code → recompile → run | `set_component_properties -- --target <instanceId> --type Foo --properties '{"_y":10}'` | `set-field` |

The console is a ring buffer: an empty `get_console_logs` / `console` is a clue, not proof that nothing failed. For evidence, diff `Editor.log` from a baseline line count.

## When NOT to query the live Editor

| Task | Use this instead |
|---|---|
| Adding new features / refactoring | Write code, compile, test |
| Anything that needs to be in version control | Write code or assets (Editor changes persist only after a save) |
| Anything that needs to be in CI/build | Write code, write tests |
| Bulk asset operations (100+ items) | A small Editor script + a menu item |
| Anything in a player build (non-editor) | Neither channel reaches a build |
| When the code answer is obvious from a 30-line file | Just read the code; don't be dogmatic |

## Safety

**Both channels**

- Verification (code review, self-review, explain, add-tests) is **read-only**: no setting values, no menu items, no entering Play mode, no mutating `eval` / `call-method`, no test runs.
- Leave Play mode when you are done — Unity does not compile scripts during Play, the top cause of "my change did nothing".
- Never kill the Unity process (Workers included): it risks Library corruption.

**Official Unity CLI**

- Always pass `--project-path "$PWD"`. Without it the CLI picks *some* running Editor — possibly another worktree's.
- Never use the CLI's own test / build / run subcommands: they start a second, batch-mode Editor on the same project.
- Don't hand-write `run_tests`: its own 300 s default timeout, when it fires on a long suite, wedges the Editor's whole CLI channel; and its exit code and `success` fields report green for runs with failures. `/qq:test` handles both.
- `eval` only for small read-only queries: it runs synchronously on the Editor's main thread, its `--timeout` is in **milliseconds**, and a long one wedges the CLI channel just like a long test run.

**tykit**

- See [`tykit-reference.md`](./tykit-reference.md) — tykit changes are not persisted until `save-scene`, and reflection writes (`set-field`, `call-method`) bypass Undo.

## Recovery

- **Official Unity CLI** — follow [`unity-cli-reference.md#recovery`](./unity-cli-reference.md#recovery). This channel has no focus or dismiss-dialog endpoints and needs none: the Pipeline server keeps ticking while the Editor is unfocused or minimized.
- **tykit** — `/health` → `/focus-unity` → `/dismiss-dialog` (or the `tykit_mcp` equivalents); see [`tykit-reference.md`](./tykit-reference.md#recovery-when-unity-hangs).

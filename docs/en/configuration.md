# Configuration Reference

Settings flow: built-in defaults -> profile inheritance -> `qq.yaml` -> `.qq/local.yaml`.

| File | Committed | Purpose |
|---|---|---|
| `qq.yaml` | Yes | Project-wide: default profile, rules, install hosts |
| `.qq/local.yaml` | No | Per-worktree overrides: work mode, profile, trust level, workflow |
| `CLAUDE.md` / `AGENTS.md` | Yes | Coding standards, architecture rules |
| `.qq/state/session-decisions.json` | No (auto) | Cross-skill decision journal — `/qq:go` reads this so later skills stay coherent with earlier ones within the same session |

## qq.yaml Reference

### Top-Level Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `version` | int | `1` | Config schema version |
| `default_profile` | string | `feature` | Profile used when no local override is set |
| `work_mode` | string | (profile) | `prototype` / `feature` / `fix` / `hardening` (alias: `release`) |
| `policy_profile` | string | (profile) | `core` / `feature` / `hardening` |
| `trust_level` | string | `trusted` | `trusted` / `balanced` / `strict` |
| `workflow` | string | `heavy-review` | `heavy-review` (Heavy Review) / `prototype-loop` (Prototype Loop) |
| `enabled_rules` | list | (engine) | Policy rules to enforce (replaces profile defaults) |
| `task_focus` | any | null | Task-focus hint for `/qq:go` |
| `engine` | string | (detected) | Game engine id |

### install

| Field | Type | Default | Description |
|---|---|---|---|
| `hosts` | list | `[claude, codex, mcp]` | Host environments that receive managed config |
| `add_modules` | list | `[]` | Extra modules to install |
| `remove_modules` | list | `[]` | Modules to exclude |
| `sync` | bool | `false` | Prune stale managed files on install |

### profiles

Custom profiles defined under `profiles:` inherit from built-in ones via `extends`. Each profile can set `work_mode`, `policy_profile`, `trust_level`, `workflow`, `packs` (replace) or `add_packs`/`remove_packs` (delta), `enabled_rules` (replace) or `add_rules`/`remove_rules` (delta), and `skills`/`hooks` toggles (`{enable: [], disable: []}`).

## Built-in Profiles

Each profile inherits from the one above it.

| Profile | Extends | Work Mode | Policy | Added Packs |
|---|---|---|---|---|
| `lightweight` | -- | `prototype` | `core` | runtime-core, workflow-basic, workflow-utility, hooks-auto-compile |
| `core` | lightweight | `feature` | `core` | -- |
| `feature` | core | `feature` | `feature` | workflow-planning, workflow-review, hooks-review-gate, git-pre-push |
| `hardening` | feature | `hardening` | `hardening` | workflow-docs, hooks-skill-review |

## Work Mode vs Policy Profile vs Trust Level vs Workflow

Four independent knobs. Any combination is valid -- a `prototype` work mode can use `hardening` policy.

**Work Mode** -- "What kind of task is this?" Controls which artifacts are expected.

| Mode | Design Doc | Plan | Review | Tests |
|---|---|---|---|---|
| `prototype` | No | No | No | Targeted/manual |
| `feature` | Yes | Yes | Yes | Targeted |
| `fix` | No | No | No | Regression |
| `hardening` | No | No | Yes | Full/targeted |

**Policy Profile** -- "How much verification?" Sets the verification floor.

| Policy | Compile | Tests | Policy Check | Review | Doc Drift |
|---|---|---|---|---|---|
| `core` | Required | Basic | Advisory | Off | Off |
| `feature` | Required | Targeted | Expected | Light | Advisory |
| `hardening` | Required | Strong | Required | Required | Required |

Policy `feature`/`hardening` auto-adds `workflow-review` + `hooks-review-gate`; `hardening` also adds `workflow-docs`.

**Trust Level** -- "How much automatic permission widening?"

| Level | Auto Resume | Worktree Access | Raw Engine Cmds |
|---|---|---|---|
| `trusted` | Yes | Auto | Visible |
| `balanced` | No | Closeout only | Hidden |
| `strict` | No | Explicit opt-in | Hidden |

**Workflow** -- "How heavy is the process?" Changes how the design, plan, review, and execute skills run, not which artifacts the task needs.

| Step | `heavy-review` (Heavy Review, default) | `prototype-loop` (Prototype Loop) |
|---|---|---|
| Design | Full design doc, then the post-design-review loop | A numbered acceptance checklist (an outcome with a number; what you get, where to see it, what is not done, when it is done). The user approves it: the only hard stop, `--auto` starts after it |
| Plan | Full implementation plan | A slice list; each slice names the checklist items it covers, the check written first, and the files |
| Plan review | Loop, up to 5 rounds | One round, only for hard-to-undo plans (save or persisted formats, threading, cross-module public interfaces) |
| Execute | Per-phase review subagents | Each slice: failing check first, then green; the checklist is re-read at every checkpoint |
| Code review | Loop, up to 5 rounds; every finding verified by a subagent (one subagent may check a whole round's findings) | One round, verified by the main agent; then an agent that did not do the work checks the checklist item by item |
| Review gate | On | Off, unless `hooks.enable` names `review_gate` |

The rules live in [`shared/prototype-loop.md`](../../shared/prototype-loop.md); each affected skill says at the top which section it follows. Not to be confused with `work_mode: prototype`, which skips design and plan altogether.

`workflow` resolves like `trust_level`: `.qq/local.yaml` > `qq.yaml` > profile > default. A layer with an unknown value is skipped, so the layer below stays in effect, and a skill's `--workflow` argument wins over all of them. `qq-project-state.py` and `qq-config.py field workflow` report it (with `workflow_source`). Config is read on every call, so switching is one line in `.qq/local.yaml`, no restart; a running `--auto` pipeline keeps the workflow it started with.

## Local Overrides

`.qq/local.yaml` overrides `qq.yaml` per-worktree (gitignored). Any `qq.yaml` field can appear; local values win.

```yaml
work_mode: prototype
policy_profile: lightweight
profile: core
trust_level: balanced
workflow: prototype-loop
add_packs:
  - workflow-review
skills:
  disable:
    - codex-code-review
```

Inline (flow) form works too, e.g. `hooks: {disable: [auto_compile, compile_gate]}`. Indent with spaces, not tabs. If `qq.yaml` or `.qq/local.yaml` cannot be parsed, `qq-config.py`, `qq-project-state.py`, and the other entry points exit non-zero and name the file, line, and key. The Claude Code hooks (`auto_compile`, `compile_gate`, `review_gate`, `skill_review`, `auto_pipeline`) treat an unreadable config as switched off, so a broken config never blocks a session; instead the SessionStart hook reports the error at the start of every session (and skips script sync until it is fixed). The git `pre-push` hook (`git_pre_push`) runs in your terminal, so it prints the error and blocks the push (`git push --no-verify` skips it). After editing config by hand, run `python3 scripts/qq-config.py resolve` to confirm it parses.

## Install Knobs

`install.sh` reads `qq.yaml` and accepts CLI flags:

| Flag | Description |
|---|---|
| `--profile <name>` | Starter profile: `lightweight`, `core`, `feature`, `hardening` |
| `--modules <list>` | Comma-separated modules to install |
| `--without <list>` | Comma-separated modules to exclude |
| `--preset <name>` | One-shot setup: `quickstart`, `daily`, `stabilize` |
| `--wizard` | Interactive setup (mutually exclusive with `--preset`) |
| `--sync` | Prune stale managed files no longer in the active profile |

## Related Docs

- [qq.yaml template](../../templates/qq.yaml.example)
- [CLAUDE.md template](../../templates/CLAUDE.md.example)
- [AGENTS.md template](../../templates/AGENTS.md.example)
- [Project State Schema](../dev/qq-project-state.md)

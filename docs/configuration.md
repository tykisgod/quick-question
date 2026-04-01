# Configuration Reference

Settings flow: built-in defaults -> profile inheritance -> `qq.yaml` -> `.qq/local.yaml`.

| File | Committed | Purpose |
|---|---|---|
| `qq.yaml` | Yes | Project-wide: default profile, rules, install hosts |
| `.qq/local.yaml` | No | Per-worktree overrides: work mode, profile, trust level |
| `CLAUDE.md` / `AGENTS.md` | Yes | Coding standards, architecture rules |

## qq.yaml Reference

### Top-Level Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `version` | int | `1` | Config schema version |
| `default_profile` | string | `feature` | Profile used when no local override is set |
| `work_mode` | string | (profile) | `prototype` / `feature` / `fix` / `hardening` (alias: `release`) |
| `policy_profile` | string | (profile) | `core` / `feature` / `hardening` |
| `trust_level` | string | `trusted` | `trusted` / `balanced` / `strict` |
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

### context_capsule

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `true` | Master switch |
| `mode` | string | `auto` | `auto` / `manual` / `off` |
| `triggers` | list | `[resume, pre_clear, worktree_handoff, after_blocker]` | Events that fire a capsule (also: `manual`) |
| `max_chars` | int | `3000` | Character budget per capsule (floor: 400) |

### profiles

Custom profiles defined under `profiles:` inherit from built-in ones via `extends`. Each profile can set `work_mode`, `policy_profile`, `packs` (replace) or `add_packs`/`remove_packs` (delta), `enabled_rules` (replace) or `add_rules`/`remove_rules` (delta), and `skills`/`hooks` toggles (`{enable: [], disable: []}`).

## Built-in Profiles

Each profile inherits from the one above it.

| Profile | Extends | Work Mode | Policy | Added Packs |
|---|---|---|---|---|
| `lightweight` | -- | `prototype` | `core` | runtime-core, workflow-basic, workflow-utility, hooks-auto-compile |
| `core` | lightweight | `feature` | `core` | -- |
| `feature` | core | `feature` | `feature` | workflow-planning, workflow-review, hooks-review-gate, git-pre-push |
| `hardening` | feature | `hardening` | `hardening` | workflow-docs, hooks-skill-review |

## Work Mode vs Policy Profile vs Trust Level

Three independent knobs. Any combination is valid -- a `prototype` work mode can use `hardening` policy.

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

## Local Overrides

`.qq/local.yaml` overrides `qq.yaml` per-worktree (gitignored). Any `qq.yaml` field can appear; local values win.

```yaml
work_mode: prototype
policy_profile: lightweight
profile: core
trust_level: balanced
add_packs:
  - workflow-review
skills:
  disable:
    - codex-code-review
```

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

- [qq.yaml template](../templates/qq.yaml.example)
- [CLAUDE.md template](../templates/CLAUDE.md.example)
- [AGENTS.md template](../templates/AGENTS.md.example)
- [Project State Schema](qq-project-state.md)

# TODO

_Last updated: 2026-03-30_

This file tracks follow-up issues discovered after runtime, policy, and host-integration changes. Keep it current when new E2E or user-facing gaps show up.

## Open

### Real host multi-worktree collaboration E2E

- [ ] Validate the three-engineer scenario through real Claude/Codex host flows, not just controller/runtime simulation.
  - Current automated coverage is in [`docs/evals/collaboration-multi-actor.md`](./evals/collaboration-multi-actor.md) and proves policy/runtime isolation.
  - Still missing:
    - Claude experience across separate worktrees with different local modes
    - how much cross-talk shows up in real `/qq:go`, `/qq:test`, and `/qq:commit-push`
    - Codex parity for the same workflow

### Codex MCP E2E

- [ ] Make Codex CLI non-interactive sessions expose the built-in `tykit_mcp` tool surface end-to-end.
  - Current finding: `codex mcp list/get` sees the server config, but `codex exec` only exposed generic MCP resource access in E2E and not the Unity tool surface.
  - Need to confirm whether this is:
    - a Codex CLI feature/config gap
    - an MCP server registration/detail issue
    - or a prompt/runtime limitation in `exec`

## Recently resolved

- [x] Multi-engineer collaboration routing now has a documented, repeatable E2E suite.
  - Added [`docs/evals/collaboration-multi-actor.md`](./evals/collaboration-multi-actor.md) and [`docs/evals/collaboration-multi-actor.json`](./evals/collaboration-multi-actor.json).
  - The suite now runs in `./test.sh` and covers prototype, feature, and hardening work under shared project defaults plus per-worktree overrides.
- [x] Consumer plugin rollout now picks up the current mode-aware `/qq:go` controller.
  - Root cause: consumer projects were still running an older cached plugin build even though the marketplace repo had moved on.
  - Fix: versioned the plugin, published it, and reinstalled it in the consumer project so the active cache and installed plugin metadata now point at the latest controller skill.
- [x] Claude consumer installs now have a baseline allowlist for qq controller/runtime commands.
  - `install.sh` now merges safe local Claude permissions for `qq-project-state`, `qq-doctor`, compile, and test entrypoints.
  - Real `/qq:go` validation in `project_pirate_demo` no longer stops on the initial `qq-project-state.py` permission gate once those rules are present.
- [x] Artifact routing is now task-aware instead of repo-global.
  - `qq-project-state.py` only activates design docs / plans when they match current task evidence.
  - Repo-global docs remain background context unless they are the only candidate or match `task_focus` / modified files.
- [x] Compile/test freshness now invalidates stale verification after newer `.cs` changes.
  - `qq-project-state.py` downgrades stale runs to effective `not_run`.
  - `qq-run-record.py` and `tykit_bridge.py` now write sub-second timestamps so fresh verification is not immediately misclassified as stale.
- [x] `policy_profile` now changes controller recommendations, not just diagnostics.
- [x] `/qq:test` and pre-push now honor profile-driven default test scope.
- [x] `/qq:commit-push` checks controller state before continuing.

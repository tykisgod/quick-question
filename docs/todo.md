# TODO

_Last updated: 2026-03-30_

This file tracks follow-up issues discovered after runtime, policy, and host-integration changes. Keep it current when new E2E or user-facing gaps show up.

## Open

### Real host multi-worktree collaboration E2E

- [ ] Validate the three-engineer scenario through real Claude/Codex host flows, not just controller/runtime simulation.
  - Current automated coverage is in [`docs/evals/collaboration-multi-actor.md`](./evals/collaboration-multi-actor.md) and proves policy/runtime isolation.
  - Still missing:
    - real successful `/qq:test` host behavior across the same multi-worktree scenarios in an Editor-backed or Library-valid environment
    - Codex parity for the same workflow

### Codex MCP E2E

- [ ] Make Codex CLI non-interactive sessions expose the built-in `tykit_mcp` tool surface end-to-end.
  - Current finding: `codex mcp list/get` sees the server config, but `codex exec` only exposed generic MCP resource access in E2E and not the Unity tool surface.
  - Need to confirm whether this is:
    - a Codex CLI feature/config gap
    - an MCP server registration/detail issue
    - or a prompt/runtime limitation in `exec`

## Recently resolved

- [x] Real Claude host `/qq:go` routing now matches the collaboration controller in clean `project_pirate_demo` worktrees.
  - Verified on three separate demo git worktrees:
    - prototype + hardening + dirty C# spike -> `verify_compile`
    - feature + task_focus -> `/qq:plan`
    - hardening + compile/test green -> `/qq:claude-code-review`, then `/qq:doc-drift` after review
  - Important condition: disable unrelated user plugins such as `superpowers` and `telegram` in the worktree's `.claude/settings.local.json`, otherwise host runs get noisy and much slower.
- [x] Real Claude host `/qq:commit-push` gating now matches controller state in clean `project_pirate_demo` worktrees.
  - Verified on demo git worktrees:
    - prototype + hardening + uncompiled dirty C# change -> blocked and redirected to `verify_compile`
    - hardening + compile/test/review green but no doc-drift -> blocked and redirected to `/qq:doc-drift`
- [x] Real Claude host `/qq:test` now has environment-boundary coverage in clean `project_pirate_demo` worktrees.
  - Verified that the skill entry and fallback logic work, but detached worktrees fall back to Unity batch mode and hit environment limits:
    - no `Library/` cache in the worktree
    - local installed editor version does not match the project's declared version
  - Result: the remaining open item is not basic host wiring, but successful Editor-backed `/qq:test` execution under the same collaboration setup.
- [x] `claude -p` authentication works again for real host E2E.
  - Root cause was outside qq itself: local Claude CLI first-party auth had fallen into a bad state where `auth status` reported logged-in but every non-interactive `claude -p` call returned `401 Invalid authentication credentials`.
  - Fix: refreshed local Claude auth with a clean logout/login flow.
  - Post-fix smoke: plain `claude -p "Reply with OK."` works again, and a clean temp-project `/qq:go` host smoke succeeds.
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

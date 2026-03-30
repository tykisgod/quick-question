# Changelog

All notable changes to quick-question are documented here.

## [1.3.0] — 2026-03-31

### Added
- `qq-codex-mcp.py` for project-local Codex MCP registration
- `qq-codex-exec.py` for thin Codex execution against the current project/worktree
- qq-managed worktree `closeout` flow with source-branch publication and cleanup
- Dev Container support for repository-side development:
  - `.devcontainer/`
  - `scripts/docker-dev.sh`
  - `docs/containerization.md`
  - `docs/developer-workflow.md`

### Changed
- `qq-worktree create` now copies source compile/test baseline state into linked worktrees so doc-only work can close out without re-running local verification unnecessarily
- `qq-doctor` now reports Codex registration, built-in MCP host verification, and richer managed-worktree publication state
- collaboration E2E docs now reflect real Claude and Codex host coverage on `project_pirate_demo`

### Fixed
- built-in `tykit_mcp` now speaks both framed MCP and Claude's JSONL MCP initialize flow
- real Claude `/qq:test editmode` succeeds on `project_pirate_demo`
- real Codex can execute `unity_run_tests` on `project_pirate_demo`
- `install.sh` now repins existing `com.tyk.tykit` dependencies to the current tested release instead of silently leaving older git revisions in place
- managed-worktree closeout no longer depends on manually adding the source worktree to Codex writable scope

## [1.2.2] — 2026-03-30

### Changed
- `install.sh` now merges a baseline Claude local allowlist for qq state/doctor/compile/test commands in `.claude/settings.local.json`

### Fixed
- fresh consumer installs no longer hit the first `/qq:go` permission wall just to run `qq-project-state.py`

## [1.2.1] — 2026-03-30

### Changed
- `/qq:go` now has stricter controller rules in the shipped plugin:
  - read `qq-project-state.py` before any git/branch heuristics
  - avoid repo-audit style branch summaries by default
  - answer with the current mode/profile/next step first

### Fixed
- real Claude `/qq:go` runs are steered away from expensive fallback repo scans when structured project state is already available

## [1.2.0] — 2026-03-30

### Added
- `docs/todo.md` to track user-facing follow-up issues discovered during E2E validation

### Changed
- `/qq:go` is now explicitly project-state-first and mode-aware in the shipped plugin, instead of relying on conversation/git heuristics as the default controller
- controller artifact routing now treats repo-global design docs as background context unless they match the current task focus or active changes
- compile/test freshness now uses sub-second run timestamps so freshly verified work is not immediately marked stale

### Fixed
- prototype work is no longer incorrectly dragged into `/qq:plan` just because unrelated design docs exist elsewhere in the repo
- stale test results are invalidated after newer local `.cs` changes, and fresh compile runs remain valid in the same second they complete

## [1.1.0] — 2026-03-30

### Added
- Built-in project-local `tykit_mcp` bridge with `unity_*` MCP tools and capability metadata
- `./scripts/qq-doctor.sh` to inspect direct-path vs MCP routing in consumer Unity projects
- Agent integration and consumer rollout docs for validating the published install path

### Changed
- `install.sh` now copies the built-in bridge into the consumer project, wires `.mcp.json`, and pins `tykit` to the tested published revision
- qq now prefers the built-in `tykit_mcp` bridge before third-party Unity MCP backends when MCP is available
- README installation docs now describe the default built-in bridge flow for consumer projects

### Fixed
- Unity test runs now stop Play Mode first and prevent overlapping test executions
- Missing Unity meta files for the mirrored `tykit` package are restored
- `qq-doctor.sh` is shipped as an executable script

## [1.0.0] — 2026-03-28

### Added
- 22 skills (`/qq:*`) covering the full dev lifecycle
- `/qq:go` — lifecycle-aware routing (detect stage, suggest next step, `--auto` mode)
- `/qq:design` — write game design documents from ideas or drafts
- `/qq:plan` — generate technical implementation plans from design docs
- `/qq:execute` — smart implementation with adaptive execution strategy
- `/qq:best-practice` — 18-rule Unity best-practice check
- `/qq:claude-code-review` / `/qq:claude-plan-review` — deep review using Claude subagents
- `/qq:codex-code-review` / `/qq:codex-plan-review` — cross-model review (Claude + Codex)
- `/qq:test` — EditMode + PlayMode tests with runtime error checking
- `/qq:brief` — architecture diff + PR checklist (merged from brief-arch + brief-checklist)
- `/qq:full-brief` — run brief + timeline in parallel (4 docs total)
- `/qq:timeline` — commit history timeline with phase analysis
- `/qq:deps` — `.asmdef` dependency graph + matrix + health check
- `/qq:doc-tidy` — scan repo docs, analyze organization, suggest cleanup
- `/qq:doc-drift` — compare design docs vs code, find inconsistencies
- `/qq:grandma` — explain any concept using everyday analogies
- `/qq:explain` — explain module architecture in plain language
- `/qq:research` — search open-source solutions for current problem
- Auto-compilation hook — edit a `.cs` file, compilation runs automatically
- Smart compilation stack: tykit (HTTP) → Editor trigger → batch mode fallback
- tykit — HTTP server inside Unity Editor for AI agent control
- Codex Review Gate — blocks edits while review verification is pending
- Skill review enforcement — Stop hook blocks session end until `/qq:self-review` runs
- Smart handoff between skills with `--auto` mode for full pipeline execution
- Multi-language README (English, 中文, 日本語, 한국어)
- Plugin marketplace SEO optimization
- `test.sh` — self-test script (shellcheck + JSON + structural checks)
- GitHub Actions CI workflow
- Issue templates (bug report + feature request)

### Fixed
- `install.sh` now copies `scripts/hooks/` subdirectory
- `install.sh` output uses current skill names (`/qq:test`, `/qq:commit-push`)
- Duplicate scripts in tykit `Scripts~/` replaced with symlinks
- Review Gate documentation accuracy (`.cs` and `Docs/*.md`, not "all edits")
- Git added to Prerequisites (hard dependency)
- Claude-only review skills now read `AGENTS.md` for architecture rules
- `claude-plan-review` fallback glob excludes generated review artifacts

## [0.1.0] — 2026-03-27

### Added
- Initial release — Unity Agent Harness for Claude Code
- Core skills: test, st, commit-push, codex-code-review, codex-plan-review, code-review, self-review, explain, research, changes
- Hook system: auto-compile, skill review enforcement
- tykit UPM package
- `install.sh` installer
- Claude Code Plugin format (plugin.json, marketplace.json)

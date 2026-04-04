# Changelog

All notable changes to quick-question are documented here.

## [1.13.4] — 2026-04-04

### Fixed
- execute coordinator 模式严格串行：review 完成前禁止启动下一个 phase
- CI `grep -P` 改为 python3 提取版本号（macOS 兼容）
- pre-push hook 本地检查版本一致性

## [1.13.3] — 2026-04-04

### Fixed
- auto-sync 支持无 `install-state.json` 的项目（`.qq/` 存在但从未成功跑过 `install.sh`）
- Windows `bin/` 脚本兼容 + 全面 Windows 路径修复

## [1.13.1] — 2026-04-04

### Fixed
- auto-sync hook matcher 从 `startup` 改为空匹配，覆盖 resume/clear/compact 所有 session 事件

## [1.13.0] — 2026-04-04

### Added
- **Plugin Auto-Sync**：`SessionStart[startup]` hook 自动检测 plugin 升级，将新增/更新的 scripts 同步到项目目录。用户只需 `/plugins → upgrade`，下次开 session 自动部署脚本，不再需要手动跑 `install.sh`
- `qq-auto-sync.py`：轻量同步脚本，读写 `install-state.json` 作为唯一 state 源，不需要 jq

## [1.12.1] — 2026-04-04

### Fixed
- `qq-execute-checkpoint.py` 加入 `runtime-core` 安装列表，修复 install 后项目目录缺少 checkpoint 脚本的问题

## [1.12.0] — 2026-04-04

### Added
- **Execute Checkpoint/Resume 系统**：
  - `qq-execute-checkpoint.py`：确定性 checkpoint 脚本（save/resume/clear），用 step 标题文本匹配 checkbox，JSON 为权威源
  - `SessionStart[compact]` hook：上下文压缩后自动注入执行恢复提示
  - `qq-project-state.py` 检测活跃执行，`recommend_next` 自动返回 `/qq:execute <plan>`
- `/qq:execute` coordinator 模式 per-phase 轻量 review（dispatch subagent 检查实现与 plan 一致性）

### Changed
- `/qq:execute` checkpoint 从 Edit plan 文件改为调用 `qq-execute-checkpoint.py` Bash 命令（确定性，不依赖 agent 记忆）

## [1.11.0] — 2026-04-04

### Changed
- **`/qq:execute` 重写**：
  - 执行永远自动，不再逐步问用户确认
  - `--auto` 语义改为"完成后自动走下一步"（best-practice → code-review → add-tests → test → commit-push）
  - 大任务（>8步 / >12文件 / >3模块）自动切 coordinator 模式，每 phase 派 subagent，主 agent 不写实现代码
  - 每步完成后更新 plan checkbox（`- [x]`），支持断点恢复
  - 从 154 行精简到 88 行

## [1.10.0] — 2026-04-04

### Removed
- **Context Capsule 系统**：移除 `qq-context-capsule.py`（~660 行）、capsule 配置、capsule 测试、所有相关 hook 触发和文档。该功能在 Claude Code 端从未被消费，在 Codex 端可被 `.qq/state/` 直接读取替代。
- `qq-codex-exec.py` 中的 `--resume` / `--no-resume` / `--resume-refresh` / `--resume-note` 参数
- `qq_internal_config.py` 中的 `context_capsule` 配置段（`qq.yaml` 中的 `context_capsule:` 字段将被静默忽略）

### Changed
- `session-cleanup` hook 不再触发 capsule 构建，仅执行 gate 清理和 prune
- `qq-codex-exec.py` 精简为纯 worktree/sandbox/MCP 隔离 wrapper
- `qq-doctor` 输出不再包含 `contextCapsule` 段
- `qq-worktree` create/closeout 不再构建或携带 capsule

### Added
- `/qq:plan` skill 增强：review 步骤必选，优先跨模型 codex review，技术选型时自动调用 `/qq:tech-research`
- `/qq:post-design-review` 独立 skill，主 agent 验证 subagent 结果后再呈现
- 4 个 review skill 统一引用共享 `verification-prompt.md`

### Fixed
- `skills/_shared/` 路径修正为 `shared/`
- codex-exec worktree 测试中残留的 resume 字段断言

## [1.9.0] — 2026-03-31

### Added
- first-party S&box runtime parity:
  - `qq_engine.py` / `qq_mcp.py` now compose S&box as a first-class engine alongside Unity, Godot, and Unreal
  - S&box compile/test/runtime bridge scripts and capabilities
  - bundled S&box editor bridge runtime under `engines/sbox/Editor/QQ/QQSboxEditorBridge.cs`
- modular install planning and a guided onboarding flow:
  - `install.sh --wizard`
  - preset installs: `quickstart`, `daily`, `stabilize`
  - physical install modules resolved from engine/host/profile instead of copying the whole runtime by default

### Changed
- `install.sh` now installs only the selected runtime modules for the current engine/host surface
- `qq-doctor` now reports installed-vs-expected modules and module drift
- `qq-policy-check`, `qq-project-state`, `qq-compile.sh`, `qq-test.sh`, and `qq_mcp.py` now resolve S&box-aware runtime/test flows

### Fixed
- install-time `qq.yaml install` settings now merge correctly with local overrides instead of being reset by missing local config
- `git-pre-push` is no longer installed implicitly just because a heavier workflow profile is selected; it is now explicit opt-in
- `install.sync: true` now actually prunes stale managed runtime files during reinstall

## [1.8.0] — 2026-03-31

### Added
- first-party Unreal runtime parity:
  - `qq_engine.py` / `qq_mcp.py` now compose Unreal as a first-class engine alongside Unity and Godot
  - Unreal compile/test/runtime bridge scripts and capabilities
  - bundled Unreal editor bridge bootstrap under `engines/unreal/python/qq_unreal_bridge.py`

### Changed
- `install.sh` now detects Unreal projects, enables required Unreal project plugins, installs support scripts, and wires the built-in live editor bridge
- `qq-doctor`, `qq-policy-check`, `qq-compile.sh`, and `qq-test.sh` now resolve Unreal-aware runtime/test flows
- trust-level MCP filtering now applies consistently to Unreal raw tools as well as Unity/Godot

### Fixed
- engine-generic MCP composition now keeps trust-level raw-command restrictions intact while adding Unreal runtime delegates
- regression coverage now exercises Unreal provider resolution, compile/test routing, and install-time project bootstrap
## [1.7.0] — 2026-03-31

### Added
- first-party Godot runtime parity:
  - `qq_engine.py` engine registry and engine-aware defaults
  - `qq_mcp.py` as the engine-generic project-local MCP entrypoint
  - Godot compile/test/runtime bridge scripts and capabilities
  - bundled Godot editor bridge addon under `engines/godot/addons/qq_editor_bridge`

### Changed
- `qq-project-state` now uses an engine-agnostic runtime/test status model (`changed_runtime_files`, `changed_test_files`) instead of Unity-only code-change fields
- `install.sh`, `qq-compile.sh`, `qq-test.sh`, and auto-compile hooks now route through the active engine instead of assuming Unity-only project semantics
- project-local Claude/Codex host setup now resolves the correct engine bridge for Unity or Godot projects

### Fixed
- managed worktree and controller tests now declare the target engine explicitly, so runtime verification stays correct in engine-agnostic fixtures

## [1.6.0] — 2026-03-31

### Added
- `/qq:add-tests` as an explicit test-authoring skill for targeted EditMode, PlayMode, and regression coverage

### Changed
- `feature`, `fix`, and `hardening` controller flows now route compile-green code changes to `/qq:add-tests` before `/qq:test` when fresh coverage is still missing
- `workflow-basic` and `lightweight` now include explicit test authoring as part of the default runtime loop
- docs, install output, benchmark suites, and marketplace metadata now reflect the new 23-skill surface

### Fixed
- `qq-worktree cleanup` now prunes copied local runtime artifacts before removal, so consumer linked worktrees no longer get stuck on untracked `qq.yaml` / `scripts/` noise during closeout

## [1.5.1] — 2026-03-31

### Fixed
- `/qq:changes` now persists a meaningful local-change snapshot, so prototype flows can advance from `/qq:changes` to `/qq:commit-push` without forcing the push path
- changes summaries now invalidate immediately after newer local edits, even when the follow-up edit lands within the same filesystem timestamp bucket
- `qq-worktree closeout` now deletes the remote linked branch before removing the managed worktree directory, so the normal closeout path no longer leaves behind a stale remote worktree branch
- runtime change detection now ignores `.qq` and `qq.yaml` config/runtime noise when deciding whether controller flows should treat the project as having unfinished user work

## [1.5.0] — 2026-03-31

### Added
- `qq.yaml` as the single supported shared project config surface, with `.qq/local.yaml` as the per-worktree override
- `qq-config.py` / `qq_internal_config.py` as the new config resolver and CLI entrypoint
- built-in profiles: `lightweight`, `core`, `feature`, `hardening`
- `qq-context-capsule.py consume` as a host-neutral capsule handoff/consume API
- `qq_internal_git.py` for correct git inspection in bare+worktree repo layouts
- qq benchmark suites and reference solver scaffolding:
  - `docs/evals/qq-bench-*.json`
  - `scripts/eval/reference_solver.py`

### Changed
- removed legacy `qq-policy.json` / `.qq/local-policy.json` compatibility; qq now only reads `qq.yaml` and `.qq/local.yaml`
- `qq-project-state`, `qq-doctor`, hooks, install flow, and worktree runtime copying now all resolve through the new config/runtime layer
- `qq-codex-exec.py` now consumes Context Capsules through the host-neutral `consume` API instead of duplicating resume logic
- `qq-worktree create` now copies project-local runtime files required by consumer installs (`qq.yaml`, `.mcp.json`, `.claude/settings.local.json`, `scripts/`, and related handoff artifacts)

### Fixed
- bare+worktree repos now report dirty state, branch state, and controller context correctly
- copied runtime artifacts in managed worktrees no longer block merge-back / cleanup as false-positive dirt
- real Codex E2E now passes on both the root `project_pirate_demo` project and a seeded qq-managed linked worktree

## [1.4.0] — 2026-03-31

### Added
- `qq-worktree.py seed-library` to seed or refresh a managed worktree `Library` from its source worktree

### Changed
- `qq-worktree create` now seeds the source worktree `Library` into the linked worktree when one is available
- `unity-test.sh` now auto-seeds a missing managed-worktree `Library` before falling back to batch mode
- `qq-project-state` and `qq-doctor` now expose managed-worktree Library readiness (`sourceLibraryExists`, `localLibraryExists`, `librarySeedState`, `librarySeedStrategy`)

### Fixed
- real Claude `/qq:test editmode` now succeeds in a qq-managed linked worktree with a seeded `Library`
- real Codex `unity_run_tests editmode` now succeeds in the same qq-managed linked worktree

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

<p align="center">
  <img src="logo.png" alt="quick-question" width="200">
</p>

<h1 align="center">quick-question</h1>

<p align="center">
  <strong>Game Development Agent Runtime for Claude Code</strong><br>
  Auto-compile, test pipelines, cross-model review, editor control — across Unity, Godot, Unreal, and S&box.
</p>

<p align="center">
  <a href="https://github.com/tykisgod/quick-question/actions/workflows/validate.yml"><img src="https://github.com/tykisgod/quick-question/actions/workflows/validate.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/version-v1.9.0-blue" alt="Version">
  <a href="https://github.com/tykisgod/quick-question/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%2B%20Windows%20(preview)-blue" alt="Platform">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Unity-2021.3+-000000?logo=unity&logoColor=white" alt="Unity">
  <img src="https://img.shields.io/badge/Godot-4.x-478CBF?logo=godotengine&logoColor=white" alt="Godot">
  <img src="https://img.shields.io/badge/Unreal-5.x-0E1128?logo=unrealengine&logoColor=white" alt="Unreal">
  <img src="https://img.shields.io/badge/S%26box-latest-E4A032" alt="S&box">
</p>

<p align="center">
  English |
  <a href="docs/README.zh-CN.md">中文</a> |
  <a href="docs/README.ja.md">日本語</a> |
  <a href="docs/README.ko.md">한국어</a>
</p>

---

## What is qq

qq is a runtime layer on top of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that gives the AI agent deep awareness of the game development cycle. Instead of treating every task the same way, qq knows whether you are prototyping a new mechanic, building a production feature, fixing a regression, or hardening for release — and adjusts its process intensity accordingly. The artifact-driven controller `/qq:go` reads structured project state from `.qq/`, recent run records, and your configured `work_mode`, then recommends the concrete next step.

On every code edit, qq auto-compiles through engine-specific hooks (`.cs` for Unity and S&box, `.gd` for Godot, C++ for Unreal). It runs test pipelines, enforces deterministic policy checks before deeper model review, and orchestrates cross-model code review where Claude coordinates and Codex independently reviews — with every finding verified by subagents before any code is changed. Editor control is built in: tykit for Unity, editor bridges for Godot, Unreal, and S&box.

qq ships 23 slash commands covering the full workflow from design through shipping: `/qq:design` → `/qq:plan` → `/qq:execute` → `/qq:test` → `/qq:codex-code-review` → `/qq:commit-push`. The approach is grounded in the document-first methodology described in [AI Coding in Practice: An Indie Developer's Document-First Approach](https://tyksworks.com/posts/ai-coding-workflow-en/).

## Feature Highlights

- **`/qq:go` — lifecycle-aware routing** — reads project state, `work_mode`, and run history, then recommends the right next step for your current phase
- **Auto-compile** — hook-driven compilation fires on every code edit; supports `.cs` (Unity/S&box), `.gd` (Godot), and C++ (Unreal)
- **Test pipeline** — EditMode + PlayMode for Unity, GUT/GdUnit4 for Godot, Automation for Unreal, runtime tests for S&box, all with structured pass/fail reporting
- **Cross-model review** — Claude orchestrates, Codex independently reviews the diff, subagents verify each finding against source before any fix is applied
- **Editor control** — tykit (in-process HTTP server for Unity), plus Python bridges for Godot, Unreal, and S&box; zero manual config
- **Work modes** — `prototype`, `feature`, `fix`, `hardening` — each applies appropriate process weight so prototypes stay light and releases get full verification
- **Runtime data** — structured state in `.qq/` provides loop continuity across sessions and feeds the controller
- **Modular install** — wizard mode with engine auto-detection, one-shot presets (`quickstart`/`daily`/`stabilize`), per-module control

## Supported Engines

| Engine | Compile | Test | Editor Control | Bridge |
|--------|---------|------|----------------|--------|
| **Unity 2021.3+** | tykit / editor trigger / batch | EditMode + PlayMode | tykit HTTP server | `tykit_bridge.py` |
| **Godot 4.x** | GDScript check via headless editor | GUT / GdUnit4 | Editor addon | `godot_bridge.py` |
| **Unreal 5.x** | UnrealBuildTool + editor commandlet | Automation tests | Editor command (Python) | `unreal_bridge.py` |
| **S&box** | `dotnet build` | Runtime tests | Editor bridge | `sbox_bridge.py` |

Unity has the deepest integration (tykit provides in-process HTTP control with millisecond response times). Godot, Unreal, and S&box are at runtime parity — compile, test, editor control, and structured run records all work — with active development continuing.

## Install

### Requirements

- macOS or Windows ([Git for Windows](https://gitforwindows.org/) required; Windows support is in preview)
- Engine: Unity 2021.3+ / Godot 4.x / Unreal 5.x / S&box
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `curl`, `python3`, `jq`
- [Codex CLI](https://github.com/openai/codex) *(optional — enables cross-model review)*

### Steps

**1. Install the plugin**

```
/plugin marketplace add tykisgod/quick-question
/plugin install qq@quick-question-marketplace
```

**2. Install runtime into your project**

```bash
# Auto-detects engine (Unity / Godot / Unreal / S&box)
./install.sh /path/to/your-project

# Or use the interactive wizard
./install.sh --wizard /path/to/your-project

# Or pick a preset
./install.sh --preset quickstart /path/to/your-project
```

Available presets: `quickstart` (minimal, great for first run), `daily` (recommended default), `stabilize` (full checks for release prep). For fine-grained control see `--profile`, `--modules`, and `--without`.

**3. Open your editor.** In Unity, tykit starts automatically. For other engines, follow the post-install instructions printed by the installer.

## Quick Start

```bash
# Let qq figure out where you are
/qq:go

# Design a feature
/qq:design "inventory system with drag-and-drop"

# Generate an implementation plan
/qq:plan

# Execute the plan — auto-compiles on each edit
/qq:execute

# Run tests
/qq:test
```

qq adjusts process intensity based on work mode. In `prototype` mode, it stays light — keep compile green, stay playable, move fast. In `hardening` mode, it enforces tests and review before shipping. See [Getting Started](docs/getting-started.md) for detailed walkthrough scenarios.

## Commands

### Workflow

| Command | Description |
|---------|-------------|
| `/qq:go` | Detect workflow stage, recommend next step |
| `/qq:design` | Write a game design document |
| `/qq:plan` | Generate technical implementation plan |
| `/qq:execute` | Smart implementation with auto-compile verification |

### Testing

| Command | Description |
|---------|-------------|
| `/qq:add-tests` | Author EditMode, PlayMode, or regression tests |
| `/qq:test` | Run tests and check for runtime errors |

### Code Review

| Command | Description |
|---------|-------------|
| `/qq:codex-code-review` | Cross-model review: Codex reviews, Claude verifies (max 5 rounds) |
| `/qq:codex-plan-review` | Cross-model plan/design review |
| `/qq:claude-code-review` | Claude-only deep code review with auto-fix loop |
| `/qq:claude-plan-review` | Claude-only plan/design review |
| `/qq:best-practice` | Quick scan for anti-patterns and performance issues |
| `/qq:self-review` | Review recent skill/config changes |

### Analysis

| Command | Description |
|---------|-------------|
| `/qq:brief` | Architecture diagram + PR review checklist vs base branch |
| `/qq:timeline` | Commit history grouped into semantic phases |
| `/qq:full-brief` | Run brief + timeline in parallel |
| `/qq:deps` | Analyze `.asmdef` dependencies (Mermaid graph + matrix) |
| `/qq:doc-drift` | Compare design docs against actual code |

### Utilities

| Command | Description |
|---------|-------------|
| `/qq:commit-push` | Batch commit and push |
| `/qq:explain` | Explain module architecture in plain language |
| `/qq:grandma` | Explain concepts using everyday analogies |
| `/qq:research` | Search open-source communities for solutions |
| `/qq:changes` | Summarize all changes from current session |
| `/qq:doc-tidy` | Scan and recommend documentation cleanup |

## Work Modes

| Mode | When | Must Do | Usually Skip |
|------|------|---------|--------------|
| `prototype` | New mechanic, greybox, fun check | Keep compile green, stay playable | Formal docs, full review |
| `feature` | Building a retainable system | Design, plan, compile, targeted tests | Full regression on every change |
| `fix` | Bug fix, regression repair | Reproduce first, smallest safe fix | Large refactors |
| `hardening` | Risky refactor, release prep | Tests, review, doc/code consistency | Prototype shortcuts |

Set the shared default in `qq.yaml`. Override per-worktree in `.qq/local.yaml`. Type `/qq:go` to start — it reads your mode and adjusts recommendations.

`work_mode` and `policy_profile` are separate knobs. `work_mode` answers "what kind of task is this?" while `policy_profile` answers "how much verification does this project expect?" A prototype and a hardening pass can share the same policy profile, or not — they are independent. See [Configuration](docs/configuration.md) for the full reference.

## How It Works

qq operates as a four-layer runtime:

```
Edit .cs/.gd file
  → Hook auto-compiles (tykit / editor trigger / batch mode)
    → Result written to .qq/state/
      → /qq:go reads state, recommends next step
```

**Hooks** fire automatically on tool use — compiling after code edits, tracking skill modifications, and gating edits during review verification. **`/qq:go`** is the controller: it reads project state (`work_mode`, `policy_profile`, last compile/test results) from `.qq/state/` and routes you to the right skill. **Engine bridges** provide verified, in-process execution rather than blind file writes. **Runtime data** in `.qq/` gives every layer a shared, structured view of project health.

For cross-model review, the Codex Tribunal runs Codex CLI against your diff, then Claude subagents verify each finding and check for over-engineering — up to 5 rounds until clean.

See [Architecture Overview](docs/architecture/overview.md) for diagrams and layer details, [Hook System](docs/hooks.md) for auto-compile and review gate internals, [Cross-Model Review](docs/cross-model-review.md) for the Codex Tribunal flow, and [Worktrees](docs/worktrees.md) for parallel task isolation.

## Customization

Three files control qq's behavior in your project:

- **`qq.yaml`** — runtime config: `work_mode`, `policy_profile`, `trust_level`, module selection. Built-in profiles: `lightweight`, `core`, `feature`, `hardening`. See [`templates/qq.yaml.example`](templates/qq.yaml.example).
- **`CLAUDE.md`** — coding standards and compile verification rules scoped to your project. See [`templates/CLAUDE.md.example`](templates/CLAUDE.md.example).
- **`AGENTS.md`** — architecture rules and review criteria for subagent workflows. See [`templates/AGENTS.md.example`](templates/AGENTS.md.example).

## tykit

tykit is a lightweight HTTP server inside the Unity Editor process — zero setup, no external dependencies, millisecond response times. It exposes compile, test, play/stop, console, and inspector commands over localhost. Port is derived from your project path hash and stored in `Temp/tykit.json`.

```bash
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")
curl -s -X POST http://localhost:$PORT/ -d '{"command":"compile"}' -H 'Content-Type: application/json'
curl -s -X POST http://localhost:$PORT/ -d '{"command":"run-tests","args":{"mode":"editmode"}}' -H 'Content-Type: application/json'
```

tykit works standalone without qq — just add the [UPM package](packages/com.tyk.tykit/). An MCP bridge (`tykit_mcp.py`) is available for non-Claude agents. See [`docs/tykit-api.md`](docs/tykit-api.md) for the full API and [`docs/tykit-mcp.md`](docs/tykit-mcp.md) for MCP integration.

## FAQ

**Does this work on Windows?**
Yes, with preview status. Requires [Git for Windows](https://gitforwindows.org/) (provides bash, curl, and core utilities).

**Do I need Codex CLI?**
No. Codex CLI enables cross-model review (`/qq:codex-code-review`), but Claude-only review via `/qq:claude-code-review` works without it.

**Can I use this with Cursor/Copilot?**
The `/qq:*` skills require Claude Code. tykit works standalone via HTTP with any tool, and the MCP bridge (`tykit_mcp.py`) exposes it to other agents.

**What happens when compilation fails?**
The auto-compile hook captures the error output and surfaces it in the conversation. Claude reads the errors and fixes the code, then the hook compiles again automatically.

**Can I use tykit without quick-question?**
Yes. Add the UPM package from [`packages/com.tyk.tykit/`](packages/com.tyk.tykit/) to your project. See the [tykit README](packages/com.tyk.tykit/README.md).

**Which Unity versions are supported?**
tykit requires Unity 2021.3+. MCP alternatives: [mcp-unity](https://github.com/nicoboss/mcp-unity) requires Unity 6+, [Unity-MCP](https://github.com/mpiechot/Unity-MCP) has no version requirement.

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).

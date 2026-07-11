<p align="center">
  <img src="logo.png" alt="quick-question" width="200">
</p>

<h1 align="center">quick-question</h1>

<p align="center">
  <strong>The control plane for game-dev agents.</strong><br>
  Close the loop — compile, test, review, and ship — across Unity, Godot, Unreal, and S&box.<br>
  <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a>-first.
  Open to any agent via HTTP and MCP.
</p>

<p align="center">
  <a href="https://github.com/tykisgod/quick-question/actions/workflows/validate.yml"><img src="https://github.com/tykisgod/quick-question/actions/workflows/validate.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/version-v1.17.0-blue" alt="Version">
  <a href="https://github.com/tykisgod/quick-question/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows-blue" alt="Platform">
</p>

<table align="center" cellspacing="0" cellpadding="16" border="0">
  <tr>
    <td align="center" border="0">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/unity-light.svg">
        <img src="docs/images/unity-dark.svg" width="56" alt="Unity">
      </picture>
      <br>
      <a href="https://unity.com">Unity</a>
    </td>
    <td align="center" border="0">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/godot-light.svg">
        <img src="docs/images/godot-dark.svg" width="56" alt="Godot">
      </picture>
      <br>
      <a href="https://godotengine.org">Godot</a>
    </td>
    <td align="center" border="0">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/unreal-light.svg">
        <img src="docs/images/unreal-dark.svg" width="56" alt="Unreal">
      </picture>
      <br>
      <a href="https://www.unrealengine.com">Unreal</a>
    </td>
    <td align="center" border="0">
      <img src="docs/images/sbox.svg" width="56" alt="S&amp;box">
      <br>
      <a href="https://github.com/Facepunch/sbox-public">S&amp;box</a>
    </td>
  </tr>
</table>

<p align="center">
  English |
  <a href="#中文">中文</a> |
  <a href="docs/ja/README.md">日本語</a> |
  <a href="docs/ko/README.md">한국어</a>
</p>

---

> **✅ Verified path:** **Claude Code + Unity 2021.3+ on macOS or Windows.** Daily-driven, end-to-end battle-tested. This is the recommended setup if you want everything in this README to "just work".
>
> **🧪 Experimental — contributions welcome:** Godot, Unreal, and S&box adapters ship as scaffolds. The bridge code, command surface, and CI smoke tests are in place, but **no one has yet shipped a real game using any non-Unity adapter** — they have not been validated in actual development use. Same caveat for non-Claude hosts (Codex CLI, Cursor, Continue, other MCP hosts): the runtime is agent-agnostic *by design*, but the verified loop is Claude Code-only. If you're building with one of these, your bug reports and PRs are how the adapter graduates to "verified" — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Why qq

AI agents can write code. They cannot, by default, tell you whether the code compiles, the tests pass, the behavior is right, or whether they just produced 500 lines of plausible-looking nonsense. In a game project — where "running" means the editor opens, the scene loads, and frame N+1 looks like you wanted — that gap is the entire problem.

quick-question is the runtime layer that closes it. Four work modes — `prototype`, `feature`, `fix`, `hardening` — are first-class state, not flavor text. A prototype keeps the compile green and stays playable; a hardening pass forces tests, review, and document/code consistency before shipping. The artifact-driven controller (`/qq:go`) reads `.qq/state/*.json` and your `work_mode`, then recommends the concrete next skill — instead of guessing from chat history.

The runtime is engine-symmetric and agent-agnostic. tykit gives Unity the deepest integration (an in-process HTTP server, millisecond response). Godot, Unreal, and S&box are at runtime parity through Python bridges. [Claude Code](https://docs.anthropic.com/en/docs/claude-code) gets 26 skills, auto-compile hooks, and review gates. Codex, Cursor, Continue, and any MCP-compatible host get the same underlying runtime through HTTP and MCP. Structured state in `.qq/` is plain JSON on disk — readable by any agent, across sessions.

The methodology is grounded in the document-first approach described in [*AI Coding in Practice: An Indie Developer's Document-First Approach*](https://tyksworks.com/posts/ai-coding-workflow-en/).

## How it works

```
Edit .cs/.gd/.cpp file
  → Hook auto-compiles via qq-compile.sh
    → Result + error context written to .qq/state/
      → /qq:go reads state, recommends next skill
        → Skill runs, writes new state
          → Loop
```

Four layers cooperate:

- **Hooks** fire on every Claude Code tool call. PostToolUse compiles after `Edit`/`Write` on engine source files via `qq-compile.sh` (the multi-engine dispatcher). PreToolUse blocks edits during review verification, or after a red compile, until the relevant gate clears. Stop blocks session end if skills were modified without `/qq:self-review`. All gate files are keyed by `$PPID` for session isolation.
- **Controller** — `/qq:go` reads `.qq/state/*.json`, recent run records, your `work_mode`, and the active `policy_profile`, then routes to the next skill. It is a controller, not an implementation engine — it only falls back to context heuristics when state is ambiguous.
- **Engine bridges** — tykit (Unity in-process HTTP), `godot_bridge.py`, `unreal_bridge.py`, `sbox_bridge.py`. Compile, test, console, find / inspect — verified execution, not blind file writes.
- **Runtime data** — `.qq/runs/*.json` (raw run logs), `.qq/state/*.json` (latest compile / test state), `.qq/state/session-decisions.json` (cross-skill decision journal), `.qq/telemetry/`. Plain JSON, readable by any agent across sessions.

For code review, two symmetric modes share the same verification loop: **Codex review** (`code-review.sh` → `codex exec`, cross-model) and **Claude review** (`claude-review.sh` → `claude -p`, single-model). Each produces findings, then independent verification subagents check every finding against actual source and flag over-engineering — up to 5 rounds until clean. The unified review gate (`scripts/hooks/review-gate.sh`) blocks edits until all verification subagents complete (three-field format: `<ts>:<completed>:<expected>`). MCP exposes one-shot `qq_code_review` and `qq_plan_review` tools for non-Claude hosts.

See [Architecture Overview](docs/dev/architecture/overview.md), [Hook System](docs/en/hooks.md), [Cross-Model Review](docs/en/cross-model-review.md), and [Worktrees](docs/en/worktrees.md) for layer-by-layer detail.

## Engines

| Engine | Compile | Test | Editor control | Bridge |
|--------|---------|------|----------------|--------|
| **Unity 2021.3+** ✅ verified | tykit / editor trigger / batch | EditMode + PlayMode | tykit HTTP server | `tykit_bridge.py` |
| **Godot 4.x** 🧪 preview | GDScript check via headless editor | GUT / GdUnit4 | Editor addon | `godot_bridge.py` |
| **Unreal 5.x** 🧪 preview | UnrealBuildTool + editor commandlet | Automation tests | Editor command (Python) | `unreal_bridge.py` |
| **S&box** 🧪 preview | `dotnet build` | Runtime tests | Editor bridge | `sbox_bridge.py` |

Unity is the verified path — daily-driven via tykit's in-process HTTP server (millisecond response). Godot, Unreal, and S&box ship as **experimental scaffolds**: the adapter code, bridge surfaces, and CI smoke tests are in place, but no one has yet built a real game on top of any non-Unity adapter. Treat them as starting points for contributors, not as production-ready paths — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Install

### Requirements

- macOS or Windows (Windows needs [Git for Windows](https://gitforwindows.org/) for bash + core utilities)
- Engine: Unity 2021.3+ / Godot 4.x / Unreal 5.x / S&box
- `python3` (required), `jq` (recommended — hook scripts fall back to python3 when jq is missing)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) for the full skill + hook experience
- [Codex CLI](https://github.com/openai/codex) (optional — enables cross-model review)

### Install the runtime

All agents share the same runtime install. It auto-detects your engine and writes scripts, bridges, and config into the project.

```bash
git clone https://github.com/tykisgod/quick-question.git /tmp/qq
/tmp/qq/install.sh /path/to/your-project          # auto-detect engine
/tmp/qq/install.sh --wizard /path/to/your-project  # interactive wizard
/tmp/qq/install.sh --preset quickstart /path/to/your-project  # one-shot preset
rm -rf /tmp/qq
```

Available presets: `quickstart` (minimal), `daily` (recommended), `stabilize` (full checks for release prep). Use `--profile`, `--modules`, `--without` for fine-grained control.

### Connect your agent

| Agent | Setup | What you get |
|-------|-------|--------------|
| **Claude Code** | `/plugin marketplace add tykisgod/quick-question`<br>`/plugin install qq@quick-question-marketplace` | All 26 `/qq:*` slash commands, auto-compile hooks, review gates, MCP — full experience |
| **Codex CLI** | `python3 ./scripts/qq-codex-mcp.py install --pretty` | Project-local MCP bridge; use `qq-codex-exec.py` to pin the working root |
| **Cursor / Continue / other MCP hosts** | Add `qq` to `mcpServers` in your host config: `command: python3`, `args: ["./scripts/qq_mcp.py"]`, `cwd: /path/to/project` | Compile, test, console, editor control as MCP tools — see [`docs/en/tykit-mcp.md`](docs/en/tykit-mcp.md) |
| **Any HTTP client** | Read port from `Temp/tykit.json`, POST JSON to `localhost:$PORT/` | Direct tykit access — see [`docs/en/tykit-api.md`](docs/en/tykit-api.md) |

For non-Unity engines, call the bridge scripts directly (e.g. `python3 ./scripts/godot_bridge.py compile`).

## Quick start

> **80/20 principle.** qq has 26 commands but most of the value comes from 4. This section is the fastest path to ROI — learn the 20% that matters, ignore the rest until you actually need it.

### Step 1 — Set your default work mode

`work_mode` controls how strict the workflow is. Pick the lightest mode that fits the task; escalate later only when needed.

| Mode | When | What it does |
|---|---|---|
| `prototype` | Trying ideas, gray-box, fun check | Compile-green only. Skips formal docs and review. |
| `feature` ⭐ | **Default for normal feature work** | Plan + execute + test + targeted review. Balanced. |
| `fix` | Reproducing and fixing a known bug | Repro first, smallest safe fix, regression test. |
| `hardening` | Pre-merge, pre-release, risky refactor | Tests + review + doc-drift + best-practice. The strict gate. |

Set it once in `.qq/local.yaml`:

```yaml
work_mode: feature
```

**The most common new-user mistake is leaving the project on `hardening` by default**, then complaining qq is "too noisy". Stay in `feature` and only flip to `hardening` at merge time.

### Step 2 — Learn one loop, not 26 commands

For 90% of tasks this is all you need:

```bash
/qq:go "what you want to do"   # picks the right next step from .qq/state + work_mode
/qq:execute                     # implement (auto-compile on every .cs edit)
/qq:test                        # run tests + scrape runtime errors from Editor.log
/qq:best-practice               # quick anti-pattern + perf scan
```

`/qq:go` is the adaptive entry point — it reads `.qq/state` and your `work_mode`, then routes to the right skill. For clear tasks, jump straight to `/qq:execute`. For vague ones, let `/qq:go` route you through `/qq:design` → `/qq:plan` first.

The auto-compile hook is what makes this worth the setup: every `.cs` edit triggers compile, and the **compile gate blocks further edits while compilation is red** until you fix it. The single biggest time sink the loop kills is "I think it builds — let me find out tomorrow".

### Step 3 — Three templates that cover most work

**Feature development**
```bash
/qq:go "add a fatigue recovery system to crew"
/qq:execute
/qq:test
/qq:best-practice
```

**Bug fix** (qq enters `fix` mode → repro → minimal patch → regression test)
```bash
/qq:go "fix the harbor docking bug, repro first"
/qq:execute
/qq:test
```

**Pre-merge gate** (only when you're about to push or PR)
```bash
/qq:best-practice
/qq:claude-code-review        # or /qq:codex-code-review for cross-model
/qq:doc-drift
/qq:test
/qq:commit-push
```

### Step 4 — What to skip in your first week

Resist using these until the basic loop above is predictable:

- **`/qq:bootstrap`** — wait until you trust the loop
- **Heavy doc ceremony** (`/qq:design` → `/qq:plan` → `/qq:doc-drift` for every task) — only use design/plan when the task is genuinely vague. They're not a tax.
- **Cross-model review on every change** — save `/qq:codex-code-review` for merge gates or large refactors. It's 5–10 min per round; running it after every small edit kills the rhythm.
- **`/qq:go --auto`** — end-to-end automation works, but build trust in manual runs first
- **Custom profiles / packs / module switching** — defaults are fine for week one

### Step 5 — Customize `CLAUDE.md` as real guardrails

Install copies a `CLAUDE.md` template to your project. **Replace the boilerplate with 5–8 hard rules that match your project**, not an essay. Example rules for a Unity game project:

- Runtime logic must not use reflection
- Do not modify UI / prefab names / inspector fields unless asked
- No `GetComponent` / `FindObjectOfType` in `Update` / `FixedUpdate` paths
- After editing `.cs`, must verify compile-green before reporting "done"
- Prefer existing patterns; do not invent a second framework
- No abstraction layers for hypothetical future requirements

This is the single highest-ROI customization — it cuts the rate at which the model "gets clever" in the wrong direction.

### Two warnings

1. **Don't read raw `.qq/runs/*.json` logs in your prompts.** They're operational telemetry, not context. Use `qq-project-state.py --pretty` for the structured snapshot when you actually need state.
2. **Don't run cross-model review after every small edit.** It makes the loop feel slow and you'll start hating qq for the wrong reason. Reserve it for merge gates and large refactors.

### Success check (week 1)

After a week, ask yourself:

1. Did manual "back to Unity to check compile" trips drop noticeably?
2. Did "AI says done but it isn't" rework drop?
3. Did mid-size feature wrap-up time get shorter?
4. Did review-gate ceremony start feeling annoying?

If 1–3 improved and 4 is tolerable, scale up. If 4 dominates, drop the project to `feature` or `prototype` and only flip to `hardening` at merge time — that's exactly what the profile system is designed for.

→ Deeper walkthroughs: [Getting Started](docs/en/getting-started.md) · [Configuration](docs/en/configuration.md) · [Worktrees](docs/en/worktrees.md)

## Commands

### Workflow

| Command | Description |
|---------|-------------|
| `/qq:go` | Detect workflow stage, recommend next step |
| `/qq:bootstrap` | Decompose a game vision into epics, orchestrate full pipeline for each |
| `/qq:design` | Write a game design document |
| `/qq:plan` | Generate technical implementation plan |
| `/qq:execute` | Smart implementation with auto-compile verification |

### Testing

| Command | Description |
|---------|-------------|
| `/qq:add-tests` | Author EditMode, PlayMode, or regression tests |
| `/qq:test` | Run tests and check for runtime errors |

### Code review

| Command | Description |
|---------|-------------|
| `/qq:codex-code-review` | Cross-model: Codex reviews, Claude verifies (max 5 rounds) |
| `/qq:codex-plan-review` | Cross-model plan / design review |
| `/qq:claude-code-review` | Claude-only deep code review with auto-fix loop |
| `/qq:claude-plan-review` | Claude-only plan / design review |
| `/qq:best-practice` | Quick scan for anti-patterns and performance issues |
| `/qq:self-review` | Review recent skill / config changes |
| `/qq:post-design-review` | Review a design doc from implementer's perspective — check consistency, buildability, codebase gaps |

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
| `/qq:tech-research` | Search open-source communities for technical solutions |
| `/qq:design-research` | Search for game design references and patterns |
| `/qq:changes` | Summarize all changes from the current session |
| `/qq:doc-tidy` | Scan and recommend documentation cleanup |

## Work modes

| Mode | When | Must do | Usually skip |
|------|------|---------|--------------|
| `prototype` | New mechanic, greybox, fun check | Keep compile green, stay playable | Formal docs, full review |
| `feature` | Building a retainable system | Design, plan, compile, targeted tests | Full regression on every change |
| `fix` | Bug fix, regression repair | Reproduce first, smallest safe fix | Large refactors |
| `hardening` | Risky refactor, release prep | Tests, review, doc / code consistency | Prototype shortcuts |

Set the shared default in `qq.yaml`. Override per-worktree in `.qq/local.yaml`. `work_mode` and `policy_profile` are independent: the first answers "what kind of task is this?", the second answers "how much verification does this project expect?". A prototype and a hardening pass can share the same policy profile, or not. See [Configuration](docs/en/configuration.md) for the full reference.

## Configuration

Three files control qq's behavior in your project:

- **`qq.yaml`** — runtime config: `work_mode`, `policy_profile`, `trust_level`, module selection. Built-in profiles: `lightweight`, `core`, `feature`, `hardening`. See [`templates/qq.yaml.example`](templates/qq.yaml.example).
- **`CLAUDE.md`** — coding standards and compile verification rules scoped to your project. See [`templates/CLAUDE.md.example`](templates/CLAUDE.md.example).
- **`AGENTS.md`** — architecture rules and review criteria for subagent workflows. See [`templates/AGENTS.md.example`](templates/AGENTS.md.example).

## tykit

tykit (currently **v0.5.0**) is a lightweight HTTP server inside the Unity Editor process — zero setup, no external dependencies, millisecond response. It exposes 60+ commands over localhost, organized into compile/test, console, scene/hierarchy, GameObject lifecycle, **reflection** (`call-method` / `get-field` / `set-field` — invoke arbitrary methods on components without scaffolding), prefab editing, **physics queries** (raycast, overlap-sphere), asset management, UI automation, and editor control. Port is derived from your project path hash and stored in `Temp/tykit.json`.

```bash
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")
curl -s -X POST http://localhost:$PORT/ -d '{"command":"compile"}' -H 'Content-Type: application/json'
curl -s -X POST http://localhost:$PORT/ -d '{"command":"run-tests","args":{"mode":"editmode"}}' -H 'Content-Type: application/json'
```

**The differentiator** (v0.5.0): when Unity's main thread is blocked by a modal dialog or background-throttled domain reload, tykit's listener-thread `GET /health`, `GET /focus-unity`, and `GET /dismiss-dialog` endpoints can drag Unity back into a working state without depending on the stuck main thread. Every other Unity bridge dies in this scenario; tykit recovers. See [`docs/en/tykit-api.md#main-thread-recovery`](docs/en/tykit-api.md#main-thread-recovery).

tykit also works standalone, without qq — add the [UPM package](packages/com.tyk.tykit/) to any Unity project. Any agent that can send HTTP can use it directly. The MCP bridge (`tykit_mcp.py`) wraps it for MCP-compatible hosts. See [`docs/en/tykit-api.md`](docs/en/tykit-api.md) and [`docs/en/tykit-mcp.md`](docs/en/tykit-mcp.md).

## FAQ

**Does this work on Windows?**
Yes. Requires [Git for Windows](https://gitforwindows.org/) for bash, curl, and core utilities. The 1.15.x and 1.16.x releases hardened Windows support — LF line endings via `.gitattributes`, path normalization, Python Store-alias detection, and a jq fallback in hook scripts.

**Do I need Codex CLI?**
No. Codex CLI enables cross-model review (`/qq:codex-code-review`), but `/qq:claude-code-review` works without it.

**Can I use this with Cursor / Copilot / Codex / other agents?**
Yes. The runtime layer (tykit, engine bridges, `.qq/` state, scripts) is agent-agnostic — anything that can send HTTP or speak MCP can use it. The 26 `/qq:*` slash commands and auto-compile hooks are Claude Code-specific, but the underlying scripts they call are ordinary shell and Python. See [`docs/dev/agent-integration.md`](docs/dev/agent-integration.md).

**What happens when compilation fails?**
The auto-compile hook captures the error output and surfaces it in the conversation. The compile gate then blocks subsequent edits to engine source files until the compile recovers. The agent reads the errors, fixes the code, and the hook compiles again automatically.

**Can I use tykit without quick-question?**
Yes. Add the UPM package from [`packages/com.tyk.tykit/`](packages/com.tyk.tykit/). See the [tykit README](packages/com.tyk.tykit/README.md).

**Which Unity versions are supported?**
tykit requires Unity 2021.3+. MCP alternatives: [mcp-unity](https://github.com/nicoboss/mcp-unity) requires Unity 6+; [Unity-MCP](https://github.com/mpiechot/Unity-MCP) has no version requirement.

---

<!--
  ╔════════════════════════════════════════════════════════════════════════╗
  ║  ⚠️  DO NOT EDIT THE CHINESE SECTION BELOW DIRECTLY                    ║
  ║                                                                        ║
  ║  The Chinese half of this README is AUTO-GENERATED from                ║
  ║      docs/zh-CN/README.md                                              ║
  ║  by scripts/qq-sync-readme-zh.py.                                      ║
  ║                                                                        ║
  ║  To update Chinese content:                                            ║
  ║    1. Edit  docs/zh-CN/README.md                                       ║
  ║    2. Run   python scripts/qq-sync-readme-zh.py --write                ║
  ║    3. Commit BOTH docs/zh-CN/README.md AND README.md                   ║
  ║                                                                        ║
  ║  CI enforces sync via test.sh section 4 and qq-release.sh pre-flight.  ║
  ║  Direct edits below this comment will be overwritten on next sync.     ║
  ╚════════════════════════════════════════════════════════════════════════╝
-->

<h2 align="center">中文</h2>

> **✅ 已验证路径**：**Claude Code + Unity 2021.3+，macOS 或 Windows**。每天实战、端到端经过验证。这是想让 README 里所有内容"开箱即用"时的推荐配置。
>
> **🧪 实验性 — 欢迎贡献**：Godot、Unreal、S&box 适配器目前只是**脚手架**。桥接代码、命令接口和 CI smoke test 都到位了，但**还没有人用任何非 Unity 适配器实际开发过游戏**——它们没有经过真实开发场景的验证。非 Claude 宿主（Codex CLI、Cursor、Continue 等其他 MCP 宿主）同理——运行时的*设计*是 agent 无关的，但已验证的工作流仅限 Claude Code。如果你正在用其中之一开发，你的 bug 报告和 PR 就是该适配器晋级到"已验证"的路径——参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 为什么选 qq

AI agent 能写代码。但默认情况下，它告诉不了你代码能不能编译、测试有没有过、行为对不对，或者它是不是刚写了 500 行貌似合理的废话。在游戏项目里——"运行起来"意味着编辑器打开、场景加载、第 N+1 帧看起来跟你想的一样——这个鸿沟就是问题的全部。

quick-question 是把这个鸿沟闭合掉的运行时层。四种工作模式 `prototype`、`feature`、`fix`、`hardening` 是一等公民状态，不是装饰文字。原型模式保持编译绿灯、保持可玩；加固模式在发版前强制测试、审阅和文档/代码一致性。artifact 驱动的控制器 `/qq:go` 读取 `.qq/state/*.json` 和你的 `work_mode`，然后推荐具体的下一个 skill——而不是从聊天历史里靠猜。

运行时是引擎对称的、agent 无关的。tykit 给 Unity 提供最深度的集成（进程内 HTTP 服务器，毫秒级响应）。Godot、Unreal 和 S&box 通过 Python 桥接达到运行时对等。[Claude Code](https://docs.anthropic.com/en/docs/claude-code) 拥有 26 个 skill、自动编译 hook 和审阅门。Codex、Cursor、Continue 和任何 MCP 兼容宿主通过 HTTP 和 MCP 访问相同的底层运行时。`.qq/` 中的结构化状态是磁盘上的纯 JSON——任何 agent 都能跨会话读取。

方法论基于 [*AI 编程实践：独立开发者的文档驱动方法*](https://tyksworks.com/posts/ai-coding-workflow-zh/)。

## 工作原理

```
Edit .cs/.gd/.cpp file
  → Hook 通过 qq-compile.sh 自动编译
    → 结果 + 错误上下文写入 .qq/state/
      → /qq:go 读状态，推荐下一个 skill
        → Skill 跑完，写新状态
          → 循环
```

四层协作：

- **Hooks** 在每次 Claude Code 工具调用时触发。PostToolUse 在 `Edit`/`Write` 编辑引擎源文件后通过 `qq-compile.sh`（多引擎分派器）编译。PreToolUse 在审阅验证期间或编译红灯之后阻止编辑，直到对应的门解除。Stop 在 skill 修改后未运行 `/qq:self-review` 时阻止会话结束。
- **控制器** —— `/qq:go` 读取 `.qq/state/*.json`、最近的运行记录、你的 `work_mode` 和当前 `policy_profile`，然后路由到下一个 skill。它是控制器，不是实现引擎——只在状态模糊时才回退到上下文启发式。
- **引擎桥接** —— tykit（Unity 进程内 HTTP）、`godot_bridge.py`、`unreal_bridge.py`、`sbox_bridge.py`。编译、测试、控制台、find / inspect——经过验证的执行，而非盲目文件写入。
- **运行时数据** —— `.qq/runs/*.json`（原始运行日志）、`.qq/state/*.json`（最新编译/测试状态）、`.qq/state/session-decisions.json`（跨 skill 决策日志）、`.qq/telemetry/`。纯 JSON，任何 agent 都能跨会话读取。

代码审阅有两种对称模式共享相同的验证循环：**Codex 审阅**（`code-review.sh` → `codex exec`，跨模型）和 **Claude 审阅**（`claude-review.sh` → `claude -p`，单模型）。每种都产出发现，然后独立的验证子 agent 对照实际源码逐条检查并标记过度设计——最多 5 轮直到通过。统一审阅门（`scripts/hooks/review-gate.sh`）在所有验证子 agent 完成前阻止编辑（三字段格式：`<ts>:<completed>:<expected>`）。MCP 为非 Claude 宿主提供一次性 `qq_code_review` 和 `qq_plan_review` 工具。

详见 [架构总览](docs/dev/architecture/overview.md)、[Hook 系统](docs/zh-CN/hooks.md)、[跨模型审阅](docs/zh-CN/cross-model-review.md) 和 [并行 Worktree](docs/zh-CN/worktrees.md)。

## 引擎

| 引擎 | 编译 | 测试 | 编辑器控制 | 桥接 |
|------|------|------|-----------|------|
| **Unity 2021.3+** ✅ verified | tykit / editor trigger / batch | EditMode + PlayMode | tykit HTTP server | `tykit_bridge.py` |
| **Godot 4.x** 🧪 preview | GDScript check via headless editor | GUT / GdUnit4 | Editor addon | `godot_bridge.py` |
| **Unreal 5.x** 🧪 preview | UnrealBuildTool + editor commandlet | Automation tests | Editor command (Python) | `unreal_bridge.py` |
| **S&box** 🧪 preview | `dotnet build` | Runtime tests | Editor bridge | `sbox_bridge.py` |

Unity 是已验证路径，每天通过 tykit 进程内 HTTP 实战使用（毫秒级响应）。Godot、Unreal、S&box 以**实验性脚手架**形式出货：适配器代码、桥接接口和 CI smoke test 都到位了，但还没有人用任何非 Unity 适配器实际开发过游戏。把它们当成贡献者的起点，而不是生产就绪的路径——参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 安装

### 前置条件

- macOS 或 Windows（Windows 需要 [Git for Windows](https://gitforwindows.org/) 提供 bash 和核心工具）
- 引擎：Unity 2021.3+ / Godot 4.x / Unreal 5.x / S&box
- `python3`（必需）、`jq`（推荐——hook 脚本在 jq 缺失时会 fallback 到 python3）
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)（完整 skill + hook 体验）
- [Codex CLI](https://github.com/openai/codex)（可选——启用跨模型审阅）

### 安装运行时

所有 agent 共享同一套运行时安装。它自动检测引擎并将脚本、桥接和配置写入项目。

```bash
git clone https://github.com/tykisgod/quick-question.git /tmp/qq
/tmp/qq/install.sh /path/to/your-project          # 自动检测引擎
/tmp/qq/install.sh --wizard /path/to/your-project  # 交互式向导
/tmp/qq/install.sh --preset quickstart /path/to/your-project  # 一键预设
rm -rf /tmp/qq
```

可用预设：`quickstart`（最轻量）、`daily`（推荐）、`stabilize`（发版前完整检查）。细粒度控制参见 `--profile`、`--modules` 和 `--without`。

### 接入你的 agent

| Agent | 接入命令 | 你将获得 |
|-------|---------|--------|
| **Claude Code** | `/plugin marketplace add tykisgod/quick-question`<br>`/plugin install qq@quick-question-marketplace` | 全部 26 个 `/qq:*` slash 命令、自动编译 hook、审阅门、MCP——完整体验 |
| **Codex CLI** | `python3 ./scripts/qq-codex-mcp.py install --pretty` | 项目本地 MCP 桥接；用 `qq-codex-exec.py` 固定工作根目录 |
| **Cursor / Continue / 其他 MCP 宿主** | 在宿主配置的 `mcpServers` 加 `qq`：`command: python3`、`args: ["./scripts/qq_mcp.py"]`、`cwd: /path/to/project` | 编译、测试、控制台、编辑器控制作为 MCP tool——参见 [`docs/zh-CN/tykit-mcp.md`](docs/zh-CN/tykit-mcp.md) |
| **任何 HTTP 客户端** | 从 `Temp/tykit.json` 读端口，POST JSON 到 `localhost:$PORT/` | 直接访问 tykit——参见 [`docs/zh-CN/tykit-api.md`](docs/zh-CN/tykit-api.md) |

非 Unity 引擎直接调用桥接脚本（如 `python3 ./scripts/godot_bridge.py compile`）。

## 快速开始

> **80/20 原则**：qq 有 26 个命令，但绝大部分价值集中在其中 4 个。这一节是最快的 ROI 路径——掌握那 20% 真正重要的，剩下的等到你真的需要再说。

### 第一步 —— 设置默认 work_mode

`work_mode` 控制流程的严格程度。**选最轻量的模式** 来匹配任务，需要时再升级。

| 模式 | 适用场景 | 它做什么 |
|---|---|---|
| `prototype` | 试玩法、灰盒、fun check | 只要编译绿灯。跳过正式文档和审阅。 |
| `feature` ⭐ | **常规功能开发的默认值** | 计划 + 实现 + 测试 + 定向审阅。平衡型。 |
| `fix` | 复现并修复明确 bug | 先复现，最小安全修复，回归测试。 |
| `hardening` | 合并前 / 发版前 / 高风险重构 | 测试 + 审阅 + 文档对比 + 最佳实践。严格闸门。 |

在 `.qq/local.yaml` 里设一次：

```yaml
work_mode: feature
```

**新用户最常犯的错误是默认让项目停在 `hardening`**，然后抱怨 qq "太啰嗦"。日常待在 `feature`，只在 merge 前切到 `hardening`。

### 第二步 —— 学一条主循环，不是 26 个命令

90% 的任务，你只需要这 4 个命令：

```bash
/qq:go "你想做的事情"      # 根据 .qq/state 和 work_mode 决定下一步
/qq:execute                # 实现——每次 .cs 编辑自动编译
/qq:test                   # 跑测试 + 从 Editor.log 抓运行时错误
/qq:best-practice          # 快速反模式 + 性能扫描
```

`/qq:go` 是自适应入口——它读 `.qq/state` 和你的 `work_mode`，自动路由到正确的 skill。**任务清晰** 时直接跳到 `/qq:execute`；**任务模糊** 时让 `/qq:go` 路由你先走 `/qq:design` → `/qq:plan`。

让这套设置回本的关键是 auto-compile hook：每次 `.cs` 编辑触发编译，**编译失败时 compile gate 会阻止进一步编辑**，直到你修好。这条循环消灭的最大时间黑洞就是"我以为编过了，明天再确认"。

### 第三步 —— 三个覆盖大部分工作的模板

**新功能开发**
```bash
/qq:go "给船员系统加疲劳恢复机制"
/qq:execute
/qq:test
/qq:best-practice
```

**修 bug**（qq 进入 `fix` 模式 → 复现 → 最小修复 → 回归测试）
```bash
/qq:go "修复港口靠岸 bug，先复现"
/qq:execute
/qq:test
```

**合并前闸门**（只在你准备 push 或开 PR 时跑）
```bash
/qq:best-practice
/qq:claude-code-review        # 或 /qq:codex-code-review 跨模型审阅
/qq:doc-drift
/qq:test
/qq:commit-push
```

### 第四步 —— 第一周先不要碰这些

主循环跑顺之前，**忍住别用** 这些：

- **`/qq:bootstrap`** —— 等你信任主循环之后再说
- **重度文档 ceremony**（每个任务都 `/qq:design` → `/qq:plan` → `/qq:doc-drift`）—— design/plan 是给真模糊的任务用的，不是每个任务的税
- **每次改动都跑跨模型审阅** —— `/qq:codex-code-review` 留给 merge 闸门或大重构。每轮 5–10 分钟，每改几行就跑会拖垮节奏。
- **`/qq:go --auto`** —— 端到端自动化是真的能跑，但先在手动模式建立"可预测感"
- **自定义 profile / pack / 模块切换** —— 默认值在第一周完全够用

### 第五步 —— 把 `CLAUDE.md` 改成真正的护栏

安装时会复制一份 `CLAUDE.md` 模板到你的项目。**把模板里的套话替换成你项目真正在乎的 5–8 条硬规则**，不要写成作文。Unity 游戏项目的示例规则：

- Runtime 逻辑禁止反射
- 未明确要求时不要改 UI / prefab 命名 / inspector 暴露字段
- `Update` / `FixedUpdate` 路径里禁止 `GetComponent` / `FindObjectOfType`
- 改完 `.cs` 必须验证编译绿灯才能汇报"完成"
- 优先沿用现有模式，不要发明第二套框架
- 不要为假设的未来需求增加抽象层

这是 ROI 最高的一项定制——它直接降低模型"自作聪明往错方向走"的频率。

### 两个警告

1. **不要把 `.qq/runs/*.json` 原始日志塞进 prompt。** 那是运维 telemetry，不是上下文。真需要状态时跑 `qq-project-state.py --pretty` 拿结构化快照。
2. **不要每改一点就跑跨模型审阅。** 它会让循环感觉很慢，你会因为错误的原因开始讨厌 qq。Cross-model review 留给 merge 闸门和大重构。

### 第一周自检

一周后，问自己 4 个问题：

1. 手动回 Unity 查编译结果的次数有没有明显下降？
2. 因为 AI "说完成了但其实没好"导致的返工有没有下降？
3. 中型功能的收尾时间有没有变短？
4. 审阅闸门 / ceremony 有没有开始让你觉得烦？

如果 1–3 改善了、4 还可以接受，就继续加码。如果 4 让你受不了，把项目降到 `feature` 或 `prototype`，只在 merge 前临时切 `hardening`——profile 系统本来就是为这种分层设计的。

→ 更深入的演练：[快速上手](docs/zh-CN/getting-started.md) · [配置参考](docs/zh-CN/configuration.md) · [Worktrees](docs/zh-CN/worktrees.md)

## 命令

### 工作流

| 命令 | 描述 |
|------|------|
| `/qq:go` | 检测工作流阶段，推荐下一步 |
| `/qq:bootstrap` | 从游戏愿景分解成 epics，编排完整 pipeline |
| `/qq:design` | 编写游戏设计文档 |
| `/qq:plan` | 生成技术实现计划 |
| `/qq:execute` | 智能实现，自动编译验证 |

### 测试

| 命令 | 描述 |
|------|------|
| `/qq:add-tests` | 编写 EditMode、PlayMode 或回归测试 |
| `/qq:test` | 运行测试并检查运行时错误 |

### 代码审阅

| 命令 | 描述 |
|------|------|
| `/qq:codex-code-review` | 跨模型：Codex 审阅，Claude 验证（最多 5 轮） |
| `/qq:codex-plan-review` | 跨模型计划/设计审阅 |
| `/qq:claude-code-review` | Claude 单模型深度代码审阅，自动修复循环 |
| `/qq:claude-plan-review` | Claude 单模型计划/设计审阅 |
| `/qq:best-practice` | 快速扫描反模式和性能问题 |
| `/qq:self-review` | 审阅最近的 skill / 配置变更 |
| `/qq:post-design-review` | 从实现者视角审查设计文档——检查自洽性、可实现性、代码库差距 |

### 分析

| 命令 | 描述 |
|------|------|
| `/qq:brief` | 架构图 + PR 审阅清单（对比基准分支） |
| `/qq:timeline` | 提交历史按语义阶段分组 |
| `/qq:full-brief` | 并行运行 brief + timeline |
| `/qq:deps` | 分析 `.asmdef` 依赖关系（Mermaid 图 + 矩阵） |
| `/qq:doc-drift` | 对比设计文档与实际代码，找出不一致 |

### 工具

| 命令 | 描述 |
|------|------|
| `/qq:commit-push` | 批量提交并推送 |
| `/qq:explain` | 用通俗语言解释模块架构 |
| `/qq:grandma` | 用日常类比解释概念 |
| `/qq:tech-research` | 搜索开源社区寻找技术解决方案 |
| `/qq:design-research` | 搜索游戏设计参考和设计模式 |
| `/qq:changes` | 汇总当前会话的所有变更 |
| `/qq:doc-tidy` | 扫描并建议文档清理 |

## 工作模式

| 模式 | 适用场景 | 必须做 | 通常跳过 |
|------|---------|--------|---------|
| `prototype` | 新玩法、灰盒、fun check | 保持编译绿灯，可运行 | 正式文档，完整审阅 |
| `feature` | 构建可保留的系统 | 设计、计划、编译、定向测试 | 每次改动跑完整回归 |
| `fix` | bug 修复、回归修复 | 先复现，最小安全修复 | 大规模重构 |
| `hardening` | 风险重构、发版前 | 测试、审阅、文档/代码一致性 | 原型快捷方式 |

在 `qq.yaml` 中设置共享默认值。在 `.qq/local.yaml` 中按 worktree 覆盖。`work_mode` 和 `policy_profile` 是独立的：前者回答"这是什么类型的任务？"，后者回答"这个项目需要多少验证？"。原型和加固阶段可以共享同一个 policy profile，也可以不。完整参考参见 [配置参考](docs/zh-CN/configuration.md)。

## 配置

三个文件控制 qq 在你项目中的行为：

- **`qq.yaml`** —— 运行时配置：`work_mode`、`policy_profile`、`trust_level`、模块选择。内置 profile：`lightweight`、`core`、`feature`、`hardening`。参见 [`templates/qq.yaml.example`](templates/qq.yaml.example)。
- **`CLAUDE.md`** —— 项目级编码规范和编译验证规则。参见 [`templates/CLAUDE.md.example`](templates/CLAUDE.md.example)。
- **`AGENTS.md`** —— 子 agent 工作流的架构规则和审阅标准。参见 [`templates/AGENTS.md.example`](templates/AGENTS.md.example)。

## tykit

tykit（当前 **v0.5.0**）是 Unity Editor 进程内的轻量级 HTTP 服务器——零配置、无外部依赖、毫秒级响应。它通过 localhost 暴露 60+ 命令，分为编译/测试、控制台、场景/层级、GameObject 生命周期、**反射**（`call-method` / `get-field` / `set-field`——不需要预埋脚手架就能调用任意组件方法）、预制体编辑、**物理查询**（raycast、overlap-sphere）、资源管理、UI 自动化、Editor 控制等类目。端口由项目路径哈希生成，存储在 `Temp/tykit.json`。

```bash
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")
curl -s -X POST http://localhost:$PORT/ -d '{"command":"compile"}' -H 'Content-Type: application/json'
curl -s -X POST http://localhost:$PORT/ -d '{"command":"run-tests","args":{"mode":"editmode"}}' -H 'Content-Type: application/json'
```

**关键差异**（v0.5.0）：当 Unity 主线程被 modal 对话框或后台节流的 domain reload 卡住时，tykit 的监听线程 `GET /health`、`GET /focus-unity`、`GET /dismiss-dialog` 端点可以在不依赖被卡住的主线程的情况下把 Unity 拉回工作状态。所有其他 Unity 桥接在这种场景下都会死，只有 tykit 能恢复。详见 [`tykit-api.md`](docs/zh-CN/tykit-api.md) 的主线程恢复段。

tykit 不依赖 qq 即可独立使用——只需添加 [UPM 包](packages/com.tyk.tykit/)。MCP 桥接（`tykit_mcp.py`）可供非 Claude agent 使用。参见 [tykit API 参考](docs/zh-CN/tykit-api.md) 获取完整 API，[tykit MCP 桥接](docs/zh-CN/tykit-mcp.md) 了解 MCP 集成。

## 常见问题

**支持 Windows 吗？**
支持。需要 [Git for Windows](https://gitforwindows.org/)（提供 bash、curl 和核心工具）。1.15.x 和 1.16.x 系列对 Windows 支持做了大量加固——LF 行结束、路径规范化、Python Store alias 检测、hook 脚本里的 jq fallback。

**必须安装 Codex CLI 吗？**
不需要。Codex CLI 启用跨模型审阅（`/qq:codex-code-review`），但 `/qq:claude-code-review` 无需它即可使用。

**能和 Cursor / Copilot / Codex 等 agent 一起用吗？**
可以。运行时层（tykit、引擎桥接、`.qq/` 状态、脚本）是 agent 无关的——任何能发 HTTP 或使用 MCP 的工具都能用。26 个 `/qq:*` slash 命令和自动编译 hook 是 Claude Code 专属的，但底层脚本是普通的 shell 和 Python。参见 [`docs/dev/agent-integration.md`](docs/dev/agent-integration.md)。

**编译失败了会怎样？**
自动编译 hook 捕获错误输出并显示在对话中。编译门接着会阻止后续对引擎源文件的编辑直到编译恢复。agent 读取错误信息并修复代码，然后 hook 自动重新编译。

**能不装 quick-question 单独用 tykit 吗？**
可以。将 [`packages/com.tyk.tykit/`](packages/com.tyk.tykit/) 中的 UPM 包添加到你的项目。参见 [tykit README](packages/com.tyk.tykit/README.md)。

**支持哪些 Unity 版本？**
tykit 需要 Unity 2021.3+。MCP 替代方案：[mcp-unity](https://github.com/nicoboss/mcp-unity) 需要 Unity 6+；[Unity-MCP](https://github.com/mpiechot/Unity-MCP) 无版本要求。

## 贡献

欢迎贡献——参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

MIT — 参见 [LICENSE](LICENSE)。

---

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).

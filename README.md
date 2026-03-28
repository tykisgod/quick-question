<p align="center">
  <img src="logo.png" alt="quick-question" width="200">
</p>

<h1 align="center">quick-question</h1>

<p align="center">
  Unity Agent Harness for Claude Code.<br>
  Auto-compile, test pipelines, cross-model review — out of the box.
</p>

<p align="center">
  <a href="#english">English</a> |
  <a href="#中文">中文</a> |
  <a href="#日本語">日本語</a> |
  <a href="#한국어">한국어</a>
</p>

---

# English

## What It Does

Install quick-question into any Unity project and get:

1. **Auto-compilation hook** — edit a .cs file, compilation runs automatically
2. **Test pipeline** — EditMode + PlayMode tests with runtime error checking
3. **Cross-model review** — Claude orchestrates, Codex reviews, every finding verified against source
4. **15 slash commands** — test, commit, review, explain, and more
5. **EvalServer** — HTTP server inside Unity Editor that AI agents can control (play/stop/console/run tests)

```
Edit .cs file
     ↓ (hook auto-triggers)
Compile verification
     ↓
/qq-ut → EditMode + PlayMode tests + error check
     ↓
/qq-codex-code-review → Codex reviews, Claude verifies
     ↓
/qq-cp → commit + push (pre-push hook runs tests again)
```

## Prerequisites

- macOS (v1 limitation, Windows/Linux planned for v2)
- Unity Editor 2021.3+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- curl, python3, jq
- [Codex CLI](https://github.com/openai/codex) (optional, for cross-model review)

## Install

### Step 1: Install Plugin (skills + hooks)

In Claude Code:
```
/plugin marketplace add tykisgod/quick-question
/plugin install quick-question@quick-question-marketplace
```

This gives you all 15 skills and hooks (auto-compile, skill review enforcement). No files are copied into your project — the plugin runs from its cache.

### Step 2: Install EvalServer (Unity package)

EvalServer (tykit) is the HTTP server that lets Claude control Unity Editor. Run in your project root:
```bash
git clone https://github.com/tykisgod/quick-question.git /tmp/qq-install
/tmp/qq-install/install.sh /path/to/your-unity-project
rm -rf /tmp/qq-install
```

The installer only handles Unity-specific setup:
- Adds EvalServer (tykit) to `Packages/manifest.json`
- Copies shell scripts to `scripts/`
- Creates `CLAUDE.md` and `AGENTS.md` from templates (only if missing, never overwrites)

## Quick Start

After installation, open your Unity project and start Claude Code:

```
/qq-ut                              # Run all tests + check errors
/qq-ut play                         # PlayMode only
/qq-ut --filter "Health"            # Filter by test name
/qq-cp                              # Commit and push
/qq-codex-plan-review spec.md       # Cross-model design review
/qq-codex-code-review               # Cross-model code review
/qq-arch-review                     # Architecture diff visualization
/qq-code-review                     # Project-specific code review
/qq-explain PlayerController        # Explain a module
/qq-how-others-solve-this            # Search industry solutions
```

## All Commands

| Command | Description |
|---------|-------------|
| `/qq-ut` | Run unit/integration tests with error checking |
| `/qq-st` | Full test pipeline (EditMode + PlayMode) |
| `/qq-cp` | Batch commit and push |
| `/qq-codex-plan-review` | Cross-model design document review |
| `/qq-codex-code-review` | Cross-model code review |
| `/qq-arch-review` | Architecture change diff with Mermaid diagrams |
| `/qq-pr-review` | PR review checklist generator |
| `/qq-review` | Combined arch + PR review |
| `/qq-code-review` | Project-specific code review (customizable rules) |
| `/qq-timeline` | Commit history timeline with review docs |
| `/qq-self-review` | Review skill/config changes for quality |
| `/qq-explain` | Explain module architecture in plain language |
| `/qq-how-others-solve-this` | Search open source solutions for current problem |
| `/qq-what-has-changed` | Summarize all changes in current conversation |
| `/qq-analyze-deps` | Analyze .asmdef dependency graph |

## How It Works

### Auto-Compilation (PostToolUse Hook)

Every time Claude edits a `.cs` file, a hook automatically runs `unity-compile-smart.sh`:
- If Unity Editor is open: uses EvalServer for fast incremental compile
- If Editor is closed: falls back to batch mode

### EvalServer (tykit)

An HTTP server that starts automatically when Unity Editor opens. Enables:
- Running tests via `run-tests` + polling `get-test-result`
- Checking compilation status
- Controlling Play Mode (play/stop)
- Reading console logs
- Finding and inspecting GameObjects

### Cross-Model Review (Tribunal)

Two AI models reviewing each other's work:
1. Codex reviews your design doc or code diff
2. Claude independently verifies each finding against actual source code
3. Over-engineering check: is the suggested fix proportional to the problem?
4. Only confirmed issues get fixed
5. Loop until no critical issues remain (max 5 rounds)

### Skill Review Enforcement (Stop Hook)

When you edit a skill file, a Stop hook prevents Claude from ending the conversation until `/qq-self-review` has been run. This ensures skill changes are always reviewed.

## Customization

### CLAUDE.md

Your coding standards. The auto-compilation hook and test commands respect whatever rules you define here.

### AGENTS.md

Your architecture documentation and review rules. The `qq-code-review` and cross-model review commands read this to understand your project's anti-patterns and module boundaries.

### Extending qq-st

The default `/qq-st` only runs EditMode + PlayMode tests. To add scenario tests or integration tests, edit `.claude/commands/qq-st.md` and add steps after the `/qq-ut` call.

## What Makes This Different

| Feature | quick-question | Typical AI Tools |
|---------|---------------|-----------------|
| Auto-compile on edit | Yes (hook) | No |
| Test pipeline | EditMode + PlayMode + error check | Manual |
| Cross-model review | Claude + Codex with verification | Single model |
| EvalServer | HTTP control of Unity Editor | No runtime access |
| Skill review enforcement | Stop hook blocks until reviewed | Honor system |
| Scene restoration | Auto-restores after PlayMode tests | Left on test scene |

## Limitations

- **macOS only** (v1) — scripts use osascript, /Applications/Unity, ~/Library/Logs
- **Codex CLI required** for cross-model review features
- **Unity 2021.3+** required by tykit package
- **EvalServer is localhost-only, no authentication** — any local process can send commands. This is acceptable for development machines but not for shared/CI environments
- **Compile verification via EvalServer uses console log scraping** — may occasionally misreport if old errors are in the console buffer. Use `clear-console` before critical compiles

---

# 中文

## 功能

安装 quick-question 到任何 Unity 项目，立刻获得：

1. **自动编译 hook** — 编辑 .cs 文件后自动编译验证
2. **测试流水线** — EditMode + PlayMode 测试 + 运行时错误检查
3. **跨模型审阅** — Claude 编排，Codex 审阅，每条发现逐一验证
4. **15 个斜杠命令** — 测试、提交、审阅、解释等
5. **EvalServer** — Unity Editor 内的 HTTP 服务器，AI agent 可控制

## 安装

```bash
git clone https://github.com/tykisgod/quick-question.git
cd quick-question
./install.sh /path/to/unity-project
```

前置条件：macOS、Unity 2021.3+、Claude Code、curl/python3/jq、Codex CLI（可选）

## 快速开始

```
/qq-ut                    # 跑测试 + 检查错误
/qq-cp                    # 提交推送
/qq-codex-plan-review     # 跨模型设计审阅
/qq-codex-code-review     # 跨模型代码审阅
/qq-arch-review           # 架构变动对比
```

所有 skill 自动检测用户语言并用对应语言回复。

---

# 日本語

## 機能

quick-question を Unity プロジェクトにインストールすると：

1. **自動コンパイル hook** — .cs ファイル編集後に自動コンパイル検証
2. **テストパイプライン** — EditMode + PlayMode テスト + ランタイムエラーチェック
3. **クロスモデルレビュー** — Claude が編成、Codex がレビュー、各指摘をソースで検証
4. **15 個のスラッシュコマンド**
5. **EvalServer** — Unity Editor 内の HTTP サーバー

## インストール

```bash
git clone https://github.com/tykisgod/quick-question.git
cd quick-question
./install.sh /path/to/unity-project
```

前提条件：macOS、Unity 2021.3+、Claude Code、curl/python3/jq、Codex CLI（オプション）

---

# 한국어

## 기능

quick-question 을 Unity 프로젝트에 설치하면：

1. **자동 컴파일 hook** — .cs 파일 편집 후 자동 컴파일 검증
2. **테스트 파이프라인** — EditMode + PlayMode 테스트 + 런타임 에러 체크
3. **크로스 모델 리뷰** — Claude 오케스트레이션, Codex 리뷰, 각 발견사항 소스 검증
4. **15개 슬래시 커맨드**
5. **EvalServer** — Unity Editor 내 HTTP 서버

## 설치

```bash
git clone https://github.com/tykisgod/quick-question.git
cd quick-question
./install.sh /path/to/unity-project
```

사전 요구사항: macOS, Unity 2021.3+, Claude Code, curl/python3/jq, Codex CLI (선택)

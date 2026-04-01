# quick-question

[English](../README.md) | 中文 | [日本語](README.ja.md) | [한국어](README.ko.md)

---

## qq 是什么

qq 是 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 之上的运行时层，让 AI agent 深度感知游戏开发周期。它不会把所有任务一视同仁——qq 知道你是在验证新玩法原型、构建生产功能、修复回归 bug，还是在发版前加固——并据此调整流程强度。artifact 驱动的控制器 `/qq:go` 从 `.qq/` 读取结构化项目状态、最近的运行记录和你配置的 `work_mode`，然后推荐具体的下一步。

每次代码编辑，qq 都会通过引擎专属的 hook 自动编译（Unity 和 S&box 的 `.cs`、Godot 的 `.gd`、Unreal 的 C++）。它运行测试流水线，在深度模型审阅之前执行确定性策略检查，并编排跨模型代码审阅——Claude 协调、Codex 独立审阅——每条发现都由子 agent 验证后才修改代码。编辑器控制内置：Unity 的 tykit、Godot/Unreal/S&box 的编辑器桥接。

qq 提供 23 个 slash 命令，覆盖从设计到发布的完整工作流：`/qq:design` → `/qq:plan` → `/qq:execute` → `/qq:test` → `/qq:codex-code-review` → `/qq:commit-push`。方法论基于 [AI 编程实践：独立开发者的文档驱动方法](https://tyksworks.com/posts/ai-coding-workflow-zh/)。

## 功能亮点

- **`/qq:go` — 生命周期感知路由** — 读取项目状态、`work_mode` 和运行历史，为当前阶段推荐正确的下一步
- **自动编译** — hook 驱动，每次代码编辑自动触发；支持 `.cs`（Unity/S&box）、`.gd`（Godot）和 C++（Unreal）
- **测试流水线** — Unity 的 EditMode + PlayMode、Godot 的 GUT/GdUnit4、Unreal 的 Automation、S&box 的运行时测试，全部结构化通过/失败报告
- **跨模型审阅** — Claude 编排，Codex 独立审阅 diff，子 agent 逐条验证后才应用修复
- **编辑器控制** — tykit（Unity 进程内 HTTP 服务器），加上 Godot、Unreal、S&box 的 Python 桥接；零手动配置
- **工作模式** — `prototype`、`feature`、`fix`、`hardening` — 每种模式施加适当的流程强度，原型保持轻量，发版获得完整验证
- **运行时数据** — `.qq/` 中的结构化状态提供跨会话的循环连续性，并为控制器提供数据
- **模块化安装** — 向导模式自动检测引擎，一键预设（`quickstart`/`daily`/`stabilize`），按模块细粒度控制

## 支持的引擎

| 引擎 | 编译 | 测试 | 编辑器控制 | 桥接 |
|------|------|------|-----------|------|
| **Unity 2021.3+** | tykit / editor trigger / batch | EditMode + PlayMode | tykit HTTP server | `tykit_bridge.py` |
| **Godot 4.x** | GDScript check via headless editor | GUT / GdUnit4 | Editor addon | `godot_bridge.py` |
| **Unreal 5.x** | UnrealBuildTool + editor commandlet | Automation tests | Editor command (Python) | `unreal_bridge.py` |
| **S&box** | `dotnet build` | Runtime tests | Editor bridge | `sbox_bridge.py` |

Unity 集成最深（tykit 提供进程内 HTTP 控制，毫秒级响应）。Godot、Unreal 和 S&box 已达到运行时对等——编译、测试、编辑器控制和结构化运行记录均可用——持续开发中。

## 安装

### 前置条件

- macOS 或 Windows（需要 [Git for Windows](https://gitforwindows.org/)；Windows 支持为预览版）
- 引擎：Unity 2021.3+ / Godot 4.x / Unreal 5.x / S&box
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `curl`、`python3`、`jq`
- [Codex CLI](https://github.com/openai/codex) *（可选——启用跨模型审阅）*

### 步骤

**1. 安装插件**

```
/plugin marketplace add tykisgod/quick-question
/plugin install qq@quick-question-marketplace
```

**2. 将运行时安装到你的项目**

```bash
# 自动检测引擎（Unity / Godot / Unreal / S&box）
./install.sh /path/to/your-project

# 或使用交互式向导
./install.sh --wizard /path/to/your-project

# 或选择预设
./install.sh --preset quickstart /path/to/your-project
```

可用预设：`quickstart`（最轻量，适合首次运行）、`daily`（推荐默认值）、`stabilize`（发版前完整检查）。细粒度控制参见 `--profile`、`--modules` 和 `--without`。

**3. 打开编辑器。** Unity 中 tykit 自动启动。其他引擎请按安装脚本输出的提示操作。

## 快速开始

```bash
# 让 qq 判断你在哪个阶段
/qq:go

# 设计一个功能
/qq:design "inventory system with drag-and-drop"

# 生成实现计划
/qq:plan

# 执行计划——每次编辑自动编译
/qq:execute

# 运行测试
/qq:test
```

qq 根据工作模式调整流程强度。在 `prototype` 模式下保持轻量——编译绿灯、可运行、快速推进。在 `hardening` 模式下强制测试和审阅后才发布。详细场景演练参见 [Getting Started](docs/getting-started.md)。

## 命令

### 工作流

| 命令 | 描述 |
|------|------|
| `/qq:go` | 检测工作流阶段，推荐下一步 |
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
| `/qq:codex-code-review` | 跨模型审阅：Codex 审阅，Claude 验证（最多 5 轮） |
| `/qq:codex-plan-review` | 跨模型计划/设计审阅 |
| `/qq:claude-code-review` | Claude 深度代码审阅，自动修复循环 |
| `/qq:claude-plan-review` | Claude 计划/设计审阅 |
| `/qq:best-practice` | 快速扫描反模式和性能问题 |
| `/qq:self-review` | 审阅最近的 skill/配置变更 |

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
| `/qq:research` | 搜索开源社区寻找解决方案 |
| `/qq:changes` | 汇总当前会话的所有变更 |
| `/qq:doc-tidy` | 扫描并建议文档清理 |

## 工作模式

| 模式 | 适用场景 | 必须做 | 通常跳过 |
|------|---------|--------|---------|
| `prototype` | 新玩法、灰盒、fun check | 保持编译绿灯，可运行 | 正式文档，完整审阅 |
| `feature` | 构建可保留的系统 | 设计、计划、编译、定向测试 | 每次改动跑完整回归 |
| `fix` | bug 修复、回归修复 | 先复现，最小安全修复 | 大规模重构 |
| `hardening` | 风险重构、发版前 | 测试、审阅、文档/代码一致性 | 原型快捷方式 |

在 `qq.yaml` 中设置共享默认值。在 `.qq/local.yaml` 中按 worktree 覆盖。输入 `/qq:go` 开始——它读取你的模式并调整推荐。

`work_mode` 和 `policy_profile` 是两个独立旋钮。`work_mode` 回答"这是什么类型的任务？"，`policy_profile` 回答"这个项目需要多少验证？"原型和加固阶段可以共享同一个 policy profile，也可以不——它们是独立的。完整参考参见 [Configuration](docs/configuration.md)。

## 工作原理

qq 作为四层运行时运行：

```
Edit .cs/.gd file
  → Hook auto-compiles (tykit / editor trigger / batch mode)
    → Result written to .qq/state/
      → /qq:go reads state, recommends next step
```

**Hooks** 在工具使用时自动触发——代码编辑后编译、追踪 skill 修改、审阅验证期间阻止编辑。**`/qq:go`** 是控制器：读取项目状态（`work_mode`、`policy_profile`、最近的编译/测试结果）并路由到正确的 skill。**引擎桥接**提供经过验证的进程内执行，而非盲目文件写入。**运行时数据**在 `.qq/` 中为每一层提供共享的结构化项目健康视图。

对于跨模型审阅，Codex Tribunal 对你的 diff 运行 Codex CLI，然后 Claude 子 agent 验证每条发现并检查是否过度设计——最多 5 轮直到通过。

参见 [Architecture Overview](docs/architecture/overview.md) 获取架构图和层级详情，[Hook System](docs/hooks.md) 了解自动编译和审阅门控内部机制，[Cross-Model Review](docs/cross-model-review.md) 了解 Codex Tribunal 流程，[Worktrees](docs/worktrees.md) 了解并行任务隔离。

## 自定义

三个文件控制 qq 在你项目中的行为：

- **`qq.yaml`** — 运行时配置：`work_mode`、`policy_profile`、`trust_level`、模块选择。内置 profile：`lightweight`、`core`、`feature`、`hardening`。参见 [`templates/qq.yaml.example`](../templates/qq.yaml.example)。
- **`CLAUDE.md`** — 项目级编码规范和编译验证规则。参见 [`templates/CLAUDE.md.example`](../templates/CLAUDE.md.example)。
- **`AGENTS.md`** — 子 agent 工作流的架构规则和审阅标准。参见 [`templates/AGENTS.md.example`](../templates/AGENTS.md.example)。

## tykit

tykit 是 Unity Editor 进程内的轻量级 HTTP 服务器——零配置、无外部依赖、毫秒级响应。它通过 localhost 暴露编译、测试、Play/Stop、控制台和检视器命令。端口由项目路径哈希生成，存储在 `Temp/tykit.json`。

```bash
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")
curl -s -X POST http://localhost:$PORT/ -d '{"command":"compile"}' -H 'Content-Type: application/json'
curl -s -X POST http://localhost:$PORT/ -d '{"command":"run-tests","args":{"mode":"editmode"}}' -H 'Content-Type: application/json'
```

tykit 不依赖 qq 即可独立使用——只需添加 [UPM 包](packages/com.tyk.tykit/)。MCP 桥接（`tykit_mcp.py`）可供非 Claude agent 使用。参见 [`docs/tykit-api.md`](docs/tykit-api.md) 获取完整 API，[`docs/tykit-mcp.md`](docs/tykit-mcp.md) 了解 MCP 集成。

## 常见问题

**支持 Windows 吗？**
支持，预览版。需要 [Git for Windows](https://gitforwindows.org/)（提供 bash、curl 和核心工具）。

**必须安装 Codex CLI 吗？**
不需要。Codex CLI 启用跨模型审阅（`/qq:codex-code-review`），但 `/qq:claude-code-review` 无需它即可使用。

**能和 Cursor/Copilot 一起用吗？**
`/qq:*` skill 需要 Claude Code。tykit 通过 HTTP 独立工作，可搭配任何工具，MCP 桥接（`tykit_mcp.py`）可将其暴露给其他 agent。

**编译失败了会怎样？**
自动编译 hook 捕获错误输出并在对话中显示。Claude 读取错误信息并修复代码，然后 hook 自动重新编译。

**能不装 quick-question 单独用 tykit 吗？**
可以。将 [`packages/com.tyk.tykit/`](packages/com.tyk.tykit/) 中的 UPM 包添加到你的项目。参见 [tykit README](packages/com.tyk.tykit/README.md)。

**支持哪些 Unity 版本？**
tykit 需要 Unity 2021.3+。MCP 替代方案：[mcp-unity](https://github.com/nicoboss/mcp-unity) 需要 Unity 6+，[Unity-MCP](https://github.com/mpiechot/Unity-MCP) 无版本要求。

## 贡献

欢迎贡献——参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

MIT — 参见 [LICENSE](LICENSE)。

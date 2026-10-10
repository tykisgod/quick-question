# 配置参考

配置优先级：内置默认值 → profile 继承 → `qq.yaml` → `.qq/local.yaml`。

| 文件 | 提交到仓库 | 用途 |
|---|---|---|
| `qq.yaml` | 是 | 项目级：默认 profile、规则、安装宿主 |
| `.qq/local.yaml` | 否 | 每个 worktree 覆盖：工作模式、profile、信任等级、工作流 |
| `CLAUDE.md` / `AGENTS.md` | 是 | 编码规范、架构规则 |
| `.qq/state/session-decisions.json` | 否（自动生成） | 跨 skill 决策日志——`/qq:go` 会读它，让同一个 session 里后面的 skill 跟前面的决策保持一致 |

## qq.yaml 参考

### 顶级字段

| 字段 | 类型 | 默认值 | 描述 |
|---|---|---|---|
| `version` | int | `1` | 配置 schema 版本 |
| `default_profile` | string | `feature` | 未设置本地覆盖时使用的 profile |
| `work_mode` | string | (profile) | `prototype` / `feature` / `fix` / `hardening`（别名：`release`） |
| `policy_profile` | string | (profile) | `core` / `feature` / `hardening` |
| `trust_level` | string | `trusted` | `trusted` / `balanced` / `strict` |
| `workflow` | string | `heavy-review` | `heavy-review`（重审核）/ `prototype-loop`（原型 loop） |
| `enabled_rules` | list | (引擎) | 要执行的策略规则（替换 profile 默认值） |
| `task_focus` | any | null | `/qq:go` 的任务焦点提示 |
| `engine` | string | (自动检测) | 游戏引擎 id |

### install

| 字段 | 类型 | 默认值 | 描述 |
|---|---|---|---|
| `hosts` | list | `[claude, codex, mcp]` | 接收托管配置的宿主环境 |
| `add_modules` | list | `[]` | 额外安装的模块 |
| `remove_modules` | list | `[]` | 排除的模块 |
| `sync` | bool | `false` | 安装时清理过期的托管文件 |

### profiles

在 `profiles:` 下定义自定义 profile，通过 `extends` 继承内置 profile。每个 profile 可设置 `work_mode`、`policy_profile`、`trust_level`、`workflow`、`packs`（替换）或 `add_packs`/`remove_packs`（增量）、`enabled_rules`（替换）或 `add_rules`/`remove_rules`（增量），以及 `skills`/`hooks` 开关（`{enable: [], disable: []}`）。

## 内置 Profile

每个 profile 继承自上一个。

| Profile | 继承自 | 工作模式 | 策略 | 新增 Pack |
|---|---|---|---|---|
| `lightweight` | -- | `prototype` | `core` | runtime-core, workflow-basic, workflow-utility, hooks-auto-compile |
| `core` | lightweight | `feature` | `core` | -- |
| `feature` | core | `feature` | `feature` | workflow-planning, workflow-review, hooks-review-gate, git-pre-push |
| `hardening` | feature | `hardening` | `hardening` | workflow-docs, hooks-skill-review |

## 工作模式 vs 策略 Profile vs 信任等级 vs 工作流

四个独立旋钮，任意组合都有效——`prototype` 工作模式可以搭配 `hardening` 策略。

**工作模式（Work Mode）**——"这是什么类型的任务？"控制期望产出哪些 artifact。

| 模式 | 设计文档 | 计划 | 审阅 | 测试 |
|---|---|---|---|---|
| `prototype` | 否 | 否 | 否 | 定向/手动 |
| `feature` | 是 | 是 | 是 | 定向 |
| `fix` | 否 | 否 | 否 | 回归 |
| `hardening` | 否 | 否 | 是 | 完整/定向 |

**策略 Profile（Policy Profile）**——"需要多少验证？"设定验证下限。

| 策略 | 编译 | 测试 | 策略检查 | 审阅 | 文档漂移 |
|---|---|---|---|---|---|
| `core` | 必须 | 基础 | 建议性 | 关闭 | 关闭 |
| `feature` | 必须 | 定向 | 预期 | 轻度 | 建议性 |
| `hardening` | 必须 | 强力 | 必须 | 必须 | 必须 |

策略 `feature`/`hardening` 自动添加 `workflow-review` + `hooks-review-gate`；`hardening` 还添加 `workflow-docs`。

**信任等级（Trust Level）**——"自动授权多宽？"

| 等级 | 自动恢复 | Worktree 访问 | 原始引擎命令 |
|---|---|---|---|
| `trusted` | 是 | 自动 | 可见 |
| `balanced` | 否 | 仅 closeout | 隐藏 |
| `strict` | 否 | 需显式启用 | 隐藏 |

**工作流（Workflow）**——"流程走多重？"改的是设计、计划、审查、执行这几个技能怎么跑，不改任务要产出哪些 artifact。

| 环节 | `heavy-review`（重审核，默认） | `prototype-loop`（原型 loop） |
|---|---|---|
| 设计 | 完整设计文档，再跑 post-design-review 循环 | 一份编号验收清单（一句带数字的成果；拿到什么、在哪看得到、不做什么、怎么算做完）。用户点头才往下走：这是唯一的硬停点，`--auto` 从点头之后才开始 |
| 计划 | 完整实现计划 | 切片清单：每片写覆盖哪几条验收项、先写哪个检查、动哪些文件 |
| 计划审查 | 循环，最多 5 轮 | 只在难撤回时审一轮（存档或持久化格式、多线程、跨模块公共接口） |
| 执行 | 每阶段派审查子 agent | 每片先写检查跑出红，再实现到绿；每个检查点重读清单 |
| 代码审查 | 循环，最多 5 轮；每条发现各派一个子 agent 核实 | 只审一轮，主 agent 自己核实；收尾由没参与干活的 agent 逐条对清单要证据 |
| 审查门 | 开 | 关，除非 `hooks.enable` 点名 `review_gate` |

规则集中写在 [`shared/prototype-loop.md`](../../shared/prototype-loop.md)，受影响的技能顶部都写明按它哪一节做。别和 `work_mode: prototype` 混了：那个是干脆跳过设计和计划。

`workflow` 的取值顺序同 `trust_level`：`.qq/local.yaml` > `qq.yaml` > profile > 默认；`qq-project-state.py` 和 `qq-config.py field workflow` 会报出它（带 `workflow_source`）。配置每次调用都现读，切换只改 `.qq/local.yaml` 一行，不用重开会话；已经在跑的 `--auto` 流水线沿用开跑时的工作流。

## 本地覆盖

`.qq/local.yaml` 按 worktree 覆盖 `qq.yaml`（已 gitignore）。`qq.yaml` 中的任何字段都可出现；本地值优先。

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

也可以用行内写法，如 `hooks: {disable: [auto_compile, compile_gate]}`。缩进只能用空格，不能用 Tab。`qq.yaml` 或 `.qq/local.yaml` 解析不了时，`qq-config.py`、`qq-project-state.py` 等入口会非 0 退出，并报出文件、行号和键名。Claude Code 的钩子（`auto_compile`、`compile_gate`、`review_gate`、`skill_review`、`auto_pipeline`）读不出配置时一律按关闭处理，配置写坏不会卡住会话；作为补偿，SessionStart 钩子每次开会话都会把这个错误报出来（修好之前也不做脚本同步）。git 的 `pre-push` 钩子（`git_pre_push`）跑在你的终端里，会打出错误并拒绝这次推送（`git push --no-verify` 可跳过）。手改配置后可以跑一次 `python3 scripts/qq-config.py resolve` 确认。

## 安装选项

`install.sh` 读取 `qq.yaml`，同时接受 CLI 参数：

| 参数 | 描述 |
|---|---|
| `--profile <name>` | 起始 profile：`lightweight`、`core`、`feature`、`hardening` |
| `--modules <list>` | 逗号分隔的模块列表 |
| `--without <list>` | 逗号分隔的排除模块 |
| `--preset <name>` | 一键预设：`quickstart`、`daily`、`stabilize` |
| `--wizard` | 交互式安装（与 `--preset` 互斥） |
| `--sync` | 清理不在当前 profile 中的过期托管文件 |

## 相关文档

- [qq.yaml 模板](../../templates/qq.yaml.example)
- [CLAUDE.md 模板](../../templates/CLAUDE.md.example)
- [AGENTS.md 模板](../../templates/AGENTS.md.example)
- [项目状态 Schema](../dev/qq-project-state.md)

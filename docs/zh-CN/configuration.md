# 配置参考

配置优先级：内置默认值 → profile 继承 → `qq.yaml` → `.qq/local.yaml`。

| 文件 | 提交到仓库 | 用途 |
|---|---|---|
| `qq.yaml` | 是 | 项目级：默认 profile、规则、安装宿主 |
| `.qq/local.yaml` | 否 | 每个 worktree 覆盖：工作模式、profile、信任等级 |
| `CLAUDE.md` / `AGENTS.md` | 是 | 编码规范、架构规则 |

## qq.yaml 参考

### 顶级字段

| 字段 | 类型 | 默认值 | 描述 |
|---|---|---|---|
| `version` | int | `1` | 配置 schema 版本 |
| `default_profile` | string | `feature` | 未设置本地覆盖时使用的 profile |
| `work_mode` | string | (profile) | `prototype` / `feature` / `fix` / `hardening`（别名：`release`） |
| `policy_profile` | string | (profile) | `core` / `feature` / `hardening` |
| `trust_level` | string | `trusted` | `trusted` / `balanced` / `strict` |
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

### context_capsule

| 字段 | 类型 | 默认值 | 描述 |
|---|---|---|---|
| `enabled` | bool | `true` | 总开关 |
| `mode` | string | `auto` | `auto` / `manual` / `off` |
| `triggers` | list | `[resume, pre_clear, worktree_handoff, after_blocker]` | 触发 capsule 的事件（另有：`manual`） |
| `max_chars` | int | `3000` | 每个 capsule 的字符预算（下限 400） |

### profiles

在 `profiles:` 下定义自定义 profile，通过 `extends` 继承内置 profile。每个 profile 可设置 `work_mode`、`policy_profile`、`packs`（替换）或 `add_packs`/`remove_packs`（增量）、`enabled_rules`（替换）或 `add_rules`/`remove_rules`（增量），以及 `skills`/`hooks` 开关（`{enable: [], disable: []}`）。

## 内置 Profile

每个 profile 继承自上一个。

| Profile | 继承自 | 工作模式 | 策略 | 新增 Pack |
|---|---|---|---|---|
| `lightweight` | -- | `prototype` | `core` | runtime-core, workflow-basic, workflow-utility, hooks-auto-compile |
| `core` | lightweight | `feature` | `core` | -- |
| `feature` | core | `feature` | `feature` | workflow-planning, workflow-review, hooks-review-gate, git-pre-push |
| `hardening` | feature | `hardening` | `hardening` | workflow-docs, hooks-skill-review |

## 工作模式 vs 策略 Profile vs 信任等级

三个独立旋钮，任意组合都有效——`prototype` 工作模式可以搭配 `hardening` 策略。

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

## 本地覆盖

`.qq/local.yaml` 按 worktree 覆盖 `qq.yaml`（已 gitignore）。`qq.yaml` 中的任何字段都可出现；本地值优先。

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

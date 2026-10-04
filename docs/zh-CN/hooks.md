# Hook 系统

Claude Code hook 是在工具使用和会话事件发生时自动触发的 shell 脚本。qq 用 hook 实现自动编译、编译/审阅门控、skill 修改追踪、自动同步、会话清理和 compaction 后的恢复提示。所有 plugin 级 hook 定义在 [`hooks/hooks.json`](../../hooks/hooks.json)；少数项目本地 hook（如 `pre-push-test.sh`）通过 `.claude/settings.json` 接入。

## Hook 总览

| 触发器 | 匹配器 | 脚本 | 用途 |
|--------|--------|------|------|
| PreToolUse | `Edit\|Write` | `compile-gate-check.sh` | 编译红灯或项目从未在编辑器中打开过时，阻止编辑引擎源文件 |
| PreToolUse | `Edit\|Write` | `review-gate.sh check` | 审阅验证未完成时阻止编辑 |
| PreToolUse | `Bash`（项目本地） | `pre-push-test.sh` | 阻止 `git push` 直到 `./test.sh` 通过 |
| PostToolUse | `Write\|Edit` | `auto-compile.sh` | 编辑后通过 `qq-compile.sh`（多引擎分派器）自动编译引擎源文件 |
| PostToolUse | `Write\|Edit` | `skill-modified-track.sh` | 记录 skill 文件的修改 |
| PostToolUse | `Bash` | `review-gate.sh set` | 代码/计划审阅脚本运行后激活审阅门 |
| PostToolUse | `Agent` | `review-gate.sh count` | 统计验证子 agent 的完成次数，达数后释放审阅门 |
| Stop | (全部) | `check-skill-review.sh` | skill 修改但未运行 `/qq:self-review` 时阻止会话结束 |
| Stop | (全部) | `review-gate.sh stop` | 审阅验证未完成时阻止会话退出 |
| Stop | (全部) | `auto-pipeline-stop.sh` | `/qq:execute --auto` 流水线运行中时阻止会话退出 |
| Stop | (全部) | `session-cleanup.sh` | 清理临时文件、清除门、修剪过期运行时数据 |
| SessionStart | (startup) | `auto-sync.sh` | 插件升级后将 plugin 脚本同步到目标项目 |
| SessionStart | `compact` | `execute-resume-hint.sh` | context compaction 后浮出 `/qq:execute` 进行中的进度 |
| SessionStart | `compact` | `auto-pipeline-resume-hint.sh` | context compaction 后浮出 auto-pipeline 进行中状态 |

## Hook 触发类型

- **PreToolUse** —— 在工具执行前运行。非零退出或 `"decision":"block"` 响应会阻止工具运行。
- **PostToolUse** —— 在工具完成后运行。可通过 `hookSpecificOutput` 向对话注入上下文。
- **Stop** —— 在会话即将结束时运行。可阻止会话终止。
- **SessionStart** —— 在会话开始（`startup`）或 context compaction 后（`compact`）运行。可注入起始上下文。

## 编译门（Compile Gate）

编译门是项目级守护，阻止对引擎源文件的编辑直到编译变绿且项目至少在其编辑器中打开过一次。

**脚本：** `scripts/hooks/compile-gate-check.sh`
**触发器：** PreToolUse（`Edit|Write`）
**超时：** 5 秒

只对匹配引擎源文件模式的路径运行（通过 `qq_engine.py matches-source` 判定），执行两项检查：

1. **Virgin project 检查** —— 项目级事实，从文件系统读取。Unity 项目需要 `Library/`；Godot 项目需要 `.godot/`；Unreal 项目需要 `Intermediate/`。如果标记缺失，agent 会被告知先用编辑器打开项目并等初始导入完成。
2. **编译门检查** —— 会话级状态，按会话 id 隔离。编译失败后，`auto-compile.sh` 会写 `$QQ_TEMP_DIR/compile-gate-<session_id>`。check hook 读取该文件，验证没过期（1 小时），然后阻止编辑直到门清除。门会在下次成功编译时自动清除，或在 1 小时后过期。

门按会话 id 隔离，并发的 Claude Code 会话永远看不到对方的编译状态。

## 自动编译

**脚本：** `scripts/hooks/auto-compile.sh`
**触发器：** PostToolUse（`Write|Edit`）
**超时：** 120 秒

文件被写入或编辑时，此 hook 检查文件是否为引擎源文件（由 `qq_engine.py matches-source` 对照当前引擎判定）。如果是，调用 `qq-compile.sh`，由它分派到正确的引擎路径：

- **Unity** → `unity-compile-smart.sh`，自动选 tykit HTTP、editor trigger（osascript / PowerShell）或 batch mode
- **Godot** → `godot-compile.sh`（headless GDScript 校验）
- **Unreal** → `unreal-compile.sh`（UnrealBuildTool + editor commandlet）
- **S&box** → `sbox-compile.sh`（`dotnet build`）

编译输出显示在终端。agent 读取错误信息并在同一轮自动修复。编译失败时，hook 写 `compile-gate-<session_id>` 让下次编辑被编译门阻止；编译成功时清除门文件。

此 hook 受当前 qq profile 中 `auto_compile` 设置控制——禁用时立即退出。

## 审阅门（Review Gate）

统一脚本 `review-gate.sh` 协调四个子命令，共同强制在代码或计划审阅之后、编辑恢复之前完成验证。

> 早期安装的项目可能仍有遗留的 `review-gate-{check,set,count,stop}.sh` 文件；新的 hook 绑定应统一使用 `review-gate.sh <subcommand>` 形式。

### 激活门

**脚本：** `scripts/hooks/review-gate.sh set`
**触发器：** PostToolUse（`Bash`）

Bash 命令完成后，此 hook 检查命令是否调用了 `code-review.sh`、`claude-review.sh`、`plan-review.sh` 或 `claude-plan-review.sh`。如果是，在 `$QQ_TEMP_DIR/review-gate-<session_id>` 创建门文件，三字段格式 `<unix_timestamp>:<completed>:<expected>`（时间戳、零个已完成验证、预期验证总数）。同时注入上下文，告诉 agent 为每条发现派发验证子 agent。

### 检查门

**脚本：** `scripts/hooks/review-gate.sh check`
**触发器：** PreToolUse（`Edit|Write`）
**超时：** 5 秒

每次编辑或写入前，此 hook 检查当前会话是否存在门文件。如果门处于激活状态且验证子 agent 未全部完成（`completed < expected`），编辑被阻止。门只阻止相关文件类型的编辑（`.cs` 文件和 `Docs/*.md`）。门在 2 小时后自动过期。

### 计数验证

**脚本：** `scripts/hooks/review-gate.sh count`
**触发器：** PostToolUse（`Agent`）

每当子 agent 完成，此 hook 递增门文件中的已完成计数器。当 `completed >= expected` 时，门释放编辑。hook 注入上下文确认计数。

### 验证未完成时阻止会话退出

**脚本：** `scripts/hooks/review-gate.sh stop`
**触发器：** Stop

会话即将结束时，此 hook 检查是否存在未完成验证的审阅门（`completed < expected`）。如果是，阻止终止以让验证子 agent 完成。

## Skill 修改追踪

**脚本：** `scripts/hooks/skill-modified-track.sh`
**触发器：** PostToolUse（`Write|Edit`）

当 skill 文件被写入或编辑（路径匹配 `*/.claude/commands/*.md` 或 `*/skills/*/SKILL.md`），此 hook 将文件路径追加到 `$QQ_TEMP_DIR/claude-skill-modified-marker-<session_id>`。

会话结束时，Stop hook `check-skill-review.sh` 检查标记文件。如果 skill 被修改但从未运行 `/qq:self-review`，hook 阻止终止并列出已修改的文件。运行 `/qq:self-review` 会清除标记。

## Auto-Pipeline 退出守护

**脚本：** `scripts/hooks/auto-pipeline-stop.sh`
**触发器：** Stop

`/qq:execute --auto` 在跑无人值守的流水线时（`.qq/state/auto-pipeline.json` 存在且活跃），此 hook 阻止会话在流水线中途结束。实际的断路器逻辑在 `qq-execute-checkpoint.py pipeline-block` 里，由它判定流水线是否仍在进行中。

## 会话清理

**脚本：** `scripts/hooks/session-cleanup.sh`
**触发器：** Stop
**超时：** 2 秒

清理本会话（且只清本会话）的审查门文件，并通过 `qq_runtime_prune` 修剪过期的运行时数据。

## SessionStart Hook

### Auto-Sync（startup）

**脚本：** `scripts/hooks/auto-sync.sh`
**超时：** 10 秒

会话启动时，此 hook 调用 `qq-auto-sync.py` 将最新 plugin 脚本镜像到目标项目的 `scripts/` 目录。这是插件升级如何在不要求用户重跑 `install.sh` 的情况下到达已安装项目的方式。

### 恢复提示（compact）

context compaction 之后，两个 hook 读取由长流程 skill 写入的状态文件，注入恢复提示让 agent 接着从中断处继续：

- **`execute-resume-hint.sh`** —— 读取 `.qq/state/execute-progress.json`（由 `/qq:execute` 写入），报告进行中的 phase、已完成的步骤和下一步要跑什么。
- **`auto-pipeline-resume-hint.sh`** —— 读取 `.qq/state/auto-pipeline.json`（由 `/qq:execute --auto` 写入），报告进行中的流水线阶段，让无人值守循环正确续跑。

如果对应状态文件不存在，两个 hook 都静默退出。

## Pre-Push 测试门（可选）

**脚本：** `scripts/hooks/pre-push-test.sh`

这是项目本地 hook，通过 `.claude/settings.json` 注册（不是 plugin 的 `hooks.json`），所以只有选择启用的项目会触发。通过 `install.sh --with-pre-push`（或手动）安装后，它拦截 `git push` 命令并在允许 push 之前先跑 `./test.sh`。测试失败则阻止 push。

## 会话隔离

所有门文件和标记文件都以 Claude Code 会话 id 作后缀。钩子从 stdin JSON 的 `session_id` 取，技能里的 Bash 从 `CLAUDE_CODE_SESSION_ID` 取（同一个值；子 agent 带的是主会话的 id，所以主会话和它的子 agent 共用一扇门），两者都经 `scripts/platform/detect.sh` 的 `qq_session_id`，只收文件名安全的字符。这确保并发的 Claude Code 会话互不干扰——每个会话的编译门、审阅门和 skill 标记都按自己的会话 id 隔离。共享 hook 状态会导致一个会话的红编译阻止另一个会话的编辑。

早先的版本按 `$PPID` 命名这些文件；Windows Git Bash 下 `$PPID` 恒为 1，全机所有会话共用一份门文件。拿不到会话 id 时，钩子既不建门也不查门，不退回共用文件。

## 实现说明

### Hook 输入解析

Hook 脚本通过 [`scripts/qq-runtime.sh`](../../scripts/qq-runtime.sh) 中共享的 `qq_hook_input` 辅助函数从 stdin 读取 tool input。该辅助函数优先用 `jq`，没有时 fallback 到 `$QQ_PY`（python3）——所以装有 python3 但没有 jq 的 Windows 机器上 hook 也能跑，不会让宿主脚本在 `set -euo pipefail` 下崩溃。

```bash
file_path="$(qq_hook_input tool_input.file_path)"
cmd="$(qq_hook_input tool_input.command)"
```

新的 hook 脚本不应直接调用 `jq`。

### 幂等性

Hook 可能对同一输入触发两次（Claude Code 在瞬时失败时会重试）。副作用（写门文件、追加标记、记录运行状态）必须是幂等的。当前大多数 hook 通过 write-then-overwrite 而非 append、或通过标记检查来守护 append 实现幂等。

### 引擎检测

关心引擎类型的 hook 调用 `qq_engine.py matches-source` 而不是硬编码 `*.cs`。这是同一份 `auto-compile.sh` 和 `compile-gate-check.sh` 在 Unity、Godot、Unreal 和 S&box 上都正确工作的方式。

## 相关文档

- [架构总览](../dev/architecture/overview.md)
- [跨模型审阅](cross-model-review.md) —— 审阅门如何融入 tribunal 流程
- [配置参考](configuration.md) —— 通过当前 profile 控制哪些 hook 运行

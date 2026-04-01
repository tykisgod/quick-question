# Hook 系统

Claude Code hook 是在工具使用事件发生时自动触发的 shell 脚本。qq 用 hook 实现自动编译、审阅门控、skill 修改追踪和会话清理。所有 hook 定义在 [`hooks/hooks.json`](../../hooks/hooks.json)。

## Hook 总览

| 触发器 | 匹配器 | 脚本 | 用途 |
|--------|--------|------|------|
| PreToolUse | `Edit\|Write` | `codex-review-gate-check.sh` | 审阅验证未完成时阻止编辑 |
| PostToolUse | `Write\|Edit` | `auto-compile.sh` | 编辑后自动编译引擎源文件 |
| PostToolUse | `Write\|Edit` | `skill-modified-track.sh` | 记录 skill 文件的修改 |
| PostToolUse | `Bash` | `codex-review-gate-set.sh` | 代码/计划审阅后激活审阅门 |
| PostToolUse | `Agent` | `codex-review-gate-count.sh` | 统计验证子 agent 的完成次数 |
| Stop | (全部) | `check-skill-review.sh` | skill 修改但未审阅时阻止会话结束 |
| Stop | (全部) | `session-cleanup.sh` | 清理会话临时文件 |

## Hook 类型

三种触发类型：

- **PreToolUse** —— 在工具执行前运行。非零退出码或 `"decision":"block"` 响应会阻止工具运行。
- **PostToolUse** —— 在工具完成后运行。可通过 `hookSpecificOutput` 向对话注入上下文。
- **Stop** —— 在会话即将结束时运行。可阻止会话终止。

## 自动编译 Hook

**脚本：** `scripts/hooks/auto-compile.sh`
**触发器：** PostToolUse（`Write|Edit`）
**超时：** 120 秒

当文件被写入或编辑时，此 hook 检查文件是否为引擎源文件（`.cs` 或引擎特定文件，由 `qq_engine.py matches-source` 判定）。如果是，通过 `qq-compile.sh` 调用智能编译栈：

1. **tykit 模式** —— HTTP 调用 Unity 进程内服务器（最快，非阻塞）。
2. **编辑器触发** —— osascript（macOS）或 PowerShell（Windows）在已打开的 Unity 编辑器中触发编译。
3. **批处理模式** —— 编辑器关闭时使用 `Unity -quit -batchmode`。

编译输出显示在终端。Claude 读取错误信息并在同一轮自动修复。此 hook 受当前 qq profile 中 `auto_compile` 设置的控制——如果禁用，立即退出。

## 审阅门（Review Gate）

三个脚本协同工作，确保跨模型代码审阅后、编辑恢复前完成验证。

### 激活门

**脚本：** `scripts/hooks/codex-review-gate-set.sh`
**触发器：** PostToolUse（`Bash`）

Bash 命令完成后，此 hook 检查命令是否调用了 `code-review.sh` 或 `plan-review.sh`。如果是，在 `$QQ_TEMP_DIR/claude-codex-review-gate-$PPID` 创建门文件，格式为 `<unix_timestamp>:0`（时间戳和零个已验证子 agent）。同时注入上下文，告诉 Claude 为每条发现派发验证子 agent。

### 检查门

**脚本：** `scripts/hooks/codex-review-gate-check.sh`
**触发器：** PreToolUse（`Edit|Write`）
**超时：** 5 秒

每次编辑或写入前，此 hook 检查当前会话是否存在门文件。如果门处于激活状态且没有验证子 agent 完成（`count == 0`），编辑被阻止。门只阻止相关文件类型的编辑（`.cs` 文件和 `Docs/*.md`）。门在 2 小时后自动过期。

### 计数验证

**脚本：** `scripts/hooks/codex-review-gate-count.sh`
**触发器：** PostToolUse（`Agent`）

每当子 agent 完成，此 hook 递增门文件中的计数器。计数达到 1 时，门允许编辑继续。hook 注入上下文确认验证已记录。

## Skill 修改追踪

**脚本：** `scripts/hooks/skill-modified-track.sh`
**触发器：** PostToolUse（`Write|Edit`）

当 skill 文件被写入或编辑（路径匹配 `*/.claude/commands/*.md` 或 `*/skills/*/SKILL.md`），此 hook 将文件路径追加到 `$QQ_TEMP_DIR/claude-skill-modified-marker-$PPID` 标记文件。

会话结束时，Stop hook `check-skill-review.sh` 检查标记文件是否存在。如果 skill 被修改但从未运行 `/qq:self-review`，hook 阻止会话终止并列出已修改的文件。运行 `/qq:self-review` 会删除标记文件，解除门控。

## 会话清理

**脚本：** `scripts/hooks/session-cleanup.sh`
**触发器：** Stop
**超时：** 2 秒

清理当前会话的所有临时文件：门文件、skill 修改标记及其他会话级状态。同时触发 context capsule 构建（`pre_clear`）并清理过期的运行时数据。

## 会话隔离

所有临时文件使用 `$PPID` 后缀（hook shell 的父进程 ID）。这确保并发的 Claude Code 会话互不干扰——每个会话的门、计数器和标记都是独立的。

## Pre-Push Hook（可选）

**脚本：** `scripts/hooks/pre-push-test.sh`

默认不在 `hooks.json` 中注册。通过 `install.sh --with-pre-push` 安装后，此 PreToolUse hook 拦截 `git push` 命令并先运行测试套件。测试失败则阻止推送。

## 相关文档

- [架构总览](../dev/architecture/overview.md)
- [跨模型审阅](cross-model-review.md) — 审阅门如何融入 tribunal 流程
- [配置参考](configuration.md) — 控制 hook 行为

# 并行 Worktree

当不相关的任务需要并行推进时，使用 qq 管理的 linked worktree，而不是在同一个文件系统里来回切分支。每个 worktree 拥有独立的 `.qq/local.yaml`、独立的编译/测试状态和干净的 git 隔离。

## 为什么用 Worktree

单个工作树在切换任务时要么 stash，要么 partial commit，要么面对合并冲突。qq 管理的 worktree 给每个任务独立的目录、分支、运行时缓存和 `.qq/` 状态——agent 之间永不冲突。

## 创建 Worktree

```bash
python3 ./scripts/qq-worktree.py create --name sea-monster --pretty
```

这会创建：

- 一个 linked 分支（如 `feature/crew-wt-sea-monster`），从当前分支派生
- 一个同级 worktree 目录（如 `../project-wt-sea-monster`）
- `.qq/state/worktree.json` 中的本地元数据
- 从源 worktree 复制的运行时缓存（Unity `Library/` 等），避免冷导入成本

可选参数：`--source-branch`、`--branch`、`--path`、`--base-dir` 控制位置；`--allow-main` 允许从受保护分支派生；`--allow-dirty-source` 跳过源码干净检查。

## 在 Worktree 中工作

1. `cd` 到 worktree 目录（如 `../project-wt-sea-monster`）
2. 在 `.qq/local.yaml` 中设置此任务的 `work_mode`
3. 照常使用 `/qq:go`——它能检测 worktree 上下文
4. 随时查看 worktree 状态：

```bash
python3 ./scripts/qq-worktree.py status --pretty
```

状态输出包括 `isManagedWorktree`、`sourceBranch`、`linkedBranch` 和就绪标志。

## 收尾

任务验证并推送后：

```bash
python3 ./scripts/qq-worktree.py closeout --auto-yes --delete-branch --pretty
```

`closeout` 将 linked 分支合并回去、推送源分支并删除 worktree 目录。把它当作该会话的最后一步操作。

如果某一步失败，运行 `status --pretty` 检查 `canMergeBack`、`canPushSource`、`canCleanup`。也可以逐步执行：

```bash
python3 ./scripts/qq-worktree.py merge-back --auto-yes --push-source --pretty
python3 ./scripts/qq-worktree.py cleanup --delete-branch --pretty
```

## 运行时缓存复制

如果托管 worktree 丢失了 `Library/`（Unity）或等效缓存：

```bash
python3 ./scripts/qq-worktree.py seed-runtime-cache --pretty
```

`unity-test.sh` 会自动执行此操作。传 `--refresh` 强制完整重新复制。

## 最佳实践

- **每个任务/功能一个 worktree。** 保持范围隔离。
- **每个 worktree 一个 agent。** 不要在并发 agent 间共享。
- **在每个 worktree 中使用 `.qq/local.yaml`** 做任务级配置。
- **通过 worktree 命令收尾**，不要手动操作 git。

## 与 /qq:execute 和 /qq:go 集成

**Worktree 默认开启。** `/qq:execute` 和 `/qq:go` 都会在做任何工作之前自动进入隔离 worktree。**不需要传 `--worktree` 标志** —— 那是默认行为。

如要关闭，传字面 `--no-worktree`：

```
/qq:execute plan.md --no-worktree
/qq:go --no-worktree
```

skill 只接受字面 token —— skill 规范明确禁止 agent 自创"语义 bypass"（见 [skills/execute/SKILL.md](../../skills/execute/SKILL.md) Section 1）。

### 自动跳过 worktree 的条件

| Skill | 跳过条件（任一即可） |
|---|---|
| `/qq:execute` | 已在 git worktree 内；用户传了字面 `--no-worktree` token；plan 微小（≤3 步、≤3 文件、无 .cs 编译） |
| `/qq:go` | 已在 worktree 内；字面 `--no-worktree` token；下一步要路由到只读 skill（`/qq:changes`、`/qq:deps`、`/qq:explain`、`/qq:brief`、`/qq:full-brief`、`/qq:timeline`） |

skill 必须在第一条消息里说明跳过原因 —— 静默跳过被禁止。

### 常见障碍的自动处理

skill 检测到这些障碍时会修障碍，而不是绕过 worktree 检查：

| 障碍 | skill 的处理 |
|---|---|
| Plan 文件未追踪 | 先 commit plan（`docs(plan): <slug>`），再进 worktree，这样 plan 通过 git 历史可访问 |
| 工作树有不相关的未提交改动 | 让用户 commit 或 stash；绝不在 dirty main 上继续 |
| `EnterWorktree` 工具不可用 | 退回到 `qq-worktree.py create --name <slug>`，告知用户在新路径重开会话并停止 |

### EnterWorktree HEAD 验证

skill 使用 Claude Code 的 `EnterWorktree` 工具时，会在调用前 capture 源分支的 `HEAD`，调用后用 `git merge-base --is-ancestor` 验证新 worktree 的 `HEAD` 是否包含源 `HEAD`。`EnterWorktree` 默认从 `origin/<默认分支>` 开分支（`worktree.baseRef` 设为 `head` 时才从本地 `HEAD`）；新 worktree 不包含源 `HEAD` 时（例如从 `develop` 而非当前 feature 分支开出），skill 会自动用 `git reset --hard $SOURCE_HEAD` 恢复。这保证新 worktree 的分支正确根植于源分支 —— 后续 `commit-push` merge-back 时会拿到正确的历史，code review 的 `git diff source...HEAD` 范围也保持准确。

如果你手动通过 `qq-worktree.py create` 创建 worktree，这一验证不需要 —— `qq-worktree.py` 永远使用当前分支（或显式 `--source-branch`），从不会静默换 base。

## 相关文档

- [配置参考](configuration.md) — `.qq/local.yaml` 覆盖
- [开发者工作流](../dev/developer-workflow.md) — 仓库开发中的 worktree
- [快速上手](getting-started.md) — 工作流示例

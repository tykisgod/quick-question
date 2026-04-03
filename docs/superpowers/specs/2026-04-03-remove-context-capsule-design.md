# Remove Context Capsule System

## Context

Context Capsule 是 v1.5.0 引入的会话交接机制，设计目标是让 agent 在 session 中断后能快速恢复。实际分析发现：

- **Claude Code 从不消费 capsule**：没有 SessionStart hook，capsule MD 生成后无人读取
- **Codex 的实际 review skills 绕过了 capsule**：`code-review.sh` 和 `plan-review.sh` 直接调 `codex exec`，不经过 `qq-codex-exec.py`
- **Capsule 不产生新信息**：它是 `.qq/state/` 数据的 markdown 重新格式化，agent 直接读 state JSON 效果相同且更实时
- **产生文件积累**：每次 session 结束生成一个 MD，prune 逻辑遗漏了 capsule 目录

## Decision

删除整个 Context Capsule 系统。保留 `.qq/state/` 和 `qq-project-state.py` 作为运行时状态的唯一来源。

## Scope

### 删除的文件

| 文件 | 行数 | 说明 |
|------|------|------|
| `scripts/qq-context-capsule.py` | ~660 | 完整 capsule 实现 |
| `docs/dev/context-capsule.md` | ~143 | capsule 设计文档 |

### 修改的文件

| 文件 | 改动 |
|------|------|
| `scripts/qq-codex-exec.py` | 删除 `load_context_capsule_consume()`、`merge_resume_prompt()`、`looks_like_closeout_request()` 中的 capsule 依赖；删除 `--resume`/`--resume-refresh`/`--resume-note`/`--no-resume` CLI 参数；`build_exec_command()` 直接用 passthrough |
| `scripts/qq-runtime.sh` | 删除 `qq_context_capsule_build()`、`qq_context_capsule_maybe_build()`、`qq_context_capsule_status()`、`qq_context_capsule_prompt()` 四个函数；删除 `qq_run_record_finish()` 中 `failed|blocked` 分支的 capsule 触发 |
| `scripts/hooks/session-cleanup.sh` | 删除 `qq_context_capsule_maybe_build "pre_clear"` |
| `scripts/qq-run-record.py` | 删除 `prune_context_capsules()` 及其在 `prune_runtime()` 中的调用；删除 `--max-capsule-files` 参数 |
| `test.sh` | 删除 capsule 相关测试用例 |
| `docs/dev/agent-integration.md` | 删除 capsule consume API 引用 |

### 运行时数据清理

- `.qq/telemetry/context-capsules/` — 整个目录可删
- `.qq/state/context-capsule.json` — 可删

### 不受影响

- hooks（auto-compile、review-gate）
- `.qq/state/{compile,test,review_gate,latest}.json`
- `qq-project-state.py` 和 `recommend_next`
- 所有 skills
- `qq-codex-exec.py` 的 worktree/sandbox/MCP 隔离功能
- `/qq:codex-code-review`、`/qq:codex-plan-review`

## Verification

1. `test.sh` 通过（删除 capsule 测试后）
2. `session-cleanup.sh` 正常执行（不再调 capsule）
3. `qq-codex-exec.py --dry-run` 正常输出（不含 resume 字段）
4. `.qq/telemetry/context-capsules/` 不再生成新文件

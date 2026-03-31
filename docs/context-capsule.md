# Context Capsule

`Context Capsule` 是一个默认开启、可显式关闭的、artifact-driven 续跑摘要层。

它的目标不是压缩整段聊天记录，而是从 qq 已有的 runtime 数据里生成一个很薄的 handoff：

- 当前任务大概在做什么
- 当前 `work_mode` / `policy_profile`
- 最近 compile / test / review 信号
- 当前 blocker 是什么
- 推荐下一步是什么

## 目标

- 让中断后的 `resume / recover` 更快
- 让清上下文、切 worktree、切 host 之前有一个稳定交接物
- 继续坚持 `state first, summary second`
- 默认保持轻量，按少量高价值 trigger 自动运行

## 非目标

- 不做通用聊天摘要器
- 不做长期记忆系统或向量库
- 不把 capsule 当作系统真相来源
- 不替代未来的 `Task Contract` / `Evaluator` / `Run Evidence`

## 触发方式

v0 只支持显式触发或窄范围自动触发：

- `manual`
- `resume`
- `pre_clear`
- `worktree_handoff`
- `after_blocker`

默认会在少量 trigger 上自动运行；只有在配置里显式关闭后，自动触发才会停用。

## 配置

写在 `qq.yaml` 或 `.qq/local.yaml`：

```yaml
context_capsule:
  enabled: true
  mode: auto
  triggers:
    - resume
    - pre_clear
    - worktree_handoff
    - after_blocker
  max_chars: 2400
```

说明：

- `enabled: false` 或 `mode: off`：完全关闭
- `mode: manual`：只允许手动 `build`
- `mode: auto`：在允许的 trigger 上自动生成
- `.qq/local.yaml` 可以覆盖当前 worktree 的配置

## 输入来源

`Context Capsule` 只读取现有 artifact：

- `.qq/state/project-state.json` 或最新 `qq-project-state` 结果
- `.qq/state/compile.json`
- `.qq/state/test.json`
- `.qq/state/review_gate.json`
- 当前 worktree / changed files / active docs

它不直接消费整段聊天历史，也不把 raw logs 塞回 prompt。

## 输出

状态快照：

- `.qq/state/context-capsule.json`

便于 handoff 的 Markdown：

- `.qq/telemetry/context-capsules/<timestamp>-<trigger>.md`

## CLI

构建 capsule：

```bash
python3 ./scripts/qq-context-capsule.py build --trigger resume --pretty
```

查看当前 capsule 状态：

```bash
python3 ./scripts/qq-context-capsule.py status --pretty
```

查看当前生效配置：

```bash
python3 ./scripts/qq-context-capsule.py config --pretty
```

直接生成可消费的 resume prompt：

```bash
python3 ./scripts/qq-context-capsule.py prompt --refresh
python3 ./scripts/qq-context-capsule.py consume --agent codex --pretty
python3 ./scripts/qq-codex-exec.py "Continue the current qq task."
python3 ./scripts/qq-codex-exec.py --no-resume "Run a clean one-off query."
```

如果宿主想先判断“这次应不应该消费 capsule”，再决定是否把 prompt 拼进自己的请求，优先走统一的 `consume` 接口：

```bash
python3 ./scripts/qq-context-capsule.py consume --agent claude --pretty
python3 ./scripts/qq-context-capsule.py consume --agent codex --no-resume --pretty
```

这样 `resumeApplied / resumeMode / resumeReason / resumePrompt` 的判断逻辑只维护一份，不再散落在不同 host wrapper 里。

`qq-codex-exec.py` 现在默认会在这些续跑信号上自动消费 capsule：

- 当前 worktree 是 qq-managed linked worktree
- compile / test 处于 `failed` 或 `blocked`
- 已经存在 `after_blocker`、`pre_clear`、`worktree_handoff`、`resume` 触发生成的 capsule
- 当前项目有未提交的 `.cs` 改动

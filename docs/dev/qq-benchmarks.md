# qq Benchmarks

`quick-question` 的第二阶段开始引入最小可运行的 eval harness，用来回答三个问题：

- 当前 runtime foundation 是否仍然可用
- 不同 backend / host / model 切换后，哪些基础能力被打穿
- 哪些优化真的提升了本地开发闭环，而不是只改变了 prompt 表现

## 入口

运行 benchmark suite：

```bash
python3 ./scripts/eval/run-benchmarks.py --suite ./docs/evals/foundation-smoke.json --pretty
```

对已安装 qq scripts 的 Unity 项目运行本地 benchmark：

```bash
python3 ./scripts/eval/run-benchmarks.py \
  --suite ./docs/evals/unity-local.json \
  --project /path/to/unity-project \
  --pretty
```

运行最小 solver slice：

```bash
python3 ./scripts/eval/run-benchmarks.py \
  --suite ./docs/evals/qq-bench-core-solver-v0.json \
  --pretty
```

如果传了 `--project`，结果默认会写到：

```text
.qq/telemetry/evals/<timestamp>-<suite-id>.json
```

## 当前 Suite

### `foundation-smoke`

目的：

- 验证第一阶段的 runtime foundation 没有回退
- 不依赖 Unity Editor
- 可在仓库自检和 CI 里直接跑

覆盖：

- run record / state / telemetry 持久化
- artifact-driven project state
- deterministic policy checks

### `unity-local`

目的：

- 对真实 Unity 项目跑 compile / test benchmark
- 使用项目本地安装的 qq scripts，而不是仓库里的开发脚本

覆盖：

- compile
- EditMode tests
- PlayMode tests

这套 suite 是第二阶段后续扩充的入口，后面会继续加：

- console triage
- review finding verification
- scene / object workflows

### `qq-bench-core-solver-v0`

目的：

- 给 `qq-bench-core` 增加第一条 solver 执行通道
- 让同一道真实代码题可以先由外部 solver 改代码，再由 evaluator 判分
- 保持仓库自测可重复，不强绑定某个真实模型 CLI

覆盖：

- 外部 solver 命令执行
- 真实 `.cs` fixture 改动
- deterministic evaluator 判分
- runtime 下一步校验

当前仓库附带的是 [`reference_solver.py`](../../scripts/eval/reference_solver.py) 作为最小参考 solver，用于证明 harness 可以跑通。以后如果要接 `codex`、`claude` 或其他 host，更合理的方式是保留相同 evaluator，只替换 suite 里的 `solver.command`。

## 结果格式

suite 结果最小字段：

- `suite_id`
- `project_dir`
- `started_at`
- `finished_at`
- `duration_ms`
- `passed`
- `failed`
- `skipped`
- `results`

单个 task 结果最小字段：

- `task_id`
- `status`
- `started_at`
- `finished_at`
- `duration_ms`
- `summary`
- `details`

## 原则

- 先有结构化结果，再谈 dashboard
- 先有 smoke suite，再扩真实 Unity benchmark
- 优先测 durable layers：execution、policy、controller、telemetry
- 结果要能被本地、pre-push、CI 复用

## 长期方向：`QQ-Bench`

长期不应该只把这些 suite 当成仓库自测脚本，而应该把它们收敛成一个标准化 benchmark family：

- 它评估的是 **game-dev agent runtime**，不是通用代码模型
- 它关注的是 **真实闭环能力**，不是只看 prompt 漂不漂亮
- 它既要能服务本地回归，也要能服务跨 host / model / backend 的可比评测

换句话说，长期目标不是“再做一个通用 SWE-bench”，而是：

> 用 qq 自己的 runtime 模型，定义一套面向 Unity 代码工作流的 benchmark

## 为什么要做

长期做 `QQ-Bench` 的价值主要有四个：

- 判断优化是否真的提升了代码交付，而不是只改变了 prompt 表现
- 比较不同 host / model / backend / policy profile 在 qq 上的真实表现
- 约束 runtime 演化，避免 controller、policy、worktree、resume 等核心能力静默退化
- 为开源和未来商业化提供可信的、可重复的能力证据

如果没有 benchmark，qq 很容易陷入两种误判：

- 以为自己在进步，但只是 prompt 更会说
- 以为更强模型自然会让 qq 更强，但实际上是 runtime 某一层退化了

## 分层结构

`QQ-Bench` 最好分三层，而不是一套题混到底。

### 1. `qq-bench-foundation`

目的：

- 验证 runtime 基础层没有回退
- 低成本、可在本地和 CI 高频运行

典型覆盖：

- run record / state / telemetry
- controller routing
- policy escalation
- worktree state detection
- resume / recover 基础状态机

这层本质上是今天 `foundation-smoke` 的升级版。

### 2. `qq-bench-core`

目的：

- 验证 qq 能不能把真实代码任务推进到闭环
- 比较不同 agent / model / host 在 Unity 代码任务上的完成质量

典型覆盖：

- `prototype` 任务
- `feature` 任务
- `fix` 任务
- `hardening` 任务
- compile / test / policy / review / doc-drift 的组合路径

这层应该建立在可分发的 fixture project 上，是长期最重要的一层。

### 3. `qq-bench-live`

目的：

- 防 benchmark 污染
- 评估长程、更新鲜、接近真实团队工作的任务

典型形式：

- held-out 任务集
- 周期性新增任务
- 半公开或 hosted challenge
- 公共 leaderboard 只展示聚合结果，不完全公开所有题目

这层不是近期目标，但应该尽早按这个方向设计 schema，避免以后重做。

## 任务 Schema

如果长期要标准化，最先该固定的是 task schema，而不是排行榜页面。

每个 benchmark task 至少应包含：

- `task_id`
- `family`
  - 例如 `foundation`, `prototype`, `feature`, `fix`, `hardening`
- `fixture`
  - 对应的 repo / project snapshot
- `initial_state`
  - 初始 `qq.yaml`
  - 初始 `.qq/local.yaml`
  - 初始 run/state 快照（如果任务要求从中断点恢复）
- `prompt`
  - 用户给 agent 的任务描述
- `allowed_tools`
  - 本地脚本、MCP、direct path、是否允许联网
- `budget`
  - 时间、步骤、token 或调用次数预算
- `success_criteria`
  - compile / test / policy / review / doc-drift / state transition 的明确要求
- `grading`
  - 哪些是公开检查
  - 哪些是隐藏检查

长期看，task 不应该只有“修一个 bug”这一类，也应该包含：

- 路由类任务
- 恢复类任务
- 多 worktree 协作类任务
- policy 强度切换类任务

## 指标

`QQ-Bench` 不应该只看单一 `resolved rate`。

更适合 qq 的核心指标是：

- `strict_resolve_rate`
  - 任务最终完整通过成功条件的比例
- `stage_success_rate`
  - compile / test / policy / review / doc-drift 各层成功率
- `routing_accuracy`
  - `recommended_next` 是否符合任务期望
- `recovery_rate`
  - 任务失败或中断后，是否能从 runtime 状态继续
- `false_finish_rate`
  - agent 宣称完成，但 benchmark 判定未完成的比例
- `policy_compliance_rate`
  - 是否按 profile 要求完成该走的验证路径
- `worktree_safety_rate`
  - 并行任务是否保持隔离，不串状态、不误 merge
- `cost_per_resolved`
  - 每个解决任务的 token / 时间 / 调用成本

其中最关键的不是“做完多少”，而是：

- 有没有误判完成
- 有没有绕过该走的验证
- 出问题后能不能恢复

## 版本化与污染控制

`QQ-Bench` 应该从第一版开始就带版本化和污染意识。

建议：

- suite 使用显式版本号
  - 例如 `qq-bench-foundation@0.1`
  - `qq-bench-core@0.1`
- 区分：
  - `public`
  - `held-out`
  - `live`
- public task 文本里加入 canary 字符串或唯一标记，方便日后污染检测
- 成绩展示时区分：
  - 开发集结果
  - 发布前结果
  - leaderboards / paper 结果

长期如果真的要公开 leaderboard，更合适的是：

- public 题库用于开发和回归
- held-out / live 题库用于正式比较

## 现有 Harness 如何演进

不需要重写，应该从当前 harness 直接往上长。

优先顺序建议：

1. 保持 `foundation-smoke` 作为最小回归层
2. 把 `collaboration-multi-actor` 提升成正式 suite，而不是只当 E2E 附录
3. 给 `unity-local` 增加更明确的任务分型，不只测 compile/test
4. 增加基于 fixture 的 `fix` / `feature` / `hardening` 代码任务
5. 在结果 JSON 里补统一字段，逐步接近 `QQ-Bench` task/result schema

这样做的好处是：

- 不会让 benchmark 设计脱离现有代码
- 每一步都能直接服务当前开发
- 以后要扩成公开 benchmark family 时，不需要推倒重来

## 第一批代码侧题型

长期第一批最值得标准化的，不是“大而全项目”，而是这些题型：

1. `controller-routing-prototype`
   - prototype 模式下，无 artifact 时应走 `prototype_direct`
2. `controller-routing-feature`
   - design 存在、plan 不存在时应走 `/qq:plan`
3. `controller-routing-hardening`
   - compile/test 通过后应强制经过 review / doc-drift
4. `policy-escalation`
   - 相同任务在 `core`、`feature`、`hardening` 下得到不同验证强度
5. `worktree-lifecycle`
   - create → implement → push → merge-back → cleanup
6. `resume-after-compile-failure`
   - 先失败，再从最近状态恢复继续
7. `targeted-fix-task`
   - 最小 bugfix + regression verification
8. `feature-task-with-plan`
   - 依据 implementation plan 完成一个可测试功能
9. `hardening-refactor-task`
   - 风险改动必须经过 stronger checks
10. `review-finding-verification`
   - review finding 必须先验证，再决定修还是驳回

这 10 类题已经足够构成 `QQ-Bench Core v0` 的骨架。

## 当前判断

长期来看，做 benchmark 是有必要的，但节奏应该是：

- 先把 qq 自己的 runtime 跑通
- 再把现有 eval harness 标准化
- 然后逐步长成 `QQ-Bench`
- 最后才考虑 leaderboard 和 hosted challenge

也就是说，benchmark 对 qq 来说不是附属品，而是 runtime 成熟后的自然结果。

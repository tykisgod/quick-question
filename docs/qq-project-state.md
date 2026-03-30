# qq Project State

`/qq:go` 不再主要依赖 prompt 猜测，而是优先读取项目状态。

最小 project state 字段：

- `work_mode`
- `work_mode_source`
- `mode_profile`
- `mode_recommended_next`
- `policy_profile`
- `policy_profile_source`
- `policy_profile_expectations`
- `default_test_scope`
- `has_design_doc`
- `has_implementation_plan`
- `has_uncommitted_cs_changes`
- `changed_cs_files`
- `last_compile_status`
- `last_test_status`
- `review_gate_status`
- `doc_drift_status`
- `is_managed_worktree`
- `worktree_role`
- `worktree_branch`
- `worktree_source_branch`
- `worktree_source_worktree_path`
- `worktree_can_merge_back`
- `worktree_can_cleanup`
- `recommended_next`
- `last_compile_summary`
- `last_test_summary`
- `last_compile_failure_category`
- `last_test_failure_category`

读取来源：

- `qq-policy.json`
- `.qq/local-policy.json`
- `Docs/design/*.md`
- `Docs/qq/**/*_implementation.md`
- `git diff` / `git ls-files`
- `.qq/runs/*.json`
- `.qq/state/*.json`
- review gate temp file（best effort）

当前阶段的目标不是做复杂状态机，而是做一个 **artifact-driven controller**：

- 先读 `work_mode`，决定流程强度
- `qq-policy.json` 是团队共享默认值；`.qq/local-policy.json` 是当前 worktree / 当前任务的本地覆盖
- `policy_profile` 决定验证基线；`work_mode` 决定当前任务处在哪个阶段
- `default_test_scope` 是当前 profile 下无参数 `/qq:test` 和 pre-push 的默认测试强度
- `is_managed_worktree` / `worktree_*` 字段描述当前是否在 qq 创建的 linked worktree 中，以及 merge-back / cleanup 是否适用
- `mode_recommended_next` 是单看任务阶段时最自然的下一步
- `recommended_next` 是在 compile/test 阻塞和 `policy_profile` 验证下限之后的真实建议
- `prototype`：默认轻，只要求 compile 绿和结果记录
- `feature`：设计/计划/实现/测试是主路径
- `fix`：先固定复现，再做最小修复和回归验证
- `hardening`：风险重构、稳定性收口、发版前检查
- compile/test 未通过时，优先修复，而不是跳到下一个阶段

设计原则：

- controller 负责“读状态、选下一步”
- 具体工作仍由各个 skill 负责
- raw logs 不进入 prompt
- state summary 才进入 prompt
- 每次读取后会把摘要写回 `.qq/state/project-state.json`
- `recommended_next` 可以是 skill，也可以是轻量动作提示（例如 `prototype_direct`、`verify_compile`、`reproduce_bug`）

## 与 Runtime 路线的关系

`qq-project-state` 的职责仍然是“摘要当前状态”，不是把整个执行协议都塞进一个文件里。

下一层 runtime 能力会建立在这些状态摘要之上：

- `Task Contract`：说明这一轮代码任务的目标、约束、涉及文件和验收条件
- `Evaluator`：把 compile、test、policy、review、doc drift 汇总成权威的 `pass / block / continue`
- `Run Evidence`：记录本轮计划改哪些文件、实际改了哪些文件、验证结果是什么、为什么还没完成
- `Resume / Recover`：从最近一次 contract、evidence 和 blocker 继续，而不是重新依赖对话记忆

`project-state` 仍然只暴露 prompt 需要的紧凑摘要；raw record 和完整 evidence 留在 `.qq/` 里供 runtime、doctor 和后续 CI 读取。

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
- `trust_level`
- `trust_level_source`
- `trust_level_expectations`
- `default_test_scope`
- `has_design_doc`
- `has_implementation_plan`
- `has_uncommitted_runtime_changes`
- `changed_runtime_files`
- `has_uncommitted_test_changes`
- `changed_test_files`
- `last_compile_status`
- `last_test_status`
- `review_gate_status`
- `doc_drift_status`
- `is_managed_worktree`
- `worktree_role`
- `worktree_branch`
- `worktree_source_branch`
- `worktree_source_worktree_path`
- `worktree_runtime_cache_dir`
- `worktree_source_runtime_cache_exists`
- `worktree_local_runtime_cache_exists`
- `worktree_local_runtime_cache_support_exists`
- `worktree_can_seed_runtime_cache`
- `worktree_runtime_cache_seed_state`
- `worktree_runtime_cache_seed_strategy`
- `worktree_can_merge_back`
- `worktree_can_push_source`
- `worktree_can_cleanup`
- `recommended_next`
- `last_compile_summary`
- `last_test_summary`
- `last_compile_failure_category`
- `last_test_failure_category`

读取来源：

- `qq.yaml`
- `.qq/local.yaml`
- `Docs/design/*.md`
- `Docs/qq/**/*_implementation.md`
- `git diff` / `git ls-files`
- `.qq/runs/*.json`
- `.qq/state/*.json`
- review gate temp file（best effort）

当前阶段的目标不是做复杂状态机，而是做一个 **artifact-driven controller**：

- 先读 `work_mode`，决定流程强度
- `qq.yaml` 是团队共享默认值；`.qq/local.yaml` 是当前 worktree / 当前任务的本地覆盖
- `policy_profile` 决定验证基线；`work_mode` 决定当前任务处在哪个阶段
- `trust_level` 决定自动权限边界；它不会改变任务阶段，但会影响 Codex 自动续跑、managed worktree 的 source scope 放大，以及 standard MCP surface 是否暴露 raw command
- `profile` 决定当前启用了哪些预设 pack、hook、skill 和 policy floor
- `default_test_scope` 是当前 profile 下无参数 `/qq:test` 和 pre-push 的默认测试强度
- `changed_runtime_files` 描述当前需要验证的引擎运行时改动；`changed_test_files` / `has_uncommitted_test_changes` 用来区分“刚改了运行时代码，还没补测试”与“测试已经补上，下一步该执行验证”
- `is_managed_worktree` / `worktree_*` 字段描述当前是否在 qq 创建的 linked worktree 中，以及 merge-back / push-source / cleanup 是否适用
- `worktree_*runtime_cache*` 字段描述当前 linked worktree 是否已经具备引擎 runtime cache，以及该 cache 是否由 qq 自动种子过
- `mode_recommended_next` 是单看任务阶段时最自然的下一步
- `recommended_next` 是在 compile/test 阻塞和 `policy_profile` 验证下限之后的真实建议
- `trust_level_expectations` 说明当前自动权限策略，例如：
  - `codex_auto_resume`
  - `codex_source_worktree_access`
  - `standard_raw_command`
- `prototype`：默认轻，只要求 compile 绿和结果记录
- `feature`：设计/计划/实现是主路径；compile 绿后如果还没补覆盖，先走 `/qq:add-tests`，再 `/qq:test`
- `fix`：先固定复现，再做最小修复；如果还没补回归测试，先走 `/qq:add-tests`，再做回归验证
- `hardening`：风险重构、稳定性收口、发版前检查；compile 绿但缺覆盖时同样先走 `/qq:add-tests`
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

对于 qq-managed worktree，推荐的收口动作是：

```bash
python3 ./scripts/qq-worktree.py closeout --auto-yes --delete-branch --pretty
```

只有在 closeout 被状态门禁拦住时，才去单独查看 `qq-worktree status` 或手动拆成 `merge-back` / `cleanup`。

如果你用的是 Codex 而不是 Claude，推荐通过：

```bash
python3 ./scripts/qq-codex-exec.py "..."
```

来运行 `codex exec`。如果当前 `trust_level=trusted`，它会在 qq-managed linked worktree 中自动补齐 source worktree 的写权限；如果是 `strict`，则必须显式传 `--allow-source-worktree`。

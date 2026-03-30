# qq Project State

`/qq:go` 不再主要依赖 prompt 猜测，而是优先读取项目状态。

最小 project state 字段：

- `has_design_doc`
- `has_implementation_plan`
- `has_uncommitted_cs_changes`
- `changed_cs_files`
- `last_compile_status`
- `last_test_status`
- `review_gate_status`
- `doc_drift_status`
- `recommended_next`
- `last_compile_summary`
- `last_test_summary`
- `last_compile_failure_category`
- `last_test_failure_category`

读取来源：

- `Docs/design/*.md`
- `Docs/qq/**/*_implementation.md`
- `git diff` / `git ls-files`
- `.qq/runs/*.json`
- `.qq/state/*.json`
- review gate temp file（best effort）

当前阶段的目标不是做复杂状态机，而是做一个 **artifact-driven controller**：

- 有设计、没计划 → `/qq:plan`
- 有计划、没实现 → `/qq:execute`
- 有未提交 `.cs` 改动 → `/qq:best-practice`
- compile/test 未通过 → 优先修复，而不是跳到下一个阶段

设计原则：

- controller 负责“读状态、选下一步”
- 具体工作仍由各个 skill 负责
- raw logs 不进入 prompt
- state summary 才进入 prompt
- 每次读取后会把摘要写回 `.qq/state/project-state.json`

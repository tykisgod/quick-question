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

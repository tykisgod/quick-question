# qq Run Record

`quick-question` 将每次关键运行写入项目根目录下的 `.qq/`：

```text
.qq/
├── runs/
├── state/
└── telemetry/
```

当前阶段三层都会被使用：

- `runs/`：每次运行的完整 JSON record
- `state/`：`latest.json`、`compile.json`、`test.json` 等最新快照
- `telemetry/`：最小事件流，当前为 `events.jsonl`

## 轻量清理策略

`.qq/` 不会无限增长。当前采用轻量 retention：

- `state/`：只保留最新快照
- `runs/`：默认保留最近 `200` 条 run record，同时清理超过 `14` 天的旧记录
- `telemetry/events.jsonl`：默认超过 `5 MB` 自动 rotate
- `telemetry/events-*.jsonl`：默认保留最近 `10` 个 rotated 文件，并清理超过 `14` 天的旧文件
- `telemetry/evals/`：默认长期保留，不参与自动清理

触发方式：

- `qq-run-record.py finish` 低频自动触发一次 prune
- `session-cleanup.sh` 在会话结束时再补一次轻量 prune

也可以手动运行：

```bash
python3 ./scripts/qq-run-record.py prune --project .
```

可通过环境变量覆盖默认值：

- `QQ_MAX_RUN_RECORDS`
- `QQ_MAX_RUN_AGE_DAYS`
- `QQ_MAX_TELEMETRY_BYTES`
- `QQ_MAX_ROTATED_TELEMETRY_FILES`
- `QQ_PRUNE_WRITE_INTERVAL`
- `QQ_PRUNE_MIN_INTERVAL_SEC`

当前已覆盖的 stage：

- `compile`
- `test`
- `review_gate`
- `skill_gate`
- `tykit` bridge fallback 路径

每条 run record 是一个独立 JSON 文件，最小字段包括：

- `run_id`
- `command`
- `stage`
- `status`
- `backend`
- `transport`
- `started_at`
- `finished_at`
- `duration_ms`
- `failure_category`
- `summary`
- `artifacts`
- `details`

设计目标：

- 本地脚本可写
- CI 可读
- project state 可查询
- 不默认进入对话上下文

设计原则：

- raw record 是系统数据，不是 prompt 输入
- prompt 只消费摘要，不消费全量记录
- 失败记录保留，成功记录也要有最小结构化输出
- `state/` 给 controller 和 CI 读取
- `telemetry/` 给后续统计和 benchmark 读取
- 清理必须低频、轻量，不能出现在 compile/test 的重路径上做全量扫描

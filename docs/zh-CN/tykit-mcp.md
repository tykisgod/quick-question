# tykit MCP 桥接

`tykit_mcp.py` 将 `tykit` 以 stdio MCP 服务器形式暴露给 Codex、Cursor、Continue 及其他 MCP 客户端。

它**不会**替代 qq 现有的快速路径：

- qq / Claude hook 仍然直接使用本地脚本
- MCP 客户端通过标准 tool 接口获得相同的 Unity 能力
- compile 和 test 工具在目标项目安装了 qq 脚本时优先使用它们

如果 qq / Claude 正在使用 MCP，这个内置桥接应该是默认 MCP 后端。第三方 Unity MCP 服务器是兼容的备选，而非首选。

如果你在 demo 或示例项目中验证，请确保该项目与真实用户使用相同的安装路径。参见 [Consumer Rollout](../dev/consumer-rollout.md)。

对于 qq 管理的消费者项目，`install.sh` 现在会将桥接复制到 `scripts/`，将 `.mcp.json` 指向项目本地的 `scripts/qq_mcp.py`，并添加 `./scripts/qq-doctor.sh`。

## 为什么需要它

`tykit` 故意做得快和简单：Unity 编辑器进程内的本地 HTTP。

这对 qq 的高频工作流来说很理想，但许多通用 agent 期望 MCP tool 而非手写 `curl` 命令。桥接让两者共存：

- **快速路径：** `scripts/unity-compile-smart.sh`、`scripts/unity-test.sh`、hooks
- **通用路径：** `scripts/tykit_mcp.py`

## 前置条件

- Python 3
- 已安装 `tykit` 的 Unity 项目
- 完整 qq 快速路径需要：在 Unity 项目中安装 quick-question 脚本
- Windows 上：Git for Windows，确保 `bash` 可用于 qq 脚本和 `unity-eval.sh`

## 快速开始

### Codex

推荐的消费者路径：

```bash
cd /path/to/unity-project
python3 ./scripts/qq-codex-mcp.py install --pretty
```

这会注册一个项目级 Codex MCP 服务器名称，指向该 worktree 自己的 `scripts/qq_mcp.py`。

对于在项目内执行 Codex 任务，推荐：

```bash
python3 ./scripts/qq-codex-exec.py "Call unity_health and reply true or false only."
```

该包装器不替代 MCP 注册。它只是确保 `codex exec` 在当前项目根目录运行，并在 qq 管理的 linked worktree 需要 merge-back 或 closeout 时自动添加源 worktree 为可写范围。

手动方式：

```bash
codex mcp add tykit -- python3 /path/to/quick-question/scripts/tykit_mcp.py --project /path/to/unity-project
```

### Cursor / 其他 stdio MCP 客户端

使用相同的命令：

```bash
python3 /path/to/quick-question/scripts/tykit_mcp.py --project /path/to/unity-project
```

如果客户端从 Unity 项目根目录启动，`--project` 可省略。

## Profile

### `standard`

默认 profile。暴露大多数 agent 需要的高频 tool：

- `unity_health`
- `unity_doctor`
- `unity_compile`
- `unity_run_tests`
- `unity_console`
- `unity_editor`
- `unity_query`
- `unity_object`
- `unity_assets`
- `unity_batch`
- `unity_raw_command`

### `full`

添加低频领域 tool：

- `unity_input`
- `unity_visual`
- `unity_ui`
- `unity_animation`
- `unity_screenshot`

示例：

```bash
python3 scripts/tykit_mcp.py --project /path/to/unity-project --profile full
```

## Tool 设计

桥接有意偏向粗粒度 tool 以提升性能：

- `unity_compile` 一次 tool 调用完成整个编译工作流
- `unity_run_tests` 一次 tool 调用完成整个测试工作流
- `unity_batch` 让客户端在一次 MCP 往返中组合多个操作
- `unity_raw_command` 保持完整的 `tykit` 命令面可达

这避免了"MCP 千刀万剐"问题。

## 快速路径路由

### 编译

优先级顺序：

1. 项目本地 qq 脚本：`scripts/unity-compile-smart.sh`
2. `tykit` 包辅助脚本：`Packages/com.tyk.tykit/Scripts~/unity-eval.sh`
3. 直接 `tykit` HTTP 轮询

### 测试

优先级顺序：

1. 项目本地 qq 脚本：`scripts/unity-test.sh`
2. 直接 `tykit` HTTP `run-tests` / `get-test-result`

这意味着安装了 qq 的项目保持现有行为，而仅安装 `tykit` 的项目在编辑器打开时同样能工作。

## Tool 示例

### Health

```json
{
  "name": "unity_health",
  "arguments": {
    "project_dir": "/path/to/project"
  }
}
```

### Doctor

```json
{
  "name": "unity_doctor",
  "arguments": {
    "project_dir": "/path/to/project"
  }
}
```

### Compile

```json
{
  "name": "unity_compile",
  "arguments": {
    "timeout_sec": 20,
    "mode": "auto"
  }
}
```

### Tests

```json
{
  "name": "unity_run_tests",
  "arguments": {
    "mode": "editmode",
    "filter": "Health",
    "timeout_sec": 180
  }
}
```

### Batch

```json
{
  "name": "unity_batch",
  "arguments": {
    "operations": [
      {
        "tool": "unity_query",
        "arguments": {
          "action": "status"
        }
      },
      {
        "tool": "unity_query",
        "arguments": {
          "action": "find",
          "name": "Player"
        }
      }
    ]
  }
}
```

## 第三方 MCP 兼容性

桥接设计为与第三方 Unity MCP 服务器共存：

- 使用独立的 tool 命名空间：`unity_*`
- 不会覆盖 `mcp-unity` 或 `Unity-MCP` 的 tool 名称
- 桥接特定的 tool profile 定义在 [`scripts/tykit_capabilities.json`](../../scripts/tykit_capabilities.json)
- 核心能力路由定义在 [`scripts/qq-capabilities.json`](../../scripts/qq-capabilities.json)

这意味着你可以同时运行：

- `mcp-unity`
- `Unity-MCP`
- `tykit_mcp.py`

在同一个宿主中，然后让宿主或 agent prompt 决定优先使用哪个能力。对于 qq 管理的工作流，优先级仍然是 `qq direct` 优先，其次 `tykit_mcp`，最后第三方 MCP。

在架构层面，`tykit_mcp` 是更广泛 adapter 模型下的一个 Unity provider。参见 [Adapter Contract](../dev/architecture/adapter-contract.md)。

## Windows 注意事项

Windows 与 qq 其他部分使用相同的前提条件：

- 已安装 Git for Windows
- `bash` 在 `PATH` 中
- 已安装 Python 3

桥接本身是 Python，但 qq 快速路径脚本和 `unity-eval.sh` 仍然通过 `bash` 运行。

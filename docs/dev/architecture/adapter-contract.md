# Adapter Contract

这份文档定义 `quick-question` 当前的最小 adapter contract。

核心原则：

- `qq-core` 只依赖 capability
- engine / host / transport 差异通过 adapter 表达
- 上层不要直接依赖具体工具名
- 当前高强度验证仍然放在 Unity，但 contract 不允许写死为 Unity-only

## 1. 分层

### Core

负责：

- capability schema
- run record / telemetry schema
- project state schema
- controller
- policy runtime
- eval runtime

不负责：

- Unity 文件结构
- `tykit`
- Claude-specific workflow glue

### Engine Adapter

负责：

- project detection
- artifact scanning
- compile/build
- test
- console/log
- engine-specific policy checks

### Host Adapter

负责：

- 交互入口
- slash command / skill glue
- batch / CI mode

### Transport Adapter

负责：

- 调用协议
- timeout / error mapping
- capability discovery

## 2. Capability Boundary

当前能力注册表位于：

- [`scripts/qq-capabilities.json`](../../scripts/qq-capabilities.json)

当前第一批 capability：

- `compile`
- `test`
- `test.edit`
- `test.play`
- `console.read`
- `console.clear`
- `artifact.scan`
- `policy.check`
- `scene.query`
- `scene.mutate`
- `asset.query`
- `asset.mutate`

规则：

- controller、policy、docs 讨论 capability 名，而不是具体工具名
- provider 只是 capability 的具体实现，不是架构边界

## 3. 当前 Provider 模型

当前 registry 里已经存在三类 engine provider：

- `unity.qq-direct`
- `unity.tykit-mcp`
- `unity.mcp-unity`
- `unity.unity-mcp`
- `unity.raw-tykit`
- `godot.qq-direct`
- `godot.qq-mcp`
- `unreal.qq-direct`
- `unreal.qq-mcp`
- `unreal.unreal-engine-mcp`
- `unreal.runreal-mcp`
- `unreal.flop-mcp`
- `sbox.qq-direct`
- `sbox.qq-mcp`

这仍然不代表系统已经是“任意引擎都可用”。

它表示：

- 当前强实现仍然以 Unity 为主
- Godot 已经达到 `qq-direct + built-in qq-mcp bridge` 的第一批非 Unity adapter 形态
- Unreal 已经达到 `qq-direct + built-in qq-mcp bridge + third-party MCP fallback` 的第二批非 Unity adapter 形态
- S&box 现在已经达到 `qq-direct + built-in qq-mcp bridge` 的 Godot-style typed adapter 形态：
  direct compile/test/policy/project-state + typed `console/editor/query/object/scene/assets`, with local file-safe fallback when the live bridge is inactive
- provider contract 继续允许以后增加：
  - `sbox.*`
  - `godot.*`
  - `unreal.*`
  - `custom.*`

与当前 contract 对齐的 `s&box` 适配方案见：

- [S&box Adapter Spec](./sbox-adapter-spec.md)

## 4. Contract Rules

新增功能时必须遵守：

1. 如果是 core 功能，先落 capability，再落具体 provider
2. 如果是引擎差异，必须放进 engine adapter / provider
3. 如果是 host 差异，必须放进 host adapter
4. 如果是 transport 差异，必须放进 transport adapter
5. 不允许在 controller 里直接依赖 Unity 文件结构或具体工具名

## 5. 当前 CLI

使用：

```bash
python3 ./scripts/qq-capability.py validate --pretty
python3 ./scripts/qq-capability.py list-capabilities --pretty
python3 ./scripts/qq-capability.py list-providers --engine unity --pretty
python3 ./scripts/qq-capability.py resolve --engine unity --capability compile --pretty
```

这些命令的目的不是替代运行时，而是：

- 检查 contract 是否一致
- 让未来的 adapter 扩展有一个稳定入口
- 防止 capability routing 继续散落在文档和 prompt 里

项目级 provider 探测可以用：

```bash
./scripts/qq-doctor.sh --pretty
./scripts/qq-doctor.sh --write-state --pretty
```

它会输出：

- 当前项目检测到的 provider
- 每个 capability 的优先级和最终解析结果
- 可选地写入 `.qq/state/provider-resolution.json`

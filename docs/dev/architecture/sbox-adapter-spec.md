# S&box Adapter Spec

_Status: Implemented (Phase 0-2 complete, richer editor automation still open)_  
_Last updated: 2026-03-31_

## 1. Why This Spec Exists

`main` 现在已经不只是 Unity-first 的抽象预留。

从当前代码看，`quick-question` 已经对三类引擎建立了明确兼容面：

- engine detection + metadata via [`scripts/qq_engine.py`](../../scripts/qq_engine.py)
- capability / provider resolution via [`scripts/qq-capabilities.json`](../../scripts/qq-capabilities.json)
- host-local direct workflows via [`scripts/qq-compile.sh`](../../scripts/qq-compile.sh), [`scripts/qq-test.sh`](../../scripts/qq-test.sh)
- project diagnosis via [`scripts/qq-doctor.py`](../../scripts/qq-doctor.py)
- worktree-aware execution via [`scripts/qq-worktree.py`](../../scripts/qq-worktree.py)
- built-in MCP bridge routing via [`scripts/qq_mcp.py`](../../scripts/qq_mcp.py)
- automated validation in [`test.sh`](../../test.sh)

当前 `main` 上的真实兼容面是：

- `unity`: strong
- `godot`: direct + built-in bridge
- `unreal`: direct + built-in bridge
- `sbox`: direct + built-in bridge

因此，`s&box` 支持不应该再写成“未来也许能支持”的概念文档，而应该按现有 contract 写成一份**可以对标当前三引擎兼容面**的 adapter spec。

## 2. Product Position

`s&box` 在 qq 里的定位应该是：

> 一个公开可获取、可文档化、可本地执行的 C# 游戏引擎 / 平台 adapter

它和 Valve 官方按游戏分发的 `Source 2 Workshop Tools` 不同，原因是：

- `s&box` 有公开项目标记 `*.sbproj`
- 有公开 editor / source / docs / dedicated server surface
- 有公开 C# 开发模型
- 有官方 `UnitTests` + `dotnet test` 路径
- 有 dedicated server 可加载本地 `.sbproj`

这使它比“纯 Source 2 生态”更接近 qq 现有的 engine-adapter 目标。

## 3. Current Compatibility Baseline on `main`

基于当前 `main` 上已经存在的实现，qq 的多引擎兼容并不是“概念性预留”，而是已经有明确梯度：

| Engine | Direct runtime | Built-in qq MCP bridge | Rich typed editor / scene / asset surface | Third-party MCP fallback | Install / doctor / worktree coverage |
| --- | --- | --- | --- | --- | --- |
| `unity` | yes | yes (`unity.tykit-mcp`) | yes | yes | yes |
| `godot` | yes | yes (`godot.qq-mcp`) | yes | no | yes |
| `unreal` | yes | yes (`unreal.qq-mcp`) | yes | yes | yes |
| `sbox` | yes | yes (`sbox.qq-mcp`) | yes (`console/editor/query/object/scene/assets`) | no | yes |

这个矩阵的含义很重要：

- `s&box` 不是要一步跳到 “Unity 级深度”
- 它先对齐了 **当前 Godot / Unreal 的共同底座**
- 然后补上了项目内 `qq-mcp` bridge、`console.read|clear`、`scene.query|mutate`、`asset.query|mutate`
- 当前 bridge 已经覆盖 live `editor/query/object` surface；当 live bridge 不活跃时，scene/asset 工具仍可回退到 project-local file operations

因此，对“我们能不能做到类似 Godot / Unreal”的回答是：

> 可以，而且当前实现已经做到 direct runtime + built-in bridge；剩下没做的是更深的 live editor control，不是基础兼容层。

## 4. Official Facts We Can Safely Build Around

以下事实来自官方材料，适合作为 adapter 设计前提：

1. `s&box` 是一个基于 Source 2 和 .NET 的现代游戏引擎，使用 C# 开发。  
2. 项目根标记是 `*.sbproj`；它告诉编辑器“这是一个项目文件夹”。  
3. 代码保存后会自动 hotload；官方明确提到 `.cs` 和 `.razor` 文件会触发重编译与热重载。  
4. 如果项目根目录有 `UnitTests/`，编辑器会自动生成测试项目，测试可以通过 `dotnet test` 跑。  
5. 项目里的 `Libraries/` 是源码共享机制；每个 library 有自己的 `Assets/`、`Code/`、`Editor/`，且默认应提交到版本控制。  
6. `Editor/` 工程不受 API whitelist 限制，可以访问完整 editor/tooling 能力。  
7. 运行中的平台代码受 API whitelist 限制；编辑器在 whitelist 模式下会给出 `SB1000 Whitelist Error`。  
8. dedicated server 支持直接加载本地 `.sbproj`。  

这些前提意味着：

- `s&box` 适合做 code/runtime adapter
- 但不应假定它已经提供了 Godot/Unreal 那种稳定的 editor automation/plugin contract

## 5. Why `main` Can Support This

从当前代码结构看，`s&box` 不需要为“多引擎抽象”重新开路，已有的基础已经够用：

- [`scripts/qq_engine.py`](../../scripts/qq_engine.py) 已经把 engine metadata 抽成统一表
- [`scripts/qq-capabilities.json`](../../scripts/qq-capabilities.json) 已经把 capability/provider/resolution 做成显式 registry
- [`scripts/qq-compile.sh`](../../scripts/qq-compile.sh) 和 [`scripts/qq-test.sh`](../../scripts/qq-test.sh) 已经是按 engine 路由的统一入口
- [`scripts/qq_mcp.py`](../../scripts/qq_mcp.py) 已经有 generic script bridge，可以先提供 host-neutral MCP 能力
- [`scripts/qq-doctor.py`](../../scripts/qq-doctor.py) 已经形成“provider availability + evidence + resolution”诊断模型
- [`install.sh`](../../install.sh) 已经能按 engine 分支安装 project-local bridge 资产
- [`test.sh`](../../test.sh) 已经把 Godot / Unreal fixture 跑成了正式 regression contract

这意味着 `s&box` 的难点不在“要不要重构 core”，而在于：

- 给它定义正确的 project markers
- 给它补 direct compile/test/policy/project-state/doctor/install contract
- 谨慎判断 rich bridge 哪些该做、哪些不该假装做
- 用项目内 editor bridge 先落真实可验证的 `queue + console + scene/asset file operations`

## 6. Target Parity with Current Engines

`s&box` 不需要一开始就达到 Unity/Godot/Unreal 的全部深度，但应该按相同的层次定义“做到什么算支持”。

### 6.1 Minimum parity

与当前 `godot.qq-direct` / `unreal.qq-direct` 对齐：

- project detection
- compile
- test
- artifact.scan
- policy.check
- install
- doctor
- worktree compatibility

### 6.2 Second-step parity

与当前 `godot.qq-mcp` / `unreal.qq-mcp` 对齐：

- generic MCP bridge exposure via `qq_mcp.py`
- health / doctor / project-state over MCP
- compile / test / policy over MCP
- typed `sbox_scene` / `sbox_assets` / `sbox_console`

### 6.3 Stretch parity

与当前 richer editor bridges 对齐：

- console.read
- console.clear
- scene.query
- scene.mutate
- asset.query
- asset.mutate

当前实现已经提供这个层次里的可用子集：

- `console.read`
- `console.clear`
- `scene.query`
- `scene.mutate`
- `asset.query`
- `asset.mutate`
- `editor` actions: `play`, `stop`, `pause`, `save_scene`, `open_scene`, `new_scene`, `reload_scene`
- `object` actions: `create`, `destroy`, `duplicate`, `set_transform`, `set_parent`, `set_active`, `set_property`, `select`
- 当 live editor bridge 不活跃时：
  - `sbox_query.status`
  - `sbox_query.list_scenes`
  - `sbox_query.list_assets`
  - `sbox_scene`
  - `sbox_assets`
  仍可回退到 project-local file operations

仍然不在当前发货门槛里的，是更深的 runtime/playtest automation 和 Unity 深度级工具面。

## 7. Proposed Engine Metadata

在 [`scripts/qq_engine.py`](../../scripts/qq_engine.py) 中新增 `sbox` engine definition，目标形态如下：

```python
"sbox": {
    "displayName": "S&box",
    "projectMarkers": ["*.sbproj"],
    "sourcePatterns": [
        "Code/*.cs",
        "Code/**/*.cs",
        "Code/*.razor",
        "Code/**/*.razor",
        "Editor/*.cs",
        "Editor/**/*.cs",
        "Editor/*.razor",
        "Editor/**/*.razor",
        "Libraries/*/Code/*.cs",
        "Libraries/*/Code/**/*.cs",
        "Libraries/*/Code/*.razor",
        "Libraries/*/Code/**/*.razor",
        "Libraries/*/Editor/*.cs",
        "Libraries/*/Editor/**/*.cs",
        "Libraries/*/Editor/*.razor",
        "Libraries/*/Editor/**/*.razor",
        "UnitTests/*.cs",
        "UnitTests/**/*.cs",
    ],
    "verificationPatterns": [
        "*.sbproj",
        "Code/**",
        "Editor/**",
        "Libraries/**",
        "Assets/**",
        "UnitTests/**",
    ],
    "runtimeCacheDir": "",
    "runtimeCacheSupportDir": "",
    "bridgeScript": "qq_mcp.py",
    "bridgeBackend": "qq-sbox-editor",
    "bridgeServerName": "qq-sbox",
    "bridgeHostStateFile": "qq-sbox-mcp-host.json",
    "editorBridgeStateFile": ".qq/state/qq-sbox-editor-bridge.json",
    "editorBridgeRequestDir": ".qq/state/qq-sbox-editor/requests",
    "editorBridgeResponseDir": ".qq/state/qq-sbox-editor/responses",
    "editorBridgeConsoleFile": ".qq/state/qq-sbox-editor-console.jsonl",
    "engineSupportSourceDir": "engines/sbox/Editor/QQ",
    "engineSupportTargetDir": "Editor/QQ",
    "codexServerPrefix": "qq-sbox-",
    "defaultSlug": "sbox-project",
    "defaultEnabledRules": [
        "sbox_whitelist_violation",
        "sbox_library_boundary",
    ],
    "defaultTestScopes": {
        "core": "unit",
        "feature": "unit",
        "hardening": "unit",
    },
    "hostValidationReason": "S&box validation should run against the local editor or dedicated-server install on the host machine.",
    "recommendedCompileAction": "./scripts/qq-compile.sh",
}
```

### Notes

- `runtimeCacheDir` / `runtimeCacheSupportDir` 在 v0 保持空值，表示 qq 不对 `s&box` 做 Unity/Godot/Unreal 那种 cache seeding 承诺。
- `verificationPatterns` 故意比 `sourcePatterns` 更宽，因为 `Assets/`、`Libraries/`、`.sbproj` 都会影响运行时行为。

## 8. Capability and Provider Model

在 [`scripts/qq-capabilities.json`](../../scripts/qq-capabilities.json) 中新增：

### 8.1 Engine adapter

- `sbox`

### 8.2 Initial providers

- `sbox.qq-direct`
- `sbox.qq-mcp`

v0 支持能力：

- `compile`
- `test`
- `artifact.scan`
- `policy.check`

tool mappings 形态：

```json
"sbox.qq-direct": {
  "engineAdapter": "sbox",
  "transportAdapter": "direct",
  "hostAdapters": ["claude", "codex", "ci"],
  "official": true,
  "description": "Project-local qq scripts with direct S&box fast paths.",
  "capabilities": ["compile", "test", "artifact.scan", "policy.check"],
  "toolMappings": {
    "compile": ["scripts/qq-compile.sh"],
    "test": ["scripts/qq-test.sh"],
    "artifact.scan": ["scripts/qq-project-state.py"],
    "policy.check": ["scripts/qq-policy-check.sh"]
  }
}
```

`sbox.qq-mcp` 当前支持能力：

- `compile`
- `test`
- `console.read`
- `console.clear`
- `artifact.scan`
- `policy.check`
- `scene.query`
- `scene.mutate`
- `asset.query`
- `asset.mutate`
- typed tools:
  - `sbox_console`
  - `sbox_editor`
  - `sbox_query`
  - `sbox_object`
  - `sbox_scene`
  - `sbox_assets`

### 8.3 Deferred providers

不在 v0 发货范围：

- third-party `sbox.*` MCP providers
- deeper editor/runtime automation beyond the built-in `editor/query/object` surface

## 9. Compile Contract

`s&box` 的 compile 路径必须尊重它的官方模型：**hotload-first，而不是假装它有现成的 Unity-style batch compile CLI**。

### 9.1 v0 compile goal

`compile` 回答的问题是：

> 当前项目代码是否能被 `s&box` 接受并进入可运行状态？

### 9.2 v0 compile modes

#### `editor`

优先目标：

- 当编辑器处于活跃状态时，读取最近一次 hotload/compile 结果
- 将 whitelist、普通编译错误、Razor/代码热重载失败标准化成 qq run record

#### `server`

次优路径：

- 使用 dedicated server 加载本地 `.sbproj`
- 观察启动 / compile / load 期错误

#### `batch`

不作为 v0 的承诺。

理由：

- 当前官方文档强调 hotload 和 dedicated server
- 没有看到一个像 Unity `-batchmode` 或 Unreal `UnrealEditor-Cmd` 那样明确、稳定、面向项目 compile-only 的公开 contract

### 9.3 qq direct entry

新增：

- [`scripts/sbox-compile.sh`](../../scripts/sbox-compile.sh)

并由 [`scripts/qq-compile.sh`](../../scripts/qq-compile.sh) 按 engine 路由。

## 10. Test Contract

`s&box` 的测试面有一个官方稳定入口：`UnitTests/` + `dotnet test`。

### 10.1 v0 test goal

支持：

- `UnitTests/` 的纯 CLI 测试
- engine-backed component tests（仍通过生成的测试项目运行）

### 10.2 qq direct entry

新增：

- [`scripts/sbox-test.sh`](../../scripts/sbox-test.sh)

行为：

1. 检查是否存在 `UnitTests/`
2. 如无，返回结构化 `not_run` / `no_tests_found`
3. 如有，运行 `dotnet test`
4. 将 stdout/stderr、发现数、失败数、耗时写入 run record

### 10.3 scope mapping

`test.unit` 可作为未来扩展 capability，但在 v0 先映射到统一 `test` 即可。

## 11. Artifact Scan and Project State

`artifact.scan` 与 [`scripts/qq-project-state.py`](../../scripts/qq-project-state.py) 需要识别 `s&box` 的项目结构。

至少要补：

- `.sbproj` 是否存在
- `UnitTests/` 是否存在
- `Libraries/` 是否存在以及 library 个数
- `Editor/` 是否存在
- `Code/` / `Assets/` 改动列表
- 是否存在 `.Server.cs` 文件

新增的 project-state 字段建议：

- `sboxProjectDetected`
- `sboxProjectFile`
- `sboxUnitTestsPresent`
- `sboxLibraryCount`
- `sboxEditorProjectPresent`
- `sboxServerCodePresent`

## 12. Policy Contract

`s&box` 的 v0 policy 应该围绕官方明确公开的限制来做，而不是先发明一堆“最佳实践”。

### 12.1 Required rules in v0

#### `sbox_whitelist_violation`

目标：

- 标准化 `SB1000 Whitelist Error`
- 把明显的 whitelist 违规从 compile 错误里提纯为 policy finding

起步可覆盖：

- `Console.Log` → 推荐 `Log.Info`
- `System.IO*` → 推荐 `Filesystem` / 平台安全 API

#### `sbox_library_boundary`

目标：

- 检查 library 之间的非法直接依赖或约定外引用

理由：

- 官方文档明确说 libraries 不能引用 other libraries

### 12.2 Deferred rules

后续再考虑：

- server/client code placement checks
- exported-game-only API checks
- editor-code leakage checks

## 13. Install Contract

[`install.sh`](../../install.sh) 对 `sbox` 的目标应更接近 `godot/unreal` 的 built-in bridge 安装，但仍保持轻量：

### 13.1 v0 install must do

- 复制 qq scripts / hooks / JSON registries
- 写入 `.mcp.json`
- 创建 `qq.yaml`
- 写入 Claude local permission baseline
- 安装 project-local editor bridge support 到 `Editor/QQ`

### 13.2 v0 install must not pretend to do

- 不自动 patch project source
- 不自动强制启动 editor
- 不自动替用户执行 runtime/playtest 操作

理由：

- 当前 bridge 通过 project-local `Editor/QQ/QQSboxEditorBridge.cs` 落地，不需要额外插件安装
- 但 qq 仍不应该替用户偷偷改业务代码或自动拉起编辑器

## 14. Doctor Contract

[`scripts/qq-doctor.py`](../../scripts/qq-doctor.py) 需要同时覆盖 `sbox.qq-direct` 和 `sbox.qq-mcp`。

v0 至少检查：

- `.sbproj` 是否存在
- `scripts/qq-compile.sh`, `scripts/qq-test.sh`, `scripts/qq-project-state.py`, `scripts/qq-policy-check.sh` 是否存在
- `dotnet` 是否可用
- 是否存在 `UnitTests/`
- 是否能发现本地 `s&box` editor 或 dedicated server（如提供路径配置）

推荐输出：

- `providers["sbox.qq-direct"]`
- `providers["sbox.qq-mcp"]`
- `resolution.compile`
- `resolution.test`
- `resolution.policy.check`
- `resolution.console.read`
- `resolution.scene.query`
- `resolution.scene.mutate`

## 15. Worktree Contract

`s&box` 在 qq worktree 里必须避免沿用 Unity/Unreal 的错误假设。

### 15.1 Rules

- `Libraries/` 是源码面，不是 cache；必须跟普通项目文件一样复制/跟踪
- v0 不做 runtime cache seed
- `Code/`, `Editor/`, `Assets/`, `Libraries/`, `UnitTests/`, `*.sbproj` 都属于 relevant status 范围

### 15.2 Why

- 官方文档明确说明 `Libraries/` 不是自动 restore 的二进制依赖，而是项目源码组成部分

## 16. MCP / Bridge Strategy

### 16.1 Current shipping bridge

当前 `main` 已经有 `sbox.qq-mcp`：

- generic `qq_*` tools via [`scripts/qq_mcp.py`](../../scripts/qq_mcp.py)
- typed S&box tools via [`scripts/sbox_bridge.py`](../../scripts/sbox_bridge.py)
- project-local editor bridge support via [`engines/sbox/Editor/QQ/QQSboxEditorBridge.cs`](../../engines/sbox/Editor/QQ/QQSboxEditorBridge.cs)

typed surface 当前包含：

- `sbox_console`
- `sbox_editor`
- `sbox_query`
- `sbox_object`
- `sbox_scene`
- `sbox_assets`

### 16.2 Runtime behavior

- live bridge running:
  - full `editor/query/object/console` surface available
- live bridge inactive:
  - `sbox_query.status`
  - `sbox_query.list_scenes`
  - `sbox_query.list_assets`
  - `sbox_scene`
  - `sbox_assets`
  continue to work through project-local file operations

### 16.3 Current limits

当前 bridge 仍然不承诺：

- deep playtest/runtime automation
- asset authoring parity with Unity tooling depth
- third-party `sbox.*` MCP providers

## 17. Benchmarks and Validation

`s&box` adapter 进入主线前，至少要补以下验证：

### 17.1 Foundation smoke

- engine detection resolves to `sbox`
- provider resolution picks `sbox.qq-direct`
- install creates `qq.yaml`, `.mcp.json`, scripts, and `Editor/QQ/QQSboxEditorBridge.cs`
- doctor reports `sbox.qq-direct` and `sbox.qq-mcp` as available when the project-local bridge is installed

### 17.2 Script fixtures

- fake `dotnet` / test runner fixture for `UnitTests`
- compile fixture for whitelist failure (`SB1000`)
- worktree fixture with `Libraries/`
- queue/batch fixture for `sbox_editor`, `sbox_query`, and `sbox_object`

### 17.3 Controller / runtime checks

- `qq-project-state` correctly detects runtime changes under `Code/`, `Editor/`, `Libraries/`
- `qq-worktree` does not misclassify `Libraries/` as cache

## 18. Shipping Plan

### Phase 0: Spec + metadata

- add `sbox` engine definition
- add `sbox.qq-direct` capability/provider entries
- add spec + roadmap references if needed

### Phase 1: direct runtime

- `sbox-compile.sh`
- `sbox-test.sh`
- `qq-compile.sh` / `qq-test.sh` routing
- `qq-project-state` support
- `qq-policy-check.sh` initial `sbox_*` rules
- `qq-doctor` provider detection
- install flow

### Phase 2: validation

- smoke tests
- fixture tests
- worktree coverage
- benchmark suite entries

### Phase 3: richer runtime

- live hierarchy / object control
- editor actions (`play/stop/open/save/reload`)
- scene/asset query + safe mutations
- richer doctor/benchmark coverage

### Phase 4: deeper parity

- dedicated-server-backed runtime smoke / validation
- benchmark coverage for live bridge workflows
- evaluate whether Unity-depth tooling is justified

## 19. Non-Goals

本 spec 明确不承诺：

- Unity-depth tooling parity in v0-v3
- exported-game packaging flow
- standalone build/release automation
- full playtest/runtime control parity

## 20. Decision

`s&box` 值得支持，但应该按以下原则进入 qq：

- **先作为 direct/runtime adapter 进入**
- **先把 compile/test/policy/project-state/doctor/install/worktree 做扎实**
- **不要为了“像 Godot/Unreal 一样 rich”而在 v0 虚构 editor bridge**

一句话：

> 对 `s&box`，qq 应该先做“可验证的代码执行 runtime”，而不是“看起来很酷的编辑器远控”。

## References

- `s&box-public` README: <https://github.com/Facepunch/sbox-public>
- S&box documentation overview: <https://docs.facepunch.com/s/sbox-dev>
- Project Types (`.sbproj`): <https://docs.facepunch.com/s/sbox-dev/doc/project-types-WX9qrDXXoq>
- Hotloading: <https://docs.facepunch.com/s/sbox-dev/doc/hotloading-qTNrWweMMS>
- Unit Tests: <https://docs.facepunch.com/s/sbox-dev/doc/unit-tests-xtbQZBAVAb>
- Libraries: <https://docs.facepunch.com/s/sbox-dev/doc/libraries-6Y6EtLMvQN>
- Editor Project: <https://docs.facepunch.com/s/sbox-dev/doc/editor-project-LuRHQgnNjC>
- API Whitelist: <https://docs.facepunch.com/s/sbox-dev/doc/api-whitelist-0eSDcO6qDI>
- Dedicated Servers: <https://docs.facepunch.com/s/sbox-dev/doc/dedicated-servers-WGeGAD9U8d>

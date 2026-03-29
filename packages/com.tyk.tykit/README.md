# tykit

Lightweight HTTP server inside Unity Editor. Any AI agent can control Unity via `curl` — compile, run tests, play/stop, read console, inspect GameObjects.

No SDK. No plugin API. No UI automation. Just HTTP.

> This repo is an automated mirror of [`tykisgod/quick-question/packages/com.tyk.tykit`](https://github.com/tykisgod/quick-question). Do not edit directly — changes are synced from the source on every push.

<p align="center">
  <a href="#english">English</a> |
  <a href="#中文">中文</a> |
  <a href="#日本語">日本語</a> |
  <a href="#한국어">한국어</a>
</p>

---

# English

## Install

Add one line to your Unity project's `Packages/manifest.json`:

```json
"com.tyk.tykit": "https://github.com/tykisgod/tykit.git"
```

Open Unity — tykit starts automatically. Port is stored in `Temp/tykit.json`.

**Requirements:** Unity 2021.3+, Newtonsoft JSON (auto-resolved via UPM dependency).

## Quick Start

```bash
# Get port
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")

# Ping
curl -s http://localhost:$PORT/ping

# Send a command
curl -s -X POST http://localhost:$PORT/ \
  -d '{"command":"status"}' -H 'Content-Type: application/json'
```

## API Reference

### Read Commands

| Command | Args | Description |
|---------|------|-------------|
| `status` | — | Editor state (isPlaying, isCompiling, activeScene) |
| `compile-status` | — | Compilation state (isCompiling, isUpdating) |
| `get-compile-result` | — | Last compile result (state, errors, duration) |
| `console` | `count`, `filter` | Read console logs (last N entries, optional filter) |
| `find` | `name`, `type`, `tag` | Find GameObjects in scene |
| `inspect` | `id` or `name` | Inspect GameObject components and properties |
| `get-properties` | `id` | List serialized properties of a component |
| `hierarchy` | `depth` | Scene hierarchy tree (default depth 3) |
| `commands` | — | List all available commands |

### Write Commands

| Command | Args | Description |
|---------|------|-------------|
| `create` | `name`, `primitiveType`, `position` | Create GameObject |
| `instantiate` | `prefab`, `name` | Instantiate prefab |
| `destroy` | `id` | Destroy GameObject |
| `set-transform` | `id`, `position`, `rotation`, `scale` | Modify transform |
| `add-component` | `id`, `component` | Add component to GameObject |
| `set-property` | `id`, `component`, `property`, `value` | Set serialized property |

### Editor Control

| Command | Args | Description |
|---------|------|-------------|
| `play` | — | Enter Play Mode |
| `stop` | — | Exit Play Mode |
| `pause` | — | Pause Play Mode |
| `save-scene` | — | Save current scene |
| `open-scene` | `path` | Open scene by asset path |
| `refresh` | — | AssetDatabase.Refresh() |
| `clear-console` | — | Clear console buffer |
| `menu` | `item` | Execute menu item |

### Testing

| Command | Args | Description |
|---------|------|-------------|
| `run-tests` | `mode`, `filter`, `assemblyNames` | Start EditMode/PlayMode tests |
| `get-test-result` | `runId` (optional) | Poll test results |

### Batch

Execute multiple commands in one call:

```bash
curl -s -X POST http://localhost:$PORT/ -d '{
  "command": "batch",
  "args": {
    "commands": [
      {"command": "create", "args": {"name": "Sun", "primitiveType": "Sphere"}},
      {"command": "set-transform", "args": {"id": "$0", "scale": [3,3,3]}}
    ]
  }
}' -H 'Content-Type: application/json'
```

`$N` references the `instanceId` returned by the Nth command in the batch.

## CLI Tool

The included `Scripts~/unity-eval.sh` provides a convenient CLI:

```bash
./unity-eval.sh hierarchy                        # Scene hierarchy
./unity-eval.sh find '{"name":"Ship"}'           # Find by name
./unity-eval.sh --compile                        # Compile + wait + check
./unity-eval.sh --ping                           # Health check
./unity-eval.sh --help                           # All options
```

## How It Works

tykit uses `[InitializeOnLoad]` to start an `HttpListener` on a deterministic port (hashed from project path, range 8090-8153). Commands are received on a background thread and dispatched to the Unity main thread via `EditorApplication.update`.

- `/ping` responds directly from the listener thread (no main thread needed)
- All other commands are queued and processed on the main thread
- Port info is written to `Temp/tykit.json` (port, PID, project path)
- Server stops cleanly on domain reload and editor quit

## Use with quick-question

tykit is also bundled with [quick-question](https://github.com/tykisgod/quick-question), a Claude Code plugin for Unity development. When used with qq, tykit powers auto-compilation, test execution, and scene control behind the scenes.

## Security

tykit listens on **localhost only** with **no authentication**. Any local process can send commands. This is acceptable for development machines but not suitable for shared environments without network controls. See [SECURITY.md](SECURITY.md) for details.

## License

[MIT](LICENSE) &copy; Yukang Tian

---

# 中文

Unity Editor 内的轻量 HTTP 服务器。任何 AI agent 都能通过 `curl` 控制 Unity — 编译、运行测试、Play/Stop、读取控制台、检视 GameObject。

无需 SDK。无需插件 API。无需 UI 自动化。只有 HTTP。

> 本仓库是 [`tykisgod/quick-question/packages/com.tyk.tykit`](https://github.com/tykisgod/quick-question) 的自动镜像。请勿直接编辑 — 每次推送时自动从源仓库同步。

## 安装

在 Unity 项目的 `Packages/manifest.json` 中添加一行：

```json
"com.tyk.tykit": "https://github.com/tykisgod/tykit.git"
```

打开 Unity — tykit 自动启动。端口信息保存在 `Temp/tykit.json`。

**环境要求：** Unity 2021.3+，Newtonsoft JSON（UPM 依赖自动解析）。

## 快速开始

```bash
# 获取端口
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")

# 心跳检查
curl -s http://localhost:$PORT/ping

# 发送命令
curl -s -X POST http://localhost:$PORT/ \
  -d '{"command":"status"}' -H 'Content-Type: application/json'
```

## API 参考

### 读取命令

| 命令 | 参数 | 说明 |
|------|------|------|
| `status` | — | Editor 状态（isPlaying, isCompiling, activeScene） |
| `compile-status` | — | 编译状态（isCompiling, isUpdating） |
| `get-compile-result` | — | 编译结果（state, errors, duration） |
| `console` | `count`, `filter` | 控制台日志（最近 N 条，可选过滤） |
| `find` | `name`, `type`, `tag` | 查找场景中的 GameObject |
| `inspect` | `id` 或 `name` | 检视 GameObject 组件和属性 |
| `get-properties` | `id` | 列出组件的序列化属性 |
| `hierarchy` | `depth` | 场景层级树（默认深度 3） |
| `commands` | — | 列出所有可用命令 |

### 写入命令

| 命令 | 参数 | 说明 |
|------|------|------|
| `create` | `name`, `primitiveType`, `position` | 创建 GameObject |
| `instantiate` | `prefab`, `name` | 实例化预制体 |
| `destroy` | `id` | 销毁 GameObject |
| `set-transform` | `id`, `position`, `rotation`, `scale` | 修改 Transform |
| `add-component` | `id`, `component` | 添加组件 |
| `set-property` | `id`, `component`, `property`, `value` | 设置序列化属性 |

### Editor 控制

| 命令 | 参数 | 说明 |
|------|------|------|
| `play` | — | 进入 Play Mode |
| `stop` | — | 退出 Play Mode |
| `pause` | — | 暂停 Play Mode |
| `save-scene` | — | 保存当前场景 |
| `open-scene` | `path` | 按资源路径打开场景 |
| `refresh` | — | AssetDatabase.Refresh() |
| `clear-console` | — | 清空控制台缓冲区 |
| `menu` | `item` | 执行菜单项 |

### 测试

| 命令 | 参数 | 说明 |
|------|------|------|
| `run-tests` | `mode`, `filter`, `assemblyNames` | 启动 EditMode/PlayMode 测试 |
| `get-test-result` | `runId`（可选） | 查询测试结果 |

### 批量执行

一次调用执行多个命令：

```bash
curl -s -X POST http://localhost:$PORT/ -d '{
  "command": "batch",
  "args": {
    "commands": [
      {"command": "create", "args": {"name": "Sun", "primitiveType": "Sphere"}},
      {"command": "set-transform", "args": {"id": "$0", "scale": [3,3,3]}}
    ]
  }
}' -H 'Content-Type: application/json'
```

`$N` 引用批量中第 N 个命令返回的 `instanceId`。

## CLI 工具

内置 `Scripts~/unity-eval.sh` 命令行工具：

```bash
./unity-eval.sh hierarchy                        # 场景层级
./unity-eval.sh find '{"name":"Ship"}'           # 按名称查找
./unity-eval.sh --compile                        # 编译 + 等待 + 检查
./unity-eval.sh --ping                           # 健康检查
./unity-eval.sh --help                           # 所有选项
```

## 工作原理

tykit 通过 `[InitializeOnLoad]` 启动 `HttpListener`，端口由项目路径哈希确定（范围 8090-8153）。命令在后台线程接收，通过 `EditorApplication.update` 分发到 Unity 主线程。

- `/ping` 直接在监听线程响应（不需要主线程）
- 所有其他命令排队后在主线程处理
- 端口信息写入 `Temp/tykit.json`（port, PID, project path）
- Domain reload 和 Editor 退出时自动清理

## 配合 quick-question 使用

tykit 也随 [quick-question](https://github.com/tykisgod/quick-question)（Claude Code Unity 开发插件）一起分发。配合 qq 使用时，tykit 在后台驱动自动编译、测试执行和场景控制。

## 安全

tykit 仅监听 **localhost**，**无认证**。本机任何进程都可以发送命令。这对开发机器是可接受的，但不适用于未做网络管控的共享环境。详见 [SECURITY.md](SECURITY.md)。

## 许可证

[MIT](LICENSE) &copy; Yukang Tian

---

# 日本語

Unity Editor 内部の軽量 HTTP サーバー。あらゆる AI エージェントが `curl` で Unity を制御 — コンパイル、テスト実行、Play/Stop、コンソール読取、GameObject 検査。

SDK 不要。プラグイン API 不要。UI オートメーション不要。HTTP だけ。

> このリポジトリは [`tykisgod/quick-question/packages/com.tyk.tykit`](https://github.com/tykisgod/quick-question) の自動ミラーです。直接編集しないでください — プッシュ時にソースから自動同期されます。

## インストール

Unity プロジェクトの `Packages/manifest.json` に1行追加：

```json
"com.tyk.tykit": "https://github.com/tykisgod/tykit.git"
```

Unity を開く — tykit が自動起動。ポート情報は `Temp/tykit.json` に保存。

**要件：** Unity 2021.3+、Newtonsoft JSON（UPM 依存関係で自動解決）。

## クイックスタート

```bash
# ポート取得
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")

# ヘルスチェック
curl -s http://localhost:$PORT/ping

# コマンド送信
curl -s -X POST http://localhost:$PORT/ \
  -d '{"command":"status"}' -H 'Content-Type: application/json'
```

## API リファレンス

### 読取コマンド

| コマンド | 引数 | 説明 |
|----------|------|------|
| `status` | — | Editor 状態（isPlaying, isCompiling, activeScene） |
| `compile-status` | — | コンパイル状態 |
| `get-compile-result` | — | コンパイル結果（state, errors, duration） |
| `console` | `count`, `filter` | コンソールログ（直近 N 件、フィルタ可） |
| `find` | `name`, `type`, `tag` | シーン内 GameObject 検索 |
| `inspect` | `id` または `name` | GameObject コンポーネント検査 |
| `hierarchy` | `depth` | シーン階層ツリー（デフォルト深度 3） |
| `commands` | — | 利用可能コマンド一覧 |

### 書込コマンド

| コマンド | 引数 | 説明 |
|----------|------|------|
| `create` | `name`, `primitiveType`, `position` | GameObject 作成 |
| `destroy` | `id` | GameObject 削除 |
| `set-transform` | `id`, `position`, `rotation`, `scale` | Transform 変更 |
| `set-property` | `id`, `component`, `property`, `value` | シリアライズプロパティ設定 |

### Editor 制御

| コマンド | 説明 |
|----------|------|
| `play` / `stop` / `pause` | Play Mode 制御 |
| `save-scene` | シーン保存 |
| `refresh` | AssetDatabase.Refresh() |
| `run-tests` | EditMode/PlayMode テスト実行 |
| `get-test-result` | テスト結果取得 |

## quick-question との連携

tykit は [quick-question](https://github.com/tykisgod/quick-question)（Claude Code Unity 開発プラグイン）にもバンドルされています。qq と併用すると、自動コンパイル・テスト実行・シーン制御を裏側で担います。

## セキュリティ

tykit は **localhost のみ**でリスン、**認証なし**。詳細は [SECURITY.md](SECURITY.md) を参照。

## ライセンス

[MIT](LICENSE) &copy; Yukang Tian

---

# 한국어

Unity Editor 내부의 경량 HTTP 서버. 어떤 AI 에이전트든 `curl`로 Unity를 제어 — 컴파일, 테스트 실행, Play/Stop, 콘솔 읽기, GameObject 검사.

SDK 불필요. 플러그인 API 불필요. UI 자동화 불필요. HTTP만.

> 이 저장소는 [`tykisgod/quick-question/packages/com.tyk.tykit`](https://github.com/tykisgod/quick-question)의 자동 미러입니다. 직접 편집하지 마세요 — 푸시 시 소스에서 자동 동기화됩니다.

## 설치

Unity 프로젝트의 `Packages/manifest.json`에 한 줄 추가:

```json
"com.tyk.tykit": "https://github.com/tykisgod/tykit.git"
```

Unity 열기 — tykit이 자동 시작. 포트 정보는 `Temp/tykit.json`에 저장.

**요구 사항:** Unity 2021.3+, Newtonsoft JSON (UPM 의존성으로 자동 해결).

## 빠른 시작

```bash
# 포트 가져오기
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")

# 헬스 체크
curl -s http://localhost:$PORT/ping

# 명령 전송
curl -s -X POST http://localhost:$PORT/ \
  -d '{"command":"status"}' -H 'Content-Type: application/json'
```

## API 레퍼런스

### 읽기 명령

| 명령 | 인수 | 설명 |
|------|------|------|
| `status` | — | Editor 상태 (isPlaying, isCompiling, activeScene) |
| `compile-status` | — | 컴파일 상태 |
| `get-compile-result` | — | 컴파일 결과 (state, errors, duration) |
| `console` | `count`, `filter` | 콘솔 로그 (최근 N개, 필터 가능) |
| `find` | `name`, `type`, `tag` | 씬 내 GameObject 검색 |
| `inspect` | `id` 또는 `name` | GameObject 컴포넌트 검사 |
| `hierarchy` | `depth` | 씬 계층 트리 (기본 깊이 3) |
| `commands` | — | 사용 가능 명령 목록 |

### 쓰기 명령

| 명령 | 인수 | 설명 |
|------|------|------|
| `create` | `name`, `primitiveType`, `position` | GameObject 생성 |
| `destroy` | `id` | GameObject 삭제 |
| `set-transform` | `id`, `position`, `rotation`, `scale` | Transform 변경 |
| `set-property` | `id`, `component`, `property`, `value` | 직렬화 프로퍼티 설정 |

### Editor 제어

| 명령 | 설명 |
|------|------|
| `play` / `stop` / `pause` | Play Mode 제어 |
| `save-scene` | 씬 저장 |
| `refresh` | AssetDatabase.Refresh() |
| `run-tests` | EditMode/PlayMode 테스트 실행 |
| `get-test-result` | 테스트 결과 조회 |

## quick-question과 함께 사용

tykit은 [quick-question](https://github.com/tykisgod/quick-question) (Claude Code Unity 개발 플러그인)에도 번들됩니다. qq와 함께 사용하면 자동 컴파일, 테스트 실행, 씬 제어를 백그라운드에서 처리합니다.

## 보안

tykit은 **localhost만** 수신, **인증 없음**. 자세한 내용은 [SECURITY.md](SECURITY.md) 참조.

## 라이선스

[MIT](LICENSE) &copy; Yukang Tian

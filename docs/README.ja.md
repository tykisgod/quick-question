# quick-question

[English](../README.md) | [中文](README.zh-CN.md) | 日本語 | [한국어](README.ko.md)

---

## qq とは

qq は [Claude Code](https://docs.anthropic.com/en/docs/claude-code) の上に構築されたランタイムレイヤーで、AI エージェントにゲーム開発サイクルへの深い理解を与えます。すべてのタスクを一律に扱うのではなく、qq は今プロトタイプ中なのか、本番機能の構築中なのか、リグレッション修正中なのか、リリース前の堅牢化中なのかを把握し、プロセスの強度を適切に調整します。アーティファクト駆動コントローラー `/qq:go` は `.qq/` 内の構造化されたプロジェクト状態、最近の実行記録、設定された `work_mode` を読み取り、具体的な次のステップを提案します。

コード編集のたびに、qq はエンジン固有のフックを通じて自動コンパイルを実行します（Unity と S&box は `.cs`、Godot は `.gd`、Unreal は C++）。テストパイプラインを実行し、深いモデルレビューの前に決定的なポリシーチェックを適用し、Claude がオーケストレーションし Codex が独立にレビューするクロスモデルコードレビューを統括します。すべての指摘はコード変更前にサブエージェントによって検証されます。エディタ制御も組み込み済み：Unity には tykit、Godot・Unreal・S&box にはエディタブリッジがあります。

qq はデザインから出荷まで全ワークフローをカバーする 23 個のスラッシュコマンドを提供します：`/qq:design` → `/qq:plan` → `/qq:execute` → `/qq:test` → `/qq:codex-code-review` → `/qq:commit-push`。このアプローチは [AI Coding in Practice: An Indie Developer's Document-First Approach](https://tyksworks.com/posts/ai-coding-workflow-en/) で紹介されているドキュメントファースト手法に基づいています。

## 主な特徴

- **`/qq:go` — ライフサイクル対応ルーティング** — プロジェクト状態、`work_mode`、実行履歴を読み取り、現在のフェーズに適した次のステップを提案
- **自動コンパイル** — フック駆動のコンパイルがコード編集のたびに発火。`.cs`（Unity/S&box）、`.gd`（Godot）、C++（Unreal）に対応
- **テストパイプライン** — Unity は EditMode + PlayMode、Godot は GUT/GdUnit4、Unreal は Automation、S&box はランタイムテスト。すべて構造化された合否レポート付き
- **クロスモデルレビュー** — Claude がオーケストレーションし、Codex が差分を独立にレビュー。サブエージェントが各指摘をソースと照合してから修正を適用
- **エディタ制御** — tykit（Unity 用のインプロセス HTTP サーバー）に加え、Godot・Unreal・S&box 用の Python ブリッジ。手動設定不要
- **作業モード** — `prototype`、`feature`、`fix`、`hardening` — それぞれ適切なプロセス強度を適用し、プロトタイプは軽量に、リリースは完全な検証を実施
- **ランタイムデータ** — `.qq/` 内の構造化された状態がセッション間のループ継続性を提供し、コントローラーにフィード
- **モジュラーインストール** — エンジン自動検出付きウィザードモード、ワンショットプリセット（`quickstart`/`daily`/`stabilize`）、モジュール単位の制御

## 対応エンジン

| エンジン | コンパイル | テスト | エディタ制御 | ブリッジ |
|----------|-----------|--------|-------------|----------|
| **Unity 2021.3+** | tykit / editor trigger / batch | EditMode + PlayMode | tykit HTTP server | `tykit_bridge.py` |
| **Godot 4.x** | GDScript check via headless editor | GUT / GdUnit4 | Editor addon | `godot_bridge.py` |
| **Unreal 5.x** | UnrealBuildTool + editor commandlet | Automation tests | Editor command (Python) | `unreal_bridge.py` |
| **S&box** | `dotnet build` | Runtime tests | Editor bridge | `sbox_bridge.py` |

Unity は最も深い統合を持ちます（tykit はミリ秒単位のレスポンスタイムでインプロセス HTTP 制御を提供）。Godot、Unreal、S&box はランタイムパリティに到達 — コンパイル、テスト、エディタ制御、構造化された実行記録がすべて動作 — 開発は継続中です。

## インストール

### 前提条件

- macOS または Windows（[Git for Windows](https://gitforwindows.org/) が必要。Windows サポートはプレビュー版）
- エンジン：Unity 2021.3+ / Godot 4.x / Unreal 5.x / S&box
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `curl`、`python3`、`jq`
- [Codex CLI](https://github.com/openai/codex) *（オプション — クロスモデルレビューを有効化）*

### 手順

**1. プラグインのインストール**

```
/plugin marketplace add tykisgod/quick-question
/plugin install qq@quick-question-marketplace
```

**2. プロジェクトへのランタイムインストール**

```bash
# エンジンを自動検出（Unity / Godot / Unreal / S&box）
./install.sh /path/to/your-project

# または対話式ウィザードを使用
./install.sh --wizard /path/to/your-project

# またはプリセットを選択
./install.sh --preset quickstart /path/to/your-project
```

利用可能なプリセット：`quickstart`（最小構成、初回導入に最適）、`daily`（推奨デフォルト）、`stabilize`（リリース準備用のフルチェック）。詳細な制御は `--profile`、`--modules`、`--without` を参照してください。

**3. エディタを開く。** Unity では tykit が自動起動します。他のエンジンではインストーラーが表示するインストール後の手順に従ってください。

## クイックスタート

```bash
# qq に現在の状態を判断させる
/qq:go

# 機能を設計する
/qq:design "inventory system with drag-and-drop"

# 実装計画を生成する
/qq:plan

# 計画を実行 — 編集ごとに自動コンパイル
/qq:execute

# テストを実行する
/qq:test
```

qq は作業モードに応じてプロセス強度を調整します。`prototype` モードでは軽量に — コンパイルをグリーンに保ち、プレイ可能な状態を維持し、素早く進めます。`hardening` モードでは出荷前にテストとレビューを強制します。詳しいウォークスルーは [Getting Started](docs/getting-started.md) を参照してください。

## コマンド

### ワークフロー

| コマンド | 説明 |
|---------|------|
| `/qq:go` | ワークフロー段階を検出し、次のステップを提案 |
| `/qq:design` | ゲームデザインドキュメントを作成 |
| `/qq:plan` | 技術的な実装計画を生成 |
| `/qq:execute` | 自動コンパイル検証付きスマート実装 |

### テスト

| コマンド | 説明 |
|---------|------|
| `/qq:add-tests` | EditMode、PlayMode、またはリグレッションテストを作成 |
| `/qq:test` | テストを実行し、ランタイムエラーをチェック |

### コードレビュー

| コマンド | 説明 |
|---------|------|
| `/qq:codex-code-review` | クロスモデルレビュー：Codex がレビュー、Claude が検証（最大 5 ラウンド） |
| `/qq:codex-plan-review` | クロスモデル計画/設計レビュー |
| `/qq:claude-code-review` | Claude 単独の深いコードレビュー（自動修正ループ付き） |
| `/qq:claude-plan-review` | Claude 単独の計画/設計レビュー |
| `/qq:best-practice` | アンチパターンとパフォーマンス問題のクイックスキャン |
| `/qq:self-review` | 最近のスキル/設定変更をレビュー |

### 分析

| コマンド | 説明 |
|---------|------|
| `/qq:brief` | アーキテクチャ図 + ベースブランチ対比の PR レビューチェックリスト |
| `/qq:timeline` | コミット履歴をセマンティックフェーズに分類 |
| `/qq:full-brief` | brief + timeline を並列実行 |
| `/qq:deps` | `.asmdef` 依存関係を分析（Mermaid グラフ + マトリックス） |
| `/qq:doc-drift` | 設計ドキュメントと実際のコードを比較 |

### ユーティリティ

| コマンド | 説明 |
|---------|------|
| `/qq:commit-push` | 一括コミットとプッシュ |
| `/qq:explain` | モジュールアーキテクチャをわかりやすく説明 |
| `/qq:grandma` | 日常的なたとえで概念を説明 |
| `/qq:research` | オープンソースコミュニティで解決策を検索 |
| `/qq:changes` | 現在のセッションでの全変更を要約 |
| `/qq:doc-tidy` | ドキュメント整理の推奨事項をスキャン |

## 作業モード

| モード | タイミング | 必須 | 通常スキップ |
|--------|-----------|------|-------------|
| `prototype` | 新メカニクス、グレーボックス、面白さの検証 | コンパイルグリーン維持、プレイ可能 | 正式なドキュメント、フルレビュー |
| `feature` | 保持可能なシステムの構築 | 設計、計画、コンパイル、的を絞ったテスト | 全変更ごとの完全リグレッション |
| `fix` | バグ修正、リグレッション対応 | まず再現、最小限の安全な修正 | 大規模リファクタリング |
| `hardening` | リスクの高いリファクタ、リリース準備 | テスト、レビュー、ドキュメント/コードの一貫性 | プロトタイプのショートカット |

共有デフォルトは `qq.yaml` で設定。ワークツリーごとのオーバーライドは `.qq/local.yaml` で設定。`/qq:go` と入力すれば、モードを読み取り推奨を調整します。

`work_mode` と `policy_profile` は独立した設定です。`work_mode` は「これはどんな種類のタスクか？」に答え、`policy_profile` は「このプロジェクトにどの程度の検証を期待するか？」に答えます。プロトタイプと堅牢化パスで同じポリシープロファイルを共有することも、しないことも可能 — それらは独立しています。完全なリファレンスは [Configuration](docs/configuration.md) を参照してください。

## 仕組み

qq は 4 層のランタイムとして動作します：

```
Edit .cs/.gd file
  → Hook auto-compiles (tykit / editor trigger / batch mode)
    → Result written to .qq/state/
      → /qq:go reads state, recommends next step
```

**フック** はツール使用時に自動的に発火 — コード編集後のコンパイル、スキル変更の追跡、レビュー検証中の編集のゲーティング。**`/qq:go`** はコントローラーです：プロジェクト状態（`work_mode`、`policy_profile`、最新のコンパイル/テスト結果）を `.qq/state/` から読み取り、適切なスキルにルーティングします。**エンジンブリッジ** はブラインドなファイル書き込みではなく、検証済みのインプロセス実行を提供します。**ランタイムデータ**（`.qq/`）がすべてのレイヤーにプロジェクトの健全性の共有された構造化ビューを提供します。

クロスモデルレビューでは、Codex Tribunal が差分に対して Codex CLI を実行し、Claude サブエージェントが各指摘を検証してオーバーエンジニアリングをチェック — クリーンになるまで最大 5 ラウンド実施します。

詳細は [Architecture Overview](docs/architecture/overview.md) で図とレイヤーの詳細、[Hook System](docs/hooks.md) で自動コンパイルとレビューゲートの内部構造、[Cross-Model Review](docs/cross-model-review.md) で Codex Tribunal のフロー、[Worktrees](docs/worktrees.md) で並列タスクの分離について参照してください。

## カスタマイズ

プロジェクトでの qq の動作は 3 つのファイルで制御します：

- **`qq.yaml`** — ランタイム設定：`work_mode`、`policy_profile`、`trust_level`、モジュール選択。組み込みプロファイル：`lightweight`、`core`、`feature`、`hardening`。[`templates/qq.yaml.example`](../templates/qq.yaml.example) を参照。
- **`CLAUDE.md`** — プロジェクトにスコープされたコーディング標準とコンパイル検証ルール。[`templates/CLAUDE.md.example`](../templates/CLAUDE.md.example) を参照。
- **`AGENTS.md`** — サブエージェントワークフロー向けのアーキテクチャルールとレビュー基準。[`templates/AGENTS.md.example`](../templates/AGENTS.md.example) を参照。

## tykit

tykit は Unity Editor プロセス内の軽量 HTTP サーバーです — セットアップ不要、外部依存なし、ミリ秒単位のレスポンスタイム。localhost 経由でコンパイル、テスト、Play/Stop、コンソール、インスペクターのコマンドを公開します。ポートはプロジェクトパスのハッシュから算出され、`Temp/tykit.json` に保存されます。

```bash
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")
curl -s -X POST http://localhost:$PORT/ -d '{"command":"compile"}' -H 'Content-Type: application/json'
curl -s -X POST http://localhost:$PORT/ -d '{"command":"run-tests","args":{"mode":"editmode"}}' -H 'Content-Type: application/json'
```

tykit は qq なしでも単独で動作します — [UPM パッケージ](../packages/com.tyk.tykit/)を追加するだけです。MCP ブリッジ（`tykit_mcp.py`）は Claude 以外のエージェント向けに利用可能です。完全な API は [`docs/tykit-api.md`](tykit-api.md)、MCP 統合は [`docs/tykit-mcp.md`](tykit-mcp.md) を参照してください。

## よくある質問

**Windows で動作しますか？**
はい、プレビュー版として動作します。[Git for Windows](https://gitforwindows.org/)（bash、curl、コアユーティリティを提供）が必要です。

**Codex CLI は必要ですか？**
いいえ。Codex CLI はクロスモデルレビュー（`/qq:codex-code-review`）を有効にしますが、Claude 単独レビューの `/qq:claude-code-review` は Codex なしで動作します。

**Cursor/Copilot で使えますか？**
`/qq:*` スキルは Claude Code が必要です。tykit は HTTP 経由でどのツールとも単独で動作し、MCP ブリッジ（`tykit_mcp.py`）が他のエージェントに公開します。

**コンパイルが失敗したらどうなりますか？**
自動コンパイルフックがエラー出力をキャプチャし、会話内に表示します。Claude がエラーを読み取りコードを修正すると、フックが再び自動的にコンパイルします。

**quick-question なしで tykit を使えますか？**
はい。[`packages/com.tyk.tykit/`](../packages/com.tyk.tykit/) の UPM パッケージをプロジェクトに追加してください。[tykit README](../packages/com.tyk.tykit/README.md) を参照。

**どの Unity バージョンに対応していますか？**
tykit は Unity 2021.3+ が必要です。MCP の代替：[mcp-unity](https://github.com/nicoboss/mcp-unity) は Unity 6+ 必須、[Unity-MCP](https://github.com/mpiechot/Unity-MCP) はバージョン制限なし。

## コントリビュート

コントリビュート歓迎 — [CONTRIBUTING.md](../CONTRIBUTING.md) を参照してください。

## ライセンス

MIT — [LICENSE](../LICENSE) を参照。

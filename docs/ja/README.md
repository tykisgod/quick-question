# quick-question

[English](../../README.md) | [中文](../zh-CN/README.md) | 日本語 | [한국어](../ko/README.md)

---

> **✅ 検証済みパス**：**Claude Code + Unity 2021.3+（macOS または Windows）**。日常的に使われ、エンドツーエンドで検証済み。この README の内容を「そのまま動かしたい」場合の推奨構成です。
>
> **🧪 実験的 — コントリビューション歓迎**：Godot、Unreal、S&box アダプタは**スキャフォールド**として出荷されています。ブリッジコード、コマンドサーフェス、CI スモークテストは整っていますが、**Unity 以外のアダプタで実際にゲームを出荷した人はまだいません** — 実際の開発シナリオで検証されていません。Claude 以外のホスト（Codex CLI、Cursor、Continue その他の MCP ホスト）も同様です — ランタイムは*設計上*エージェント非依存ですが、検証済みのループは Claude Code のみです。これらのいずれかで開発している場合、あなたのバグ報告と PR がそのアダプタを「検証済み」に昇格させる道です — [CONTRIBUTING.md](../../CONTRIBUTING.md) を参照してください。

## なぜ qq か

AI エージェントはコードを書ける。しかしデフォルトでは、そのコードがコンパイルできるのか、テストが通るのか、振る舞いが正しいのか、それとも単に 500 行のもっともらしいナンセンスを生成しただけなのか、エージェント自身は教えてくれない。ゲームプロジェクト ―― 「動く」とはエディタが開き、シーンがロードされ、N+1 フレーム目があなたの想像通りに見えること ―― ではこのギャップが問題のすべてだ。

quick-question はそのギャップを閉じるランタイムレイヤー。4 つの作業モード `prototype`、`feature`、`fix`、`hardening` を装飾文字ではなく一級のステートとして扱う。プロトタイプはコンパイルをグリーンに保ちプレイ可能な状態を維持する。ハードニングパスは出荷前にテスト、レビュー、ドキュメント / コードの一貫性を強制する。アーティファクト駆動のコントローラー `/qq:go` が `.qq/state/*.json` とあなたの `work_mode` を読み取り、チャット履歴から推測するのではなく、具体的な次のスキルを推奨する。

ランタイムはエンジン対称かつエージェント非依存。tykit が Unity に最も深い統合を提供する（インプロセス HTTP サーバー、ミリ秒応答）。Godot、Unreal、S&box は Python ブリッジを通じてランタイムパリティに到達。[Claude Code](https://docs.anthropic.com/en/docs/claude-code) は 27 個のスキル、自動コンパイルフック、レビューゲートを得る。Codex、Cursor、Continue、その他の MCP 互換ホストは HTTP と MCP を通じて同じ基盤ランタイムを使う。`.qq/` の構造化ステートはディスク上のプレーン JSON ―― セッションを跨いでどのエージェントからも読める。

方法論は [*AI Coding in Practice: An Indie Developer's Document-First Approach*](https://tyksworks.com/posts/ai-coding-workflow-en/) で説明されているドキュメントファーストアプローチに基づいている。

## 仕組み

```
Edit .cs/.gd/.cpp file
  → Hook が qq-compile.sh 経由で自動コンパイル
    → 結果 + エラーコンテキストを .qq/state/ に書き込み
      → /qq:go がステートを読んで次のスキルを推奨
        → スキルが実行され、新しいステートを書き込む
          → ループ
```

4 つのレイヤーが協調する：

- **フック** は Claude Code のすべてのツール呼び出しで発火する。PostToolUse はエンジンソースファイルへの `Edit`/`Write` 後に `qq-compile.sh`（マルチエンジンディスパッチャー）でコンパイルする。PreToolUse はレビュー検証中、またはコンパイルが赤の後、対応するゲートが解除されるまで編集をブロックする。Stop は `/qq:self-review` を実行せずにスキルが変更された場合にセッション終了をブロックする。
- **コントローラー** ―― `/qq:go` は `.qq/state/*.json`、最近の実行記録、あなたの `work_mode`、現在の `policy_profile` を読み、次のスキルへルーティングする。これはコントローラーであって実装エンジンではない ―― ステートが曖昧な場合のみコンテキストヒューリスティックにフォールバックする。
- **エンジンブリッジ** ―― tykit（Unity インプロセス HTTP）、`godot_bridge.py`、`unreal_bridge.py`、`sbox_bridge.py`。コンパイル、テスト、コンソール、find / inspect ―― 検証された実行であって、盲目的なファイル書き込みではない。
- **ランタイムデータ** ―― `.qq/runs/*.json`（生の実行ログ）、`.qq/state/*.json`（最新のコンパイル / テストステート）、`.qq/state/session-decisions.json`（クロススキル決定ジャーナル）、`.qq/telemetry/`。プレーン JSON で、セッションを跨いでどのエージェントからも読める。

コードレビューには 2 つの対称モードがあり、同じ検証ループを共有する：**Codex レビュー**（`code-review.sh` → `codex exec`、クロスモデル）と **Claude レビュー**（`claude-review.sh` → `claude -p`、シングルモデル）。それぞれが指摘を生成し、独立した検証サブエージェントが各指摘を実際のソースと照合してオーバーエンジニアリングをチェックする ―― クリーンになるまで最大 5 ラウンド。統一レビューゲート（`scripts/hooks/review-gate.sh`）はすべての検証サブエージェントが完了するまで編集をブロックする（3 フィールド形式：`<ts>:<completed>:<expected>`）。MCP は非 Claude ホスト向けに ワンショットの `qq_code_review` と `qq_plan_review` ツールを公開する。

詳細は [Architecture Overview](../dev/architecture/overview.md)、[Hook System](../en/hooks.md)、[Cross-Model Review](../en/cross-model-review.md)、[Worktrees](../en/worktrees.md) を参照。

## エンジン

| エンジン | コンパイル | テスト | エディタ制御 | ブリッジ |
|----------|-----------|--------|-------------|----------|
| **Unity 2021.3+** ✅ verified | tykit / editor trigger / batch | EditMode + PlayMode | tykit HTTP server | `tykit_bridge.py` |
| **Godot 4.x** 🧪 preview | GDScript check via headless editor | GUT / GdUnit4 | Editor addon | `godot_bridge.py` |
| **Unreal 5.x** 🧪 preview | UnrealBuildTool + editor commandlet | Automation tests | Editor command (Python) | `unreal_bridge.py` |
| **S&box** 🧪 preview | `dotnet build` | Runtime tests | Editor bridge | `sbox_bridge.py` |

Unity は検証済みのパスで、tykit のインプロセス HTTP サーバー（ミリ秒応答）を通じて日常的に使用されています。Godot、Unreal、S&box は**実験的なスキャフォールド**として出荷されています：アダプタコード、ブリッジサーフェス、CI スモークテストは整っていますが、Unity 以外のアダプタで実際にゲームを構築した人はまだいません。これらは本番運用可能なパスではなく、コントリビューターの出発点として扱ってください — [CONTRIBUTING.md](../../CONTRIBUTING.md) を参照。

## インストール

### 前提条件

- macOS または Windows（Windows では bash とコアユーティリティのために [Git for Windows](https://gitforwindows.org/) が必要）
- エンジン：Unity 2021.3+ / Godot 4.x / Unreal 5.x / S&box
- `python3`（必須）、`jq`（推奨 ―― hook スクリプトは jq がない場合 python3 にフォールバックする）
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)（フルスキル + フック体験向け）
- [Codex CLI](https://github.com/openai/codex)（オプション ―― クロスモデルレビューを有効化）

### ランタイムのインストール

すべてのエージェントが同じランタイムインストールを共有する。エンジンを自動検出して、スクリプト、ブリッジ、設定をプロジェクトに書き込む。

```bash
git clone https://github.com/tykisgod/quick-question.git /tmp/qq
/tmp/qq/install.sh /path/to/your-project          # エンジン自動検出
/tmp/qq/install.sh --wizard /path/to/your-project  # 対話式ウィザード
/tmp/qq/install.sh --preset quickstart /path/to/your-project  # ワンショットプリセット
rm -rf /tmp/qq
```

利用可能なプリセット：`quickstart`（最小構成）、`daily`（推奨）、`stabilize`（リリース準備用フルチェック）。詳細な制御は `--profile`、`--modules`、`--without` を参照。

### エージェントの接続

| エージェント | セットアップ | 得られるもの |
|--------------|-------------|--------------|
| **Claude Code** | `/plugin marketplace add tykisgod/quick-question`<br>`/plugin install qq@quick-question-marketplace` | 27 個の `/qq:*` スラッシュコマンド全部、自動コンパイルフック、レビューゲート、MCP ―― フル体験 |
| **Codex CLI** | `python3 ./scripts/qq-codex-mcp.py install --pretty` | プロジェクトローカル MCP ブリッジ；作業ルートを固定するには `qq-codex-exec.py` を使う |
| **Cursor / Continue / その他の MCP ホスト** | ホスト設定の `mcpServers` に `qq` を追加：`command: python3`、`args: ["./scripts/qq_mcp.py"]`、`cwd: /path/to/project` | コンパイル、テスト、コンソール、エディタ制御を MCP ツールとして公開 ―― [`docs/en/tykit-mcp.md`](../en/tykit-mcp.md) 参照 |
| **任意の HTTP クライアント** | `Temp/tykit.json` からポートを読み取り、`localhost:$PORT/` に JSON を POST | tykit への直接アクセス ―― [`docs/en/tykit-api.md`](../en/tykit-api.md) 参照 |

非 Unity エンジンの場合はブリッジスクリプトを直接呼び出す（例：`python3 ./scripts/godot_bridge.py compile`）。

## クイックスタート

```bash
/qq:go                                       # フェーズを検出、次のステップを推奨
/qq:design "inventory with drag-and-drop"    # デザインドキュメントを書く
/qq:plan                                     # 実装計画を生成する
/qq:execute                                  # 実装する ―― 編集ごとに自動コンパイル
/qq:test                                     # テスト実行、ランタイムエラーを表示
/qq:commit-push                              # 一括コミットとプッシュ
```

`/qq:go` は `work_mode` に応じて適応する。`prototype` では軽量を保つ（コンパイルグリーン、プレイ可能を維持）。`hardening` では出荷前にテスト、レビュー、ドキュメント / コードの一貫性を強制する。詳しいウォークスルーは [Getting Started](../en/getting-started.md) を参照。

## コマンド

### ワークフロー

| コマンド | 説明 |
|---------|------|
| `/qq:go` | ワークフロー段階を検出し、次のステップを推奨 |
| `/qq:bootstrap` | ゲームビジョンを epics に分解し、フルパイプラインをオーケストレーション |
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
| `/qq:codex-code-review` | クロスモデル：Codex がレビュー、Claude が検証（最大 5 ラウンド） |
| `/qq:codex-plan-review` | クロスモデル計画 / 設計レビュー |
| `/qq:claude-code-review` | Claude 単独の深いコードレビュー（自動修正ループ付き） |
| `/qq:claude-plan-review` | Claude 単独の計画 / 設計レビュー |
| `/qq:best-practice` | アンチパターンとパフォーマンス問題のクイックスキャン |
| `/qq:self-review` | 最近のスキル / 設定変更をレビュー |
| `/qq:post-design-review` | 実装者視点で設計ドキュメントをレビュー ―― 一貫性、ビルド可能性、コードベースのギャップをチェック |

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
| `/qq:tech-research` | オープンソースコミュニティで技術ソリューションを検索 |
| `/qq:design-research` | ゲームデザインのリファレンスとパターンを検索 |
| `/qq:changes` | 現在のセッションでのすべての変更を要約 |
| `/qq:doc-tidy` | ドキュメント整理の推奨事項をスキャン |

## 作業モード

| モード | タイミング | 必須 | 通常スキップ |
|--------|-----------|------|-------------|
| `prototype` | 新メカニクス、グレーボックス、面白さの検証 | コンパイルグリーン維持、プレイ可能 | 正式ドキュメント、フルレビュー |
| `feature` | 保持するシステムの構築 | 設計、計画、コンパイル、ターゲットテスト | 全変更ごとの完全リグレッション |
| `fix` | バグ修正、リグレッション対応 | まず再現、最小限の安全な修正 | 大規模リファクタリング |
| `hardening` | 高リスクのリファクタ、リリース準備 | テスト、レビュー、ドキュメント / コードの一貫性 | プロトタイプのショートカット |

共有デフォルトは `qq.yaml` で設定。ワークツリーごとのオーバーライドは `.qq/local.yaml` で設定。`work_mode` と `policy_profile` は独立している：前者は「これはどんな種類のタスクか？」に答え、後者は「このプロジェクトはどれだけの検証を期待するか？」に答える。プロトタイプとハードニングパスで同じポリシープロファイルを共有することも、しないことも可能。完全なリファレンスは [Configuration](../en/configuration.md) を参照。

## 設定

プロジェクトでの qq の動作は 3 つのファイルで制御する：

- **`qq.yaml`** ―― ランタイム設定：`work_mode`、`policy_profile`、`trust_level`、モジュール選択。組み込みプロファイル：`lightweight`、`core`、`feature`、`hardening`。[`templates/qq.yaml.example`](../../templates/qq.yaml.example) を参照。
- **`CLAUDE.md`** ―― プロジェクトにスコープされたコーディング標準とコンパイル検証ルール。[`templates/CLAUDE.md.example`](../../templates/CLAUDE.md.example) を参照。
- **`AGENTS.md`** ―― サブエージェントワークフロー向けのアーキテクチャルールとレビュー基準。[`templates/AGENTS.md.example`](../../templates/AGENTS.md.example) を参照。

## tykit

tykit（現在 **v0.5.0**）は Unity Editor プロセス内の軽量 HTTP サーバー ―― セットアップ不要、外部依存なし、ミリ秒応答。localhost を通じて 60+ コマンドを公開する：コンパイル / テスト、コンソール、シーン / 階層、GameObject ライフサイクル、**リフレクション**（`call-method` / `get-field` / `set-field` ―― 事前にスキャフォールディングを仕込まずに任意のコンポーネントメソッドを呼び出せる）、プレハブ編集、**物理クエリ**（raycast、overlap-sphere）、アセット管理、UI 自動化、エディタ制御など。ポートはプロジェクトパスのハッシュから算出され、`Temp/tykit.json` に保存される。

```bash
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")
curl -s -X POST http://localhost:$PORT/ -d '{"command":"compile"}' -H 'Content-Type: application/json'
curl -s -X POST http://localhost:$PORT/ -d '{"command":"run-tests","args":{"mode":"editmode"}}' -H 'Content-Type: application/json'
```

**主要な差別化要因**（v0.5.0）：Unity のメインスレッドがモーダルダイアログまたはバックグラウンドスロットリング中の domain reload でブロックされた場合、tykit のリスナースレッド `GET /health`、`GET /focus-unity`、`GET /dismiss-dialog` エンドポイントは、ブロックされたメインスレッドに依存せずに Unity を作業状態に引き戻すことができる。他のすべての Unity ブリッジはこのシナリオで停止する ―― tykit だけが回復できる。詳細は [`tykit-api.md`](../en/tykit-api.md) のメインスレッドリカバリーセクションを参照。

tykit は qq なしでもスタンドアロンで動作する ―― [UPM パッケージ](../../packages/com.tyk.tykit/) を任意の Unity プロジェクトに追加するだけ。HTTP を送信できるエージェントなら直接使える。MCP ブリッジ（`tykit_mcp.py`）は MCP 互換ホスト向けにラップする。[`docs/en/tykit-api.md`](../en/tykit-api.md) と [`docs/en/tykit-mcp.md`](../en/tykit-mcp.md) を参照。

## よくある質問

**Windows で動作しますか？**
はい。bash、curl、コアユーティリティのために [Git for Windows](https://gitforwindows.org/) が必要です。1.15.x と 1.16.x シリーズで Windows サポートが大幅に強化されました ―― LF 改行の強制、パス正規化、Python Store エイリアス検出、hook スクリプトでの jq フォールバック。

**Codex CLI は必要ですか？**
いいえ。Codex CLI はクロスモデルレビュー（`/qq:codex-code-review`）を有効にしますが、`/qq:claude-code-review` は Codex なしでも動作します。

**Cursor / Copilot / Codex / その他のエージェントと一緒に使えますか？**
はい。ランタイムレイヤー（tykit、エンジンブリッジ、`.qq/` ステート、スクリプト）はエージェント非依存です ―― HTTP を送信できる、または MCP を話せるツールならどれでも使えます。27 個の `/qq:*` スラッシュコマンドと自動コンパイルフックは Claude Code 専用ですが、それらが呼び出す基盤スクリプトは普通の shell と Python です。[`docs/dev/agent-integration.md`](../dev/agent-integration.md) を参照。

**コンパイルが失敗したらどうなりますか？**
自動コンパイルフックがエラー出力をキャプチャし、会話に表示します。コンパイルゲートはその後、コンパイルが回復するまでエンジンソースファイルへの後続の編集をブロックします。エージェントがエラーを読んでコードを修正すると、フックが再び自動的にコンパイルします。

**quick-question なしで tykit を使えますか？**
はい。[`packages/com.tyk.tykit/`](../../packages/com.tyk.tykit/) から UPM パッケージを追加してください。[tykit README](../../packages/com.tyk.tykit/README.md) を参照。

**どの Unity バージョンに対応していますか？**
tykit は Unity 2021.3+ が必要です。MCP の代替：[mcp-unity](https://github.com/nicoboss/mcp-unity) は Unity 6+ 必須、[Unity-MCP](https://github.com/mpiechot/Unity-MCP) はバージョン制限なし。

## コントリビュート

コントリビュート歓迎 ―― [CONTRIBUTING.md](../../CONTRIBUTING.md) を参照してください。

## ライセンス

MIT ―― [LICENSE](../../LICENSE) を参照。

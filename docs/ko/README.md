# quick-question

[English](../../README.md) | [中文](../zh-CN/README.md) | [日本語](../ja/README.md) | 한국어

---

> **✅ 검증된 경로**: **Claude Code + Unity 2021.3+ (macOS 또는 Windows)**. 매일 사용되고 엔드 투 엔드로 검증되었습니다. 이 README의 모든 내용이 "그대로 동작"하길 원할 때의 권장 구성입니다.
>
> **🧪 실험적 — 기여 환영**: Godot, Unreal, S&box 어댑터는 **스캐폴드**로만 출시됩니다. 브리지 코드, 명령 표면, CI 스모크 테스트는 모두 갖춰져 있지만, **Unity 외의 어떤 어댑터로도 실제 게임을 출시한 사람이 아직 없습니다** — 실제 개발 시나리오에서 검증되지 않았습니다. 비-Claude 호스트(Codex CLI, Cursor, Continue 및 기타 MCP 호스트)도 마찬가지입니다 — 런타임은 *설계상* 에이전트 무관이지만, 검증된 루프는 Claude Code 전용입니다. 이들 중 하나로 개발 중이라면, 여러분의 버그 리포트와 PR이 어댑터를 "검증됨"으로 승격시키는 길입니다 — [CONTRIBUTING.md](../../CONTRIBUTING.md) 참조.

## 왜 qq인가

AI 에이전트는 코드를 쓸 수 있다. 하지만 기본적으로는 그 코드가 컴파일되는지, 테스트가 통과하는지, 동작이 올바른지, 아니면 그저 500줄의 그럴듯한 헛소리를 만들어냈는지 알려주지 못한다. 게임 프로젝트에서 ―― "실행된다"는 것이 에디터가 열리고, 씬이 로드되고, N+1 프레임이 당신이 원하던 모습으로 보인다는 의미라면 ―― 그 간극이 문제의 전부다.

quick-question은 그 간극을 닫는 런타임 레이어다. 네 가지 작업 모드 `prototype`, `feature`, `fix`, `hardening`은 장식이 아니라 일급 상태다. 프로토타입은 컴파일 그린을 유지하고 플레이 가능한 상태를 유지한다. 하드닝 패스는 배포 전에 테스트, 리뷰, 문서/코드 일관성을 강제한다. 아티팩트 기반 컨트롤러 `/qq:go`는 `.qq/state/*.json`과 `work_mode`를 읽고, 채팅 히스토리에서 추측하는 대신 구체적인 다음 스킬을 추천한다.

런타임은 엔진 대칭이며 에이전트 무관이다. tykit이 Unity에 가장 깊은 통합을 제공한다(인프로세스 HTTP 서버, 밀리초 응답). Godot, Unreal, S&box는 Python 브리지를 통해 런타임 패리티에 도달한다. [Claude Code](https://docs.anthropic.com/en/docs/claude-code)는 27개의 스킬, 자동 컴파일 훅, 리뷰 게이트를 얻는다. Codex, Cursor, Continue, 그리고 모든 MCP 호환 호스트는 HTTP와 MCP를 통해 같은 기반 런타임을 사용한다. `.qq/`의 구조화된 상태는 디스크상의 일반 JSON ―― 어떤 에이전트든 세션을 가로질러 읽을 수 있다.

방법론은 [*AI Coding in Practice: An Indie Developer's Document-First Approach*](https://tyksworks.com/posts/ai-coding-workflow-en/)에서 설명한 문서 우선 접근법에 기반한다.

## 동작 원리

```
Edit .cs/.gd/.cpp file
  → Hook이 qq-compile.sh를 통해 자동 컴파일
    → 결과 + 에러 컨텍스트가 .qq/state/에 기록됨
      → /qq:go가 상태를 읽고 다음 스킬을 추천
        → 스킬이 실행되어 새 상태를 기록
          → 루프
```

네 개의 레이어가 협력한다:

- **훅**은 모든 Claude Code 도구 호출에서 발화한다. PostToolUse는 엔진 소스 파일에 대한 `Edit`/`Write` 후 `qq-compile.sh`(멀티엔진 디스패처)를 통해 컴파일한다. PreToolUse는 리뷰 검증 중이거나 컴파일 레드 이후, 해당 게이트가 해제될 때까지 편집을 차단한다. Stop은 `/qq:self-review` 없이 스킬이 수정된 경우 세션 종료를 차단한다.
- **컨트롤러** ―― `/qq:go`는 `.qq/state/*.json`, 최근 실행 기록, `work_mode`, 활성 `policy_profile`을 읽고 다음 스킬로 라우팅한다. 이는 컨트롤러이지 구현 엔진이 아니다 ―― 상태가 모호할 때만 컨텍스트 휴리스틱으로 폴백한다.
- **엔진 브리지** ―― tykit(Unity 인프로세스 HTTP), `godot_bridge.py`, `unreal_bridge.py`, `sbox_bridge.py`. 컴파일, 테스트, 콘솔, find / inspect ―― 검증된 실행이지 맹목적인 파일 쓰기가 아니다.
- **런타임 데이터** ―― `.qq/runs/*.json`(원시 실행 로그), `.qq/state/*.json`(최신 컴파일/테스트 상태), `.qq/state/session-decisions.json`(크로스 스킬 결정 저널), `.qq/telemetry/`. 일반 JSON으로 어떤 에이전트든 세션을 가로질러 읽을 수 있다.

코드 리뷰의 경우 두 가지 대칭 모드가 같은 검증 루프를 공유한다: **Codex 리뷰**(`code-review.sh` → `codex exec`, 크로스 모델)와 **Claude 리뷰**(`claude-review.sh` → `claude -p`, 단일 모델). 각각이 발견을 생성한 다음, 독립된 검증 서브에이전트가 모든 발견을 실제 소스와 대조하고 오버엔지니어링을 표시한다 ―― 깨끗해질 때까지 최대 5라운드. 통합 리뷰 게이트(`scripts/hooks/review-gate.sh`)는 모든 검증 서브에이전트가 완료될 때까지 편집을 차단한다(3-필드 형식: `<ts>:<completed>:<expected>`). MCP는 비-Claude 호스트 용으로 일회성 `qq_code_review`와 `qq_plan_review` 도구를 노출한다.

자세한 내용은 [Architecture Overview](../dev/architecture/overview.md), [Hook System](../en/hooks.md), [Cross-Model Review](../en/cross-model-review.md), [Worktrees](../en/worktrees.md) 참조.

## 엔진

| 엔진 | 컴파일 | 테스트 | 에디터 제어 | 브리지 |
|------|--------|--------|------------|--------|
| **Unity 2021.3+** ✅ verified | tykit / editor trigger / batch | EditMode + PlayMode | tykit HTTP server | `tykit_bridge.py` |
| **Godot 4.x** 🧪 preview | headless editor를 통한 GDScript 검사 | GUT / GdUnit4 | Editor addon | `godot_bridge.py` |
| **Unreal 5.x** 🧪 preview | UnrealBuildTool + editor commandlet | Automation tests | Editor command (Python) | `unreal_bridge.py` |
| **S&box** 🧪 preview | `dotnet build` | Runtime tests | Editor bridge | `sbox_bridge.py` |

Unity는 검증된 경로로, tykit의 인프로세스 HTTP 서버(밀리초 응답)를 통해 매일 사용된다. Godot, Unreal, S&box는 **실험적 스캐폴드**로 출시된다: 어댑터 코드, 브리지 표면, CI 스모크 테스트가 모두 갖춰져 있지만, Unity 외의 어떤 어댑터로도 실제 게임을 만든 사람이 아직 없다. 프로덕션 준비된 경로가 아닌, 기여자를 위한 출발점으로 취급하라 — [CONTRIBUTING.md](../../CONTRIBUTING.md) 참조.

## 설치

### 요구사항

- macOS 또는 Windows (Windows는 bash와 코어 유틸리티를 위해 [Git for Windows](https://gitforwindows.org/) 필요)
- 엔진: Unity 2021.3+ / Godot 4.x / Unreal 5.x / S&box
- `python3` (필수), `jq` (권장 ―― hook 스크립트는 jq가 없으면 python3로 폴백)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (전체 스킬 + 훅 경험)
- [Codex CLI](https://github.com/openai/codex) (선택 ―― 크로스 모델 리뷰 활성화)

### 런타임 설치

모든 에이전트가 같은 런타임 설치를 공유한다. 엔진을 자동 감지하고 스크립트, 브리지, 설정을 프로젝트에 작성한다.

```bash
git clone https://github.com/tykisgod/quick-question.git /tmp/qq
/tmp/qq/install.sh /path/to/your-project          # 엔진 자동 감지
/tmp/qq/install.sh --wizard /path/to/your-project  # 대화형 마법사
/tmp/qq/install.sh --preset quickstart /path/to/your-project  # 원샷 프리셋
rm -rf /tmp/qq
```

사용 가능한 프리셋: `quickstart`(최소 구성), `daily`(권장), `stabilize`(릴리스 준비를 위한 전체 검사). 세밀한 제어는 `--profile`, `--modules`, `--without` 참조.

### 에이전트 연결

| 에이전트 | 설정 | 얻는 것 |
|----------|------|---------|
| **Claude Code** | `/plugin marketplace add tykisgod/quick-question`<br>`/plugin install qq@quick-question-marketplace` | 27개 `/qq:*` 슬래시 커맨드 전체, 자동 컴파일 훅, 리뷰 게이트, MCP ―― 전체 경험 |
| **Codex CLI** | `python3 ./scripts/qq-codex-mcp.py install --pretty` | 프로젝트 로컬 MCP 브리지; 작업 루트를 고정하려면 `qq-codex-exec.py` 사용 |
| **Cursor / Continue / 기타 MCP 호스트** | 호스트 설정의 `mcpServers`에 `qq` 추가: `command: python3`, `args: ["./scripts/qq_mcp.py"]`, `cwd: /path/to/project` | 컴파일, 테스트, 콘솔, 에디터 제어를 MCP 도구로 노출 ―― [`docs/en/tykit-mcp.md`](../en/tykit-mcp.md) 참조 |
| **모든 HTTP 클라이언트** | `Temp/tykit.json`에서 포트를 읽고 `localhost:$PORT/`로 JSON POST | tykit 직접 액세스 ―― [`docs/en/tykit-api.md`](../en/tykit-api.md) 참조 |

비-Unity 엔진의 경우 브리지 스크립트를 직접 호출(예: `python3 ./scripts/godot_bridge.py compile`).

## 빠른 시작

```bash
/qq:go                                       # 단계 감지, 다음 단계 추천
/qq:design "inventory with drag-and-drop"    # 디자인 문서 작성
/qq:plan                                     # 구현 계획 생성
/qq:execute                                  # 구현 ―― 편집마다 자동 컴파일
/qq:test                                     # 테스트 실행, 런타임 에러 표시
/qq:commit-push                              # 일괄 커밋 및 푸시
```

`/qq:go`는 `work_mode`에 맞춰 적응한다. `prototype`에서는 가볍게 유지(컴파일 그린, 플레이 가능 상태 유지). `hardening`에서는 배포 전에 테스트, 리뷰, 문서/코드 일관성을 강제한다. 자세한 시나리오는 [Getting Started](../en/getting-started.md) 참조.

## 커맨드

### 워크플로우

| 커맨드 | 설명 |
|--------|------|
| `/qq:go` | 워크플로우 단계 감지, 다음 단계 추천 |
| `/qq:bootstrap` | 게임 비전을 epics로 분해, 전체 파이프라인 오케스트레이션 |
| `/qq:design` | 게임 디자인 문서 작성 |
| `/qq:plan` | 기술 구현 계획 생성 |
| `/qq:execute` | 자동 컴파일 검증이 포함된 스마트 구현 |

### 테스트

| 커맨드 | 설명 |
|--------|------|
| `/qq:add-tests` | EditMode, PlayMode 또는 리그레션 테스트 작성 |
| `/qq:test` | 테스트 실행 및 런타임 에러 확인 |

### 코드 리뷰

| 커맨드 | 설명 |
|--------|------|
| `/qq:codex-code-review` | 크로스 모델: Codex가 리뷰하고 Claude가 검증 (최대 5라운드) |
| `/qq:codex-plan-review` | 크로스 모델 계획/설계 리뷰 |
| `/qq:claude-code-review` | Claude 단독 심층 코드 리뷰 (자동 수정 루프 포함) |
| `/qq:claude-plan-review` | Claude 단독 계획/설계 리뷰 |
| `/qq:best-practice` | 안티패턴 및 성능 이슈 빠른 스캔 |
| `/qq:self-review` | 최근 스킬/설정 변경 리뷰 |
| `/qq:post-design-review` | 구현자 관점에서 디자인 문서 리뷰 ―― 일관성, 빌드 가능성, 코드베이스 갭 확인 |

### 분석

| 커맨드 | 설명 |
|--------|------|
| `/qq:brief` | 아키텍처 다이어그램 + base 브랜치 대비 PR 리뷰 체크리스트 |
| `/qq:timeline` | 커밋 이력을 의미 단위 단계로 그룹화 |
| `/qq:full-brief` | brief + timeline 병렬 실행 |
| `/qq:deps` | `.asmdef` 의존성 분석 (Mermaid 그래프 + 매트릭스) |
| `/qq:doc-drift` | 설계 문서와 실제 코드 비교 |

### 유틸리티

| 커맨드 | 설명 |
|--------|------|
| `/qq:commit-push` | 일괄 커밋 및 푸시 |
| `/qq:explain` | 모듈 아키텍처를 쉬운 말로 설명 |
| `/qq:grandma` | 일상적인 비유로 개념 설명 |
| `/qq:tech-research` | 오픈소스 커뮤니티에서 기술 솔루션 검색 |
| `/qq:design-research` | 게임 디자인 레퍼런스 및 패턴 검색 |
| `/qq:changes` | 현재 세션의 모든 변경 사항 요약 |
| `/qq:doc-tidy` | 문서 정리 스캔 및 추천 |

## 작업 모드

| 모드 | 시기 | 필수 | 보통 생략 |
|------|------|------|-----------|
| `prototype` | 새 메카닉, 그레이박스, 재미 확인 | 컴파일 그린 유지, 플레이 가능 상태 유지 | 정식 문서, 전체 리뷰 |
| `feature` | 유지할 시스템 구축 | 설계, 계획, 컴파일, 타겟 테스트 | 매 변경마다 전체 리그레션 |
| `fix` | 버그 수정, 리그레션 복구 | 먼저 재현, 최소한의 안전한 수정 | 대규모 리팩토링 |
| `hardening` | 위험한 리팩토링, 릴리스 준비 | 테스트, 리뷰, 문서/코드 일관성 | 프로토타입 지름길 |

공유 기본값은 `qq.yaml`에서 설정한다. 워크트리별 오버라이드는 `.qq/local.yaml`에서. `work_mode`와 `policy_profile`은 독립적이다: 전자는 "이 작업이 어떤 종류인가?"에 답하고, 후자는 "이 프로젝트가 얼마나 많은 검증을 기대하는가?"에 답한다. 프로토타입과 하드닝 패스가 같은 정책 프로필을 공유할 수도 있고, 아닐 수도 있다. 전체 레퍼런스는 [Configuration](../en/configuration.md) 참조.

## 설정

프로젝트에서 qq의 동작을 제어하는 세 가지 파일:

- **`qq.yaml`** ―― 런타임 설정: `work_mode`, `policy_profile`, `trust_level`, 모듈 선택. 내장 프로필: `lightweight`, `core`, `feature`, `hardening`. [`templates/qq.yaml.example`](../../templates/qq.yaml.example) 참조.
- **`CLAUDE.md`** ―― 프로젝트에 범위가 지정된 코딩 표준 및 컴파일 검증 규칙. [`templates/CLAUDE.md.example`](../../templates/CLAUDE.md.example) 참조.
- **`AGENTS.md`** ―― 서브에이전트 워크플로우를 위한 아키텍처 규칙 및 리뷰 기준. [`templates/AGENTS.md.example`](../../templates/AGENTS.md.example) 참조.

## tykit

tykit (현재 **v0.5.0**)은 Unity Editor 프로세스 내부의 경량 HTTP 서버다 ―― 설정 불필요, 외부 의존성 없음, 밀리초 응답. localhost를 통해 60+ 커맨드를 노출한다: 컴파일/테스트, 콘솔, 씬/계층, GameObject 라이프사이클, **리플렉션**(`call-method` / `get-field` / `set-field` ―― 사전 스캐폴딩 없이 임의의 컴포넌트 메서드 호출 가능), 프리팹 편집, **물리 쿼리**(raycast, overlap-sphere), 에셋 관리, UI 자동화, 에디터 제어 등. 포트는 프로젝트 경로 해시에서 파생되며 `Temp/tykit.json`에 저장된다.

```bash
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")
curl -s -X POST http://localhost:$PORT/ -d '{"command":"compile"}' -H 'Content-Type: application/json'
curl -s -X POST http://localhost:$PORT/ -d '{"command":"run-tests","args":{"mode":"editmode"}}' -H 'Content-Type: application/json'
```

**핵심 차별화 요소** (v0.5.0): Unity의 메인 스레드가 모달 다이얼로그 또는 백그라운드 스로틀링된 도메인 리로드로 차단된 경우, tykit의 리스너 스레드 `GET /health`, `GET /focus-unity`, `GET /dismiss-dialog` 엔드포인트는 차단된 메인 스레드에 의존하지 않고도 Unity를 작업 상태로 되돌릴 수 있다. 다른 모든 Unity 브리지는 이 시나리오에서 죽는다 ―― tykit만 복구할 수 있다. 자세한 내용은 [`tykit-api.md`](../en/tykit-api.md)의 메인 스레드 복구 섹션 참조.

tykit은 qq 없이도 단독으로 동작한다 ―― [UPM 패키지](../../packages/com.tyk.tykit/)를 모든 Unity 프로젝트에 추가하기만 하면 된다. HTTP를 보낼 수 있는 에이전트는 직접 사용할 수 있다. MCP 브리지(`tykit_mcp.py`)는 MCP 호환 호스트용으로 래핑한다. [`docs/en/tykit-api.md`](../en/tykit-api.md)와 [`docs/en/tykit-mcp.md`](../en/tykit-mcp.md) 참조.

## FAQ

**Windows에서 동작하나요?**
네. bash, curl, 코어 유틸리티를 위해 [Git for Windows](https://gitforwindows.org/)가 필요합니다. 1.15.x와 1.16.x 시리즈는 Windows 지원을 강화했습니다 ―― LF 줄바꿈 강제, 경로 정규화, Python Store 별칭 감지, hook 스크립트의 jq 폴백.

**Codex CLI가 필요한가요?**
아닙니다. Codex CLI는 크로스 모델 리뷰(`/qq:codex-code-review`)를 활성화하지만, `/qq:claude-code-review`는 Codex 없이도 동작합니다.

**Cursor / Copilot / Codex / 기타 에이전트와 함께 사용할 수 있나요?**
네. 런타임 레이어(tykit, 엔진 브리지, `.qq/` 상태, 스크립트)는 에이전트 무관입니다 ―― HTTP를 보내거나 MCP를 말할 수 있는 모든 도구가 사용할 수 있습니다. 27개의 `/qq:*` 슬래시 커맨드와 자동 컴파일 훅은 Claude Code 전용이지만, 그것들이 호출하는 기반 스크립트는 평범한 shell과 Python입니다. [`docs/dev/agent-integration.md`](../dev/agent-integration.md) 참조.

**컴파일이 실패하면 어떻게 되나요?**
자동 컴파일 훅이 에러 출력을 캡처하여 대화에 표시합니다. 컴파일 게이트는 그 후 컴파일이 복구될 때까지 엔진 소스 파일에 대한 후속 편집을 차단합니다. 에이전트가 에러를 읽고 코드를 수정하면, 훅이 다시 자동으로 컴파일합니다.

**tykit을 quick-question 없이 사용할 수 있나요?**
네. [`packages/com.tyk.tykit/`](../../packages/com.tyk.tykit/)의 UPM 패키지를 프로젝트에 추가하세요. [tykit README](../../packages/com.tyk.tykit/README.md) 참조.

**어떤 Unity 버전을 지원하나요?**
tykit은 Unity 2021.3+가 필요합니다. MCP 대안: [mcp-unity](https://github.com/nicoboss/mcp-unity)는 Unity 6+ 필요, [Unity-MCP](https://github.com/mpiechot/Unity-MCP)는 버전 제한 없음.

## 기여

기여를 환영합니다 ―― [CONTRIBUTING.md](../../CONTRIBUTING.md) 참조.

## 라이선스

MIT ―― [LICENSE](../../LICENSE) 참조.

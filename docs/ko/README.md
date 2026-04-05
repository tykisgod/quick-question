# quick-question

[English](../../README.md) | [中文](../zh-CN/README.md) | [日本語](../ja/README.md) | 한국어

---

## qq란

qq는 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 위에서 동작하는 런타임 레이어로, AI 에이전트에게 게임 개발 주기에 대한 깊은 인식을 부여한다. 모든 작업을 동일하게 처리하는 대신, qq는 새로운 메카닉을 프로토타이핑하는 중인지, 프로덕션 기능을 구축하는 중인지, 리그레션을 수정하는 중인지, 릴리스 준비를 하는 중인지를 파악하고 프로세스 강도를 조절한다. 아티팩트 기반 컨트롤러 `/qq:go`는 `.qq/`의 구조화된 프로젝트 상태, 최근 실행 기록, 설정된 `work_mode`를 읽은 뒤 구체적인 다음 단계를 추천한다.

코드 편집 시마다 qq는 엔진별 훅을 통해 자동 컴파일한다(Unity와 S&box는 `.cs`, Godot는 `.gd`, Unreal은 C++). 테스트 파이프라인을 실행하고, 심층 모델 리뷰 전에 결정적 정책 검사를 강제하며, Claude가 조율하고 Codex가 독립적으로 리뷰하는 크로스 모델 코드 리뷰를 오케스트레이션한다 — 모든 발견 사항은 코드 변경 전에 서브에이전트가 검증한다. 에디터 제어가 내장되어 있다: Unity용 tykit, Godot/Unreal/S&box용 에디터 브리지.

qq는 설계부터 배포까지 전체 워크플로우를 커버하는 23개의 슬래시 커맨드를 제공한다: `/qq:design` → `/qq:plan` → `/qq:execute` → `/qq:test` → `/qq:codex-code-review` → `/qq:commit-push`. 이 접근법은 [AI Coding in Practice: An Indie Developer's Document-First Approach](https://tyksworks.com/posts/ai-coding-workflow-en/)에서 설명한 문서 우선 방법론에 기반한다.

## 주요 기능

- **`/qq:go` — 라이프사이클 인식 라우팅** — 프로젝트 상태, `work_mode`, 실행 이력을 읽고 현재 단계에 맞는 다음 단계를 추천
- **자동 컴파일** — 코드 편집마다 훅 기반 컴파일이 실행됨; `.cs`(Unity/S&box), `.gd`(Godot), C++(Unreal) 지원
- **테스트 파이프라인** — Unity의 EditMode + PlayMode, Godot의 GUT/GdUnit4, Unreal의 Automation, S&box의 런타임 테스트, 구조화된 통과/실패 리포팅
- **구조화된 코드 리뷰** — 크로스 모델(Codex 리뷰, Claude 검증) 또는 Claude 리뷰(`claude -p`로 프로세스 격리, 별도 서브에이전트가 검증); 어느 경우든 수정 적용 전에 소스 대조로 각 발견 사항을 검증
- **에디터 제어** — tykit(Unity용 인프로세스 HTTP 서버) + Godot/Unreal/S&box용 Python 브리지; 수동 설정 불필요
- **작업 모드** — `prototype`, `feature`, `fix`, `hardening` — 각각 적절한 프로세스 강도를 적용하여 프로토타입은 가볍게, 릴리스는 완전한 검증으로
- **런타임 데이터** — `.qq/`의 구조화된 상태가 세션 간 루프 연속성을 제공하고 컨트롤러에 데이터를 공급
- **모듈식 설치** — 엔진 자동 감지 마법사 모드, 원샷 프리셋(`quickstart`/`daily`/`stabilize`), 모듈별 제어

## 지원 엔진

| 엔진 | 컴파일 | 테스트 | 에디터 제어 | 브리지 |
|------|--------|--------|------------|--------|
| **Unity 2021.3+** | tykit / editor trigger / batch | EditMode + PlayMode | tykit HTTP server | `tykit_bridge.py` |
| **Godot 4.x** | headless editor를 통한 GDScript 검사 | GUT / GdUnit4 | Editor addon | `godot_bridge.py` |
| **Unreal 5.x** | UnrealBuildTool + editor commandlet | Automation tests | Editor command (Python) | `unreal_bridge.py` |
| **S&box** | `dotnet build` | Runtime tests | Editor bridge | `sbox_bridge.py` |

Unity가 가장 깊은 통합을 제공한다(tykit은 밀리초 응답 시간의 인프로세스 HTTP 제어를 제공). Godot, Unreal, S&box는 런타임 패리티 상태 — 컴파일, 테스트, 에디터 제어, 구조화된 실행 기록 모두 동작하며 — 지속적으로 개발 중이다.

## 설치

### 요구사항

- macOS 또는 Windows([Git for Windows](https://gitforwindows.org/) 필요; Windows 지원은 미리보기 단계)
- 엔진: Unity 2021.3+ / Godot 4.x / Unreal 5.x / S&box
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- `curl`, `python3`, `jq`
- [Codex CLI](https://github.com/openai/codex) *(선택 — 크로스 모델 리뷰 활성화)*

### 단계

**1. 플러그인 설치**

```
/plugin marketplace add tykisgod/quick-question
/plugin install qq@quick-question-marketplace
```

**2. 프로젝트에 런타임 설치**

```bash
# 엔진 자동 감지 (Unity / Godot / Unreal / S&box)
./install.sh /path/to/your-project

# 또는 대화형 마법사 사용
./install.sh --wizard /path/to/your-project

# 또는 프리셋 선택
./install.sh --preset quickstart /path/to/your-project
```

사용 가능한 프리셋: `quickstart`(최소 구성, 첫 실행에 적합), `daily`(추천 기본값), `stabilize`(릴리스 준비를 위한 전체 검사). 세밀한 제어는 `--profile`, `--modules`, `--without`을 참조.

**3. 에디터를 연다.** Unity에서는 tykit이 자동으로 시작된다. 다른 엔진은 설치 후 출력되는 안내를 따른다.

## 빠른 시작

```bash
# qq가 현재 상태를 파악하도록
/qq:go

# 기능 설계
/qq:design "inventory system with drag-and-drop"

# 구현 계획 생성
/qq:plan

# 계획 실행 — 편집마다 자동 컴파일
/qq:execute

# 테스트 실행
/qq:test
```

qq는 작업 모드에 따라 프로세스 강도를 조절한다. `prototype` 모드에서는 가볍게 유지 — 컴파일 그린, 플레이 가능 상태 유지, 빠르게 진행. `hardening` 모드에서는 배포 전에 테스트와 리뷰를 강제한다. 자세한 시나리오 안내는 [Getting Started](../en/getting-started.md) 참조.

## 커맨드

### 워크플로우

| 커맨드 | 설명 |
|--------|------|
| `/qq:go` | 워크플로우 단계 감지, 다음 단계 추천 |
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
| `/qq:codex-code-review` | 크로스 모델 리뷰: Codex가 리뷰하고 Claude가 검증 (최대 5라운드) |
| `/qq:codex-plan-review` | 크로스 모델 계획/설계 리뷰 |
| `/qq:claude-code-review` | Claude 단독 심층 코드 리뷰 (자동 수정 루프 포함) |
| `/qq:claude-plan-review` | Claude 단독 계획/설계 리뷰 |
| `/qq:best-practice` | 안티패턴 및 성능 이슈 빠른 스캔 |
| `/qq:self-review` | 최근 스킬/설정 변경 리뷰 |

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
| `/qq:tech-research` | 오픈소스 커뮤니티에서 솔루션 검색 |
| `/qq:changes` | 현재 세션의 모든 변경 사항 요약 |
| `/qq:doc-tidy` | 문서 정리 스캔 및 추천 |

## 작업 모드

| 모드 | 시기 | 필수 | 보통 생략 |
|------|------|------|-----------|
| `prototype` | 새 메카닉, 그레이박스, 재미 확인 | 컴파일 그린 유지, 플레이 가능 상태 유지 | 정식 문서, 전체 리뷰 |
| `feature` | 유지할 수 있는 시스템 구축 | 설계, 계획, 컴파일, 타겟 테스트 | 매 변경마다 전체 리그레션 |
| `fix` | 버그 수정, 리그레션 복구 | 먼저 재현, 최소한의 안전한 수정 | 대규모 리팩토링 |
| `hardening` | 위험한 리팩토링, 릴리스 준비 | 테스트, 리뷰, 문서/코드 일관성 | 프로토타입 지름길 |

공유 기본값은 `qq.yaml`에서 설정한다. 워크트리별 오버라이드는 `.qq/local.yaml`에서. `/qq:go`를 입력하면 — 모드를 읽고 추천을 조정한다.

`work_mode`와 `policy_profile`은 별개의 설정이다. `work_mode`는 "이 작업이 어떤 종류인가?"에 답하고, `policy_profile`은 "이 프로젝트가 얼마나 많은 검증을 기대하는가?"에 답한다. 프로토타입과 하드닝 패스가 같은 정책 프로필을 공유할 수도 있고, 아닐 수도 있다 — 독립적이다. 전체 레퍼런스는 [Configuration](../en/configuration.md) 참조.

## 동작 원리

qq는 4계층 런타임으로 동작한다:

```
Edit .cs/.gd file
  → Hook auto-compiles (tykit / editor trigger / batch mode)
    → Result written to .qq/state/
      → /qq:go reads state, recommends next step
```

**훅**은 도구 사용 시 자동으로 실행된다 — 코드 편집 후 컴파일, 스킬 수정 추적, 리뷰 검증 중 편집 차단. **`/qq:go`**는 컨트롤러다: `.qq/state/`에서 프로젝트 상태(`work_mode`, `policy_profile`, 최근 컴파일/테스트 결과)를 읽고 적절한 스킬로 라우팅한다. **엔진 브리지**는 맹목적인 파일 쓰기 대신 검증된 인프로세스 실행을 제공한다. **런타임 데이터** `.qq/`는 모든 레이어에 프로젝트 건강 상태에 대한 공유된 구조화된 뷰를 제공한다.

코드 리뷰는 두 가지 대칭 모드를 제공한다: Codex 리뷰(`code-review.sh` → `codex exec`)와 Claude 리뷰(`claude-review.sh` → `claude -p`). 두 모드 모두 별도의 검증 서브에이전트가 각 발견 사항을 소스와 대조하고 오버엔지니어링 여부를 확인한다 — 클린할 때까지 최대 5라운드.

다이어그램과 레이어 상세는 [Architecture Overview](../dev/architecture/overview.md), 자동 컴파일과 리뷰 게이트 내부 구조는 [Hook System](../en/hooks.md), Codex Tribunal 흐름은 [Cross-Model Review](../en/cross-model-review.md), 병렬 작업 격리는 [Worktrees](../en/worktrees.md) 참조.

## 커스터마이징

프로젝트에서 qq의 동작을 제어하는 세 가지 파일:

- **`qq.yaml`** — 런타임 설정: `work_mode`, `policy_profile`, `trust_level`, 모듈 선택. 내장 프로필: `lightweight`, `core`, `feature`, `hardening`. [`templates/qq.yaml.example`](../../templates/qq.yaml.example) 참조.
- **`CLAUDE.md`** — 프로젝트에 범위가 지정된 코딩 표준 및 컴파일 검증 규칙. [`templates/CLAUDE.md.example`](../../templates/CLAUDE.md.example) 참조.
- **`AGENTS.md`** — 서브에이전트 워크플로우를 위한 아키텍처 규칙 및 리뷰 기준. [`templates/AGENTS.md.example`](../../templates/AGENTS.md.example) 참조.

## tykit

tykit은 Unity Editor 프로세스 내부의 경량 HTTP 서버다 — 설정 불필요, 외부 의존성 없음, 밀리초 응답 시간. localhost를 통해 컴파일, 테스트, 플레이/정지, 콘솔, 인스펙터 명령을 제공한다. 포트는 프로젝트 경로 해시에서 파생되며 `Temp/tykit.json`에 저장된다.

```bash
PORT=$(python3 -c "import json; print(json.load(open('Temp/tykit.json'))['port'])")
curl -s -X POST http://localhost:$PORT/ -d '{"command":"compile"}' -H 'Content-Type: application/json'
curl -s -X POST http://localhost:$PORT/ -d '{"command":"run-tests","args":{"mode":"editmode"}}' -H 'Content-Type: application/json'
```

tykit은 qq 없이도 단독으로 동작한다 — [UPM 패키지](../../packages/com.tyk.tykit/)만 추가하면 된다. MCP 브리지(`tykit_mcp.py`)는 Claude가 아닌 에이전트에서도 사용 가능하다. 전체 API는 [`docs/tykit-api.md`](../en/tykit-api.md), MCP 통합은 [`docs/tykit-mcp.md`](../en/tykit-mcp.md) 참조.

## FAQ

**Windows에서 동작하나요?**
네, 미리보기 상태입니다. [Git for Windows](https://gitforwindows.org/)가 필요합니다(bash, curl 및 핵심 유틸리티 제공).

**Codex CLI가 필요한가요?**
아닙니다. Codex CLI는 크로스 모델 리뷰(`/qq:codex-code-review`)를 활성화하지만, Claude 리뷰 `/qq:claude-code-review`는 Codex 없이도 동작합니다. Claude 리뷰에는 Claude CLI가 필요합니다.

**Cursor/Copilot과 함께 사용할 수 있나요?**
`/qq:*` 스킬은 Claude Code가 필요합니다. tykit은 HTTP를 통해 어떤 도구와도 단독으로 동작하며, MCP 브리지(`tykit_mcp.py`)가 다른 에이전트에 노출합니다.

**컴파일이 실패하면 어떻게 되나요?**
자동 컴파일 훅이 에러 출력을 캡처하여 대화에 표시합니다. Claude가 에러를 읽고 코드를 수정하면, 훅이 다시 자동으로 컴파일합니다.

**tykit을 quick-question 없이 사용할 수 있나요?**
네. [`packages/com.tyk.tykit/`](../../packages/com.tyk.tykit/)의 UPM 패키지를 프로젝트에 추가하세요. [tykit README](../../packages/com.tyk.tykit/README.md) 참조.

**어떤 Unity 버전을 지원하나요?**
tykit은 Unity 2021.3+가 필요합니다. MCP 대안: [mcp-unity](https://github.com/nicoboss/mcp-unity)는 Unity 6+ 필요, [Unity-MCP](https://github.com/mpiechot/Unity-MCP)는 버전 제한 없음.

## 기여

기여를 환영합니다 — [CONTRIBUTING.md](../../CONTRIBUTING.md) 참조.

## 라이선스

MIT — [LICENSE](../../LICENSE) 참조.

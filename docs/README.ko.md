# 한국어

## 기능

**`/qq:go` — 라이프사이클 인식 라우팅.** 개발 주기에서 현재 위치를 감지하고 다음 단계를 제안한다. 설계 문서가 있다면? 계획을 제안. 코드가 작성되었다면? 리뷰를 제안. 테스트가 통과했다면? 배포를 제안.

**tykit — AI가 제어하는 Unity Editor.** Unity Editor 내부의 HTTP 서버. 어떤 AI 에이전트에서든 호출할 수 있다. 컴파일, 테스트 실행, Play Mode 제어, 콘솔 로그 읽기, GameObject 검색 및 검사 — 모두 `curl`로. SDK 불필요, UI 자동화 불필요. qq 없이도 단독으로 동작한다. **[mcp-unity](https://github.com/CoderGamester/mcp-unity)** 및 **[Unity-MCP](https://github.com/IvanMurzak/Unity-MCP)**를 대체 백엔드로도 사용 가능.

추가 기능: `.cs` 편집마다 자동 컴파일, EditMode + PlayMode 테스트 파이프라인, 크로스 모델 코드 리뷰(Claude + Codex + 검증), 전체 개발 라이프사이클을 커버하는 22개 스킬.

## 라이프사이클 파이프라인

```mermaid
flowchart LR
    GO["<b>/qq:go</b>"] --> D["설계"]
    D --> P["계획"]
    P --> E["구현"]
    E --> R["리뷰"]
    R --> T["테스트"]
    T --> S["배포"]

    style GO fill:#4a9eff,color:#fff
```

`/qq:go`를 입력하면 qq가 프로젝트 상태를 읽고 적절한 단계로 라우팅한다. 각 단계가 다음을 제안. `--auto`로 전체 파이프라인을 자동 실행.

## 설치

**사전 요구사항:** macOS + Windows(Windows에서는 [Git for Windows](https://gitforwindows.org/) 필요), Unity 2021.3+, [Claude Code](https://docs.anthropic.com/en/docs/claude-code), curl, python3, jq. [Codex CLI](https://github.com/openai/codex)는 선택(크로스 모델 리뷰용). *Windows 지원은 미리보기 단계입니다 — 앞으로 몇 주에 걸쳐 안정화 예정.*

**1단계 — 플러그인(스킬 + 훅):**
```
/plugin marketplace add tykisgod/quick-question
/plugin install qq@quick-question-marketplace
```

**2단계 — tykit(Unity 패키지):**

> 2단계는 선택사항. 스킬만 사용한다면 불필요 — tykit은 Unity Editor 직접 제어를 추가한다.

```bash
git clone https://github.com/tykisgod/quick-question.git /tmp/qq-install
/tmp/qq-install/install.sh /path/to/your-unity-project
rm -rf /tmp/qq-install
```

## 빠른 시작

```bash
/qq:go                  # 지금 어디? 다음에 뭘 해야 하지?
/qq:go "add health system"   # 아이디어에서 시작
/qq:go --auto design.md      # 전체 파이프라인 자동 실행
```

또는 아무 스킬이나 직접 사용:
```bash
/qq:test                      # 테스트 실행
/qq:best-practice             # 18개 규칙 빠른 점검
/qq:codex-code-review         # 크로스 모델 리뷰
/qq:commit-push               # 배포
```

## MCP 지원

qq는 타사 MCP Unity 서버를 tykit의 대안으로 지원합니다:

- **[mcp-unity](https://github.com/CoderGamester/mcp-unity)** — Node.js + WebSocket 브리지 (Unity 6+ 필요)
- **[Unity-MCP](https://github.com/IvanMurzak/Unity-MCP)** — 독립 서버, Docker/원격 지원

Claude Code에 MCP 서버가 설정되어 있으면, qq skill이 자동으로 MCP 도구를 컴파일, 테스트, 콘솔 접근에 우선 사용합니다. 추가 설정 불필요 — Claude가 런타임에 사용 가능한 MCP 도구를 감지합니다.

**호환성:** mcp-unity는 Unity 6+ 필요. Unity-MCP는 버전 제한 없음. qq 자체는 Unity 2021.3+ 지원.

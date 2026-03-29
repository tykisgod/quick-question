# MCP Backend Support Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let qq skills auto-detect and use MCP-based Unity control servers (mcp-unity, Unity-MCP) as alternatives to tykit.

**Architecture:** Single detection layer at the Claude reasoning level — CLAUDE.md template and skill prompts include a capability mapping table so Claude resolves the correct MCP tool at runtime. No hook or script changes. tykit remains the zero-dependency fallback.

**Tech Stack:** Markdown (CLAUDE.md template, SKILL.md, README.md). No code changes.

**Spec:** `docs/superpowers/specs/2026-03-29-mcp-backend-support-design.md`

---

### Task 1: Update CLAUDE.md template — Compile Verification + MCP Backend section

**Files:**
- Modify: `templates/CLAUDE.md.example`

- [ ] **Step 1: Revise the "Compile Verification (Required)" section**

Replace the current `## Compile Verification (Required)` section with an MCP-aware version:

```markdown
## Compile Verification (Required)

After every .cs file change, **must** verify compilation passes before reporting "done":
- If you have MCP compile tools available (`recompile_scripts` from mcp-unity, or `assets-refresh` from Unity-MCP), call them directly.
- Otherwise, use `./scripts/unity-compile-smart.sh --timeout 15`
- If compilation fails, analyze the error, fix it, and recompile until it passes
- Do not skip this step
```

- [ ] **Step 2: Add "MCP Backend (Optional)" section after the tykit section**

Insert after the closing triple-backtick of the tykit "Common Commands" code block (the last ``` before end of file):

```markdown
## MCP Backend (Optional)

If you have an MCP Unity server configured (mcp-unity or Unity-MCP), qq skills will prefer MCP tools over tykit for Unity operations. tykit installation is optional when using an MCP backend.

**Compatibility:** mcp-unity requires Unity 6+. Unity-MCP has no specific version requirement.

### Capability Mapping

| Capability | tykit (curl) | mcp-unity | Unity-MCP |
|-----------|-------------|-----------|-----------|
| Compile | `compile` | `recompile_scripts` | `assets-refresh` |
| Run tests | `run-tests` | `run_tests` | `tests-run` |
| Read console | `console` | `get_console_logs` | `console-get-logs` |
| Clear console | `clear-console` | *(not available)* | *(not available)* |

When MCP tools are available, use them directly instead of curl/tykit commands. When no MCP tools are detected, the tykit workflow applies as documented above.
```

- [ ] **Step 3: Verify the template reads correctly end to end**

Read `templates/CLAUDE.md.example` and confirm:
- No contradictory instructions between Compile Verification and MCP Backend sections
- tykit section is still present and unmodified (except the Compile Verification change)

- [ ] **Step 4: Commit**

```bash
git add templates/CLAUDE.md.example
git commit -m "feat: add MCP backend support to CLAUDE.md template"
```

---

### Task 2: Update test skill for MCP backends

**Files:**
- Modify: `skills/test/SKILL.md`

- [ ] **Step 1: Add MCP note to the EvalServer block at the top**

Replace the current `> **EvalServer:**` blockquote with:

```markdown
> **Unity Backend:** This skill supports multiple backends. If MCP tools are available (`run_tests` from mcp-unity, or `tests-run` from Unity-MCP), use them instead of the tykit/script commands below. If no MCP tools are available, use tykit's EvalServer as documented here. To discover tykit commands: `curl -s -X POST http://localhost:$PORT/ -d '{"command":"commands"}' -H 'Content-Type: application/json'` where PORT comes from `Temp/eval_server.json`.
```

- [ ] **Step 2: Add MCP note to Step 1 (Clear Console)**

After the closing triple-backtick of the clear-console bash code block (after the `fi` / ``` line), add:

```markdown
> **MCP backends:** Skip this step — neither mcp-unity nor Unity-MCP has a console-clear equivalent. Runtime error checking (Step 3) uses Editor.log directly and does not depend on console state.
```

- [ ] **Step 3: Add MCP note to Step 2 (Run tests)**

After the bullet "On failure, analyze the cause..." (last bullet before `### 3. Check runtime errors`), add:

```markdown
> **MCP backends:** Use `run_tests` (mcp-unity) or `tests-run` (Unity-MCP) instead of the scripts above. Pass mode, filter, assembly, and timeout as tool parameters. When no mode argument is given, preserve the sequencing: run EditMode first, check the result, and only proceed to PlayMode if EditMode passes. On failure, apply the same analysis as below.
```

- [ ] **Step 4: Verify the skill reads correctly**

Read `skills/test/SKILL.md` and confirm:
- MCP notes are clearly marked and non-disruptive to the main flow
- The existing tykit/script path is still the default
- No contradictions

- [ ] **Step 5: Commit**

```bash
git add skills/test/SKILL.md
git commit -m "feat: add MCP backend notes to test skill"
```

---

### Task 3: Add MCP Support section to README (English)

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add MCP Support section after FAQ, before Limitations**

Insert before the `## Limitations` heading in the English section:

```markdown
## MCP Support

qq works with third-party MCP servers for Unity as alternatives to tykit:

- **[mcp-unity](https://github.com/CoderGamester/mcp-unity)** — Node.js + WebSocket bridge (requires Unity 6+)
- **[Unity-MCP](https://github.com/IvanMurzak/Unity-MCP)** — standalone server, supports Docker/remote

If an MCP server is configured in Claude Code, qq skills automatically prefer MCP tools for compilation, testing, and console access. No configuration needed — Claude detects available MCP tools at runtime.

**tykit becomes optional** when using an MCP backend. The auto-compile hook still runs as a fallback, but MCP tools take priority when available.

**Compatibility:** mcp-unity requires Unity 6+. Unity-MCP has no specific version requirement. qq itself targets Unity 2021.3+.

| Capability | tykit | mcp-unity | Unity-MCP |
|-----------|-------|-----------|-----------|
| Compile | `compile` | `recompile_scripts` | `assets-refresh` |
| Run tests | `run-tests` | `run_tests` | `tests-run` |
| Read console | `console` | `get_console_logs` | `console-get-logs` |
| Clear console | `clear-console` | — | — |
```

- [ ] **Step 2: Update FAQ item 3**

Find the FAQ item starting with `**3. Can I use this with Cursor` in the English section and replace it:

```markdown
**3. Can I use this with Cursor / Copilot / other AI tools?**
The skills and hooks require Claude Code. tykit (the HTTP server) works with any tool that can send HTTP requests. If you use an MCP Unity server (mcp-unity or Unity-MCP), qq skills will detect and use it automatically — see [MCP Support](#mcp-support).
```

- [ ] **Step 3: Commit English README changes**

```bash
git add README.md
git commit -m "docs: add MCP Support section to README (English)"
```

---

### Task 4: Add MCP Support section to README (Chinese)

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add MCP 支持 section after 常见问题, before 限制**

Insert before the `## 限制` heading in the Chinese section:

```markdown
## MCP 支持

qq 支持第三方 MCP Unity 服务器作为 tykit 的替代方案：

- **[mcp-unity](https://github.com/CoderGamester/mcp-unity)** — Node.js + WebSocket 桥接（需要 Unity 6+）
- **[Unity-MCP](https://github.com/IvanMurzak/Unity-MCP)** — 独立服务器，支持 Docker/远程部署

如果 Claude Code 中配置了 MCP 服务器，qq skill 会自动优先使用 MCP 工具进行编译、测试和控制台访问。无需额外配置 — Claude 在运行时自动检测可用的 MCP 工具。

**使用 MCP 后端时 tykit 变为可选。** 自动编译 hook 仍作为备选运行，但 MCP 工具在可用时优先。

**兼容性：** mcp-unity 需要 Unity 6+。Unity-MCP 无特定版本要求。qq 本身支持 Unity 2021.3+。

| 能力 | tykit | mcp-unity | Unity-MCP |
|------|-------|-----------|-----------|
| 编译 | `compile` | `recompile_scripts` | `assets-refresh` |
| 运行测试 | `run-tests` | `run_tests` | `tests-run` |
| 读取控制台 | `console` | `get_console_logs` | `console-get-logs` |
| 清除控制台 | `clear-console` | — | — |
```

- [ ] **Step 2: Update Chinese FAQ item 3**

Find the FAQ item starting with `**3. 能和 Cursor` (or similar) in the Chinese section and replace it:

```markdown
**3. 能和 Cursor / Copilot / 其他 AI 工具一起用吗？**
skill 和 hook 需要 Claude Code。tykit（HTTP 服务器）可与任何能发送 HTTP 请求的工具配合使用。如果你使用 MCP Unity 服务器（mcp-unity 或 Unity-MCP），qq skill 会自动检测并使用 — 参见 [MCP 支持](#mcp-支持)。
```

- [ ] **Step 3: Commit Chinese README changes**

```bash
git add README.md
git commit -m "docs: add MCP Support section to README (Chinese)"
```

---

### Task 5: Add MCP Support section to README (Japanese + Korean)

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add MCP サポート section to Japanese section**

The Japanese section is shorter (no FAQ/Limitations subsections like EN/CN). Insert before the `---` divider that precedes the `# 한국어` heading:

```markdown
## MCP サポート

qq はサードパーティの MCP Unity サーバーを tykit の代替として使用できます：

- **[mcp-unity](https://github.com/CoderGamester/mcp-unity)** — Node.js + WebSocket ブリッジ（Unity 6+ 必須）
- **[Unity-MCP](https://github.com/IvanMurzak/Unity-MCP)** — スタンドアロンサーバー、Docker/リモート対応

Claude Code に MCP サーバーが設定されている場合、qq skill は自動的に MCP ツールをコンパイル、テスト、コンソールアクセスに優先使用します。追加設定不要 — Claude が利用可能な MCP ツールをランタイムで検出します。

**互換性：** mcp-unity は Unity 6+ が必要。Unity-MCP にはバージョン制限なし。qq 自体は Unity 2021.3+ をサポート。
```

- [ ] **Step 2: Add MCP 지원 section to Korean section**

Add at the end of the Korean section (end of file):

```markdown
## MCP 지원

qq는 타사 MCP Unity 서버를 tykit의 대안으로 지원합니다:

- **[mcp-unity](https://github.com/CoderGamester/mcp-unity)** — Node.js + WebSocket 브리지 (Unity 6+ 필요)
- **[Unity-MCP](https://github.com/IvanMurzak/Unity-MCP)** — 독립 서버, Docker/원격 지원

Claude Code에 MCP 서버가 설정되어 있으면, qq skill이 자동으로 MCP 도구를 컴파일, 테스트, 콘솔 접근에 우선 사용합니다. 추가 설정 불필요 — Claude가 런타임에 사용 가능한 MCP 도구를 감지합니다.

**호환성:** mcp-unity는 Unity 6+ 필요. Unity-MCP는 버전 제한 없음. qq 자체는 Unity 2021.3+ 지원.
```

- [ ] **Step 3: Commit JP + KR README changes**

```bash
git add README.md
git commit -m "docs: add MCP Support section to README (Japanese + Korean)"
```

---

### Task 6: Run tests + final verification

**Files:** None (verification only)

- [ ] **Step 1: Run test.sh**

```bash
./test.sh
```

Expected: All checks pass. The test validates README skill count, skill presence, JSON validity, etc. No new skills were added, so the count should remain at the current number.

- [ ] **Step 2: Verify no regressions in hooks.json**

```bash
python3 -m json.tool hooks/hooks.json > /dev/null && echo "valid"
```

Expected: `valid`

- [ ] **Step 3: Verify MCP-related content exists in README**

```bash
grep -c "MCP" README.md
```

Expected: multiple matches across all 4 language sections.

- [ ] **Step 4: Final commit if any fixups needed**

Only if previous steps revealed issues that needed fixing.

# MCP Backend Support

## Goal

Let quick-question automatically detect and use MCP-based Unity control servers (mcp-unity, Unity-MCP) as alternatives to tykit. tykit remains the zero-dependency fallback.

## Context

Two major open-source MCP servers exist for Unity:

- **mcp-unity** (CoderGamester, ~1500 stars) — Node.js + WebSocket bridge, requires Unity 6+
- **Unity-MCP** (IvanMurzak, 100+ tools) — standalone server binary, supports Docker/remote

Both already work with Claude Code as MCP servers. The problem: quick-question's auto-compile hook and test skill only know how to talk to tykit via curl. Users who have mcp-unity or Unity-MCP installed get no benefit from quick-question's automation layer.

## Design

### Capability Mapping

| Capability | tykit (curl) | mcp-unity (CoderGamester) | Unity-MCP (IvanMurzak) |
|-----------|-------------|--------------------------|----------------------|
| Compile | `compile` | `recompile_scripts` | `script-execute` |
| Run tests | `run-tests` | `run_tests` | `tests-run` |
| Read console | `console` | `get_console_logs` | `console-get-logs` |
| Clear console | `clear-console` | `send_console_log` (clear) | *(not available — skip)* |

This table is the single source of truth. It gets embedded in the CLAUDE.md template so Claude can resolve the correct tool name at runtime.

### Detection Strategy

**Single layer: CLAUDE.md template + skill prompts.**

No hook-level MCP detection. The auto-compile hook (`unity-compile-smart.sh`) stays unchanged — it tries tykit → osascript → batch mode as before. The `|| true` in hooks.json means if all tiers fail (e.g., MCP-only user without tykit), the hook exits silently.

MCP detection happens at the Claude reasoning layer:

1. The CLAUDE.md template includes the capability mapping table and explicit instructions:
   "If you have MCP tools `recompile_scripts` or `script-execute` available, call them after editing .cs files. Otherwise, the auto-compile hook handles compilation automatically via tykit."
2. Claude knows its own available tools at runtime — no process scanning, no false positives.
3. Skill prompts (test, etc.) include the same MCP-first logic.

**Why no hook-level detection:**
- `unity-compile-smart.sh` is dual-use (called by hooks AND directly by users). Adding hookSpecificOutput makes direct calls emit confusing JSON.
- `pgrep -f "mcp-unity"` has high false-positive risk. A false positive at tier 0 silently skips compilation — worse than a false negative.
- Claude already knows which MCP tools it has. Duplicating that knowledge in bash adds complexity for no gain.

**Worst case for MCP-only users (no tykit):**
The auto-compile hook tries tykit (fails in ~1s), tries osascript (fails or succeeds depending on Editor state), falls through. Meanwhile Claude follows CLAUDE.md instructions and calls MCP compile. The hook's failure is harmless (`|| true`), and the MCP call handles compilation. Redundant but correct.

### Changes

#### 1. `templates/CLAUDE.md.example`

Add a "MCP Backend" section containing:
- The capability mapping table (all 4 rows)
- Instruction: "If you have MCP tools `recompile_scripts` or `script-execute` available, call them after editing .cs files. Otherwise, the auto-compile hook handles compilation automatically via tykit."
- Note: tykit installation is optional when using an MCP backend

#### 2. `skills/test/SKILL.md`

Update the test execution section to cover MCP for each step:
- Step 1 (clear console): if MCP `send_console_log` (clear) or `console-get-logs` available, use it; if not, skip (non-critical)
- Step 2 (run tests): if MCP `run_tests` or `tests-run` available, use it instead of `unity-test.sh`
- Step 3 (check runtime errors): no change — reads `Editor.log` directly via file, MCP-independent

#### 3. README.md (all 4 languages)

Add a "MCP Support" section explaining:
- quick-question works with mcp-unity and Unity-MCP out of the box
- If an MCP server is configured in Claude Code, qq skills use MCP tools for compile/test/console
- tykit installation becomes optional when using an MCP backend
- Link to both MCP projects

#### 4. `scripts/unity-compile-smart.sh`

No changes. The existing tier system (tykit → osascript → batch) remains as the fallback path for users without MCP.

### What Does NOT Change

- tykit package — untouched, remains zero-dependency option
- 21 of 22 skills — only `test` is updated; others don't call Unity Editor directly
- Hook architecture — same PreToolUse/PostToolUse/Stop structure, same hook scripts
- `unity-compile-smart.sh` — no modifications
- Review gate, lifecycle routing — pure Claude Code layer, MCP-independent
- install.sh — still installs tykit; users can choose not to use it

### Risks

- **MCP tool names may change.** Both projects are pre-1.0. Mitigation: the mapping table lives in CLAUDE.md template (user-editable), not hardcoded in scripts. Users can update it when upstream renames tools.
- **Claude may not reliably follow the CLAUDE.md instruction.** Mitigation: the instruction is explicit with exact tool names, not a vague "check for compile tools." Skill prompts reinforce the same logic at point of use.
- **Auto-compile hook wastes ~1s on tykit check for MCP-only users.** Acceptable — the hook's `|| true` means no breakage, and compilation happens via MCP regardless.

### Implementation ordering note

If the Windows support spec lands first, the CLAUDE.md template and test skill changes here must account for the platform abstraction layer introduced by that spec. If this spec lands first, the Windows spec should preserve the MCP capability mapping in the template.

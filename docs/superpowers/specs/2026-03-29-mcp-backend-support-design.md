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

Only three Unity operations are called by quick-question's automation:

| Capability | tykit (curl) | mcp-unity (CoderGamester) | Unity-MCP (IvanMurzak) |
|-----------|-------------|--------------------------|----------------------|
| Compile | `compile` | `recompile_scripts` | `script-execute` |
| Run tests | `run-tests` | `run_tests` | `tests-run` |
| Read console | `console` | `get_console_logs` | `console-get-logs` |

This table is the single source of truth. It gets embedded in the CLAUDE.md template so Claude can resolve the correct tool name at runtime.

### Detection Strategy

Two layers, both active simultaneously:

**Layer 1 — Hook script (`unity-compile-smart.sh`)**

Add tier 0 before the existing tykit check:

```
tier 0: MCP server process detected → skip compilation, output hookSpecificOutput
         advising Claude to call the MCP compile tool
tier 1: tykit reachable → curl compile
tier 2: Editor open → osascript trigger
tier 3: batch mode
```

Detection: `pgrep -f "mcp-unity"` or `pgrep -f "unity-mcp-server"`. Lightweight, no I/O.

When tier 0 triggers, the hook outputs:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[MCP detected] Auto-compile skipped. Use MCP compile tool (recompile_scripts or script-execute) to compile."
  }
}
```

This tells Claude what to do without the hook needing to invoke MCP itself.

**Layer 2 — CLAUDE.md template + skill prompts**

The CLAUDE.md template includes the capability mapping table and this instruction:

> After editing .cs files, check your available tools for MCP compile capabilities
> (recompile_scripts, script-execute). If available, call it. If not, the auto-compile
> hook handles it via tykit.

This covers the case where the hook skips but Claude still needs to act.

### Changes

#### 1. `scripts/unity-compile-smart.sh`

Add MCP detection as tier 0, before the tykit check. If an MCP server process is detected, exit 0 with a hookSpecificOutput JSON hint. No other tiers change.

#### 2. `templates/CLAUDE.md.example`

Add a "MCP Backend" section containing:
- The capability mapping table
- Instructions for Claude to prefer MCP tools when available
- Fallback behavior: if no MCP tools detected, tykit/hook handles everything automatically

#### 3. `skills/test/SKILL.md`

Add a paragraph at the top of the test execution section:

> If MCP test tools are available (run_tests from mcp-unity, or tests-run from
> Unity-MCP), use them instead of the unity-test.sh script. Pass the same
> parameters (test mode, filter) to the MCP tool.

#### 4. README.md (all 4 languages)

Add a "MCP Support" section under the installation/setup area explaining:
- quick-question works with mcp-unity and Unity-MCP out of the box
- Auto-detection: if an MCP server is running, qq uses it; otherwise falls back to tykit
- tykit installation becomes optional when using an MCP backend
- Link to both MCP projects

### What Does NOT Change

- tykit package — untouched, remains zero-dependency option
- 19 of 22 skills — they don't call Unity Editor directly
- Hook architecture — same PreToolUse/PostToolUse/Stop structure
- Review gate, lifecycle routing — pure Claude Code layer, MCP-independent
- install.sh — still installs tykit; users can choose not to use it

### Risks

- **Process detection is fragile.** `pgrep -f "mcp-unity"` may match unrelated processes or miss renamed binaries. Mitigation: also check for MCP-specific port files or lock files if available. Keep detection best-effort — false negative just means tykit handles it.
- **MCP tool names may change.** Both projects are pre-1.0. Mitigation: the mapping table is in CLAUDE.md template (user-editable), not hardcoded in scripts. Users can update it.
- **Claude may not reliably follow the CLAUDE.md instruction.** Mitigation: the hook hint (layer 1) provides immediate context at the point of action, not just background instructions.

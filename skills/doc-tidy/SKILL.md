---
description: "Scan the repo for scattered documentation files, analyze organization issues, and output cleanup recommendations. Analysis only — no changes made."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Scan the repo for scattered documentation files, analyze organization issues, and output cleanup recommendations. Analysis only — no changes made.

## Execution Steps

### 1. Full Scan

Dispatch 3 parallel Explore subagents (model: haiku) to collect a documentation inventory:

**Subagent A — Root + Docs/**
- All .md files in root directory (except CLAUDE.md, AGENTS.md)
- All files and directory structure under Docs/ (recursive)
- For each file: path, first line content, line count

**Subagent B — In-code documentation under Assets/**
- All .md files under Assets/ (recursive)
- Including README, ARCHITECTURE, API_REFERENCE, CHANGELOG, AGENTS.md, etc.
- For each file: path, first line content, line count

**Subagent C — Config & tool documentation**
- .claude/ directory structure
- Documentation under scripts/
- Templates under .github/
- Root config files (.mcp.json, opencode.json, etc.)

### 2. Classify

Categorize all documents by:

| Category | Description |
|----------|-------------|
| **Long-term design** | System architecture, module design, data config (should be centrally managed) |
| **In-code docs** | README, API reference, dev guides (should live with the code) |
| **Branch artifacts** | Review outputs, spec files, timelines (should be archived after merge) |
| **Temporary files** | tmp-*, one-off bug reports, old prompts (should be cleaned or archived) |
| **Project entry points** | CLAUDE.md, AGENTS.md, PR templates (should stay in root) |
| **Tool config** | Skills, hooks, script docs (each has its place, don't move) |

### 3. Find Issues

Check and report:

- **Root pollution**: files in root that shouldn't be there
- **Unorganized accumulation**: directories with >10 files and no subdirectory structure
- **Temporal mixing**: long-term docs and temporary artifacts in the same directory
- **Duplicate docs**: files with highly similar names or content across directories
- **Orphaned docs**: documents referencing deleted modules or outdated code
- **Missing docs**: Service modules with code but no documentation at all

### 4. Output Cleanup Plan

Format:

```
## Current State Summary
- X documentation files across Y locations
- Main issues: 1, 2, 3 (one sentence each)

## Issue List
For each issue: location, description, number of files affected

## Recommended Plan
### Target Directory Structure
(tree diagram)

### Specific Actions
Priority ordered:
1. Delete (temporary files, confirmed unused)
2. Move (archive, categorize)
3. Merge (eliminate duplicates)
4. Fill gaps (important modules missing docs — flag but don't rush)

### Leave Alone
Explicitly list locations that are well-organized and need no changes
```

## Important Notes

- **Analysis only — do not execute** — output the plan and wait for user confirmation
- **Do not touch design docs synced from external sources** (e.g., Notion exports) — their structure is managed externally
- **Do not touch skill files** — they are not ordinary documentation
- **Do not touch in-code READMEs** — unless duplicates are found, keep them in place
- **For docs where staleness is uncertain**, mark as "needs confirmation" rather than suggesting deletion

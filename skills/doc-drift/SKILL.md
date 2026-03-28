---
description: "Compare design documents against actual code/config, find inconsistencies, and output a prioritized attention list."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Compare design documents against actual code/configuration, find inconsistencies, and output a prioritized attention list.

Arguments: $ARGUMENTS
- No arguments: scan all modules
- `--module <name>`: only check the specified module

## Execution Flow

### 1. Determine Scope

Discover the project's documentation and code structure:
- Look for design docs in `Docs/`, `Documentation/`, or any directory referenced in `CLAUDE.md`
- Look for code modules under `Assets/Scripts/`, `Assets/Plugins/`, `src/`, or the project's main code directories
- Group related docs and code into module pairs (e.g., "Player" docs ↔ Player code directory)

If the user specified `--module`, only scan that module. Otherwise, group all discovered modules and dispatch parallel subagents (`subagent_type: "general-purpose"`, `model: "opus"`) — one per group (max 5 groups).

### 2. Each Subagent's Task

Each subagent prompt must include:
1. The doc paths and code paths for its assigned modules
2. The following review instructions:

```
You are a document-code consistency auditor. Read all rules, states, enums, and numeric parameters defined in the design documents, then search for corresponding implementations in the code and verify each one.

Focus on:
- Features defined in docs but not implemented in code (entire subsystems or individual features)
- Features implemented in code but not mentioned in docs
- Numeric parameter mismatches (doc value vs code value, with exact numbers)
- Enum value / state name mismatches
- Formula inconsistencies (doc formula vs actual code calculation)
- Architectural model deviations (doc uses model A, code uses model B)

For each inconsistency output:
- Location: doc path vs code path (with line numbers)
- What's inconsistent: what the doc says vs what the code does
- Severity: P0 (missing feature / bug / core formula error), P1 (value deviation / naming mismatch / architecture difference), P2 (outdated doc but no functional impact)

End with a summary table.
```

### 3. Aggregate Output

After all subagents return, consolidate into:

```
## Global Summary
| Module | P0 | P1 | P2 |

## P0 List (by category)
### A. Missing Subsystems (doc has full design, code has nothing)
### B. Functional Bugs
### C. Critical Formula/Value Deviations
### D. Architecture Model Mismatches
### E. Status Effects Not Wired Up

## Overall Assessment
Distinguish "not yet built" from "built wrong", and highlight items needing immediate attention.
```

## Notes

- Design docs represent the vision, code represents reality — many "missing" items may be normal for phased development, don't mark everything as P0
- Distinguish three situations: **outdated docs** (code is correct, docs need updating), **missing features** (docs are correct, code not yet built), **actual bugs** (code behavior is clearly wrong)
- Numeric comparisons must include exact numbers, not vague "inconsistent"
- Formula comparisons must show the complete doc formula and code formula

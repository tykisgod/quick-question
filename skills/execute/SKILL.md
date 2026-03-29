---
description: "Smart implementation — read a plan, decide execution strategy (direct write / subagent / agent team), build step by step with auto-compilation."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Smart implementation engine. Reads a plan/design document, breaks it into executable steps, and implements each step — choosing the right execution strategy (direct write, parallel subagents, or sequential pipeline) based on the nature of each step.

Arguments: $ARGUMENTS
- A file path to a plan/design document
- `--auto`: skip all confirmation prompts, make all decisions autonomously
- No arguments: intelligently detect the plan source

## 1. Locate the Plan

Try in priority order:

1. **User specified a file path** → use it
2. **Current conversation has a recently generated/reviewed plan** → use it
3. **Multiple candidates in `Docs/`** → list them, ask the user to pick
4. **Nothing found** → ask the user

Unless `--auto` is passed, confirm with the user: "I found this plan: `<path or summary>`. Proceed?"

## 2. Analyze and Break Down

Read the full plan. Extract an ordered list of implementation steps. For each step, determine:

- **What files** need to be created or modified
- **Dependencies** — does this step depend on output from a previous step?
- **Scope** — how many files/modules are touched?

Present the breakdown to the user (unless `--auto`):

```
Implementation plan: N steps

Step 1: Create IVehicleDamage interface          → direct write (1 file)
Step 2: Implement VehicleDamageSystem            → direct write (1 file, depends on step 1)
Step 3: Add FireEffect + ExplosionEffect         → parallel subagents (2 independent files)
Step 4: Integrate into CollisionHandler          → direct write (1 file, depends on steps 1-3)
Step 5: Unit tests                               → parallel subagents (2 test files)

Proceed?
```

## 3. Execute Step by Step

For each step, choose a strategy:

### Direct Write
**When:** step touches 1-2 files, or depends on the previous step's output.
- Write the code yourself in the main session
- Auto-compilation hook will verify after each .cs file save
- If compilation fails, fix immediately before moving to the next step

### Parallel Subagents
**When:** step involves 2+ independent files/modules with no cross-dependency.
- Dispatch subagents (`subagent_type: "general-purpose"`, `model: "opus"`) in parallel
- Each subagent prompt must include:
  1. The relevant section of the plan
  2. Any interfaces/contracts from previous steps that must be implemented against
  3. Project coding standards: read CLAUDE.md
  4. Architecture rules: read AGENTS.md (if it exists)
  5. Clear output: which files to create/modify, with full implementation
- After all subagents return, apply their changes and verify compilation

### Sequential Pipeline
**When:** step involves multiple files with sequential dependencies (A's interface needed by B, B's output needed by C).
- Execute sub-steps one by one in the main session
- Verify compilation after each sub-step before starting the next

### Agent Team
**When:** step is a large-scale refactor touching 10+ files across multiple modules.
- Break into sub-tasks, assign each to a subagent
- Designate one subagent as the "interface definer" that runs first
- Remaining subagents run in parallel against the defined interfaces
- Merge results, resolve conflicts, verify compilation

## 4. Per-Step Verification

After each step completes:

1. **Compilation** — the auto-compile hook handles this. If it fails, fix before proceeding.
2. **Sanity check** — re-read the plan step, verify the implementation matches intent. If something diverges, note it and continue (don't silently deviate from the plan).

## 5. Completion

After all steps are done:

1. Present a summary: what was implemented, any deviations from the plan, any compilation issues encountered and resolved
2. Hand control back to the user — do NOT auto-trigger review skills

```
✅ Implementation complete — N steps, M files created, K files modified

Deviations from plan:
- (none, or list them)

Next steps (your choice):
- /qq:best-practice — quick rule check
- /qq:claude-code-review — deep review
- /qq:test — run tests
```

## Notes

- Read CLAUDE.md and AGENTS.md before writing any code
- Follow existing project patterns — explore the codebase before creating new files
- Do not add features, abstractions, or "improvements" beyond what the plan specifies
- If the plan is ambiguous or contradictory, ask the user (unless `--auto`, then use best judgment and note the decision)
- Each .cs file save triggers auto-compilation via hook — do not skip or suppress this
- If a step turns out to be significantly more complex than the plan anticipated, pause and inform the user before proceeding

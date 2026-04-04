---
description: "Smart implementation — read a plan, decide execution strategy (direct write / subagent / agent team), build step by step with auto-compilation."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Smart implementation engine. Reads a plan/design document, breaks it into executable steps, and implements each step — choosing the right execution strategy (direct write, parallel subagents, or sequential pipeline) based on the nature of each step.

Arguments: $ARGUMENTS
- A file path to a plan/design document
- `--no-worktree`: skip worktree guard
- `--auto`: skip all confirmation prompts, make all decisions autonomously
- No arguments: intelligently detect the plan source

## 0. Worktree Guard

If already in a worktree (linked worktree or `.claude/worktrees/`), skip this step.

If NOT in a worktree and `--no-worktree` was not passed: create one as a safety net (go should have already done this, but execute may be called directly).
1. Note the current working directory as `SOURCE_PROJECT`.
2. Derive a slug from the plan filename or user intent.
3. Call `EnterWorktree` tool with `name: <slug>`.
4. If `EnterWorktree` is not available, fall back to `qq-worktree.py create --name <slug>`, then tell the user to reopen in the new worktree path and stop.
5. After entering, seed engine runtime cache: `qq-worktree.py seed-runtime-cache --project . --source "<SOURCE_PROJECT>"`

## 1. Locate the Plan

Try in priority order:

1. **User specified a file path** → use it
2. **Current conversation has a recently generated/reviewed plan** → use it
3. **Multiple candidates in `Docs/qq/`** → list them, ask the user to pick
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
Step 5: Targeted tests                           → hand off to `/qq:add-tests` (shared test-authoring step)

Proceed?
```

## 3. Execute Step by Step

For each step, choose a strategy:

### Direct Write
**When:** step touches 1-2 files, or depends on the previous step's output.
**Why:** maximum coherence — you have full awareness of what was just written. No spawn overhead.
- Write the code yourself in the main session
- Auto-compilation hook will verify after each .cs file save
- If compilation fails, fix immediately before moving to the next step

### Parallel Subagents
**When:** step involves 2+ independent files/modules with no cross-dependency.
**Why:** context hygiene is the primary reason, not speed. Each subagent gets a fresh context window — file reads, compilation output, and intermediate reasoning stay isolated. Research shows all LLMs degrade at ~50K tokens (well before the window limit), so offloading work to subagents preserves reasoning quality in the main session for later steps.
- Dispatch subagents (`subagent_type: "general-purpose"`, `model: "opus"`) in parallel
- **You** (the main agent) must read CLAUDE.md, AGENTS.md, and the plan file upfront. Do NOT ask subagents to read these files — pass the content directly in their prompts. This saves tool calls and ensures subagents get exactly the context they need.
- Each subagent prompt must include (as inline text, not file references):
  1. The relevant section of the plan (extract only the current step, not the full plan)
  2. Any interfaces/contracts from previous steps that must be implemented against (paste the actual code)
  3. Project coding standards (paste CLAUDE.md content)
  4. Architecture rules if applicable (paste AGENTS.md content)
  5. Clear output: which files to create/modify, with full implementation
- Assign non-overlapping files to each subagent to avoid merge conflicts
- After all subagents return, apply their changes and verify compilation

### Sequential Pipeline
**When:** step involves multiple files with sequential dependencies (A's interface needed by B, B's output needed by C).
**Why:** each step needs the previous step's output as input — cannot parallelize.
- Execute sub-steps one by one in the main session
- Verify compilation after each sub-step before starting the next
- Consider using a subagent for each sub-step if the chain is long (4+ steps), to prevent context accumulation

### Agent Team
**When:** step is a large-scale refactor touching 10+ files across 3+ independent modules.
**Why:** specialization — each agent operates in focused context on its domain, producing higher quality than a single agent juggling everything. Research shows 3 focused agents consistently outperform 1 generalist working 3x as long.
- Break into sub-tasks, assign each to a subagent with `isolation: "worktree"` for file-system isolation
- Same rule: pass all context inline in prompts, do not ask subagents to read files
- Designate one subagent as the "interface definer" that runs first
- Remaining subagents run in parallel against the defined interfaces (paste the interface code into their prompts)
- Merge results, resolve conflicts, verify compilation
- Token cost: 4-15x a single session — only use when the task justifies it

### Shared Test Authoring
**When:** a plan step is primarily about adding or updating tests, or the implementation clearly needs new regression coverage.
**Why:** keep test authoring explicit and reusable instead of burying it as ad hoc file edits inside every workflow.
- Prefer `/qq:add-tests` over hand-writing test files inline when the work is mainly coverage
- Pass the relevant plan step, code under test, and bug/regression context to that skill
- Resume the remaining implementation steps after the tests are authored

## 4. Per-Step Verification

After each step completes:

1. **Compilation** — the auto-compile hook handles this. If it fails, fix before proceeding.
2. **Sanity check** — re-read the plan step, verify the implementation matches intent. If something diverges, note it and continue (don't silently deviate from the plan).

## 5. Completion

After all steps are done:

1. Present a summary: what was implemented, any deviations from the plan, any compilation issues encountered and resolved
2. Assess the result and recommend the next step:

- **All steps clean, no issues** → "Implementation complete. Want to run `/qq:test` to verify?"
- **Implementation is done but the changed area still needs explicit coverage** → "Implementation is complete. Want to run `/qq:add-tests` before `/qq:test`?"
- **Had compilation issues that were fixed** → "Had some issues during implementation. I'd recommend `/qq:best-practice` to check for problems. Run it?"
- **Complex changes across multiple modules** → "Touched N modules. Recommend `/qq:claude-code-review` for a deep review before testing. Run it?"

**`--auto` mode:** skip asking, take the strictest path automatically:
→ `/qq:best-practice` → fix if needed → `/qq:claude-code-review` → fix if needed → `/qq:add-tests --auto` when the change needs new coverage → `/qq:test`

## Notes

- Read CLAUDE.md and AGENTS.md before writing any code
- When `--worktree` is used, the new linked worktree becomes the only valid implementation root for this run
- Follow existing project patterns — explore the codebase before creating new files
- Do not add features, abstractions, or "improvements" beyond what the plan specifies
- If the plan is ambiguous or contradictory, ask the user (unless `--auto`, then use best judgment and note the decision)
- Each .cs file save triggers auto-compilation via hook — do not skip or suppress this
- If a step turns out to be significantly more complex than the plan anticipated, pause and inform the user before proceeding

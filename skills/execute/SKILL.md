---
description: "Smart implementation — read a plan, decide execution strategy (direct write / subagent / agent team), build step by step with auto-compilation."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Smart implementation engine. Reads a plan/design document, breaks it into executable steps, and implements each step — choosing the right execution strategy (direct write, parallel subagents, or sequential pipeline) based on the nature of each step.

Arguments: $ARGUMENTS
- A file path to a plan/design document
- `--auto`: skip all confirmation prompts, make all decisions autonomously
- `--worktree`: create a git worktree for isolated development (enables parallel sessions)
- No arguments: intelligently detect the plan source

## 1. Worktree Isolation (when `--worktree` is passed)

If `--worktree` is passed, set up an isolated worktree before doing any implementation work. This allows multiple Claude Code sessions to work on different features in parallel, each in its own directory.

### 1a. Detect current branch

Run `git branch --show-current`.

- If on `main` or `master`, warn the user: "You're on the main branch. Create a feature branch first (e.g., `git checkout -b dev/my-feature`), then re-run with `--worktree`." Stop here (unless `--auto`, then create a feature branch from the plan name automatically).
- Otherwise, record the current branch as the **source branch**.

### 1b. Create worktree

Derive a short name from the plan file (e.g., `damage-system.md` → `damage-system`). Then:

```bash
WORKTREE_BRANCH="<source-branch>-wt-<short-name>"
WORKTREE_DIR="../$(basename "$PWD")-wt-<short-name>"
git worktree add "$WORKTREE_DIR" -b "$WORKTREE_BRANCH"
cd "$WORKTREE_DIR"
```

Inform the user:
```
Created worktree: <WORKTREE_DIR>
Branch: <WORKTREE_BRANCH> (from <source-branch>)
⚠ First compilation will regenerate Library/ (~5-10 min). Subsequent compiles are incremental (~15-30s).
Tip: Unity Accelerator on localhost can dramatically speed up Library/ generation.
```

All subsequent steps run inside the worktree directory. Compilation and tests use batch mode (no Unity Editor needed — `unity-compile-smart.sh` falls back to batch mode automatically).

### 1c. Skip worktree

If `--worktree` is not passed, skip this section entirely and proceed as normal in the current working directory.

## 2. Locate the Plan

Try in priority order:

1. **User specified a file path** → use it
2. **Current conversation has a recently generated/reviewed plan** → use it
3. **Multiple candidates in `Docs/qq/`** → list them, ask the user to pick
4. **Nothing found** → ask the user

Unless `--auto` is passed, confirm with the user: "I found this plan: `<path or summary>`. Proceed?"

## 3. Analyze and Break Down

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

## 4. Execute Step by Step

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

## 5. Per-Step Verification

After each step completes:

1. **Compilation** — the auto-compile hook handles this. If it fails, fix before proceeding.
2. **Sanity check** — re-read the plan step, verify the implementation matches intent. If something diverges, note it and continue (don't silently deviate from the plan).

## 6. Completion

After all steps are done:

1. Present a summary: what was implemented, any deviations from the plan, any compilation issues encountered and resolved
2. Assess the result and recommend the next step:

- **All steps clean, no issues** → "Implementation complete. Want to run `/qq:test` to verify?"
- **Had compilation issues that were fixed** → "Had some issues during implementation. I'd recommend `/qq:best-practice` to check for problems. Run it?"
- **Complex changes across multiple modules** → "Touched N modules. Recommend `/qq:claude-code-review` for a deep review before testing. Run it?"

**`--auto` mode:** skip asking, take the strictest path automatically:
→ `/qq:best-practice` → fix if needed → `/qq:claude-code-review` → fix if needed → `/qq:test`

## 7. Worktree Merge-Back (when `--worktree` was used)

If this session is running in a worktree (from step 1), merge the work back after completion:

### 7a. Commit all changes

Ensure all changes in the worktree are committed:
```bash
git add -A
git commit -m "feat: <short description from plan>"
```

### 7b. Merge back to source branch

```bash
cd <original-project-dir>
git merge <WORKTREE_BRANCH>
```

If merge conflicts occur, resolve them and inform the user of what was resolved.

### 7c. Cleanup prompt

Ask the user (unless `--auto`): "Worktree work is merged. Delete the worktree `<WORKTREE_DIR>`? (recommended)"

- **Yes** (default) →
  ```bash
  git worktree remove <WORKTREE_DIR>
  git branch -d <WORKTREE_BRANCH>
  ```
- **No** → leave the worktree in place, inform the user they can remove it later with `git worktree remove <WORKTREE_DIR>`

**`--auto` mode:** always delete the worktree after successful merge.

## Notes

- Read CLAUDE.md and AGENTS.md before writing any code
- Follow existing project patterns — explore the codebase before creating new files
- Do not add features, abstractions, or "improvements" beyond what the plan specifies
- If the plan is ambiguous or contradictory, ask the user (unless `--auto`, then use best judgment and note the decision)
- Each .cs file save triggers auto-compilation via hook — do not skip or suppress this
- If a step turns out to be significantly more complex than the plan anticipated, pause and inform the user before proceeding

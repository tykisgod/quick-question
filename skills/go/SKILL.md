---
description: "Entry point — detect where you are in the dev workflow and guide you to the right next step."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Entry point for the qq development workflow. Detects your current state and guides you to the right skill.

This skill is a **controller**, not an implementation engine. It should read real project state first and only fall back to prompt/context heuristics when the state is ambiguous.

## Hard Rules

- If `./scripts/qq-project-state.py` exists, you **must** run it before inspecting git history, branch divergence, commit counts, or repo-wide document context.
- If `qq-project-state.py` returns valid JSON, treat it as the primary source of truth.
- When project state is available, do **not** summarize branch size, recent commits, or unrelated repo-wide artifacts unless the user explicitly asked for that analysis.
- Keep the answer short and action-oriented:
  - current `work_mode`
  - current `policy_profile`
  - current `recommended_next`
  - one-sentence why
- Do not turn `/qq:go` into a repo audit. It is a router.
- Do NOT explain the pipeline order (design → plan → execute). The user already knows. Just recommend the next step and ask to proceed.

Arguments: $ARGUMENTS
- A file path (design doc, plan, or code file)
- A brief description of what to build
- `--auto`: mode-aware automation, no prompts
- `--no-worktree`: skip automatic worktree creation for this invocation
- No arguments: auto-detect from context

## Worktree Isolation (before routing)

Before routing to any skill, ensure the session is in an isolated worktree. This runs automatically — the user does not need to pass any flags.

**Skip if any of these are true:**
- Already in a worktree (check `git rev-parse --is-inside-work-tree` + `git worktree list` to see if CWD is a linked worktree)
- User passed `--no-worktree`
- The recommended next step is a read-only action (e.g., `/qq:changes`, `/qq:deps`, `/qq:explain`)

**Create worktree:**
1. Note the current working directory as `SOURCE_PROJECT` (needed for seeding later)
2. Derive a slug from the task description (3-4 keywords, lowercase, hyphen-separated, e.g., `demo-loop-closure`)
3. Call `EnterWorktree` tool with `name: <slug>`. This switches session CWD to `.claude/worktrees/<slug>/`
4. If `EnterWorktree` is not available (non-Claude-Code host), fall back to `qq-worktree.py create --name <slug>`, then tell the user to reopen the session in the new worktree path and stop
5. After entering, seed engine runtime cache (Unity Library, etc.):
   ```bash
   "${QQ_PY:-python3}" "<SOURCE_PROJECT>/scripts/qq-worktree.py" seed-runtime-cache --project . --source "<SOURCE_PROJECT>"
   ```
   Note: use the plugin script path if project scripts are not available. The `--source` flag lets this work in non-qq-managed worktrees.

Then continue to State Detection and routing below.

## State Detection

Assess the current situation in this order:

### 1. Did the user provide explicit input?
- **File path to a complete design doc** → "This looks like a design doc. Want to run `/qq:plan` to create an implementation plan?"
- **File path to a rough draft / notes** → "This looks like an incomplete draft. Want to run `/qq:design` to flesh it out into a full design doc?"
- **File path to an implementation plan** → "This is an implementation plan. Want to run `/qq:execute` to start building?"
- **File path to .cs code** → "Want to run `/qq:add-tests` to add targeted coverage for this code, `/qq:best-practice` to inspect it, or `/qq:test` to run existing tests?"
- **A request to add tests / capture a regression** → "Want to run `/qq:add-tests` to author the smallest useful coverage first?"
- **A brief feature description** → route by `work_mode` once state is loaded:
  - `prototype` → "Prototype mode is active. Skip design/plan unless you want them; build directly and keep compile green."
  - `feature` → "Want to start with `/qq:design` to write a game design doc, or skip straight to `/qq:plan` for a technical implementation plan?"
  - `fix` → "This sounds like a bug or regression path. Let's lock down the repro first, then make the smallest fix."
  - `hardening` → "Hardening mode is active. Keep the scope tight and expect test/review/doc-drift before push."

### 2. Read project state

If `./scripts/qq-project-state.py` exists, run it first:

```bash
"${QQ_PY:-python3}" ./scripts/qq-project-state.py --pretty
```

Use that structured state as the primary routing signal.

Interpretation:

- Read `work_mode` first. qq supports four working modes:
  - `prototype` → default light. Skip formal docs unless the user already wrote them.
  - `feature` → normal retainable feature work. Design/plan/review/test are expected.
  - `fix` → reproduce first, then minimal repair + regression verification.
  - `hardening` → stability-sensitive work such as risky refactors or release prep. Expect tests, review, and doc/code consistency checks.
- Then read `policy_profile`. It is not the same thing:
  - `core` → keep the verification floor low.
  - `feature` → expect at least targeted validation before acting like the task is done.
  - `hardening` → even if the task mode is light, expect tests/review/doc-drift before ship-like steps.
- Use `modeRecommendedNext` to understand the raw task-path suggestion.
- Use `recommendedNext` as the actual next step after compile/test blockers and policy-profile pressure are applied.
- Once state is available, answer from it directly. Do not add git/branch/repo-summary noise unless the user asked for that specifically.
- Then interpret `recommended_next`:
  - `/qq:plan` → a design exists; recommend turning it into an implementation plan.
  - `/qq:execute` → a usable implementation plan exists; recommend building.
  - `/qq:best-practice` → feature-mode code exists; run the lightweight review path first.
  - `/qq:add-tests` → author or update targeted regression/EditMode/PlayMode coverage before validation.
  - `/qq:test` → validate the changed area or rerun a failing path before advancing.
  - `/qq:claude-code-review` → hardening-mode code is ready for a heavier review pass.
  - `/qq:doc-drift` → hardening-mode code is ready; check docs match behavior before shipping.
  - `/qq:commit-push` → current mode's required checks are already satisfied.
  - `/qq:changes` → prototype work is compiled; capture keep/drop/observe before moving on.
  - `verify_compile` → do not escalate yet; make sure the latest C# changes actually compiled.
  - `fix_compile` → compile is red; stay here until it is green.
  - `prototype_direct` → prototype mode with no blocking artifacts. Tell the user to build directly, keep compile green, and avoid forcing design/plan.
  - `reproduce_bug` → fix mode with no active patch yet. Tell the user to lock down a repro before changing code.

### 3. Fall back to conversation context only if needed

- **Just finished discussing a new feature idea** → suggest `/qq:design`
- **A design doc was recently written or reviewed** → suggest `/qq:plan`
- **A plan was recently generated or reviewed** → suggest `/qq:execute`
- **Code was recently written or modified** → if the user is asking for coverage, suggest `/qq:add-tests`; otherwise suggest `/qq:best-practice` or `/qq:test`
- **Tests just passed** → suggest `/qq:commit-push`

### 4. Fall back to git state if project state is unavailable

- **Uncommitted .cs changes** → "You have uncommitted C# changes. Want to run `/qq:best-practice` to check them?"
- **Clean working tree, recent commits not pushed** → "You have unpushed commits. Want to run `/qq:test` before pushing?"
- **Clean tree, all pushed** → "Everything looks clean. Describe what you want to build next."

Important: git/branch heuristics are a fallback only. If project state exists, do not do this layer by default.

### 5. Nothing to go on
→ Ask: "What are you working on? You can give me a design doc, a one-liner, or tell me what stage you're at."

## `--auto` Mode

Skip all questions. Read project state first, then choose the lightest valid path for the active `work_mode`:

- `prototype`
  - If a plan already exists → `/qq:execute --auto`
  - If only a design doc exists → `/qq:plan --auto`
  - If there is no artifact yet → do **not** auto-expand into design+plan; tell the user to prototype directly and keep compile green.
- `feature`
  - Has brief description / rough draft → `/qq:design --auto`
  - Has complete design doc → `/qq:plan --auto`
  - Has plan → `/qq:execute --auto`
  - Has compile-green runtime changes but no fresh targeted coverage yet → `/qq:add-tests --auto`
  - Has compile-green targeted coverage ready to validate → `/qq:test --auto`
  - Has passing tests → `/qq:commit-push`
- `fix`
  - Compile red → stay on compile repair
  - If a patch exists but no regression coverage has been added yet → `/qq:add-tests --auto`
  - Otherwise go straight to `/qq:test --auto`
  - Do not invent design docs or broad reviews for a small fix unless the user asks
- `hardening`
  - Prefer `/qq:add-tests --auto` when coverage is still missing, then `/qq:test --auto` → `/qq:claude-code-review --auto` → `/qq:doc-drift --auto` → `/qq:commit-push`

## Notes

- This skill never does work itself — it only routes to the right skill
- Prefer structured project state over conversation heuristics whenever available
- Respect `work_mode` before suggesting process-heavy steps
- Always confirm with the user before invoking a skill (unless `--auto`)
- If ambiguous, ask one clarifying question, not five

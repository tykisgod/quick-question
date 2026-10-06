---
description: "Entry point — detect where you are in the dev workflow and guide you to the right next step."
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `qq-project-state.py` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

This skill is a router: it reads the project state, recommends the next qq skill, and asks the user before invoking it (unless `--auto`). Apart from entering a worktree, it does no work itself.

Arguments: $ARGUMENTS
- A file path (design doc, plan, or code file)
- A brief description of what to build
- `--auto`: mode-aware automation, no prompts
- `--no-worktree`: skip automatic worktree creation for this invocation
- No arguments: auto-detect from context

## Answer

Run `qq-project-state.py` (State Detection §2) before looking at git history, branch divergence, commit counts or repo-wide docs. When it returns valid JSON, it is the source of truth; answer from it, short and action-oriented:
- current `work_mode`
- current `policy_profile`
- current `recommended_next`
- one-sentence why

Don't add branch size, recent commits or unrelated repo-wide artifacts unless the user asked for that analysis, and don't explain the pipeline order (design → plan → execute) — the user knows it. Recommend the next step and ask to proceed. If the request is ambiguous, ask one clarifying question, not five.

## State Detection

Assess the situation in this order.

### 1. Explicit input
- Complete design doc → `/qq:plan`
- Rough draft or notes → `/qq:design` to flesh it out
- Implementation plan → `/qq:execute`
- Code file → `/qq:add-tests` for targeted coverage, `/qq:best-practice` to inspect it, or `/qq:test` to run existing tests
- Request to add tests or capture a regression → `/qq:add-tests`
- Brief feature description → by `work_mode`:
  - `prototype` → build directly and keep compile green; skip design/plan unless the user wants them.
  - `feature` → `/qq:design` for a game design doc, or straight to `/qq:plan` for a technical implementation plan.
  - `fix` → lock down the repro first, then make the smallest fix.
  - `hardening` → keep the scope tight and expect test/review/doc-drift before push.

### 2. Project state

```bash
qq-project-state.py --pretty
```

- `work_mode`:
  - `prototype` → default light. Skip formal docs unless the user already wrote them.
  - `feature` → normal retainable feature work. Design/plan/review/test are expected.
  - `fix` → reproduce first, then minimal repair + regression verification.
  - `hardening` → stability-sensitive work such as risky refactors or release prep. Expect tests, review, and doc/code consistency checks.
- `policy_profile` is a separate axis, the verification floor:
  - `core` → keep the verification floor low.
  - `feature` → expect at least targeted validation before acting like the task is done.
  - `hardening` → even if the task mode is light, expect tests/review/doc-drift before ship-like steps.
- `mode_recommended_next` is the raw task-path suggestion; `recommended_next` is the actual next step after compile/test blockers and policy-profile pressure are applied. Route on `recommended_next`:
  - `/qq:<skill>`, possibly with arguments (`/qq:execute <plan>` resumes an execution in progress) → recommend that skill.
  - `verify_compile` → do not escalate yet; make sure the latest code changes actually compiled.
  - `fix_compile` → compile is red; stay here until it is green.
  - `prototype_direct` / `feature_direct` → nothing to route to. Tell the user to build directly and keep compile green; in prototype mode, don't force design/plan.
  - `reproduce_bug` → fix mode with no active patch yet. Tell the user to lock down a repro before changing code.

### 3. Conversation context (only if the state is ambiguous)
- Just discussed a new feature idea → `/qq:design`
- A design doc was recently written or reviewed → `/qq:plan`
- A plan was recently generated or reviewed → `/qq:execute`
- Code was recently written or modified → `/qq:add-tests` if the user is asking for coverage, otherwise `/qq:best-practice` or `/qq:test`
- Tests just passed → `/qq:commit-push`

### 4. Git state (only if project state is unavailable)
- Uncommitted code changes → `/qq:best-practice`
- Clean tree, unpushed commits → `/qq:test` before pushing
- Clean tree, all pushed → ask what to build next

### 5. Nothing to go on
Ask: "What are you working on? You can give me a design doc, a one-liner, or tell me what stage you're at."

## Worktree

Once the next step is known, and before acting on it (invoking a skill, building directly on `prototype_direct` / `feature_direct` / `reproduce_bug`, or running `pipeline-start` in `--auto`), enter an isolated worktree; the user doesn't need to pass a flag. Skip only when:
- you are already in a linked worktree (`git rev-parse --path-format=absolute --git-dir` differs from `git rev-parse --path-format=absolute --git-common-dir`);
- `$ARGUMENTS` contains the literal `--no-worktree` (pass it on when you invoke `/qq:execute`);
- the next skill is read-only: `/qq:changes`, `/qq:deps`, `/qq:explain`, `/qq:brief`, `/qq:full-brief`, `/qq:timeline`;
- the next step acts on uncommitted changes already in this checkout (anything except `/qq:design`, `/qq:plan`, `/qq:execute`, or building directly): a new worktree would not contain them.

Create it with the procedure in §1 of [`/qq:execute`](../execute/SKILL.md) (skip its step 1 when there is no plan yet), named with 3-4 task keywords (e.g. `demo-loop-closure`). If something seems to block it (untracked plan, dirty tree), resolve it as that section says instead of skipping. State any skip and its reason in your first message.

## `--auto` Mode

Skip all questions. Read project state first, then choose the lightest valid path for the active `work_mode`.

After entering the worktree (see Worktree) and before routing to the first skill, initialize auto-pipeline tracking. The state file belongs to the checkout, and the later `pipeline-advance --project .` calls run in the worktree:
```bash
qq-execute-checkpoint.py pipeline-start --project . --type feature --current-skill "<FIRST_SKILL>" --branch "$(git branch --show-current)"
```

**Never skip a pipeline step.** Attempt every step of the workflow below in order; if a step seems impossible, invoke the skill anyway — it has its own fallbacks. The one exception is a missing Unity Editor: `/qq:test` then exits 2 by design rather than seizing the project lock — report that and let the user act; do not force `--batch`. If a step genuinely fails at runtime, report the actual error and stop rather than moving on to the next step.

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

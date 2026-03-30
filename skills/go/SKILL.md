---
description: "Entry point — detect where you are in the dev workflow and guide you to the right next step."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Entry point for the qq development workflow. Detects your current state and guides you to the right skill.

This skill is a **controller**, not an implementation engine. It should read real project state first and only fall back to prompt/context heuristics when the state is ambiguous.

Arguments: $ARGUMENTS
- A file path (design doc, plan, or code file)
- A brief description of what to build
- `--auto`: full pipeline, no prompts
- No arguments: auto-detect from context

## State Detection

Assess the current situation in this order:

### 1. Did the user provide explicit input?
- **File path to a complete design doc** → "This looks like a design doc. Want to run `/qq:plan` to create an implementation plan?"
- **File path to a rough draft / notes** → "This looks like an incomplete draft. Want to run `/qq:design` to flesh it out into a full design doc?"
- **File path to an implementation plan** → "This is an implementation plan. Want to run `/qq:execute` to start building?"
- **File path to .cs code** → "Want to run `/qq:best-practice` to check this code, or `/qq:test`?"
- **A brief feature description** → "Want to start with `/qq:design` to write a game design doc, or skip straight to `/qq:plan` for a technical implementation plan?"

### 2. Read project state

If `./scripts/qq-project-state.py` exists, run it first:

```bash
python3 ./scripts/qq-project-state.py --pretty
```

Use that structured state as the primary routing signal.

Interpretation:

- `has_design_doc=true` and `has_implementation_plan=false` → suggest `/qq:plan`
- `has_implementation_plan=true` and `has_uncommitted_cs_changes=false` → suggest `/qq:execute`
- `last_compile_status=failed|blocked` → tell the user to fix compile before advancing
- `has_uncommitted_cs_changes=true` and `last_compile_status=passed` → suggest `/qq:best-practice` or `/qq:test`
- `last_test_status=passed` and no outstanding code changes → suggest `/qq:commit-push`

### 3. Fall back to conversation context only if needed

- **Just finished discussing a new feature idea** → suggest `/qq:design`
- **A design doc was recently written or reviewed** → suggest `/qq:plan`
- **A plan was recently generated or reviewed** → suggest `/qq:execute`
- **Code was recently written or modified** → suggest `/qq:best-practice` or `/qq:test`
- **Tests just passed** → suggest `/qq:commit-push`

### 4. Fall back to git state if project state is unavailable

- **Uncommitted .cs changes** → "You have uncommitted C# changes. Want to run `/qq:best-practice` to check them?"
- **Clean working tree, recent commits not pushed** → "You have unpushed commits. Want to run `/qq:test` before pushing?"
- **Clean tree, all pushed** → "Everything looks clean. Describe what you want to build next."

### 5. Nothing to go on
→ Ask: "What are you working on? You can give me a design doc, a one-liner, or tell me what stage you're at."

## `--auto` Mode

Skip all questions. Read project state first, then pick the strictest path and chain through the full pipeline with `--auto` on each skill:

- Has brief description / rough draft → `/qq:design --auto`
- Has complete design doc → `/qq:plan --auto`
- Has plan → `/qq:execute --auto`
- Has uncommitted code → `/qq:best-practice --auto`
- Has passing tests → `/qq:commit-push`

## Notes

- This skill never does work itself — it only routes to the right skill
- Prefer structured project state over conversation heuristics whenever available
- Always confirm with the user before invoking a skill (unless `--auto`)
- If ambiguous, ask one clarifying question, not five

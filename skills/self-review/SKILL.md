---
description: "Review changes from the most recent interaction (skills, configs, settings, and other lightweight changes) for quality and consistency."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

> **Unity runtime or scene changes:** check that they behave as intended by querying the live Editor read-only through the project's channel ([`shared/unity-live-state.md`](../../shared/unity-live-state.md)), e.g. `unity command --project-path "$PWD" --json --no-banner get_component_properties -- <params>` on the official CLI; with no channel, say the runtime behavior is unverified.

## Steps

### 1. Collect changed files

Look back at the files changed in the most recent interaction and list them (file paths + one-line summary of each change).

### 2. Review Loop

Loop automatically until there are no `[Critical]` issues in the review, or 5 rounds are completed.

Output `=== Round N/5 ===` at the start of each round.

#### a. Dispatch review subagent

Dispatch a subagent (`subagent_type: "general-purpose"`, `model: "opus"`) with a prompt containing:

1. The list of changed files and a summary of what was changed
2. The full current content of each changed file (read them yourself and paste them in)
3. Review checklist:
   - **Logical correctness** — are references correct, are step numbers sequential, do file paths exist
   - **Consistency** — does the style match existing content in this repo
   - **Omissions** — are there related files that should have been updated but were missed
   - **Redundancy** — unnecessary blank lines, duplicate content
   - **Naming** — are renamed symbols/paths consistent everywhere
4. Required output format: classify each finding as `[Critical]`, `[Moderate]`, or `[Suggestion]` with file path, line number, and explanation

#### b. Fix confirmed issues

- For each `[Critical]` issue: fix immediately
- For each `[Moderate]` issue: fix at discretion
- `[Suggestion]` items: note but do not fix unless trivial

#### c. Determine whether to continue

- If this round had `[Critical]` issues fixed → start next round (back to a)
- If no `[Critical]` issues → output "Review passed" and proceed to cleanup
- If 5 rounds completed → output final status and proceed to cleanup

### 3. Clean up

Output a brief review conclusion, then clear the skill change marker:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
if qq_session_id; then rm -f "$QQ_TEMP_DIR/claude-skill-modified-marker-$QQ_SESSION_ID"; fi
```

## Handoff

After the review loop ends, recommend the next step:

- **Review passed, no issues** → "All clean. Ready to `/qq:commit-push`?"
- **Issues were found and fixed** → "Fixed N issues across M rounds. Want to `/qq:commit-push`?"
- **5 rounds exhausted with remaining issues** → "Some issues remain after 5 rounds. Please review manually before committing."

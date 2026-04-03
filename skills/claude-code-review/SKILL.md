---
description: Dispatch a Claude subagent to deeply review code changes, then fix the code based on review findings. Automatically loops until no critical issues remain or 5 rounds are complete.
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Arguments: $ARGUMENTS
- No arguments: **intelligently select the review scope based on context** (see rules below)
- `--base <branch>`: specify a base branch for a full diff
- `--commits`: review only the most recent commit's changes
- `--files "a.cs b.cs"`: specify a list of files

## Review Scope Selection (no arguments)

**Do not default to diffing the entire branch against the main branch.** Use conversation context to intelligently determine scope:

1. **If the user specified a scope** (e.g. "review Phase 8", "review recent changes") → follow the user's intent
2. **If code was just modified in this conversation** → use `--files` to review only the files that were just changed
3. **If the user explicitly says "review the whole branch" or there is no inferable context** → then use the default `main...HEAD` diff

**How to infer scope:**
- Check which `.cs` files were edited/written in this conversation
- Or use `git diff --name-only HEAD` to see uncommitted changes
- Or use `git diff --name-only HEAD~N..HEAD` to see the last N commits

**Confirm with the user:** Once the scope is determined, tell the user "I will review the following scope: XXX" and proceed unless they object.

## Execution Flow

### 2–5. Automated Review Loop

**Loop automatically — do not ask the user between rounds.** Stop when any of the following is true:
- No `[Critical]` issues in the review result
- 5 rounds have been completed
- Two consecutive rounds with no new critical issues

Each round:

#### a. Send to Claude for Review
Before sending the diff to Claude, if `./scripts/qq-policy-check.sh` exists, run it on the same changed `.cs` files first. Treat those deterministic findings as already-established local policy results. Claude should focus on bugs, behavior, architecture, and anything not trivially captured by deterministic checks.

Use the Bash tool with `run_in_background: true` to run in the background:
```bash
./scripts/claude-review.sh $ARGUMENTS
```
The script calls `claude -p`, with results output to stdout and `Docs/qq/<branch-name>/claude-code-review_<timestamp>.md`.
Claude CLI review typically takes 2-5 minutes. Using background execution, the system will automatically notify when the command completes — no need to sleep or poll.
Notify the user that the background task has been submitted and will continue processing automatically when complete.

**From round 2 onward:** If the previous round had findings deemed over-engineered, append `--prompt` to the original arguments:
```bash
./scripts/claude-review.sh $ARGUMENTS --prompt "Review these code changes using the same criteria as round 1 (bugs, architecture, performance, security, style). Additional context: the following suggestions from the previous round were deemed over-engineered and replaced with simpler solutions: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Classify by severity: [Critical] [Moderate] [Suggestion]."
```

#### b. Summarize Review Results

After the subagent returns, categorize findings by severity:
- **Critical issues**: Bugs, architectural violations, anti-patterns that must be fixed
- **Moderate issues**: Worth improving but not blocking
- **Suggestions**: Nice-to-have optimizations

Present the summary to the user. **Do not fix code yet — proceed to the verification step first.**

#### c. Independent Verification (required, parallel subagents, gate-enforced)

> **Review Gate:** After the review script runs, a PreToolUse hook blocks Edit/Write on `.cs` and `Docs/*.md` files until at least 1 verification subagent completes. This is a mechanical constraint — you cannot edit code until findings are verified.

For each critical and moderate issue, **dispatch a subagent to verify it in depth** — do not draw conclusions from a quick scan in the main session.

**How to execute:** Group all findings that need verification, and for each one (or a cluster of related ones) dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent's prompt must include the original finding (verbatim), relevant file paths, and the instructions from [../_shared/verification-prompt.md](../_shared/verification-prompt.md).

After dispatching all verification subagents, write the expected count to the gate file so the gate knows when all verifications are complete:
```bash
source "$(git rev-parse --show-toplevel)/scripts/platform/detect.sh"
IFS=: read -r ts count _ < "$QQ_TEMP_DIR/review-gate-$PPID"
echo "${ts}:${count}:N" > "$QQ_TEMP_DIR/review-gate-$PPID"
```
(Replace N with the actual number of verification subagents dispatched.)

**Aggregate:** After all subagents return, consolidate the results and present each finding's verdict and supporting evidence to the user.

#### d. Fix the Code
- For each **confirmed** critical issue, locate and fix the code
- For findings flagged as **Confirmed but over-engineered**, apply a simpler alternative fix
- For confirmed moderate issues, apply fixes at your discretion
- After each fix, run a build and tests to verify
- After all fixes, present a summary of changes to the user

**Handling test failures:** If build/test runs reveal pre-existing failures unrelated to this change, **ask the user** how to proceed:
1. **Investigate and fix** — dig into these failures and attempt to fix them
2. **Skip and continue** — log the failures and continue the current review cycle
Do not unilaterally decide "unrelated, skip it" — let the user decide.

#### e. Decide Whether to Continue
- If this round had `[Critical]` issues confirmed and fixed → automatically start the next round (back to a)
- If this round had no `[Critical]` issues → output "Review passed" and end the loop
- If 5 rounds are complete → output final status and end the loop
- If two consecutive rounds had no new critical issues → suggest ending the loop

Print `=== Round N/5 ===` at the start of each round.

### 6. Clean Up Gate
After the review loop ends (for any reason), clean up the gate marker:
```bash
source "$(git rev-parse --show-toplevel)/scripts/platform/detect.sh"
rm -f "$QQ_TEMP_DIR/review-gate-$PPID"
```

## Handoff

After the review loop ends, recommend the next step:

- **Review passed, no issues** → "Code looks good. Want to run `/qq:test` to verify?"
- **Issues were found and fixed** → "Fixed N issues. Want to run `/qq:test` to make sure nothing broke?"
- **5 rounds exhausted with remaining issues** → "Some issues remain after 5 rounds. Run `/qq:test` to check impact, or continue fixing manually?"

**`--auto` mode:** skip asking → `/qq:test --auto`

## Notes
- The review script is at `./scripts/claude-review.sh` and requires Claude CLI (`claude`) to be available
- **Never blindly trust Claude review results** — subagents may misread code or reference wrong line numbers. Every finding must go through the verification step
- **Watch for over-engineering** — always ask: "Is the proposed fix proportionate to the problem?"
- When fixing, only address the actual issues the review identified — do not opportunistically refactor surrounding code
- Output path for any generated artifacts uses `Docs/qq/<branch-name>/` where branch name is obtained via `git branch --show-current | tr '/' '_'`

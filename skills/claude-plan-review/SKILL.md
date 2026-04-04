---
description: Send a design document to a Claude subagent for review, then revise the document based on findings. Automatically loops until no critical issues remain or 5 rounds are complete.
---

> **Script path fallback**: qq scripts are invoked as bare commands (e.g. `unity-test.sh`). If "command not found", use `${CLAUDE_PLUGIN_ROOT}/bin/<command>` instead.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Arguments: $ARGUMENTS
- A file path to a design document or plan
- No arguments: default to the most recently modified `.md` file under `Docs/`

## Execution Flow

### 1. Identify the Target File

Try in priority order:
1. If the user specified a file path, use it
2. Otherwise check the current conversation for a Claude-generated plan and use the latest one
3. If no plan file exists, **review the current conversation context** — find the most recently discussed design proposal, refactoring suggestion, or review conclusion, write it as a temporary spec file (`Docs/qq/<branch-name>/tmp-review-spec_<YYYYMMDD-HHmm>.md`, timestamped with the current time), then review that file. Get the branch name with: `git branch --show-current | tr '/' '_'`
4. Final fallback: use `ls -t Docs/**/*.md | grep -v '/qq/' | head -1` to find the most recently modified design document (excluding generated review artifacts)

### 2–6. Automated Review Loop

**Loop automatically — do not ask the user between rounds.** Stop when any of the following is true:
- No `[Critical]` issues in the review result
- 5 rounds have been completed

Each round:

#### 2a. Send to Claude for Review

Use the Bash tool with `run_in_background: true` to run in the background:
```bash
claude-plan-review.sh <file_path>
```
The script calls `claude -p`, with results output to stdout and `<filename>_review.md`.
The script automatically reads the project root's `CLAUDE.md` and includes the coding standards in the Claude prompt.
Claude CLI review typically takes 2-5 minutes. Using background execution, the system will automatically notify when the command completes — no need to sleep or poll.
Notify the user that the background task has been submitted and will continue processing automatically when complete.

**From round 2 onward:** If the previous round had findings deemed over-engineered, append a custom prompt with context:
```bash
claude-plan-review.sh <file_path> "Review the updated document using the same review criteria as the first round (architecture, correctness, completeness, feasibility). Additional context: the following suggestions from the previous round were judged as over-engineered and replaced with simpler alternatives: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Grade by severity: [Critical] [Moderate] [Suggestion]."
```

#### 2b. Summarize Review Results

After the subagent returns, categorize findings by severity:
- **Critical issues**: Logic flaws, contradictions, or major design defects that must be fixed
- **Moderate issues**: Worth improving but not blocking
- **Suggestions**: Nice-to-have optimizations

Present the summary to the user. **Do not modify the spec yet — proceed to the verification step first.**

#### 2c. Independent Verification (required, parallel subagents, gate-enforced)

> **Review Gate:** After the review script runs, a PreToolUse hook blocks Edit/Write on `.cs` and `Docs/*.md` files until at least 1 verification subagent completes. This is a mechanical constraint — you cannot edit the document until findings are verified.

For each critical and moderate issue, **dispatch a subagent to verify it in depth** — do not draw conclusions from a quick scan in the main session.

**How to execute:** Group all findings that need verification, and for each one (or a cluster of related ones) dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent's prompt must include the original finding (verbatim), relevant file paths, and the instructions from [../../shared/verification-prompt.md](../../shared/verification-prompt.md).

After dispatching all verification subagents, write the expected count to the gate file so the gate knows when all verifications are complete:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
IFS=: read -r ts count _ < "$QQ_TEMP_DIR/review-gate-$PPID"
echo "${ts}:${count}:N" > "$QQ_TEMP_DIR/review-gate-$PPID"
```
(Replace N with the actual number of verification subagents dispatched.)

**Aggregate:** After all subagents return, consolidate the results and present each finding's verdict and supporting evidence to the user.

#### 2d. Revise the Design Document
- Only fix issues that are **verified as confirmed** — skip rejected ones
- For findings flagged as **Confirmed but over-engineered**, apply a simpler alternative fix
- For each confirmed critical issue, update the relevant section of the design document
- For confirmed moderate issues, apply fixes at your discretion
- After revising, present a summary of changes to the user

#### 2e. Decide Whether to Continue
- If this round had `[Critical]` issues confirmed and fixed → automatically start the next round (back to 2a)
- If this round had no `[Critical]` issues → output "Review passed" and end the loop
- If 5 rounds are complete → output final status and end the loop

Print `=== Round N/5 ===` at the start of each round.

### 7. Clean Up Gate
After the review loop ends (for any reason), clean up the gate marker:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
rm -f "$QQ_TEMP_DIR/review-gate-$PPID"
```

## Handoff

After the review loop ends, recommend the next step:

- **Review passed, plan is solid** → "Plan looks good. Want to run `/qq:execute <path>` to start implementing?"
- **Issues were found and fixed** → "Plan revised. Want to run `/qq:execute <path>`, or another review round?"

**`--auto` mode:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:claude-plan-review" --next-skill "/qq:execute"`, then invoke `/qq:execute <path> --auto`.

## Notes
- The review script is at `claude-plan-review.sh` and requires Claude CLI (`claude`) to be available
- **Never blindly trust Claude review results** — subagents may misread code or reference stale information. Every finding must go through the verification step
- **Watch for over-engineering** — always ask: "Is the proposed fix proportionate to the problem?"
- Do not alter the design intent on your own initiative — only fix what the review found
- When revising, preserve the overall document structure; only change what needs changing
- Output path for temp files uses `Docs/qq/<branch-name>/` where branch name is obtained via `git branch --show-current | tr '/' '_'`

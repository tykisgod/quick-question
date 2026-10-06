---
description: Send a design document to a separate Claude CLI run for review, then revise the document based on findings. Automatically loops until no critical issues remain or 5 rounds are complete.
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `claude-plan-review.sh` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Arguments: $ARGUMENTS
- A file path to a design document or plan
- No arguments: pick the target as in step 1

## Execution Flow

### 1. Identify the Target File

Try in priority order:
1. If the user specified a file path, use it
2. Otherwise check the current conversation for a Claude-generated plan and use the latest one
3. If no plan file exists, **review the current conversation context** — find the most recently discussed design proposal, refactoring suggestion, or review conclusion, write it as a temporary spec file (`Docs/qq/<branch-name>/tmp-review-spec_<YYYYMMDD-HHmm>.md`, timestamped with the current time), then review that file. Get the branch name with: `git branch --show-current | tr '/' '_'`
4. Final fallback: use `ls -t Docs/**/*.md | grep -v '/qq/' | head -1` to find the most recently modified design document (excluding generated review artifacts)

### 2. Review Loop

**Loop automatically — do not ask the user between rounds.** Stop when either is true:
- No `[Critical]` issues in the review result
- 5 rounds have been completed

Each round:

#### 2a. Send to Claude for Review

Run in the background (Bash tool, `run_in_background: true`):
```bash
${CLAUDE_PLUGIN_ROOT}/bin/claude-plan-review.sh <file_path>
```
The script calls `claude -p` and writes results to stdout and `<filename>_claude_review.md` (same directory as the document).
It always points the reviewer at the project root's `CLAUDE.md` and adds a provenance check, even with a custom prompt; don't repeat them in your round-2 prompt.
A review takes 2-5 minutes and you are notified when it finishes.

**From round 2 onward:** If the previous round had findings deemed over-engineered, append a custom prompt with context:
```bash
${CLAUDE_PLUGIN_ROOT}/bin/claude-plan-review.sh <file_path> "Review the updated document using the same review criteria as the first round (architecture, correctness, completeness, feasibility). Additional context: the following suggestions from the previous round were judged as over-engineered and replaced with simpler alternatives: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Grade by severity: [Critical] [Moderate] [Suggestion]."
```

#### 2b. Summarize Review Results

Read `<filename>_claude_review.md` and summarize the findings for the user by severity (`[Critical]`, `[Moderate]`, `[Suggestion]`).

#### 2c. Independent Verification

Verify every critical and moderate finding with a subagent, not with a quick look of your own.

For a `Provenance:` finding, first check this conversation yourself for the user's words on each item: note the ones you find (quote them into the document in 2d), and send the verifier only the items still unbacked. If that leaves no finding to verify, run the Clean Up Gate command (step 3) before 2d: a gate expecting 0 verifiers blocks `Docs/*.md` edits.

Dispatch the verifiers in parallel with the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), one per finding or per cluster of related findings. Each prompt must include the original finding (verbatim), relevant file paths, and the instructions from [../../shared/verification-prompt.md](../../shared/verification-prompt.md).

The review script leaves a gate: Edit/Write on `.cs` and `Docs/*.md` files stays blocked until you write the number of verifiers to it and that many have returned. Write it right after dispatching them:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
if qq_session_id && [[ -f "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID" ]]; then
  IFS=: read -r ts count _ < "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
  echo "${ts}:${count}:N" > "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
fi
```
(N = the number of verification subagents dispatched. The gate file is per session; if this session has none, there is nothing to write.)

**Aggregate:** After all subagents return, present each finding's verdict and supporting evidence to the user.

#### 2d. Revise the Design Document
- Only fix issues that are **verified as confirmed** — skip rejected ones
- For findings flagged as **Confirmed but over-engineered**, apply a simpler alternative fix
- For each confirmed critical issue, update the relevant section of the design document
- For confirmed moderate issues, apply fixes at your discretion
- **Provenance findings:** follow [`shared/user-decisions.md`](../../shared/user-decisions.md). Quote the user's words if they exist; if the user wrote the document themselves, reject the finding; otherwise put the item on the "Needs the user's decision" list and write the body with the normal rule (no protection, no added restriction, a cut item back in scope). Never mark it as your own call. Moved items count as fixed
- After revising, present a summary of changes to the user

#### 2e. Decide Whether to Continue
- If this round had `[Critical]` issues confirmed and fixed → automatically start the next round (back to 2a)
- If every `[Critical]` this round was rejected and nothing was fixed → end the loop and report the rejections with their reasons
- If this round had no `[Critical]` issues → output "Review passed" and end the loop
- If 5 rounds are complete → output final status and end the loop

Print `=== Round N/5 ===` at the start of each round.

### 3. Clean Up Gate
After the review loop ends (for any reason), clean up the gate marker:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
if qq_session_id; then rm -f "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"; fi
```

## Handoff

After the review loop ends, recommend the next step, and list every "Needs the user's decision" entry this run added (also in `--auto` mode; don't wait for answers):

- **Review passed, plan is solid** → "Plan looks good. Want to run `/qq:execute <path>` to start implementing?"
- **Issues were found and fixed** → "Plan revised. Want to run `/qq:execute <path>`, or another review round?"

**`--auto` mode:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:claude-plan-review" --next-skill "/qq:execute"`, then invoke `/qq:execute <path> --auto`.

## Notes
- `claude-plan-review.sh` needs the Claude CLI (`claude`) on PATH.
- Do not alter the design intent on your own initiative — only fix what the review found
- When revising, preserve the overall document structure; only change what needs changing

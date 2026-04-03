---
description: "Send a design document to Codex CLI for review, then revise the document based on the findings. Automatically loops until no critical issues remain or 5 rounds are completed."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Send a design document to Codex CLI for review, then revise the document based on the findings. Automatically loops until no critical issues remain or 5 rounds are completed.

Arguments: $ARGUMENTS
- A file path to a design document or plan
- No arguments: default to the most recently modified `.md` file under `Docs/`

## Execution Flow

### 1. Determine the Target File
Try in order of priority:
1. If the user specified a file path, use it
2. Otherwise check the current conversation for a Claude-generated plan (typically under `Docs/` or similar), use the most recent one
3. If no plan file exists either, **review the current conversation context** — find the most recently discussed design proposal, refactoring suggestion, or review conclusion, write it as a temporary spec file (`Docs/qq/<branch-name>/tmp-review-spec_<YYYYMMDD-HHmm>.md`, timestamped). Get branch name with: `git branch --show-current | tr '/' '_'`
4. Last resort: use `ls -t Docs/**/*.md | grep -v '/qq/' | head -1` to find the most recently modified design document (excluding qq-generated artifacts)

### 2-6. Automatic Review Loop

**Loops automatically without prompting the user each round.** Loop termination conditions (stop when any is met):
- No `[Critical]` issues in the Codex review result
- 5 rounds have been completed

Each round:

#### 2a. Send to Codex for Review
Run the following command using the Bash tool with `run_in_background: true`:
```bash
./scripts/plan-review.sh <file_path>
```
The script calls `codex exec --sandbox read-only`, outputting results to stdout and `<filename>_review.md`.
The script automatically reads the project root's `CLAUDE.md` and includes the coding standards in the Codex prompt.
Codex review typically takes 5-10 minutes. With background execution, the system automatically notifies you when done — no sleep or polling needed.
Inform the user that the background task has been submitted and will continue automatically upon completion. You may continue other conversation with the user while waiting.

**Round 2 onward:** If the previous round had findings marked as over-engineered, append a custom prompt with context:
```bash
./scripts/plan-review.sh <file_path> "Review the updated document using the same review criteria as the first round (architecture, correctness, completeness, feasibility). Additional context: the following suggestions from the previous round were judged as over-engineered and replaced with simpler alternatives: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Grade by severity: [Critical] [Moderate] [Suggestion]."
```
This preserves the full review standards while preventing Codex from re-suggesting the same complex approaches.

#### 2b. Read and Summarize Review Results
Read `<filename>_review.md` and summarize by severity:
- **Critical issues**: Logic flaws, contradictions, or major design defects that must be fixed
- **Moderate issues**: Problems worth improving but not blocking
- **Suggestions**: Nice-to-have optimizations

Present the summary to the user. **Do not modify the spec yet — proceed to the verification step first.**

#### 2c. Independent Verification (required, parallel subagents, gate-enforced)
For each critical and moderate finding, **dispatch a subagent to verify each one in depth** — do not draw conclusions from a quick scan in the main session. Every finding must be verified against the code, no exceptions.

> **Review Gate:** After the review script runs, a PreToolUse hook blocks Edit/Write on `.cs` and `Docs/*.md` files until at least 1 verification subagent completes. This is a mechanical constraint — you cannot edit the document until findings are verified.

**How to execute:** Group all findings to verify, and for each one (or a few related ones) dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent's prompt must include the original finding (verbatim), relevant file paths, and the instructions from [../_shared/verification-prompt.md](../_shared/verification-prompt.md).

After dispatching all verification subagents, write the expected count to the gate file so the gate knows when all verifications are complete:
```bash
source "$(git rev-parse --show-toplevel)/scripts/platform/detect.sh"
IFS=: read -r ts count _ < "$QQ_TEMP_DIR/review-gate-$PPID"
echo "${ts}:${count}:N" > "$QQ_TEMP_DIR/review-gate-$PPID"
```
(Replace N with the actual number of verification subagents dispatched.)

**Consolidation:** Wait for all subagents to return, then consolidate the verification results and present each finding's verdict and evidence (citing file paths and key code) to the user.

#### 2d. Revise the Design Document
- Only fix **verified and confirmed** issues; skip rejected ones
- For findings marked as **Confirmed but over-engineered**, fix using the simpler alternative, not Codex's original suggestion
- For each confirmed critical issue, revise the relevant section of the design document
- For confirmed moderate issues, revise as appropriate
- Present a summary of changes to the user after editing

#### 2e. Decide Whether to Continue
- If this round had `[Critical]` issues that were confirmed and fixed → automatically start the next round (back to 2a)
- If this round had no `[Critical]` issues → output "Review passed" and end the loop
- If 5 rounds have been completed → output final status and end the loop

Output `=== Round N/5 ===` at the start of each round.

### 7. Clean Up Gate
After the review loop ends (for any reason), clean up the gate marker:
```bash
source "$(git rev-parse --show-toplevel)/scripts/platform/detect.sh"
rm -f "$QQ_TEMP_DIR/review-gate-$PPID"
```

## Handoff

After the review loop ends, recommend the next step:

- **Review passed, plan is solid** → "Plan looks good. Want to run `/qq:execute <path>` to start implementing?"
- **Issues were found and fixed** → "Plan revised. Want to run `/qq:execute <path>`, or another review round?"

**`--auto` mode:** skip asking → `/qq:execute <path> --auto`

## Notes
- The review script is at `./scripts/plan-review.sh` and requires Codex CLI to be configured
- The script automatically appends `CLAUDE.md` coding standards to the review prompt
- **Never blindly trust Codex review results** — Codex may misread code, cite outdated information, or draw conclusions from assumptions. Every finding must be verified against the code
- **Watch out for over-engineering** — Codex tends to suggest maximally "correct" solutions (extra abstraction layers, splitting files for purity, adding generics). Always ask: "Is the fix proportionate to the problem?" If not, choose the simpler path and tell Codex why in the next round
- Do not change design intent on your own initiative — only fix issues identified by the review
- When editing, preserve the document's overall structure; only change what needs to change
- Custom prompt usage: `./scripts/plan-review.sh <file> "custom review prompt"`

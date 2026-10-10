---
description: "Send a design document to Codex CLI for review, then revise the document based on the findings. Automatically loops until no critical issues remain or 5 rounds are completed."
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `plan-review.sh` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

> **Workflow:** take `--workflow <name>` from `$ARGUMENTS` if present, else run `qq-config.py field workflow`. On `prototype-loop`, run one round only and verify the findings yourself ([`shared/prototype-loop.md`](../../shared/prototype-loop.md) §Plan), then hand off to `/qq:execute`; on `heavy-review` (the default), follow this file as written.

Arguments: $ARGUMENTS
- A file path to a design document or plan
- No arguments: pick the target as in step 1

## Execution Flow

### 1. Determine the Target File
Try in order of priority:
1. If the user specified a file path, use it
2. Otherwise check the current conversation for a Claude-generated plan (typically under `Docs/` or similar), use the most recent one
3. If no plan file exists either, **review the current conversation context** — find the most recently discussed design proposal, refactoring suggestion, or review conclusion, write it as a temporary spec file (`Docs/qq/<branch-name>/tmp-review-spec_<YYYYMMDD-HHmm>.md`, timestamped). Get branch name with: `git branch --show-current | tr '/' '_'`
4. Last resort: use `ls -t Docs/**/*.md | grep -v '/qq/' | head -1` to find the most recently modified design document (excluding qq-generated artifacts)

### 2. Review Loop

**Loops automatically without prompting the user each round.** Stop when either is met:
- No `[Critical]` issues in the Codex review result
- 5 rounds have been completed

Each round:

#### 2a. Send to Codex for Review
Run in the background (Bash tool, `run_in_background: true`):
```bash
${CLAUDE_PLUGIN_ROOT}/bin/plan-review.sh <file_path>
```
The script calls `codex exec --sandbox read-only` and writes results to stdout and `<filename>_review.md` (same directory as the document).
It always points Codex at the project root's `CLAUDE.md` and adds a provenance check, even with a custom prompt; don't repeat them in your round-2 prompt.
A review takes 5-10 minutes and you are notified when it finishes; meanwhile you can keep talking with the user.

**Round 2 onward:** If the previous round had findings marked as over-engineered, append a custom prompt with context:
```bash
${CLAUDE_PLUGIN_ROOT}/bin/plan-review.sh <file_path> "Review the updated document using the same review criteria as the first round (architecture, correctness, completeness, feasibility). Additional context: the following suggestions from the previous round were judged as over-engineered and replaced with simpler alternatives: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Grade by severity: [Critical] [Moderate] [Suggestion]."
```

#### 2b. Read and Summarize Review Results
Read `<filename>_review.md` and summarize the findings for the user by severity (`[Critical]`, `[Moderate]`, `[Suggestion]`).

#### 2c. Independent Verification
Verify every critical and moderate finding with a subagent, not with a quick look of your own.

For a `Provenance:` finding, first check this conversation yourself for the user's words on each item: note the ones you find (quote them into the document in 2d), and send the verifier only the items still unbacked. If that leaves no finding to verify, run the Clean Up Gate command (step 3) before 2d: a gate expecting 0 verifiers blocks `Docs/*.md` edits.

Dispatch the verifiers with the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`). By default hand all of this round's findings to one verifier, which gives a verdict for each; split them into a few groups verified in parallel only when there are too many for one agent to check properly. Each prompt must include the original findings (verbatim), relevant file paths, and the instructions from [../../shared/verification-prompt.md](../../shared/verification-prompt.md).

The review script leaves a gate: Edit/Write on `.cs` and `Docs/*.md` files stays blocked until you write the number of verifiers to it and that many have returned. Write it right after dispatching them:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
if qq_session_id && [[ -f "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID" ]]; then
  IFS=: read -r ts count _ < "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
  echo "${ts}:${count}:N" > "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
fi
```
(N = the number of verification subagents dispatched. The gate file is per session; if this session has none, there is nothing to write.)

**Consolidation:** After all subagents return, present each finding's verdict and evidence (citing file paths and key code) to the user.

#### 2d. Revise the Design Document
- Only fix **verified and confirmed** issues; skip rejected ones
- For findings marked as **Confirmed but over-engineered**, fix using the simpler alternative, not Codex's original suggestion
- For each confirmed critical issue, revise the relevant section of the design document
- For confirmed moderate issues, revise as appropriate
- **Provenance findings:** follow [`shared/user-decisions.md`](../../shared/user-decisions.md). Quote the user's words if they exist; if the user wrote the document themselves, reject the finding; otherwise put the item on the "Needs the user's decision" list and write the body with the normal rule (no protection, no added restriction, a cut item back in scope). Never mark it as your own call. Moved items count as fixed
- Present a summary of changes to the user after editing

#### 2e. Decide Whether to Continue
- If this round had `[Critical]` issues that were confirmed and fixed → automatically start the next round (back to 2a)
- If every `[Critical]` this round was rejected and nothing was fixed → end the loop and report the rejections with their reasons
- If this round had no `[Critical]` issues → output "Review passed" and end the loop
- If 5 rounds have been completed → output final status and end the loop

Output `=== Round N/5 ===` at the start of each round.

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

**`--auto` mode:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:codex-plan-review" --next-skill "/qq:execute"`, then invoke `/qq:execute <path> --auto`.

## Notes
- `plan-review.sh` needs a configured Codex CLI.
- Do not change design intent on your own initiative — only fix issues identified by the review
- When editing, preserve the document's overall structure; only change what needs to change

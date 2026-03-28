---
description: "Send the code changes on the current branch to Codex CLI for review, then fix the code based on the findings. Automatically loops until no critical issues remain or 5 rounds are completed."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Send the code changes on the current branch to Codex CLI for review, then fix the code based on the findings. Automatically loops until no critical issues remain or 5 rounds are completed.

Arguments: $ARGUMENTS
- No arguments: diff against develop...HEAD
- `--base <branch>`: specify a custom base branch for comparison
- `--commits`: only look at changes from the most recent commit

## Execution Flow

### 1–5. Automatic Review Loop

**Loops automatically without prompting the user each round.** Loop termination conditions (stop when any is met):
- No `[Critical]` issues in the Codex review result
- 5 rounds have been completed
- No new critical issues for two consecutive rounds

Each round:

#### a. Send to Codex for Review
Run the following command using the Bash tool with `run_in_background: true`:
```bash
./scripts/code-review.sh $ARGUMENTS
```
The script calls `codex exec --sandbox read-only`, outputting results to stdout and `Docs/<branch-name>/codex-code-review_<timestamp>.md`.
Codex review typically takes 5–10 minutes. With background execution, the system automatically notifies you when done — no sleep or polling needed.
Inform the user that the background task has been submitted and will continue automatically upon completion. You may continue other conversation with the user while waiting.

**Round 2 onward:** If the previous round had findings marked as over-engineered, append `--prompt` to the original arguments while preserving any `--base` or other flags in `$ARGUMENTS`:
```bash
./scripts/code-review.sh $ARGUMENTS --prompt "Review these code changes using the same review criteria as the first round (bugs, architecture, performance, security, style). Additional context: the following suggestions from the previous round were judged as over-engineered and replaced with simpler alternatives: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Grade by severity: [Critical] [Moderate] [Suggestion]."
```

#### b. Read and Summarize Review Results
Read the output file and summarize by severity:
- **Critical issues**: Bugs, architecture violations, or anti-patterns that must be fixed
- **Moderate issues**: Problems worth improving but not blocking
- **Suggestions**: Nice-to-have optimizations

Present the summary to the user. **Do not fix the code yet — proceed to the verification step first.**

#### c. Independent Verification (Required, parallel subagents)
For each critical and moderate finding, **dispatch a subagent to verify each one in depth** — do not draw conclusions from a quick scan in the main session. Every finding must be verified against the code, no exceptions.

**How to execute:** Group all findings to verify, and for each one (or a few related ones) dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent prompt must include:
1. The original Codex finding description (verbatim)
2. The affected file paths and line numbers
3. A clear verification task: read the actual source code and determine whether the problem Codex describes actually exists
4. Verify assertions about data flow, dependencies, or behavior — trace the call chain rather than looking at a single file
5. Required output conclusion: **Confirmed** / **Rejected** / **Partially confirmed**, with cited file paths, line numbers, and key code snippets as evidence

**Over-engineering check:** Also require each subagent to assess whether the implied fix for confirmed findings is proportionate to the problem:
- Does the suggestion add unnecessary abstraction, indirection, or configurability?
- Could a simpler, more direct fix address the same problem?
- Is the suggestion pursuing code purity (splitting files, changing namespaces, adding generics) without real architectural benefit?

For disproportionate suggestions, require the subagent to flag them as **Confirmed but over-engineered** — acknowledge the real problem, and suggest a simpler fix.

**Consolidation:** Wait for all subagents to return, then consolidate the verification results and present each finding's verdict and evidence to the user.

#### d. Fix the Code
- For each **confirmed** critical issue, locate and fix the code
- For findings marked as **Confirmed but over-engineered**, fix using the simpler alternative, not Codex's original suggestion
- For confirmed moderate issues, fix as appropriate
- Run compilation and tests to verify after each fix
- Present a summary of changes to the user after fixing

**Test failure handling:** If compilation/test failures appear that are unrelated to the current changes (pre-existing bugs in other modules), **you must ask the user** how to proceed:
1. **Investigate and fix** — dig into these failures and attempt to fix them
2. **Skip and continue** — log the failures and continue the current review flow
Do not unilaterally decide "it's unrelated, skip it" — let the user decide.

#### e. Decide Whether to Continue
- If this round had `[Critical]` issues that were confirmed and fixed → automatically start the next round (back to a)
- If this round had no `[Critical]` issues → output "Review passed" and end the loop
- If 5 rounds have been completed → output final status and end the loop
- If no new critical issues for two consecutive rounds → suggest ending the loop

Output `=== Round N/5 ===` at the start of each round.

## Notes
- The review script is at `./scripts/code-review.sh` and requires Codex CLI to be configured
- **Never blindly trust Codex review results** — Codex may misread code, cite incorrect line numbers, or draw conclusions from assumptions. Every finding must be verified against the code
- **Watch out for over-engineering** — Codex tends to suggest maximally "pure" solutions (extra layers, splitting files, adding generics). Always ask: "Is the fix proportionate to the problem?" If not, choose the simpler path and tell Codex why in the next round
- When fixing, only change the actual issues Codex identified — do not casually refactor surrounding code

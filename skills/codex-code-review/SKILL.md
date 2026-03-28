---
description: "Send code changes to Codex CLI for review, then fix the code based on the findings. Automatically loops until no critical issues remain or 5 rounds are completed."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Send code changes to Codex CLI for review, then fix the code based on the findings. Automatically loops until no critical issues remain or 5 rounds are completed.

Arguments: $ARGUMENTS
- No arguments: **intelligently select review scope based on context** (see rules below)
- `--base <branch>`: specify comparison base branch (full diff)
- `--commits`: only look at the most recent commit's changes
- `--files "a.cs b.cs"`: specify a list of files

## Review Scope Selection (no arguments)

**Do not default to reviewing the entire branch vs develop.** Intelligently determine scope based on conversation context:

1. **If the user specified a scope** (e.g., "review Phase 8", "review recent changes") → follow user intent
2. **If code was just modified in this conversation** → use `--files` to review only the recently changed files
3. **If the user explicitly says "review the entire branch" or there is no context to infer from** → use the default `develop...HEAD`

**Inference method**:
- Check the list of .cs files edited/written in this conversation
- Or use `git diff --name-only HEAD` to see uncommitted changes
- Or use `git diff --name-only HEAD~N..HEAD` to see the last N commits

**Confirm with the user**: Once scope is selected, inform the user "I will review the following scope: XXX" and proceed unless they object.

## Execution Flow

### 1-5. Automated Review Loop

**Loop automatically, no need to ask the user each round.** Loop terminates when any condition is met:
- No `[Critical]` issues in Codex review results
- 5 rounds completed
- No new critical issues in two consecutive rounds

Each round:

#### a. Send to Codex for Review
Use the Bash tool with `run_in_background: true` to run in the background:
```bash
./scripts/code-review.sh $ARGUMENTS
```
The script calls `codex exec --sandbox read-only`, with results output to stdout and `Docs/<branch-name>/codex-code-review_<timestamp>.md`.
Codex review typically takes 5-10 minutes. Using background execution, the system will automatically notify when the command completes — no need to sleep or poll.
Notify the user that the background task has been submitted and will continue processing automatically when complete. You may continue other conversations while waiting.

**From round 2 onward:** If the previous round had findings deemed over-engineered, append `--prompt` to the original arguments, keeping `--base` and other flags from `$ARGUMENTS`:
```bash
./scripts/code-review.sh $ARGUMENTS --prompt "Review these code changes using the same criteria as round 1 (bugs, architecture, performance, security, style). Additional context: the following suggestions from the previous round were deemed over-engineered and replaced with simpler solutions: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Classify by severity: [Critical] [Moderate] [Suggestion]."
```

#### b. Read and Summarize Review Results
Read the output file and classify by severity:
- **Critical issues**: bugs, architecture violations, anti-patterns that must be fixed
- **Moderate issues**: worth improving but not blocking
- **Suggestions**: nice-to-have optimizations

Present the summary to the user. **Do not fix code directly — enter the verification step first.**

#### c. Independent Verification (required, parallel subagents)
For each critical and moderate issue, **dispatch a subagent to verify each finding in depth** — do not skim code in the main session and draw quick conclusions. Every finding must be verified against the code, no exceptions.

**Execution:** Group all findings that need verification, and for each (or a related set), dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent's prompt must include:
1. Codex's original finding description (verbatim)
2. Relevant file paths and line numbers
3. A clear verification task: read the actual source code and determine if the issue Codex described truly exists
4. Verify assertions about data flow, dependencies, or behavior — trace the call chain, don't just look at a single file
5. Required output: **Confirmed** / **Refuted** / **Partially confirmed**, with cited file paths, line numbers, and key code snippets as evidence

**Over-engineering check:** Also ask each subagent to assess whether the implied fix is proportionate to the issue:
- Does the suggestion add unnecessary abstraction, indirection, or configurability?
- Could a simpler, more direct fix solve the same problem?
- Is the suggestion pursuing code purity (splitting files, changing namespaces, adding generics) without real architectural benefit?

For disproportionate suggestions, ask the subagent to flag them as **Confirmed but over-engineered** — acknowledge the real issue, propose a simpler fix.

**Aggregation:** After all subagents return, aggregate results and present each finding's verdict and evidence to the user.

#### d. Fix the Code
- For each **confirmed** critical issue, locate and fix the code
- For findings marked **confirmed but over-engineered**, fix using the simpler alternative, not Codex's original suggestion
- For confirmed moderate issues, fix at discretion
- After each fix, run compilation and tests to verify
- Present a summary of changes to the user

**Test failure handling:** If compilation/tests reveal pre-existing failures unrelated to this change (e.g., existing bugs in other modules), **ask the user** to choose next steps:
1. **Investigate and fix** — dig into these failures and attempt to fix them
2. **Skip and continue** — document the failures and continue the review process
Do not unilaterally decide "unrelated, so skip" — let the user decide.

#### e. Determine Whether to Continue
- If this round had `[Critical]` issues confirmed and fixed → automatically start the next round (back to a)
- If this round had no `[Critical]` issues → output "Review passed" and end the loop
- If 5 rounds are complete → output final status and end the loop
- If two consecutive rounds had no new critical issues → suggest ending the loop

Output `=== Round N/5 ===` at the start of each round.

## Notes
- The review script is at `./scripts/code-review.sh` and requires Codex CLI to be configured
- **Never blindly trust Codex review results** — Codex may misread code, reference wrong line numbers, or infer from assumptions. Every finding must be verified by reading the code
- **Beware of over-engineering** — Codex tends to suggest maximally "pure" solutions (extra layers, file splitting, generics). Always ask: "Is the fix proportionate to the problem?" If not, choose the simpler path and tell Codex why in the next round
- When fixing, only address the actual issues Codex identified — do not opportunistically refactor surrounding code

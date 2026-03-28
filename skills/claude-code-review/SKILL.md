---
description: Dispatch a Claude subagent to deeply review code changes, then fix the code based on review findings. Automatically loops until no critical issues remain or 5 rounds are complete.
---

Respond in the same language the user writes in.

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

### 1. Collect Changes

Collect the code changes to review based on arguments:
```bash
git diff <range> -- '*.cs'
```
Save the diff content for the subagent to use. Also read CLAUDE.md for coding standards and AGENTS.md for architecture rules (if it exists).

### 2–5. Automated Review Loop

**Loop automatically — do not ask the user between rounds.** Stop when any of the following is true:
- No `[Critical]` issues in the review result
- 5 rounds have been completed
- Two consecutive rounds with no new critical issues

Each round:

#### a. Dispatch Subagent for Review

Dispatch a subagent (`subagent_type: "general-purpose"`, `model: "opus"`) to review the code with the following prompt:

```
You are a senior C#/Unity code reviewer. Review the following code changes across six dimensions:

1. Bugs: null references, out-of-bounds, race conditions, resource leaks, logic errors
2. Architecture: single-responsibility violations, circular dependency introductions, public API design
3. Performance: per-frame allocations (new/LINQ/string concat), unnecessary GetComponent, O(n²) traversals
4. Unity best practices: MonoBehaviour lifecycle, coroutine leaks, SerializeField usage
5. Security: injection risks, exposure of interfaces that should be internal
6. Code style: naming consistency, dead code, over-defensive programming (unnecessary null checks)

Project coding standards: <CLAUDE.md content>
Architecture rules (if AGENTS.md exists): <AGENTS.md content>
Code changes: <diff content>

You must read the relevant source files to verify your findings — do not infer context from diff snippets alone.
For each finding: specify the file name and line number, describe the problem, and give a fix recommendation. Classify by severity: [Critical] [Moderate] [Suggestion].
```

**From round 2 onward:** If any suggestions from the previous round were flagged as over-engineered, append to the prompt:
```
Additional context: The following suggestions from the previous round were deemed over-engineered and replaced with simpler alternatives: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect.
```

#### b. Summarize Review Results

After the subagent returns, categorize findings by severity:
- **Critical issues**: Bugs, architectural violations, anti-patterns that must be fixed
- **Moderate issues**: Worth improving but not blocking
- **Suggestions**: Nice-to-have optimizations

Present the summary to the user. **Do not fix code yet — proceed to the verification step first.**

#### c. Independent Verification (required, parallel subagents)

For each critical and moderate issue, **dispatch a subagent to verify it in depth** — do not draw conclusions from a quick scan in the main session.

**How to execute:** Group all findings that need verification, and for each one (or a cluster of related ones) dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent's prompt must include:
1. The original finding description (verbatim)
2. Relevant file paths and line numbers
3. A clear verification task: read the actual source code and determine whether the described issue truly exists
4. Verify assertions about data flow, dependencies, or behavior by tracing the call chain — do not look at a single file in isolation
5. Required output: **Confirmed** / **Rejected** / **Partially confirmed**, with the cited file path, line number, and key code snippet as evidence

**Over-engineering check:** Also ask each subagent to assess whether the implied fix for each confirmed finding is proportionate to the problem. Flag disproportionate suggestions as **Confirmed but over-engineered**.

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

## Notes
- **Never blindly trust review results** — subagents may misread code or reference wrong line numbers. Every finding must go through the verification step
- **Watch for over-engineering** — always ask: "Is the proposed fix proportionate to the problem?"
- When fixing, only address the actual issues the review identified — do not opportunistically refactor surrounding code
- Output path for any generated artifacts uses `Docs/qq/<branch-name>/` where branch name is obtained via `git branch --show-current | tr '/' '_'`

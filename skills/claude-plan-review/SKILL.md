---
description: Send a design document to a Claude subagent for review, then revise the document based on findings. Automatically loops until no critical issues remain or 5 rounds are complete.
---

Respond in the same language the user writes in.

The user may provide: a file path. If none is specified, default to reviewing the most recently modified `.md` file under `Docs/`.

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

#### 2a. Dispatch Subagent for Review

Dispatch a subagent (`subagent_type: "general-purpose"`, `model: "opus"`) to review the document with the following prompt:

```
You are a senior game systems architect and developer. Review the following design document across six dimensions:

1. Architectural soundness: Is module separation clear? Are dependencies reasonable? Any risk of circular dependencies?
2. Logical correctness: Is the state machine complete (no deadlocks or missing states)? Are edge cases handled?
3. Completeness: Are there undefined behaviors, missing error handling, or unconsidered player actions?
4. Data flow: Where does data come from, where does it go, who owns it, who mutates it — any consistency issues?
5. Performance: Per-frame full-entity iteration, frequent GC allocations, unnecessary serialization?
6. Compatibility with existing systems: Read CLAUDE.md for coding standards and AGENTS.md for architecture rules (if it exists), check if the design conflicts with existing modules.

You must read relevant source code to verify your findings — do not infer code state from the document alone.

Project coding standards: read the root CLAUDE.md.
Architecture rules (if AGENTS.md exists): read the root AGENTS.md.
Design document content: <paste full document>

Classify findings by severity: [Critical] [Moderate] [Suggestion]. For each finding provide the specific location and a concrete fix recommendation.
```

**From round 2 onward:** If any suggestions from the previous round were flagged as over-engineered, append to the prompt:
```
Additional context: The following suggestions from the previous round were deemed over-engineered and replaced with simpler alternatives: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect.
```

#### 2b. Summarize Review Results

After the subagent returns, categorize findings by severity:
- **Critical issues**: Logic flaws, contradictions, or major design defects that must be fixed
- **Moderate issues**: Worth improving but not blocking
- **Suggestions**: Nice-to-have optimizations

Present the summary to the user. **Do not modify the spec yet — proceed to the verification step first.**

#### 2c. Independent Verification (required, parallel subagents)

For each critical and moderate issue, **dispatch a subagent to verify it in depth** — do not draw conclusions from a quick scan in the main session.

**How to execute:** Group all findings that need verification, and for each one (or a cluster of related ones) dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent's prompt must include:
1. The original finding description (verbatim)
2. Relevant file paths and line numbers
3. A clear verification task: read the actual source code / config files and determine whether the description matches reality
4. For data/config-related claims (e.g. CSV config values, thresholds), require reading the raw files directly
5. Required output: **Confirmed** (code corroborates) / **Rejected** (code does not support the claim) / **Partially confirmed** (needs rewording), with the cited file path and key code snippet as evidence

**Over-engineering check:** Also ask each subagent to assess whether the implied fix for each confirmed finding is proportionate to the problem. Flag disproportionate suggestions as **Confirmed but over-engineered**.

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

## Notes
- **Never blindly trust review results** — subagents may misread code or reference stale information. Every finding must go through the verification step
- **Watch for over-engineering** — always ask: "Is the proposed fix proportionate to the problem?"
- Do not alter the design intent on your own initiative — only fix what the review found
- When revising, preserve the overall document structure; only change what needs changing
- Output path for temp files uses `Docs/qq/<branch-name>/` where branch name is obtained via `git branch --show-current | tr '/' '_'`

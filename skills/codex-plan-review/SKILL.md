---
description: "Send a design document to Codex CLI for review, then revise the document based on the findings. Automatically loops until no critical issues remain or 5 rounds are completed."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Send a design document to Codex CLI for review, then revise the document based on the findings. Automatically loops until no critical issues remain or 5 rounds are completed.

The user may provide: a file path. If none is specified, default to the most recently modified .md file under the Docs/ directory.

## Execution Flow

### 1. Determine the Target File
Try in order of priority:
1. If the user specified a file path, use it
2. Otherwise check the current conversation for a Claude-generated plan (typically under `Docs/` or similar), use the most recent one
3. If no plan file exists either, **review the current conversation context** — find the most recently discussed design proposal, refactoring suggestion, or review conclusion, write it as a temporary spec file (`Docs/tmp-review-spec_<YYYYMMDD-HHmm>.md`, named with the current timestamp), then review that file
4. Last resort: use `ls -t Docs/**/*.md | head -1` to find the most recently modified design document

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

#### 2c. Independent Verification (required, parallel subagents)
For each critical and moderate finding, **dispatch a subagent to verify each one in depth** — do not draw conclusions from a quick scan in the main session. Every finding must be verified against the code, no exceptions.

**How to execute:** Group all findings to verify, and for each one (or a few related ones) dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent prompt must include:
1. The original Codex finding description (verbatim)
2. The affected file paths and line numbers
3. A clear verification task: read the actual source code / config files and determine whether Codex's description matches the code
4. For data/config-related claims (e.g. CSV config values, thresholds), require reading the raw files to verify
5. Required output conclusion: **Confirmed** (code supports the finding) / **Rejected** (code does not support the conclusion) / **Partially confirmed** (wording needs adjustment), with cited file paths and key code snippets as evidence

**Over-engineering check:** Also require each subagent to assess whether the implied fix for confirmed findings is proportionate to the problem:
- Does the suggestion add an abstraction layer, configuration option, or generic parameter not needed by current requirements?
- Does it split something simple into multiple parts for "purity" without real decoupling benefit?
- Is the so-called "improvement" actually just pursuing directory cleanliness or naming conventions with no real architectural return?

For disproportionate suggestions, require the subagent to flag them as **Confirmed but over-engineered** — acknowledge the real problem exists, but note the proposed solution is too heavy, and suggest a simpler alternative.

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

## Notes
- The review script is at `./scripts/plan-review.sh` and requires Codex CLI to be configured
- The script automatically appends `CLAUDE.md` coding standards to the review prompt
- **Never blindly trust Codex review results** — Codex may misread code, cite outdated information, or draw conclusions from assumptions. Every finding must be verified against the code
- **Watch out for over-engineering** — Codex tends to suggest maximally "correct" solutions (extra abstraction layers, splitting files for purity, adding generics). Always ask: "Is the fix proportionate to the problem?" If not, choose the simpler path and tell Codex why in the next round
- Do not change design intent on your own initiative — only fix issues identified by the review
- When editing, preserve the document's overall structure; only change what needs to change
- Custom prompt usage: `./scripts/plan-review.sh <file> "custom review prompt"`

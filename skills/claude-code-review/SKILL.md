---
description: "Deep code review via Claude subagent — reviews uncommitted changes by default, loops until no critical issues remain. Use after /qq:test passes, before /qq:commit-push."
---

> **Invoke scripts via `${CLAUDE_PLUGIN_ROOT}/bin/<name>`.** That env var is set by Claude Code for every plugin context and gives the absolute path to the marketplace clone — no PATH or cwd assumptions. Bare-command invocation (e.g. `claude-review.sh`) is NOT reliable: the plugin never puts its scripts on PATH, so bare calls exit 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Arguments: $ARGUMENTS
- No arguments: review uncommitted changes (default)
- `--base <branch>`: full branch diff against a base
- `--commits`: review only the most recent commit
- `--files "a.cs b.cs"`: explicit file list
- `--spec <path>` (repeatable): also check the changes against these specs (design doc, plan, or any doc that records the user's decisions)

## Review Scope Selection (no scope argument)

`--spec`, `--prompt`, and the other flags do not choose the scope. Unless `$ARGUMENTS` has `--base`, `--commits`, or `--files`, pick the scope below and pass it along with the other flags. `--auto` belongs to this skill; the script ignores it.

**Default: uncommitted changes.** Run `{ git diff --name-only HEAD -- '*.cs'; git ls-files --others --exclude-standard -- '*.cs'; } | sort -u` to get the changed and new files. This is the most common case — code has been written but not yet committed.

Override order:
1. **User specified a scope** (e.g. "review Phase 8") → follow user intent
2. **No uncommitted changes but branch has commits** → `git diff --name-only develop...HEAD -- '*.cs'`
3. **User says "review the whole branch"** → `--base develop`

Pass the file list to the review script as `--files`.

## Spec Check

When the changes finish a feature or a milestone, also pass its design doc and plan with `--spec` (next to the scope from above). The review then also lists what the specs ask for that the code does not do, what it does differently, and protections or restrictions nobody asked for. Skip it for small fixes. **Rounds 2+** use the same scope (recomputed the same way, plus every file this review's fixes created or changed) and the same flags, without `--spec`: the `[Spec]` items were listed and verified in round 1.

## Execution Flow

### 2–5. Automated Review Loop

**Loop automatically — do not ask the user between rounds.** Stop when any of the following is true:
- No `[Critical]` issues in the review result, and no code was written for `[Spec]` items this round
- 5 rounds have been completed
- Two consecutive rounds with no new critical issues

Each round:

#### a. Send to Claude for Review
Before sending the diff to Claude, if `qq-policy-check.sh` is available, run it on the same changed `.cs` files first. Treat those deterministic findings as already-established local policy results. Claude should focus on bugs, behavior, architecture, and anything not trivially captured by deterministic checks.

Use the Bash tool with `run_in_background: true` to run in the background:
```bash
${CLAUDE_PLUGIN_ROOT}/bin/claude-review.sh $ARGUMENTS
```
The script calls `claude -p`, with results output to stdout and `Docs/qq/<branch-name>/claude-code-review_<timestamp>.md`. The script always adds a test-quality section (and a spec-conformance section with `--spec`), even with a custom `--prompt`; don't repeat them in your round-2 prompt.
Claude CLI review typically takes 2-5 minutes. Using background execution, the system will automatically notify when the command completes — no need to sleep or poll.
Notify the user that the background task has been submitted and will continue processing automatically when complete.

**From round 2 onward:** If the previous round had findings deemed over-engineered, append `--prompt` to the round-2 arguments (see Spec Check):
```bash
${CLAUDE_PLUGIN_ROOT}/bin/claude-review.sh <round-2 arguments> --prompt "Review these code changes using the same criteria as round 1 (bugs, architecture, performance, security, style). Additional context: the following suggestions from the previous round were deemed over-engineered and replaced with simpler solutions: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Classify by severity: [Critical] [Moderate] [Suggestion]."
```

#### b. Summarize Review Results

After the subagent returns, categorize findings by severity:
- **Critical issues**: Bugs, architectural violations, anti-patterns that must be fixed
- **Moderate issues**: Worth improving but not blocking
- **Suggestions**: Nice-to-have optimizations
- **Spec conformance** (only with `--spec`): `[Spec]` items, listed apart from the severities

Present the summary to the user. **Do not fix code yet — proceed to the verification step first.**

#### c. Independent Verification (required, parallel subagents, gate-enforced)

> **Review Gate:** After the review script runs, a PreToolUse hook blocks Edit/Write on `.cs` and `Docs/*.md` files until at least 1 verification subagent completes. This is a mechanical constraint — you cannot edit code until findings are verified.

For each critical and moderate issue, **dispatch a subagent to verify it in depth** — do not draw conclusions from a quick scan in the main session. Verify Missing, Wrong, and Unrequested `[Spec]` items the same way, passing the spec paths. Needs-runtime-check items and the not-due-yet line are not verified: give the user at most 5 runtime checks (the likeliest to be wrong); the rest stay in the review file.

> **Verify against runtime state, not just source.** When a finding is about *current behavior* (wrong values, missed call sites, broken state), the verifying subagent should query the live Unity Editor through the project's actual channel — not just read source. Work out the channel once ([`shared/unity-live-state.md`](../../shared/unity-live-state.md); exact check: `qq-unity-cli.py channel --project "$PWD"`) and put it in each subagent's prompt:
> - **Official Unity CLI** (`Library/Pipeline/.unity-pipeline-port` exists): `unity command --project-path "$PWD" --json --no-banner <find_gameobjects|get_serialized_fields|get_component_properties|get_console_logs> -- <params>`; look up parameters with `unity command --project-path "$PWD" --query <keyword> --detail full --json` ([`shared/unity-cli-reference.md`](../../shared/unity-cli-reference.md)).
> - **tykit** (`Temp/tykit.json`): `unity_query` / `get-field` / `console` per [`shared/tykit-reference.md`](../../shared/tykit-reference.md).
> - **Neither**: verify from source and say so in the verdict.
>
> Verification is **read-only**: no `set_*`, `menu`, `editor_play`, mutating `eval` / `call-method`, or `run_tests` (tests go through `/qq:test`). Never open or print `Library/Pipeline/.unity-pipeline-port` — it holds an eval token.

**How to execute:** Group all findings that need verification, and for each one (or a cluster of related ones) dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent's prompt must include the original finding (verbatim), relevant file paths, and the instructions from [../../shared/verification-prompt.md](../../shared/verification-prompt.md).

After dispatching all verification subagents, write the expected count to the gate file so the gate knows when all verifications are complete:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
if qq_session_id && [[ -f "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID" ]]; then
  IFS=: read -r ts count _ < "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
  echo "${ts}:${count}:N" > "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
fi
```
(Replace N with the actual number of verification subagents dispatched. The gate file is keyed by this session's id — `qq_session_id` reads `CLAUDE_CODE_SESSION_ID` — so concurrent sessions never share a gate; if this session has no gate file, there is nothing to update.)

**Aggregate:** After all subagents return, consolidate the results and present each finding's verdict and supporting evidence to the user.

#### d. Fix the Code
- For each **confirmed** critical issue, locate and fix the code
- For findings flagged as **Confirmed but over-engineered**, apply a simpler alternative fix
- For confirmed moderate issues, apply fixes at your discretion
- Fix a bug by correcting the logic or the numbers. Protections, added restrictions, and scope cuts are the user's call ([`shared/user-decisions.md`](../../shared/user-decisions.md)): if the only fix you see is one of them, or a confirmed Unrequested `[Spec]` item is one without the user's words, put it on the "Needs the user's decision" list and keep the normal rule in the code
- **Confirmed Missing or Wrong `[Spec]` items:** finish or fix them (not-due-yet items wait for their milestone); if one is too big for this pass, list it in the handoff, never drop it silently
- After each fix, run a build and tests to verify
- After all fixes, present a summary of changes to the user

**Handling test failures:** If build/test runs reveal pre-existing failures unrelated to this change, **ask the user** how to proceed:
1. **Investigate and fix** — dig into these failures and attempt to fix them
2. **Skip and continue** — log the failures and continue the current review cycle
Do not unilaterally decide "unrelated, skip it" — let the user decide.

#### e. Decide Whether to Continue
- If this round had `[Critical]` issues confirmed and fixed → automatically start the next round (back to a)
- If you wrote code for `[Spec]` items this round → run one more round (see Spec Check) so that code gets reviewed, even with no `[Critical]` issues
- Otherwise, if this round had no `[Critical]` issues → output "Review passed" and end the loop
- If 5 rounds are complete → output final status and end the loop
- If two consecutive rounds had no new critical issues → suggest ending the loop

Print `=== Round N/5 ===` at the start of each round.

### 6. Clean Up Gate
After the review loop ends (for any reason), clean up the gate marker:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
if qq_session_id; then rm -f "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"; fi
```

## Handoff

After the review loop ends, recommend the next step:

- **Review passed, no issues** → "Code looks good. Want to run `/qq:test` to verify?"
- **Issues were found and fixed** → "Fixed N issues. Want to run `/qq:test` to make sure nothing broke?"
- **Open `[Spec]` items or "Needs the user's decision" entries** → list each with its spec line, and whether it waits for a later milestone or for the user (also in `--auto` mode; don't wait for answers)
- **5 rounds exhausted with remaining issues** → "Some issues remain after 5 rounds. Run `/qq:test` to check impact, or continue fixing manually?"

**`--auto` mode:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:claude-code-review" --next-skill "/qq:test"`, then invoke `/qq:test --auto`.

## Notes
- The review script is at `claude-review.sh` and requires Claude CLI (`claude`) to be available
- **Never blindly trust Claude review results** — subagents may misread code or reference wrong line numbers. Every finding must go through the verification step
- **Watch for over-engineering** — always ask: "Is the proposed fix proportionate to the problem?"
- When fixing, only address the actual issues the review identified — do not opportunistically refactor surrounding code
- Output path for any generated artifacts uses `Docs/qq/<branch-name>/` where branch name is obtained via `git branch --show-current | tr '/' '_'`

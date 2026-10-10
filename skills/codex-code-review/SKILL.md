---
description: "Cross-model code review via Codex CLI — reviews uncommitted changes by default, loops until no critical issues remain. Use after implementation (e.g. /qq:execute), before /qq:test and /qq:commit-push."
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `code-review.sh` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

> **Workflow:** take `--workflow <name>` from `$ARGUMENTS` if present, else run `qq-config.py field workflow`. On `prototype-loop`, run the single round of [`shared/prototype-loop.md`](../../shared/prototype-loop.md) §Code review instead of the loop below (it ends with recording the review and, when the work is finished, §Closeout); on `heavy-review` (the default), follow this file as written.

Arguments: $ARGUMENTS
- No arguments: review uncommitted changes (default)
- `--base <branch>`: full branch diff against a base
- `--commits`: review only the most recent commit
- `--files "a.cs b.cs"`: explicit file list
- `--spec <path>` (repeatable): also check the changes against these specs (design doc, plan, or any doc that records the user's decisions)

## Review Scope Selection (no scope argument)

`--spec`, `--prompt`, and the other flags do not choose the scope. Unless `$ARGUMENTS` has `--base`, `--commits`, or `--files`, pick the scope below and pass it along with the other flags. `--auto` belongs to this skill and the script ignores it; `--workflow <name>` the script uses only to decide whether to open the review gate.

**Default: uncommitted changes.** Run `{ git diff --name-only HEAD -- '*.cs'; git ls-files --others --exclude-standard -- '*.cs'; } | sort -u` to get the changed and new files.

Override order:
1. **User specified a scope** (e.g. "review Phase 8") → follow user intent
2. **No uncommitted changes but branch has commits** → `git diff --name-only develop...HEAD -- '*.cs'`
3. **User says "review the whole branch"** → `--base develop`

Pass the file list to the review script as `--files`.

## Spec Check

When the changes finish a feature or a milestone, also pass its design doc and plan with `--spec` (next to the scope from above). The review then also lists what the specs ask for that the code does not do, what it does differently, and protections or restrictions nobody asked for. Skip it for small fixes. **Rounds 2+** use the same scope (recomputed the same way, plus every file this review's fixes created or changed) and the same flags, without `--spec`: the `[Spec]` items were listed and verified in round 1.

## Execution Flow

### 1. Review Loop

**Loop automatically, no need to ask the user each round.** Stop when any is true:
- No `[Critical]` issues in Codex review results, and no code was written for `[Spec]` items this round
- 5 rounds completed
- Two consecutive rounds raised no new `[Critical]` issues (only repeats of rejected ones or of items on the "Needs the user's decision" list)

Each round:

#### a. Send to Codex for Review
If `qq-policy-check.sh` is available, first run it on the same changed `.cs` files and treat its deterministic findings as established.

Run in the background (Bash tool, `run_in_background: true`):
```bash
${CLAUDE_PLUGIN_ROOT}/bin/code-review.sh $ARGUMENTS
```
The script runs `codex exec` on a diff it builds, with the Unity best-practice checklist in the prompt (sent on stdin; long argv is truncated on Windows), at the model's highest reasoning level by default. It always adds a test-quality section (and a spec-conformance section with `--spec`), even with a custom `--prompt`; don't repeat them in your round-2 prompt. Results go to stdout and `Docs/qq/<branch-name>/codex-code-review_<timestamp>.md`.

Override reasoning effort per run with `--effort <level>` (any level the model supports, e.g. `high`, `xhigh`, `ultra`; `config` inherits `~/.codex/config.toml`) or globally via the `QQ_CODEX_EFFORT` env var. If Codex answers 400 "model is not supported when using Codex with a ChatGPT account", the CLI is usually older than the model: `npm i -g @openai/codex@latest`.

A review takes 5-15 minutes and you are notified when it finishes; meanwhile you can keep talking with the user.

**From round 2 onward:** If the previous round had findings deemed over-engineered, append `--prompt` to the round-2 arguments (see Spec Check):
```bash
${CLAUDE_PLUGIN_ROOT}/bin/code-review.sh <round-2 arguments> --prompt "Review these code changes using the same criteria as round 1 (bugs, architecture, performance, security, style). Additional context: the following suggestions from the previous round were deemed over-engineered and replaced with simpler solutions: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Classify by severity: [Critical] [Moderate] [Suggestion]."
```

#### b. Read and Summarize Review Results
Read the output file and summarize the findings for the user by severity (`[Critical]`, `[Moderate]`, `[Suggestion]`), with any `[Spec]` items (only with `--spec`) listed apart from the severities.

#### c. Independent Verification
Verify every critical and moderate finding with a subagent, not with a quick look of your own. Verify Missing, Wrong, and Unrequested `[Spec]` items the same way, passing the spec paths. Needs-runtime-check items and the not-due-yet line are not verified: give the user at most 5 runtime checks (the likeliest to be wrong); the rest stay in the review file.

In a Unity project, work out the live Editor channel once — `qq-unity-cli.py channel --project "$PWD"` prints `unity-cli` (calls go through `unity command --project-path "$PWD" --json --no-banner …`), `tykit` or `none`; see [`shared/unity-live-state.md`](../../shared/unity-live-state.md) — and name it in each verifier's prompt (on `tykit`, also give it [`shared/tykit-reference.md`](../../shared/tykit-reference.md)). Item 7 of the verification prompt says how a verifier uses it.

Dispatch the verifiers in parallel with the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), one per finding or per group of related findings. Each prompt must include the original finding (verbatim), relevant file paths, and the instructions from [../../shared/verification-prompt.md](../../shared/verification-prompt.md).

The review script leaves a gate: Edit/Write on `.cs` and `Docs/*.md` files stays blocked until you write the number of verifiers to it and that many have returned. Write it right after dispatching them:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
if qq_session_id && [[ -f "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID" ]]; then
  IFS=: read -r ts count _ < "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
  echo "${ts}:${count}:N" > "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
fi
```
(N = the number of verification subagents dispatched. The gate file is per session; if this session has none, there is nothing to write.)

**Aggregation:** After all subagents return, present each finding's verdict and evidence to the user.

#### d. Fix the Code
- For each **confirmed** critical issue, locate and fix the code
- For findings marked **confirmed but over-engineered**, fix using the simpler alternative, not Codex's original suggestion
- For confirmed moderate issues, fix at discretion
- Fix a bug by correcting the logic or the numbers. Protections, added restrictions, and scope cuts are the user's call ([`shared/user-decisions.md`](../../shared/user-decisions.md)): if the only fix you see is one of them, or a confirmed Unrequested `[Spec]` item is one without the user's words, put it on the "Needs the user's decision" list and keep the normal rule in the code
- **Confirmed Missing or Wrong `[Spec]` items:** finish or fix them (not-due-yet items wait for their milestone); if one is too big for this pass, list it in the handoff, never drop it silently
- After this round's fixes, compile and run the tests covering the changed code (`/qq:test` with the narrowest scope)
- Present a summary of changes to the user

**Test failures unrelated to this change** (e.g. existing bugs in other modules): ask the user whether to investigate and fix them, or note them and continue the review. Don't decide on your own that they can be skipped.

#### e. Determine Whether to Continue
- If this round had `[Critical]` issues confirmed and fixed → automatically start the next round (back to a)
- If every `[Critical]` this round was rejected and nothing was fixed → end the loop and report the rejections with their reasons
- If you wrote code for `[Spec]` items this round → run one more round (see Spec Check) so that code gets reviewed, even with no `[Critical]` issues
- If this round and the previous one raised no new `[Critical]` issues (only repeats of rejected ones or of items on the "Needs the user's decision" list) → output final status and end the loop
- Otherwise, if this round had no `[Critical]` issues → output "Review passed" and end the loop
- If 5 rounds are complete → output final status and end the loop

Output `=== Round N/5 ===` at the start of each round.

### 2. Clean Up Gate
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

**`--auto` mode:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:codex-code-review" --next-skill "/qq:test"`, then invoke `/qq:test --auto`.

## Notes
- `code-review.sh` needs a configured Codex CLI.
- **Zero findings on a 20+ file diff is suspicious**: usually a lowered reasoning effort (check the codex header line `reasoning effort:` and that no `--effort`/`QQ_CODEX_EFFORT` override lowered it) or env/tooling errors. Re-run without an effort override and check stdout for errors before accepting a clean result.
- When fixing, only address the actual issues Codex identified — do not opportunistically refactor surrounding code

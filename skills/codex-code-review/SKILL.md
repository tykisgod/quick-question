---
description: "Cross-model code review via Codex CLI — reviews uncommitted changes by default, loops until no critical issues remain. Use after /qq:test passes, before /qq:commit-push."
---

> **Invoke scripts via `${CLAUDE_PLUGIN_ROOT}/bin/<name>`.** That env var is set by Claude Code for every plugin context and gives the absolute path to the marketplace clone — no PATH or cwd assumptions. Bare-command invocation (e.g. `code-review.sh`) is NOT reliable: the plugin never puts its scripts on PATH, so bare calls exit 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Arguments: $ARGUMENTS
- No arguments: review uncommitted changes (default)
- `--base <branch>`: full branch diff against a base
- `--commits`: review only the most recent commit
- `--files "a.cs b.cs"`: explicit file list

## Review Scope Selection (no arguments)

**Default: uncommitted changes.** Run `git diff --name-only HEAD -- '*.cs'` to get the list of changed files. This is the most common case — code has been written but not yet committed.

Override order:
1. **User specified a scope** (e.g. "review Phase 8") → follow user intent
2. **No uncommitted changes but branch has commits** → `git diff --name-only develop...HEAD -- '*.cs'`
3. **User says "review the whole branch"** → `--base develop`

Pass the file list to the review script as `--files`.

## Execution Flow

### 1-5. Automated Review Loop

**Loop automatically, no need to ask the user each round.** Loop terminates when any condition is met:
- No `[Critical]` issues in Codex review results
- 5 rounds completed
- No new critical issues in two consecutive rounds

Each round:

#### a. Send to Codex for Review
Before sending the diff to Codex, if `qq-policy-check.sh` is available, run it on the same changed `.cs` files first. Treat those deterministic findings as already-established local policy results. Codex should focus on bugs, behavior, architecture, and anything not trivially captured by deterministic checks.

Use the Bash tool with `run_in_background: true` to run in the background:
```bash
${CLAUDE_PLUGIN_ROOT}/bin/code-review.sh $ARGUMENTS
```
The script calls `codex exec` with a manually-constructed diff and the Unity best-practice checklist inlined in the prompt (fed through stdin, never argv — long argv is truncated on Windows). **By default it runs at the configured model's highest supported reasoning level** (read from `~/.codex/models_cache.json`, falling back to `high`), so a low interactive effort in `~/.codex/config.toml` never leaks into reviews. Results are written to stdout and `Docs/qq/<branch-name>/codex-code-review_<timestamp>.md`.

Override reasoning effort per run with `--effort <level>` (any level the model supports, e.g. `high`, `xhigh`, `ultra`; `config` inherits `config.toml`) or globally via the `QQ_CODEX_EFFORT` env var. If Codex answers 400 "model is not supported when using Codex with a ChatGPT account", the CLI is usually older than the model chosen in the desktop app: `npm i -g @openai/codex@latest`.

Codex review typically takes 5-15 minutes at the highest reasoning level. Using background execution, the system will automatically notify when the command completes — no need to sleep or poll.
Notify the user that the background task has been submitted and will continue processing automatically when complete. You may continue other conversations while waiting.

**From round 2 onward:** If the previous round had findings deemed over-engineered, append `--prompt` to the original arguments, keeping `--base` and other flags from `$ARGUMENTS`:
```bash
${CLAUDE_PLUGIN_ROOT}/bin/code-review.sh $ARGUMENTS --prompt "Review these code changes using the same criteria as round 1 (bugs, architecture, performance, security, style). Additional context: the following suggestions from the previous round were deemed over-engineered and replaced with simpler solutions: <list items and rationale>. Do not re-suggest more complex approaches unless the simpler version introduces a real defect. Classify by severity: [Critical] [Moderate] [Suggestion]."
```

#### b. Read and Summarize Review Results
Read the output file and classify by severity:
- **Critical issues**: bugs, architecture violations, anti-patterns that must be fixed
- **Moderate issues**: worth improving but not blocking
- **Suggestions**: nice-to-have optimizations

Present the summary to the user. **Do not fix code directly — enter the verification step first.**

#### c. Independent Verification (required, parallel subagents, gate-enforced)
For each critical and moderate issue, **dispatch a subagent to verify each finding in depth** — do not skim code in the main session and draw quick conclusions. Every finding must be verified against the code, no exceptions.

> **Verify against runtime state, not just source.** When a finding is about *current behavior* ("this field has wrong value", "this method isn't called", "this state machine gets stuck"), the verifying subagent should query the live Unity Editor through the project's actual channel — not just read the source. Source tells you what *could* happen; the Editor shows what *is* happening. Work out the channel once ([`shared/unity-live-state.md`](../../shared/unity-live-state.md); exact check: `qq-unity-cli.py channel --project "$PWD"`) and put it in each subagent's prompt:
> - **Official Unity CLI** (`Library/Pipeline/.unity-pipeline-port` exists): `unity command --project-path "$PWD" --json --no-banner <find_gameobjects|get_serialized_fields|get_component_properties|get_console_logs> -- <params>`; look up parameters with `unity command --project-path "$PWD" --query <keyword> --detail full --json` ([`shared/unity-cli-reference.md`](../../shared/unity-cli-reference.md)).
> - **tykit** (`Temp/tykit.json`): `unity_query` / `get-field` / `console` per [`shared/tykit-reference.md`](../../shared/tykit-reference.md).
> - **Neither**: verify from source and say so in the verdict.
>
> Verification is **read-only**: no `set_*`, `menu`, `editor_play`, mutating `eval` / `call-method`, or `run_tests` (tests go through `/qq:test`). Never open or print `Library/Pipeline/.unity-pipeline-port` — it holds an eval token.

> **Review Gate:** After the review script runs, a PreToolUse hook blocks Edit/Write on `.cs` and `Docs/*.md` files until at least 1 verification subagent completes. This is a mechanical constraint — you cannot edit code until findings are verified.

**Execution:** Group all findings that need verification, and for each (or a related set), dispatch a subagent using the Agent tool (`subagent_type: "general-purpose"`, `model: "opus"`), running in parallel. Each subagent's prompt must include the original finding (verbatim), relevant file paths, and the instructions from [../../shared/verification-prompt.md](../../shared/verification-prompt.md).

After dispatching all verification subagents, write the expected count to the gate file so the gate knows when all verifications are complete:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/platform/detect.sh"
if qq_session_id && [[ -f "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID" ]]; then
  IFS=: read -r ts count _ < "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
  echo "${ts}:${count}:N" > "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
fi
```
(Replace N with the actual number of verification subagents dispatched. The gate file is keyed by this session's id — `qq_session_id` reads `CLAUDE_CODE_SESSION_ID` — so concurrent sessions never share a gate; if this session has no gate file, there is nothing to update.)

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
- **5 rounds exhausted with remaining issues** → "Some issues remain after 5 rounds. Run `/qq:test` to check impact, or continue fixing manually?"

**`--auto` mode:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:codex-code-review" --next-skill "/qq:test"`, then invoke `/qq:test --auto`.

## Notes
- The review script is at `code-review.sh` and requires Codex CLI to be configured. It invokes `codex exec` (not `codex review`) so the custom Unity 18-rule checklist and `--files` / `--ext` scopes keep working — codex-cli 0.118.x's `codex review` has a clap parser conflict making `--base` / `--commit` / `--uncommitted` mutually exclusive with a custom `[PROMPT]`
- **Never blindly trust Codex review results** — Codex may misread code, reference wrong line numbers, or infer from assumptions. Every finding must be verified by reading the code
- **"No findings" is suspicious on large diffs.** A 20+ file change returning zero findings is almost always a symptom of: (a) the run used a low reasoning effort (the script defaults to the model's highest level; verify the codex header line `reasoning effort:` shows it and that no `--effort`/`QQ_CODEX_EFFORT` override lowered it), or (b) the review was interrupted by env/tooling errors. Re-run without an effort override and inspect stdout for error noise before accepting a clean result.
- **Beware of over-engineering** — Codex tends to suggest maximally "pure" solutions (extra layers, file splitting, generics). Always ask: "Is the fix proportionate to the problem?" If not, choose the simpler path and tell Codex why in the next round
- When fixing, only address the actual issues Codex identified — do not opportunistically refactor surrounding code

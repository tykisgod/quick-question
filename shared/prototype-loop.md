# Prototype Loop

qq has two workflows, picked by the `workflow` config key:

- **`heavy-review`** (Heavy Review, the default): every skill runs as its own file describes, with design and plan review loops, per-phase review subagents, and code review loops whose findings are each verified by a subagent behind the review gate.
- **`prototype-loop`** (Prototype Loop): the rules below. The user approves a numbered acceptance checklist, every slice of work starts with a failing check, code is reviewed once, and an agent that did not do the work checks the checklist at the end.

This is not `work_mode: prototype`. That work mode skips design and plan; the prototype loop keeps both but makes them short, and changes how review and execution run.

**Which workflow applies:** `--workflow <name>` in the skill's arguments wins (a `--auto` pipeline passes it when it resumes a step); otherwise run `qq-config.py field workflow`. Exit code 2 means `qq.yaml` or `.qq/local.yaml` is broken: report the error and stop.

**What is off:** the `review_gate` hook is dropped from `enabled_hooks` under this workflow, so review scripts open no gate, unless the project names it in `hooks.enable`. Findings are verified by the main agent, not by one subagent each, and no review loops. If a project did re-enable the gate, verify findings with subagents as the review skill's own verification step says, still for one round only.

## The acceptance checklist

The contract for the whole run. Every later step reads it; nothing outside it gets built.

```markdown
# <Feature Name>: Acceptance Checklist

User's request: "<their exact words, 1-3 lines>" (where and when)
Outcome: <one sentence with a number the closeout will measure, e.g. "a 60-crew ship keeps 50 fps in the port scene">
Approved: "<the user's words when they agreed>" (<date>)

## Needs the user's decision
Omit if none. Plain `- ` bullets; keep this heading in English, verbatim.

## Checklist
1. <what the user gets>. See it: <where: screen, command, file>. Done when: <an observable check>.
2. ...

## Not doing
- <item> (user: "<their words>")
```

- Number the items; never use `- [ ]`: `/qq:execute` ticks unchecked boxes.
- "Not doing" entries that cut part of the user's request need the user's words ([`user-decisions.md`](user-decisions.md)); entries that only draw a boundary around what was never asked for do not.
- Changing the checklist after approval (adding, dropping or rewording an item) needs the user's OK first.

## Design

Write only *what is wanted*: the acceptance checklist above, saved to `Docs/qq/<branch-name>/<feature-name>_design.md` (branch name from `git branch --show-current | tr '/' '_'`). Read the code enough to make "See it" and "Done when" concrete; skip reference-game research, design sections, and `/qq:post-design-review` unless the user asks.

Present the checklist and wait for the user to approve it. This is the only hard stop of the workflow, and it applies with `--auto` too: write the user's words into the `Approved:` line, and only then move on. With `--auto`, before you wait, stop any pipeline still running in this checkout: otherwise the Stop hook keeps pushing its next skill and tells you not to ask the user. Run `qq-execute-checkpoint.py pipeline-clear --project . --status abandoned` (harmless when there is none). The new pipeline starts after the approval: run `qq-execute-checkpoint.py pipeline-start --project . --type feature --current-skill "/qq:design" --workflow prototype-loop --branch "$(git branch --show-current)"`, then the `--auto` handoff of `/qq:design` step 9 (its `pipeline-advance` records the design doc for the later steps). Without `--auto`, recommend `/qq:plan`.

**`/qq:post-design-review`** is not part of this workflow. If the user invokes it directly, run one review round, verify the findings yourself, and stop; no re-review loop.

## Plan

The plan is a slice list, saved to `Docs/qq/<branch-name>/<feature-name>_implementation.md`:

```markdown
# <Feature Name>: Implementation Plan

Design doc: <path>
User's request: <copied verbatim>

## Slices
- [ ] **Slice 1: <title>**. Covers checklist 1, 3. Estimate: <agent time>.
  - Check first: <the test, scenario test, or measuring script>, how to run it, and why it fails today
  - Files: <paths to create or modify>
- [ ] **Slice 2: <title>**. ...
```

Every checklist item is covered by a slice or sits under "Not doing" with the user's words. Checkboxes go only on slices.

Send the plan to review (one round of `/qq:codex-plan-review` or `/qq:claude-plan-review`) only when it touches save data or another persisted format, threading, or a public interface other modules call: those are hard to undo. Otherwise hand off straight to `/qq:execute`. With `--auto`, either way run the `pipeline-advance` of `/qq:plan` §6 (with `--plan-doc` and `--design-doc`) naming the review skill or `/qq:execute` as `--next-skill`, then invoke it with `--auto`.

**Plan review skills** under this workflow: one round, with `--workflow prototype-loop` passed to the review script so it opens no review gate. Verify the Critical and Moderate findings yourself against the plan and the code, fix the confirmed ones, and hand off to `/qq:execute` without a second round.

## Execute

`/qq:execute` keeps its worktree guard, resume check, preflight, compile and checkpoint commands, and its §5 Completion. What changes, in its §4:

- **Each slice:** write its check and run it to see it fail for the reason the plan gives (red). Then implement until the check and the compile pass (green). Then re-read the checklist items the slice covers and note which are met, with the evidence.
- **No review subagents per phase.** Implementation subagents are still fine for independent slices.
- **Re-read the checklist** after writing the plan, when dispatching a subagent, after a context compaction, at the end of each slice, and before handing off. A subagent's prompt contains the checklist verbatim and the line "Findings outside the checklist: note them, don't act on them."
- **Checklist changes** go to the user first; never drop or reword an item on your own.
- **Time:** when a slice has taken more than twice its estimate, tell the user what is taking long and the new estimate before going on.

When all slices are done, finish with `/qq:execute` §5 as written: the seams grep, then `qq-execute-checkpoint.py clear --project .` (without it the checkpoint stays `running` and `/qq:go` keeps sending the work back to `/qq:execute`), the summary, and the handoff to the code review with `--spec <design-doc> --spec <plan>`.

## Code review

`/qq:codex-code-review` and `/qq:claude-code-review` run one round:

1. Run the review script once, with the same scope selection and `--spec` rules as the skill, plus `--workflow prototype-loop` so it opens no review gate whatever the config says.
2. Verify each Critical and Moderate finding, and each Missing, Wrong and Unrequested `[Spec]` item, yourself against the code. Present the verdicts.
3. Fix the confirmed ones under the skill's fix rules (protections, added restrictions and scope cuts stay the user's call), then run the checks that cover the fixed code. No second round.
4. Record the review so `/qq:go` stops recommending it: `qq-run-record.py record --project . --stage review_gate --command "/qq:<this skill>" --status verified --state-only`.
5. If this review finishes the plan's work, run the closeout below. Then hand off to `/qq:test`; with `--auto`, `pipeline-advance` to it and invoke `/qq:test --auto`.

## Closeout

Before the work is handed over, dispatch one agent that did not take part in the work (Agent tool, `subagent_type: "general-purpose"`, `model: "opus"`). Its prompt holds the checklist verbatim and the design and plan paths, and tells it to:

- measure the Outcome's number first and report it as measured value against target;
- go through the checklist item by item and demand evidence for each: run the check, open the file, read the code. An item without evidence is "not met", never "probably met";
- list separately the items only a person can judge (feel, look, fun), each with how to try it;
- fix nothing, and write its report to `Docs/qq/<branch-name>/<feature-name>_acceptance.md`.

Do not edit its verdicts. Then follow the project's own handoff (its `CLAUDE.md` or `AGENTS.md`), quoting the measured number and every item not met.

## --auto

`/qq:go --auto` under this workflow replaces the `feature` path with:

design → (user approves the checklist) → plan → (one plan review, only for hard-to-undo plans) → execute → one code review round with closeout → test → commit-push

- No approved checklist yet: invoke `/qq:design --auto` **without** `pipeline-start`. Design stops any older pipeline still running here (`pipeline-clear`) before it waits, and starts the new one after the approval (§Design), so no Stop hook pushes on while the user decides.
- Approved checklist, no plan: `pipeline-start` with `/qq:design`, then `pipeline-advance --completed-skill "/qq:design" --next-skill "/qq:plan" --design-doc <design-doc>` and `/qq:plan --auto <design-doc>`. Plan exists: `pipeline-start` with `/qq:execute`, then `/qq:execute --auto <plan>`.
- Each `pipeline-start` gets `--workflow prototype-loop`, so the pipeline records this workflow even when the config says otherwise, and resumes each step with it.
- The `prototype`, `fix` and `hardening` work modes keep their own paths; any design, plan or review step they reach runs the prototype-loop way.

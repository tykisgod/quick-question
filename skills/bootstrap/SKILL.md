---
description: "Decompose a high-level game vision (pillars + rules + references) into executable epics, then orchestrate the full qq pipeline for each. Use when starting a new project, bootstrapping a prototype from a pitch, or breaking a large initiative into parallel workstreams."
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `qq-bootstrap-state.py` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Arguments: $ARGUMENTS (a description, a file path to a pitch/checklist document, or empty for interactive)

This skill is an orchestrator: it drives other qq skills and never writes code itself.

## Phase 1: Understand the Vision

Read the input. Extract:

- **Pillars** — the 3-5 non-negotiable design pillars (e.g., "turn-based PVP", "simple multiplayer", "WWII theme")
- **Fragment rules** — specific details mentioned in passing (unit types, reference games, feel descriptions)
- **Reference games** — any games mentioned as inspiration

Then ask about what the input and the project leave open, at most 5 questions in total; make reasonable assumptions for non-critical unknowns:

1. **Target experience** — "What should 10 minutes of gameplay feel like?"
2. **Scope** — "Is this a full game or a playable demo/prototype? How many sessions to reach 'done'?"
3. **Platform & tech** — engine, target platform, multiplayer architecture
4. **Art direction** — placeholder/greybox or a specific style (if relevant)
5. **Hard constraints** — budget, timeline, team size, must-use systems

## Phase 2: Decompose into Epics

Break the vision into **epics** — each a self-contained vertical slice that can go through the full qq pipeline independently.

Rules:
- Each epic should be completable in 1-3 qq pipeline runs (design → plan → execute → test)
- Epics have explicit dependencies: which must finish before which can start
- Flag which epics can run in parallel
- Order by: dependencies first, then core-to-peripheral (get the core loop working before polish)

Save the manifest to `Docs/qq/<branch-name>/bootstrap-manifest.md` and present it to the user for confirmation. This is the key human checkpoint: the user approves the breakdown before any automation begins.

After approval, initialize state tracking (`--pretty` goes before the subcommand):
```bash
qq-bootstrap-state.py --pretty init \
  --project . --name "<project-name>" \
  --manifest "Docs/qq/<branch-name>/bootstrap-manifest.md" \
  --epics "Epic 1 name" "Epic 2 name" "Epic 3 name" ... \
  --max-retries 3
```

Then set each epic's dependencies, adding `--parallel` for the epics flagged as parallel:
```bash
qq-bootstrap-state.py --pretty set-deps --project . --epic-id 2 --depends-on "1"
qq-bootstrap-state.py --pretty set-deps --project . --epic-id 3 --depends-on "1,2"
```

## Phase 3: Execute Epics

Check which epics are actionable:
```bash
qq-bootstrap-state.py --pretty status --project .
```

For each actionable epic (pending + all dependencies completed):

1. Mark as running:
   ```bash
   qq-bootstrap-state.py --pretty start-epic --project . --epic-id <N>
   ```
2. Invoke `/qq:design --auto` with the epic description + relevant pillars
3. The qq pipeline takes over: design → post-design-review → plan → plan-review → execute → code review → test → commit-push (under `workflow: prototype-loop`: design → the user approves the epic's checklist → plan → execute → one code review round → test → commit-push, see [`shared/prototype-loop.md`](../../shared/prototype-loop.md))
4. On pipeline success:
   ```bash
   qq-bootstrap-state.py --pretty complete-epic --project . --epic-id <N>
   ```
5. On pipeline failure:
   ```bash
   qq-bootstrap-state.py --pretty fail-epic --project . --epic-id <N> --reason "<what failed>"
   ```
   - If script returns `"action": "retry"` → retry the failed pipeline step
   - If script returns `"action": "paused"` → skip this epic, report to user, move to next

**Parallel execution**: when `status` shows multiple actionable epics with `parallel: true`, dispatch each as a separate subagent using the Agent tool with `isolation: "worktree"`. Each subagent runs the full qq pipeline for its epic.

**Between epics**: always re-check `status` to get the next actionable set. Don't hardcode the order — let the state script resolve dependencies.

## Phase 4: Integration Check

After all epics complete (or all non-paused ones):

1. Run `/qq:test` on the combined result
2. If tests fail, analyze which epic interactions caused issues
3. Fix integration problems (this may require a new mini-epic)
4. Run `/qq:commit-push` for the final integrated state
5. Clear state:
   ```bash
   qq-bootstrap-state.py --pretty clear --project .
   ```

## Resume

After a crash or in a later session, run `qq-bootstrap-state.py --pretty status --project .` — it shows which epics are completed, paused and next — and resume from the first actionable epic.

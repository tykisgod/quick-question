---
description: "Decompose a high-level game vision (pillars + rules + references) into executable epics, then orchestrate the full qq pipeline for each. Use when starting a new project, bootstrapping a prototype from a pitch, or breaking a large initiative into parallel workstreams."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Take a high-level game vision and turn it into a structured, executable project — decomposing pillars into epics, then driving each through the qq pipeline.

Arguments: $ARGUMENTS (a description, a file path to a pitch/checklist document, or empty for interactive)

## Phase 1: Understand the Vision

Read the input. Extract:

- **Pillars** — the 3-5 non-negotiable design pillars (e.g., "turn-based PVP", "simple multiplayer", "WWII theme")
- **Fragment rules** — specific details mentioned in passing (unit types, reference games, feel descriptions)
- **Reference games** — any games mentioned as inspiration

Then **ask about gaps**, using these preset directions (ask only what's missing, skip what's already covered):

1. **Target experience** — "What should 10 minutes of gameplay feel like?" (if not clear from input)
2. **Scope** — "Is this a full game or a playable demo/prototype? How many sessions to reach 'done'?"
3. **Platform & tech** — engine, target platform, multiplayer architecture (if not obvious from project context)
4. **Art direction** — placeholder/greybox or specific style? (if relevant)
5. **Hard constraints** — budget, timeline, team size, must-use systems

Max 5 questions total. Make reasonable assumptions for non-critical unknowns.

## Phase 2: Decompose into Epics

Break the vision into **epics** — each a self-contained vertical slice that can go through the full qq pipeline independently.

Rules:
- Each epic should be completable in 1-3 qq pipeline runs (design → plan → execute → test)
- Epics have explicit dependencies: which must finish before which can start
- Flag which epics can run in parallel
- Order by: dependencies first, then core-to-peripheral (get the core loop working before polish)

Output a manifest file and save to `Docs/qq/<branch-name>/bootstrap-manifest.md`.

Present to user for confirmation. **This is the key human checkpoint** — user approves the breakdown before automation begins.

After approval, initialize state tracking:
```bash
qq-bootstrap-state.py init \
  --project . --name "<project-name>" \
  --manifest "Docs/qq/<branch-name>/bootstrap-manifest.md" \
  --epics "Epic 1 name" "Epic 2 name" "Epic 3 name" ... \
  --max-retries 3 --pretty
```

Then set dependencies and parallel flags for each epic:
```bash
qq-bootstrap-state.py set-deps --project . --epic-id 2 --depends-on "1" --pretty
qq-bootstrap-state.py set-deps --project . --epic-id 3 --depends-on "1,2" --pretty
```

## Phase 3: Execute Epics

Check which epics are actionable:
```bash
qq-bootstrap-state.py status --project . --pretty
```

For each actionable epic (pending + all dependencies completed):

1. Mark as running:
   ```bash
   qq-bootstrap-state.py start-epic --project . --epic-id <N> --pretty
   ```
2. Invoke `/qq:design --auto` with the epic description + relevant pillars
3. The qq pipeline takes over: design → post-design-review → plan → plan-review → execute → test → commit-push
4. On pipeline success:
   ```bash
   qq-bootstrap-state.py complete-epic --project . --epic-id <N> --pretty
   ```
5. On pipeline failure:
   ```bash
   qq-bootstrap-state.py fail-epic --project . --epic-id <N> --reason "<what failed>" --pretty
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
   qq-bootstrap-state.py clear --project . --pretty
   ```

## Resume

If a session crashes or the user resumes later, run:
```bash
qq-bootstrap-state.py status --project . --pretty
```
This shows exactly which epics are completed, which are paused, and which are next. Resume from the first actionable epic.

## Notes

- Phase 2 (epic decomposition) is the most important human checkpoint — get this right before automating
- Each epic goes through the full qq quality pipeline (design review, plan review, code review, tests)
- The state script enforces retry limits — Claude cannot forget or miscount
- The manifest in `Docs/qq/` is human-readable; the state in `.qq/state/bootstrap.json` is machine-readable
- For Jira/Asana integration: after Phase 2, optionally create issues from the manifest using available MCP tools
- This skill is an orchestrator — it invokes other skills, never writes code itself

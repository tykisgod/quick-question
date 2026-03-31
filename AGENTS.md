# AGENTS.md

## Refactoring Authority

This repository explicitly allows aggressive refactoring when it improves the design.

- Large-scale refactors, full rewrites, file moves, and architectural cleanup are allowed.
- Backward compatibility is not required unless a task explicitly asks for it.
- Prefer the cleanest end-state over incremental compatibility layers.
- Remove obsolete code paths instead of preserving them out of habit.

## Default Engineering Bias

- Optimize for clarity, fewer layers, and stronger core abstractions.
- If the current shape is fighting the design, rewrite it instead of patching around it.
- Keep migration logic only when there is a real user or release requirement.

## Trust Levels

`qq.yaml` supports a separate `trust_level` knob:

- `trusted`: current internal-team default
- `balanced`: disable automatic Context Capsule consumption and only widen Codex into the source worktree for closeout-like flows
- `strict`: require explicit `--allow-source-worktree` and keep raw engine commands off the standard MCP surface

When touching host wrappers, Context Capsule consumption, or MCP exposure, preserve this split:

- `work_mode` = task stage
- `policy_profile` = verification floor
- `trust_level` = automatic permission boundary

## Execution Environment Split

When developing this repository, treat execution environments as a hard split:

- Use **worktrees** to isolate tasks.
- Use **Docker / Dev Container** for repository-side development:
  - `scripts/*.sh`
  - `scripts/*.py`
  - `README`
  - `docs`
  - `install.sh`
  - `test.sh`
  - policy / doctor / controller / runtime-core changes
- Use the **host machine** for Unity-specific validation:
  - `tykit`
  - Unity compile/test routing
  - real project install flow
  - Editor-backed Claude/Codex E2E
  - any check that depends on a live Unity Editor

Do not try to force local Unity Editor work into Docker.

Default repo-dev loop:

1. Create a dedicated worktree for the task.
2. Use `./scripts/docker-dev.sh build` once if needed.
3. Do repo-side development in `./scripts/docker-dev.sh shell`.
4. Run `./scripts/docker-dev.sh test` for repo-side validation.
5. If the change touches Unity behavior, switch back to the host and validate against a real Unity project.

## Parallel Agent Rule

When one person is driving multiple agents at the same time:

- Use **one worktree per agent / feature**.
- It is fine to use **one Docker container session per agent**.
- Multiple agent containers may reuse the **same Docker image**.
- Do **not** let two agents share one worktree, even if they are running in different containers.

Why:

- **worktree** isolation protects files and git state
- **container** isolation protects process and shell state

If two agents mount the same worktree, they can still overwrite each other's files. Docker does not prevent that.

Recommended pattern:

1. Create one worktree per feature.
2. Build the repo-dev image once with `./scripts/docker-dev.sh build`.
3. Let each agent use its own worktree and its own `./scripts/docker-dev.sh shell` session.
4. Let each agent run `./scripts/docker-dev.sh test` in that worktree before handoff or merge.
5. If a task touches Unity / `tykit`, validate that task on the host machine instead of trying to force it into Docker.

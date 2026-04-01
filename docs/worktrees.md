# Parallel Worktrees

When unrelated tasks should progress in parallel, use qq-managed linked worktrees instead of reusing one filesystem and flipping branches. Each worktree gets its own `.qq/local.yaml`, independent compile/test state, and clean git isolation.

## Why Worktrees

A single working tree forces stashing, partial commits, or merge conflicts when switching tasks. qq-managed worktrees give each task its own directory, branch, runtime cache, and `.qq/` state -- agents never collide.

## Creating a Worktree

```bash
python3 ./scripts/qq-worktree.py create --name sea-monster --pretty
```

This creates:

- A linked branch (e.g. `feature/crew-wt-sea-monster`) from your current branch
- A sibling worktree directory (e.g. `../project-wt-sea-monster`)
- Local metadata in `.qq/state/worktree.json`
- A seeded runtime cache (Unity `Library/`, etc.) from the source worktree, so tests run without cold-import cost

Optional: `--source-branch`, `--branch`, `--path`, `--base-dir` control placement; `--allow-main` permits branching from protected branches; `--allow-dirty-source` skips the clean-source check.

## Working in a Worktree

1. `cd` into the worktree directory (e.g. `../project-wt-sea-monster`)
2. Set `.qq/local.yaml` for this task's `work_mode`
3. Use `/qq:go` as normal -- it detects the worktree context
4. Check worktree state at any time:

```bash
python3 ./scripts/qq-worktree.py status --pretty
```

Status output includes `isManagedWorktree`, `sourceBranch`, `linkedBranch`, and readiness flags.

## Closing Out

After the task is verified and pushed:

```bash
python3 ./scripts/qq-worktree.py closeout --auto-yes --delete-branch --pretty
```

`closeout` merges the linked branch back, pushes the source branch, and removes the worktree directory. Treat it as the final action in that session.

If a step fails, run `status --pretty` and check `canMergeBack`, `canPushSource`, `canCleanup`. You can also run the steps individually:

```bash
python3 ./scripts/qq-worktree.py merge-back --auto-yes --push-source --pretty
python3 ./scripts/qq-worktree.py cleanup --delete-branch --pretty
```

## Runtime Cache Seeding

If a managed worktree loses its `Library/` (Unity) or equivalent cache:

```bash
python3 ./scripts/qq-worktree.py seed-runtime-cache --pretty
```

`unity-test.sh` does this automatically. Pass `--refresh` to force a full reseed.

## Best Practices

- **One worktree per task/feature.** Keep scope isolated.
- **One agent per worktree.** Never share between concurrent agents.
- **Use `.qq/local.yaml`** in each worktree for task-specific config.
- **Close out via the worktree command**, not manual git operations.

## Integration with /qq:execute

`/qq:execute plan.md --worktree` creates an isolated worktree before starting implementation.

## Related

- [Configuration](configuration.md) -- `.qq/local.yaml` overrides
- [Developer Workflow](developer-workflow.md) -- worktrees for repo development
- [Getting Started](getting-started.md) -- workflow examples

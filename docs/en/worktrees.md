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

## Integration with /qq:execute and /qq:go

**Worktrees are on by default.** Both `/qq:execute` and `/qq:go` enter an isolated worktree automatically before doing any work. You do NOT pass a `--worktree` flag — that's the default.

To opt out, pass `--no-worktree` as a literal token:

```
/qq:execute plan.md --no-worktree
/qq:go --no-worktree
```

The skill will only honor the literal flag — agent-invented "semantic bypass" is forbidden by the skill specification (see [skills/execute/SKILL.md](../../skills/execute/SKILL.md) Section 1).

### Conditions where the worktree step is skipped automatically

| Skill | Skip conditions (any one is enough) |
|---|---|
| `/qq:execute` | Already inside a git worktree; literal `--no-worktree` token; trivially small plan (≤3 steps, ≤3 files, no .cs compilation) |
| `/qq:go` | Already in a worktree; literal `--no-worktree` token; recommended next skill is read-only (`/qq:changes`, `/qq:deps`, `/qq:explain`, `/qq:brief`, `/qq:full-brief`, `/qq:timeline`) |

The skill must state its skip reason in its first message — silent skips are banned.

### Common obstacles handled automatically

The skill detects and fixes these obstacles instead of bypassing the worktree check:

| Obstacle | What the skill does |
|---|---|
| Plan file is untracked | Commits the plan first (`docs(plan): <slug>`), then enters the worktree, so the plan is accessible via git history |
| Working tree has uncommitted unrelated changes | Tells the user to commit or stash; never proceeds in dirty main |
| `EnterWorktree` tool unavailable | Falls back to `qq-worktree.py create --name <slug>`, asks the user to reopen in the new path, and stops |

### EnterWorktree HEAD verification

When the skill uses Claude Code's `EnterWorktree` tool, it captures the source branch's `HEAD` before the call and verifies after the call that the new worktree's `HEAD` includes the source `HEAD` (via `git merge-base --is-ancestor`). `EnterWorktree` branches from `origin/<default-branch>` unless `worktree.baseRef` is `head`; when the new worktree does not contain the source `HEAD` (e.g. it started from `develop` instead of the feature branch), the skill auto-recovers via `git reset --hard $SOURCE_HEAD`. This guarantees the new worktree's branch is correctly rooted at the source branch — `commit-push`'s eventual merge-back will pick up the right history, and `git diff source...HEAD` scoping in code review remains accurate.

If you create a worktree manually via `qq-worktree.py create`, this verification is unnecessary — `qq-worktree.py` always uses the current branch (or an explicit `--source-branch`) and never silently rebases.

## Related

- [Configuration](configuration.md) -- `.qq/local.yaml` overrides
- [Developer Workflow](../dev/developer-workflow.md) -- worktrees for repo development
- [Getting Started](getting-started.md) -- workflow examples

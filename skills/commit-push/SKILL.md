---
description: "Batch commit all uncommitted changes and push to the remote repository."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Batch commit all uncommitted changes and push to the remote repository.

## Steps

1. If `./scripts/qq-project-state.py` exists, run it first:
   ```bash
   "${QQ_PY:-python3}" ./scripts/qq-project-state.py --pretty
   ```
   Interpret it like this:
   - `recommended_next == "/qq:commit-push"` → normal ship path, continue
   - otherwise → stop and tell the user the actual next step first
   - if the user explicitly says to force the push anyway, note the risk and continue
2. Run `git status -u` and `git diff --stat` to view all uncommitted changes
3. Analyze the changes and group them by **logical relationship** (do not mix unrelated changes into the same commit):
   - Feature code changes in one group (feat/fix/refactor)
   - Asset files (prefabs, assets, scenes) in one group
   - Config/docs in one group
   - If all changes belong to the same feature, a single commit is fine
4. For each group:
   - `git add` the relevant files (do not use `git add -A`; specify files individually)
   - Write a commit message in conventional commit style
   - Append `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>` at the end of the commit message
5. After all commits are done, run `git push`
6. **Worktree closeout** — detect worktree type and close out:

   **Type A: EnterWorktree session** (CWD is inside `.claude/worktrees/`):
   - Identify the source branch: `git log --oneline --all --decorate | head -5` or read the branch the worktree was based on
   - Merge worktree branch back to source: `git checkout <source-branch> && git merge <worktree-branch>`
   - Push source branch: `git push`
   - Call `ExitWorktree` tool with `action: "remove"` to clean up and return to original CWD

   **Type B: qq-managed worktree** (`./scripts/qq-worktree.py` exists and `isManagedWorktree=true`):
   - Prefer one-step closeout:
     ```bash
     "${QQ_PY:-python3}" ./scripts/qq-worktree.py closeout --auto-yes --delete-branch --pretty
     ```
   - If closeout refuses, inspect `qq-worktree.py status --pretty`
   - Only fall back to separate `merge-back` / `cleanup` when debugging

   **Type C: Not in a worktree** → normal path, stop after push

## Exclusion rules

Do not commit:
- `.env`, API keys, credentials, or other sensitive files
- Files matched by `.gitignore`
- `.obsidian/` directory

## Notes

- If there are no changes at all, just inform the user
- In `hardening`-style flows, treat `/qq:commit-push` as the end of the verified path, not the place to discover missing tests/review/doc drift
- In any worktree (EnterWorktree or qq-managed), closeout belongs here, after verification and after push
- For EnterWorktree worktrees: merge back via git, then ExitWorktree(remove)
- For qq-managed worktrees: use `closeout` as the default path
- Keep commit messages concise and focused on "what was done" rather than "which files were changed"
- Check the style of recent commits and stay consistent

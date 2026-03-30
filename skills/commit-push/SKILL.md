---
description: "Batch commit all uncommitted changes and push to the remote repository."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Batch commit all uncommitted changes and push to the remote repository.

## Steps

1. If `./scripts/qq-project-state.py` exists, run it first:
   ```bash
   python3 ./scripts/qq-project-state.py --pretty
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
6. If `./scripts/qq-worktree.py` exists, inspect worktree context:
   ```bash
   python3 ./scripts/qq-worktree.py status --pretty
   ```
   Interpret it like this:
   - `isManagedWorktree=false` → normal path, stop after push
   - `isManagedWorktree=true` → this branch was created by qq for isolated development
7. For a qq-managed worktree, after push:
   - prefer one-step closeout:
     ```bash
     python3 ./scripts/qq-worktree.py closeout --auto-yes --delete-branch --pretty
     ```
   - if `closeout` refuses to continue, inspect:
     ```bash
     python3 ./scripts/qq-worktree.py status --pretty
     ```
   - only fall back to separate `merge-back` / `cleanup` if you are debugging a closeout failure
   - explain that closeout removes the current linked worktree directory, so it should be the final action in this session

## Exclusion rules

Do not commit:
- `.env`, API keys, credentials, or other sensitive files
- Files matched by `.gitignore`
- `.obsidian/` directory

## Notes

- If there are no changes at all, just inform the user
- In `hardening`-style flows, treat `/qq:commit-push` as the end of the verified path, not the place to discover missing tests/review/doc drift
- In a qq-managed worktree, closeout belongs here, after verification and after the remote branch is pushed
- `closeout` should be the default path; use separate `merge-back` / `cleanup` only when debugging
- Keep commit messages concise and focused on "what was done" rather than "which files were changed"
- Check the style of recent commits and stay consistent

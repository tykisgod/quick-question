---
description: "Batch commit all uncommitted changes and push to the remote repository."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Batch commit all uncommitted changes and push to the remote repository.

## Steps

1. Run `git status -u` and `git diff --stat` to view all uncommitted changes
2. **Worktree detection** — run `git worktree list` and check if the current directory is a linked worktree (not the main working tree). If it is:
   - Identify the **source branch** by parsing the worktree branch name (convention: `<source>-wt-<name>` → source is `<source>`) or by checking the main worktree's branch from `git worktree list`
   - Identify the **main worktree directory** from the first line of `git worktree list`
   - Inform the user: "You're in a worktree on branch `<branch>`. After committing, I can merge back to `<source-branch>` and clean up."
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
6. **Worktree merge-back** (only if worktree was detected in step 2) — ask the user: "Merge `<worktree-branch>` back to `<source-branch>` and delete the worktree?"
   - **Yes** (default) →
     ```bash
     # Get main worktree directory from first line of: git worktree list
     MAIN_WORKTREE_DIR="<first entry path from git worktree list>"
     cd "$MAIN_WORKTREE_DIR"
     git merge <worktree-branch>
     git worktree remove <worktree-dir>
     git branch -d <worktree-branch>
     ```
     If merge conflicts occur, resolve them and inform the user.
   - **No** → skip merge, leave the worktree in place

## Exclusion rules

Do not commit:
- `.env`, API keys, credentials, or other sensitive files
- Files matched by `.gitignore`
- `.obsidian/` directory

## Notes

- If there are no changes at all, just inform the user
- Keep commit messages concise and focused on "what was done" rather than "which files were changed"
- Check the style of recent commits and stay consistent

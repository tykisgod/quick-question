---
description: "Batch commit all uncommitted changes and push to the remote repository."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Batch commit all uncommitted changes and push to the remote repository.

## Steps

1. Run `git status -u` and `git diff --stat` to view all uncommitted changes
2. Analyze the changes and group them by **logical relationship** (do not mix unrelated changes into the same commit):
   - Feature code changes in one group (feat/fix/refactor)
   - Asset files (prefabs, assets, scenes) in one group
   - Config/docs in one group
   - If all changes belong to the same feature, a single commit is fine
3. For each group:
   - `git add` the relevant files (do not use `git add -A`; specify files individually)
   - Write a commit message in conventional commit style
   - Append `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>` at the end of the commit message
4. After all commits are done, run `git push`

## Exclusion rules

Do not commit:
- `.env`, API keys, credentials, or other sensitive files
- Files matched by `.gitignore`
- `.obsidian/` directory

## Notes

- If there are no changes at all, just inform the user
- Keep commit messages concise and focused on "what was done" rather than "which files were changed"
- Check the style of recent commits and stay consistent

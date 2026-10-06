---
description: "Batch commit all uncommitted changes (or only the given files) and push to the remote repository."
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `qq-project-state.py` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Arguments: $ARGUMENTS
- File paths: commit only these files

## Steps

1. If `qq-project-state.py` is available, run it first:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/bin/qq-project-state.py --pretty
   ```
   - `recommended_next == "/qq:commit-push"` → normal ship path, continue
   - otherwise → stop and tell the user the actual next step first
   - if the user explicitly says to force the push anyway, note the risk and continue
   - with file arguments that are all docs/config (no engine source, e.g. the doc-only commit `/qq:doc-sync` hands over), skip this check
2. Run `git status -u` and `git diff --stat` to view the uncommitted changes
3. Group them by **logical relationship** (do not mix unrelated changes into one commit): feature code (feat/fix/refactor), asset files (prefabs, assets, scenes), config/docs. One commit is fine when everything belongs to the same feature.
4. For each group:
   - `git add -- <files>` then `git commit -- <files>` (never `git add -A` / `commit -a`; the pathspec on the commit keeps out changes another session staged). While a merge is in progress (`MERGE_HEAD` exists) git refuses a partial commit: `git add -- <resolved files>`, then a plain `git commit --no-edit`
   - Write the message in the style of the repo's recent commits (conventional-commit style when there is no established style)
5. After all commits are done, run `git push`
6. **Worktree closeout** (skip when not in a linked worktree):
   - From inside the worktree, run `${CLAUDE_PLUGIN_ROOT}/bin/qq-worktree.py status --pretty` first. Continue only when `isManagedWorktree` and `sourceWorktreeClean` are true and `localChanges` is false; otherwise stay in the worktree and tell the user why (an `EnterWorktree` worktree that `/qq:execute` or `/qq:go` never seeded is not qq-managed).
   - Clear the auto-pipeline here, before leaving the worktree, if one is active: `${CLAUDE_PLUGIN_ROOT}/bin/qq-execute-checkpoint.py pipeline-clear --project . --status completed`
   - If this session entered the worktree with `EnterWorktree`, then call `ExitWorktree` with `action: "keep"`, and pass `--project <worktree path>` below: closeout deletes the worktree directory.
   - Close out in one step. It merges into the source branch recorded in `.qq/state/worktree.json`, pushes it, then removes the worktree and its branch:
     ```bash
     ${CLAUDE_PLUGIN_ROOT}/bin/qq-worktree.py closeout --auto-yes --delete-branch --pretty
     ```
   - If closeout still refuses: a merge conflict or a rejected push sits in the source checkout, so resolve it there; for any other refusal, go back with `EnterWorktree` `path: <worktree path>` before making further edits. Fall back to separate `merge-back` / `cleanup` only when debugging.
7. **Clear auto-pipeline** (if active and step 6 did not already): `${CLAUDE_PLUGIN_ROOT}/bin/qq-execute-checkpoint.py pipeline-clear --project . --status completed`

## Never commit

- `.env`, API keys, credentials, or other sensitive files
- `.obsidian/`

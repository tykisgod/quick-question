---
description: "Review a game design document from an implementer's perspective — check self-consistency, playability, buildability, and codebase gaps. Use after writing a design doc, or when you want to validate an existing design against the current codebase."
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `qq-execute-checkpoint.py` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Review a game design document from an implementer's perspective.

> **Workflow:** take `--workflow <name>` from `$ARGUMENTS` if present, else run `qq-config.py field workflow`. On `prototype-loop`, this review is not a step of the workflow: when invoked directly, run one round and stop ([`shared/prototype-loop.md`](../../shared/prototype-loop.md) §Design); on `heavy-review` (the default), follow this file as written.

Arguments: $ARGUMENTS (path to a design document, or empty to use the most recent design doc in `Docs/qq/`)

## Process

1. **Find the document:** if a path is given, read it. Otherwise, find the most recent `*_design.md` in `Docs/qq/`.
2. **Spawn a review subagent** (Agent tool) that reads [design-reviewer-prompt.md](design-reviewer-prompt.md) and the design document, checks the document's claims against the codebase itself, and returns the review in that prompt's format.
3. **Verify, then present:** check each finding yourself against the document and the code; the subagent can misread code or cite stale information. Present only the findings you confirmed, and say which ones you rejected and why.
4. **If verdict is HAS GAPS or NEEDS REWORK:** revise the document together with the user. Re-run the subagent review after revisions. Loop until SOLID or the user explicitly accepts the gaps. Items moved to the document's "Needs the user's decision" list count as resolved.
5. **If verdict is SOLID:** confirm and recommend `/qq:plan`. **If invoked with `--auto`:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:post-design-review" --next-skill "/qq:plan"`, then invoke `/qq:plan --auto <document-path>`.

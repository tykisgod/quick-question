---
description: "Local on-demand doc-sync: detect doc↔code drift, draft the reconciling updates (anchors + prose), present them as a reviewable diff, and land only what the human approves. Goes beyond qq:doc-drift's report-only by closing the loop — but never auto-commits and never touches code."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Pull drifted docs back in line with the code, run on demand when the human knows they changed something doc-affecting. doc-sync **calls** `/qq:doc-drift` (and the project's drift detectors) as its detection stage, then adds the two stages doc-drift lacks: **draft** the fixes and **land** what the human approves.

Arguments: $ARGUMENTS
- No arguments: full sweep of the project's living docs
- `--since <ref>`: only docs affected by code changed since `<ref>` (windowed reconcile)
- `--scope <design|memory|seams|rules>`: restrict to one class of living doc
- `--all`: also include `Docs/archive/` and old review artifacts

## Principle

> **Detectors are read-only; doc-sync is the sole writer, and only of docs — never code; the human is the sole lander. Reference drift (a dead anchor) is auto-drafted; semantic/process drift is only flagged for the human to decide.**
> Graphs say "what is wired now"; the seam registry says "what should be wired / what breaks if missing" — neither overwrites the other.

## Execution Flow

### 1. Discover the project's drift tooling (project-aware)

Probe for these and use whatever exists — degrade gracefully when absent (a generic project just gets doc-drift + git-diff reasoning):

| If present | Use it for |
|---|---|
| `Tools/blast_radius.py` | "changed files → affected docs + code-side ripple" (`diff [base]` / `who <token>`) |
| `Tools/check_doc_drift.py` | symbol-anchor drift in docs (LINEREF / missing file / missing GUID / 0-hit symbol) |
| `Tools/check_memory.py` | memory consistency + staleness (`audit`); re-stamp via `stamp <date> <files>` |
| `Tools/check_seams.py` | `.claude/seams.yml` anchor drift |
| `.claude/seams.yml` | cross-cutting seam registry (fan-out points) |
| `Tools/asset_graph.py` / `Tools/event_graph.py` | Unity asset / event-bus blast-radius |

### 2. Detect (read-only)

- **Scope the work.** With `--since <ref>`, run `python Tools/blast_radius.py diff <ref>` to get changed-files → affected docs + ripple. Otherwise sweep: `check_doc_drift.py` over `Docs/` + `.claude/rules/`, `check_memory.py audit`, `check_seams.py`.
- **Semantic layer.** Invoke `/qq:doc-drift` (using the Skill tool) for the affected modules — design-doc-vs-code intent mismatches the anchor checkers can't see.
- **Ignore noise.** Reconcile only against *semantic* code changes; skip test-only changes, `.meta` files, formatting churn, dependency bumps, and pure internal refactors.
- **Classify every finding** into two buckets — this decides whether doc-sync may auto-draft:
  - **Reference drift** (machine-fixable): dead anchor / line-number ref / moved-or-deleted file path / GUID no longer in repo / stale numeric value with an exact code counterpart.
  - **Semantic or process drift** (NOT machine-fixable): the design intent changed, a formula diverged, a `.claude/rules/` process note went stale, an architecture model differs.

### 3. Draft (only doc / memory / seams / rules)

One concern per pass. Feed the drafting work the project's own context (`CLAUDE.md`, `.claude/rules/`, the memory dir) so the prose keeps the author's voice and doesn't repeat known mistakes.

- **Reference drift → auto-draft the fix:**
  - Re-point the dead anchor to the current symbol/path.
  - Normalize line-number references (`Foo.cs:123`) into **symbol anchors** (a class or method name, a unique string, or a GUID).
  - For renames, use `git diff -M` rename detection + surrounding-context fingerprint to propose `OldSymbol → NewSymbol (confidence)` rather than just reporting a 0-hit.
  - For memory only, re-stamp `last_verified` on facts you re-verified.
- **Semantic / process drift → do NOT edit.** Emit a flagged note with the evidence (doc says X, code does Y) for the human to resolve.
- **`.claude/rules/` + `CLAUDE.md` process advice → flag only, never auto-edit.**

### 4. Human review (the local "draft")

The "draft" is **uncommitted working-tree changes scoped to doc/config files** — not a PR, not a scratch dir. Present `git diff` grouped by doc class. For each group, ask **apply / skip / edit**. Never auto-commit.

### 5. Land

Keep the approved subset; `git checkout --` the rest. Re-stamp touched memory: `python Tools/check_memory.py stamp <today> <files>`. Then offer `/qq:commit-push <the approved doc/config files>`.

## Notes

- **Default scope** = `Docs/design/`, the current branch's `Docs/qq/<branch>/`, the memory dir, `.claude/seams.yml`, `.claude/rules/`.
- **Notion-exported docs are in scope** if the project keeps them under `Docs/`: reconcile them, don't freeze them.
- If `${CLAUDE_PLUGIN_ROOT}/bin/qq-run-record.py` is available, persist a `doc-sync` run record after the sweep so controller state can advance.
- Distinguish four situations the same way doc-drift does: **outdated docs** (code right, doc stale → draft the doc), **missing features** (doc right, code not built → leave the doc, flag for the human), **actual bugs** (code wrong → this is out of doc-sync's scope; hand to `/qq:plan` or `/qq:test`, never edit code here). And **unrequested protections or restrictions** (only in code): never draft them into the doc body; draft a "Needs the user's decision" entry for the human to approve.

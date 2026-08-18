---
description: "Local on-demand doc-sync: detect doc↔code drift, draft the reconciling updates (anchors + prose), present them as a reviewable diff, and land only what the human approves. Goes beyond qq:doc-drift's report-only by closing the loop — but never auto-commits and never touches code."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Local, on-demand documentation synchronization. This is the **third trigger mode** for doc maintenance, complementing the event-driven layer (pre-commit warn) and the scheduled layer (periodic report): the human runs it when they know they've changed something doc-affecting, to pull drifted docs back in line with the code — but the human keeps the landing authority.

**Relationship to `qq:doc-drift`:** doc-drift is report-only (it outputs a P0/P1/P2 attention list). doc-sync is the *reconcile loop* — it **calls** doc-drift (and the project's drift detectors) as its detection stage, then adds the two stages doc-drift lacks: **draft** the fixes and **land** what the human approves.

Arguments: $ARGUMENTS
- No arguments: full sweep of the project's living docs
- `--since <ref>`: only docs affected by code changed since `<ref>` (windowed reconcile)
- `--scope <design|memory|seams|rules>`: restrict to one class of living doc
- `--all`: include archived/historical docs (default excludes `Docs/archive/` and old review artifacts)

## Principle (do not violate)

> **Detectors are read-only; doc-sync is the sole writer; the human is the sole lander. Reference drift (a dead anchor) is auto-drafted; semantic/process drift is only flagged for the human to decide.**
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
- **Classify every finding** into two buckets — this decides whether doc-sync may auto-draft:
  - **Reference drift** (machine-fixable): dead anchor / line-number ref / moved-or-deleted file path / GUID no longer in repo / stale numeric value with an exact code counterpart.
  - **Semantic or process drift** (NOT machine-fixable): the design intent changed, a formula diverged, a `.claude/rules/` process note went stale, an architecture model differs.

### 3. Draft (only doc / memory / seams / rules — NEVER `.cs`)

Feed the drafting work the project's own context (`CLAUDE.md`, `.claude/rules/`, the memory dir) so the prose keeps the author's voice and doesn't repeat known mistakes.

- **Reference drift → auto-draft the fix:**
  - Re-point the dead anchor to the current symbol/path.
  - Normalize line-number references (`Foo.cs:123`) into **symbol anchors** (`Foo.cs` 内 `BarMethod` / a unique string / a GUID) — per the project's `spec-anchors` discipline.
  - For renames, use `git diff -M` rename detection + surrounding-context fingerprint to propose `OldSymbol → NewSymbol (confidence)` rather than just reporting a 0-hit.
  - For memory only, re-stamp `last_verified` on facts you re-verified.
- **Semantic / process drift → do NOT edit.** Emit a flagged note with the evidence (doc says X, code does Y) for the human to resolve.
- **`.claude/rules/` + `CLAUDE.md` process advice → flag only, never auto-edit.**

### 4. Human review (the local "draft")

The "draft" is **uncommitted working-tree changes scoped to doc/config files** — not a PR, not a scratch dir. Present `git diff` grouped by doc class. For each group, ask **apply / skip / edit**. Never auto-commit.

### 5. Land

Keep the approved subset; `git checkout --` the rest. Re-stamp touched memory: `python Tools/check_memory.py stamp <today> <files>`. Then offer `/qq:commit-push` for the doc/config files **only** (pathspec — never `git add -A` / `commit -a`, which on a shared single worktree eats other sessions' staged work).

## Guardrails (hard — from the Ona "self-healing docs" model)

1. **Ignore noise.** Reconcile only against *semantic* code changes; skip test-only changes, `.meta` files, formatting churn, dependency bumps, and pure internal refactors.
2. **The draft never auto-merges and never touches `.cs`** — only doc / memory / seams / rules.
3. **Single responsibility + fed context.** One concern per pass; feed project memory/rules/CLAUDE.md as context; preserve the author's voice.
4. **Keep the human in the loop.** Never auto-land an AI-proposed doc edit (AI-reviewing-AI has structural blind spots).

## Notes

- **Three triggers, no overlap:** event (pre-commit) = narrow, warn-only, touched files; scheduled (cron) = wide, report-only worklist; **doc-sync (this) = wide, the only writer, still human-gated.** Same detectors underneath, escalating scope + action.
- **Default scope** = `Docs/design/`, the current branch's `Docs/qq/<branch>/`, the memory dir, `.claude/seams.yml`, `.claude/rules/`. Exclude `Docs/archive/` and old review artifacts unless `--all` (they are historical; syncing them is noise).
- **Notion-exported docs are in scope** if the project keeps them under `Docs/` (a project migrating off Notion toward Obsidian wants them reconciled, not frozen).
- If `qq-run-record.py` is available, persist a `doc-sync` run record after the sweep so controller state can advance.
- Distinguish three situations the same way doc-drift does: **outdated docs** (code right, doc stale → draft the doc), **missing features** (doc right, code not built → leave the doc, flag for the human), **actual bugs** (code wrong → this is out of doc-sync's scope; hand to `/qq:plan` or `/qq:test`, never edit code here).

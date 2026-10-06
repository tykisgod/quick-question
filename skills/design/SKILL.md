---
description: "Write a game design document from a one-liner, rough draft, or feature discussion. Outputs a structured design doc ready for /qq:plan. Use when starting a new feature, fleshing out a game idea, or documenting a design before implementation."
---

> Run qq scripts as `${CLAUDE_PLUGIN_ROOT}/bin/<name>`: they are not on PATH, so a bare `qq-execute-checkpoint.py` exits 127.

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Write a game design document, the first step of the qq pipeline; `/qq:plan` turns it into a technical implementation plan.

Arguments: $ARGUMENTS

## Language boundary

This skill writes **game design**, not technical architecture. Explore the codebase to understand what exists, but write everything in player-facing language: the saved document contains no code identifiers: file names (`Foo.cs`), type names (`FooManager`, `FooComponent`, `FooSystem`), class or interface declarations, `Service/` paths.

| Write this (design language) | Not this (implementation language) |
|---|---|
| The game flow | `GameFlowManager` |
| Crew get hungry and tired | `NeedsComponent.Hunger`, `NeedsTickSystem` |
| A workbench crafts items | `CraftingComponent`, `ITaskIssuer` |
| Food spoils over time | `ItemProperty.Freshness` float decay |

## Output structure

```markdown
# [Feature Name] Design Document

User's request: "<their exact words, 1-3 lines>" (where and when)

## Needs the user's decision
Omit if none. Plain `- ` bullets; keep this heading in English, verbatim.

## 1. Problem & Goal
What gap this addresses. What the player experience looks like when done. (2-3 sentences)

## 2. Reference Games
| Game | How they do it | What we borrow |

## 3. Design Approach
Which approach was chosen and why. One sentence on trade-offs if relevant.

## 4. Detailed Design
- Player-facing state/flow (ASCII or Mermaid diagram)
- Game concept definitions (describe what the player sees/feels, NOT code fields)
- Player interaction flow (numbered steps of what the player does)

## 5. Scope (optional — only if user mentions MVP/minimal/first pass)
| Item | In / Out | User's words (required for Out) |

## 6. Acceptance Checklist
Numbered list (not `- [ ]` checkboxes): player-visible outcomes the finished feature is checked against. One line each, pointing to the section it checks.
1. The player can X and sees Y. (§4)

## 7. Open Questions
```

## The document must

1. Have no section that contradicts another.
2. Give every game parameter (damage, speed, health, timers, distances) a concrete starting value; values still to be tuned in playtest are marked as such, never left as TBD or ???.
3. Let an engineer implement every feature without asking you questions.
4. Describe every player interaction flow fully, with all its states and transitions.
5. Back every protection, added restriction, and scope cut with the user's words, or list it under "Needs the user's decision".
6. Give every player interaction flow at least one Acceptance Checklist item.

## Running rules

- **Resolve uncertainty:** when the user hasn't figured something out, help them decide with options, reference games, and trade-offs before moving on; Open Questions is not the place for it.
- **Challenge with evidence:** when presenting a section, flag at most 1-2 choices per doc that conflict with what reference games learned, the existing codebase, or the document itself, with the evidence ("Raft tried X and removed it because..."), not just doubt. Don't challenge taste, aesthetics, or what is already built and working; if nothing conflicts, say so and move on.
- **Protections, added restrictions, and scope cuts are the user's call:** follow [`shared/user-decisions.md`](../../shared/user-decisions.md). Back each with an inline `(user: "...")` quote. When a section you present contains one, ask about it by name; an OK to the whole section is not the user's words for it. In `--auto`, or if left open, put it on the "Needs the user's decision" list and write the body with the normal rule. Everything else is your call; no tag needed.
- **Open Questions** is reserved for genuinely low-impact unknowns (e.g., visual polish).

## Process

1. **Assess input:** one-liner → ask questions; rough draft → fill gaps only, keeping the user's framing ("RimWorld style queue" stays); complete design → save
2. **Explore codebase + docs:** read existing systems, design docs, CSV configs. If you can answer your own question from the code, don't ask the user
3. **Research reference games:** invoke `/qq:design-research` using the Skill tool to find 2-3 games that solve similar design problems well. Skip only when the user says no references are needed.
4. **Ask questions (max 5):** prefer multiple choice, one per message, most impactful gaps first
5. **Write:** present each section for confirmation (unless `--auto`). Keep total doc to 1-3 pages; more means implementation detail that belongs in `/qq:plan`
6. **Save** to `Docs/qq/<branch-name>/<feature-name>_design.md` (branch name from `git branch --show-current | tr '/' '_'`)
7. **Post-design review (mandatory):** invoke `/qq:post-design-review` using the Skill tool, passing the saved document path (without `--auto`; step 9 does the handoff). If the verdict is HAS GAPS or NEEDS REWORK, revise the document before proceeding. Loop until SOLID or the user explicitly accepts the gaps.
8. **Record decisions:** record the 3-5 most important design decisions (core mechanic choice, scope boundaries, key trade-offs). In `--reason`, say who decided: `user: <their words>` or `author's call`.
   ```bash
   qq-decisions.py add --project . --phase design --key "<decision>" --value "<choice>" --reason "<why>"
   ```
9. **Handoff:** list every "Needs the user's decision" entry (also in `--auto`; don't wait for answers), and recommend `/qq:plan`. **`--auto` mode:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:design" --next-skill "/qq:plan" --design-doc "<saved-doc-path>"`, then invoke `/qq:plan --auto <saved-doc-path>`.

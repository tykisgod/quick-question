---
description: "Write a game design document from a one-liner, rough draft, or feature discussion. Outputs a structured design doc ready for /qq:plan. Use when starting a new feature, fleshing out a game idea, or documenting a design before implementation."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Write a game design document. This is the FIRST step in the qq pipeline — it produces the design doc that `/qq:plan` turns into a technical implementation plan.

Arguments: $ARGUMENTS

## Language boundary (HARD RULE)

This skill writes **game design**, not technical architecture. Explore the codebase to understand what exists, but translate everything into player-facing language.

| Write this (design language) | NOT this (implementation language) |
|---|---|
| 游戏流程管理 | `DemoGameManager` |
| 船员会感到饥饿和疲劳 | `CrewNeeds.Hunger`, `NeedsTickSystem` |
| 工作台可以制作物品 | `ProductionComponent`, `ITaskIssuer` |
| 船员前往火炮并操控 | `Task_OperateTurret`, `MannedWeaponComponent` |
| 食物保鲜随时间下降 | `ItemProperty.Freshness float decay` |

**Self-check before saving:** scan the document for `.cs`, `Manager`, `Component`, `System`, `Service/`, `class`, `interface`, `MonoSingleton`. If found, replace with design language.

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

## Running rules

- **Explore freely:** at any point, read the codebase, existing design docs, and data configs to inform your design. Don't limit exploration to one step.
- **Resolve uncertainty:** when the user says "不清楚", "没想好", "不确定", or anything indicating they haven't figured something out — STOP. Help them think it through with options, reference games, and trade-offs. Only continue when resolved. Do NOT park it in Open Questions and move on.
- **Challenge with evidence:** when presenting a section for confirmation, flag design choices that conflict with what reference games have learned, contradict the existing codebase, or create internal inconsistency within the document. Bring the evidence ("Raft tried X and removed it because..."), not just doubt. Do NOT challenge personal taste, aesthetic preferences, or things that are already built and working. Max 1-2 challenges per design doc — if everything looks solid, say so and move on.
- **Protections, added restrictions, and scope cuts are the user's call:** follow [`shared/user-decisions.md`](../../shared/user-decisions.md). Back each with an inline `(user: "...")` quote. When a section you present contains one, ask about it by name; an OK to the whole section is not the user's words for it. In `--auto`, or if left open, put it on the "Needs the user's decision" list and write the body with the normal rule. Everything else is your call; no tag needed.
- **Open Questions** is reserved for genuinely low-impact unknowns (e.g., exact number tuning, visual polish).

## Process

1. **Assess input:** one-liner → ask questions; rough draft → fill gaps only; complete design → save
2. **Explore codebase + docs:** read existing systems, design docs, CSV configs. If you can answer your own question from the code, don't ask the user
3. **Research reference games:** invoke `/qq:design-research` using the Skill tool to find 2-3 games that solve similar design problems well. **Default step — skip ONLY if the user explicitly says no references needed.**
4. **Ask questions (max 5):** prefer multiple choice, one per message, most impactful gaps first
5. **Write:** present each section for confirmation (unless `--auto`). Keep total doc to 1-3 pages
6. **Save** to `Docs/qq/<branch-name>/<feature-name>_design.md`
7. **Post-design review (mandatory):** invoke `/qq:post-design-review` using the Skill tool, passing the saved document path. If the verdict is HAS GAPS or NEEDS REWORK, revise the document before proceeding. Loop until SOLID or the user explicitly accepts the gaps.
8. **Record decisions:** After saving the design document, record key decisions:
   ```bash
   qq-decisions.py add --project . --phase design --key "<decision>" --value "<choice>" --reason "<why>"
   ```
   Record 3-5 most important design decisions (e.g., core mechanic choice, scope boundaries, key trade-offs). In `--reason`, say who decided: `user: <their words>` or `author's call`.
9. **Handoff:** list every "Needs the user's decision" entry (also in `--auto`; don't wait for answers), and recommend `/qq:plan`. **`--auto` mode:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:design" --next-skill "/qq:plan" --design-doc "<saved-doc-path>"`, then invoke `/qq:plan --auto <saved-doc-path>`.

## Self-Review (REQUIRED before saving)

Before saving the design document, review it yourself:
1. **Contradictions:** Do any sections contradict each other?
2. **Specific numbers:** Are ALL game parameters defined with exact values (damage, speed, health, timers, distances)? Replace any "TBD", "???", or vague descriptions with concrete numbers.
3. **Implementability:** Could an engineer implement every feature described without asking you questions?
4. **Completeness:** Is every player interaction flow fully described? Are all states and transitions covered?
5. **Decisions:** Is every protection, added restriction, and scope cut backed by the user's words, or listed under "Needs the user's decision"?
6. **Acceptance Checklist:** Does every player interaction flow have at least one checklist item?

If you find issues, fix them NOW — do not save a document with known gaps.

## Notes

- Diagrams show player-facing behavior, not code architecture
- Reference games: focus on the design pattern ("RimWorld uses a bill queue per workbench"), not implementation ("WorkGiver_DoBill class")
- If it's over 3 pages, you're writing implementation details that belong in `/qq:plan`
- Preserve the user's voice — if the rough draft says "RimWorld style queue", keep that framing

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
| In scope | Out of scope |

## 6. Open Questions
```

## Running rule: explore freely, resolve uncertainty

- **At any point** in the process, read the codebase, existing design docs, and data configs to inform your design. Don't limit exploration to one step.
- **When the user says "不清楚", "没想好", "不确定", or anything indicating they haven't figured something out:** STOP the current flow. Help them think it through — propose options, cite reference games, show trade-offs. Only continue when the question is resolved. Do NOT park it in Open Questions and move on.
- **Open Questions** is reserved for genuinely low-impact unknowns that won't affect the design direction (e.g., exact number tuning, visual polish details).

## Process

1. **Assess input:** one-liner → ask questions; rough draft → fill gaps only; complete design → save
2. **Explore codebase + docs:** read existing systems, design docs, CSV configs. If you can answer your own question from the code, don't ask the user
3. **Research reference games:** search for 2-3 games that solve similar design problems well, using `/qq:research` or web search or your own knowledge. Focus on design patterns, not implementations. **Default step — skip ONLY if the user explicitly says no references needed**
4. **Ask questions (max 5):** prefer multiple choice, one per message, most impactful gaps first
5. **Write:** present each section for confirmation (unless `--auto`). Keep total doc to 1-3 pages
6. **Save** to `Docs/design/<feature-name>.md`
7. **Handoff:** recommend `/qq:plan` (or note open questions to resolve first)

## Notes

- Diagrams show player-facing behavior, not code architecture
- Reference games: focus on the design pattern ("RimWorld uses a bill queue per workbench"), not implementation ("WorkGiver_DoBill class")
- If it's over 3 pages, you're writing implementation details that belong in `/qq:plan`
- Preserve the user's voice — if the rough draft says "RimWorld style queue", keep that framing

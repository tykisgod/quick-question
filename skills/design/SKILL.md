---
description: "Write a game design document — from a one-liner, a rough draft, or a feature discussion. Outputs a structured design doc ready for /qq:plan."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Write a game design document for a Unity project. This is the FIRST step in the pipeline — it produces the design doc that `/qq:plan` turns into a technical implementation plan.

Arguments: $ARGUMENTS
- A file path to an existing rough draft or notes
- A brief description of the feature to design
- `--auto`: skip all confirmation prompts
- No arguments: check conversation context for a recent feature discussion

## Target Output

No matter what the input is, the goal is to produce a document with this structure:

```markdown
# [Feature Name] Design Document

## 1. Problem & Goal
What pain point or gap this addresses.
What the player experience looks like when it's done.

## 2. Reference Games
| Game | How they do it | What we borrow |
|------|---------------|----------------|

## 3. Design Approach
Which approach was chosen and why.
If there was a trade-off between alternatives, briefly state it.

## 4. Detailed Design
- State / flow (ASCII or Mermaid diagram)
- Data definitions (config fields, enums, key values)
- Player interaction flow (what the player does step by step)

## 5. Scope (optional)
| In scope | Out of scope (future iteration) |

## 6. Open Questions
Anything unresolved that might change the design.
```

**Section 5 (Scope) is optional.** Include it only if the user mentions "MVP", "minimal", "first pass", or "just the core". Otherwise skip it — default is full implementation.

## Process

### Step 1: Assess the Input

Read the input and figure out what's already decided vs. what's missing.

**One-liner** (e.g., "add a food system"):
- Almost nothing is decided
- Go to Step 2 (ask questions)

**Rough draft** (partial notes, some decisions made):
- Read it, identify which template sections are already covered
- Mark what's missing
- Go to Step 2 but ONLY ask about missing parts — do not re-ask what the draft already answers

**Complete design** (all sections covered):
- Skip to Step 5 (save and handoff)

### Step 2: Ask Questions (max 5)

Ask targeted questions to fill gaps. Prefer multiple choice. One question per message.

Priority order — ask about the most impactful gaps first:
1. **Core mechanic** — "How should this work from the player's perspective?" (only if not clear from input)
2. **Interaction with existing systems** — explore the codebase yourself first, then confirm: "I see you have [existing system]. Should this integrate with it?"
3. **Reference games** — "Any games whose version of this you like?" (or suggest 2-3 based on the feature)
4. **Data format** — "Config via ScriptableObject, CSV, or hardcoded?" (only if relevant)
5. **Scope** — "Full feature or MVP first?" (only ask if the feature is large enough to warrant phasing)

**Do NOT ask more than 5 questions.** If something is unclear but not critical, make a reasonable assumption, note it in Open Questions, and move on.

**Explore the codebase before asking.** Read `Assets/Scripts/`, `AGENTS.md`, existing design docs in `Docs/design/`. If you can answer your own question by reading the code, don't ask the user.

### Step 3: Research (optional)

If the user mentioned reference games or the feature has well-known patterns in other games:
- Search for how 2-3 similar games implement this feature
- Summarize in the Reference Games table
- This can be done with `/qq:research` or by leveraging your own knowledge

Skip this step if the user already provided references or the feature is too project-specific for external references.

### Step 4: Write the Design Document

Fill in all sections of the template. Guidelines:

- **Problem & Goal**: 2-3 sentences max. Not a novel.
- **Reference Games**: Table format. Only include games that actually influenced a design decision. Don't pad with irrelevant games.
- **Design Approach**: State the choice, not the rejected alternatives. If there was a meaningful trade-off, one sentence about why.
- **Detailed Design**: This is the meat.
  - Use ASCII or Mermaid diagrams for state machines and data flow
  - Use tables for data definitions (field name, type, description)
  - Be concrete — actual field names, actual enum values, actual formulas
  - Describe the player interaction as a numbered sequence ("1. Player opens panel → 2. Selects recipe → 3. Sets quantity → ...")
- **Scope**: Only if asked for. Table of in/out.
- **Open Questions**: Bullet list. Things that might change the design.

**Present each section to the user for confirmation before moving to the next** (unless `--auto`).

### Step 5: Save

Save to `Docs/design/<feature-name>.md`.

This is a user-facing design doc, NOT a qq-generated artifact, so it goes in `Docs/design/` (not `Docs/qq/`).

### Step 6: Handoff

Assess the document and recommend the next step:

- **Document is complete, no open questions** → "Design doc ready. Want to run `/qq:plan` to create the technical implementation plan?"
- **Document has open questions** → "There are N open questions. Want to resolve them first, or proceed to `/qq:plan` anyway?"

**`--auto` mode:** skip asking → `/qq:plan --auto <path>`

## Notes

- This skill writes GAME DESIGN, not technical architecture. No C# code, no file paths, no .asmdef discussions. That's `/qq:plan`'s job.
- Preserve the user's voice. If the rough draft says "RimWorld style queue", keep that framing — don't rephrase it into generic terms.
- Diagrams should show PLAYER-FACING behavior (what happens in the game), not code architecture (what classes exist).
- When exploring reference games, focus on the design PATTERN, not the implementation. "RimWorld uses a bill queue per workbench" is useful. "RimWorld's WorkGiver_DoBill class" is not.
- Keep it concise. A good design doc is 1-3 pages. If it's longer, you're writing implementation details that belong in `/qq:plan`.

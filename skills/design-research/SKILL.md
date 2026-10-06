---
description: "Search for how other games solve a specific design problem — game loops, mechanics, systems, progression, economy. Returns a comparison of 2-4 reference games with what to borrow. Use when designing a new feature, exploring game mechanics, or looking for design inspiration before writing a design doc."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Search for **game design** references to the problem currently being discussed.

Arguments: $ARGUMENTS

## Process

1. Identify the core design question (e.g., "how trading between cities creates interesting choices")
2. Search for game design analyses, GDC talks, postmortems, and design breakdowns using WebSearch
3. Organize into a comparison table:

| Game | How they do it | What makes it fun | What we could borrow |
|---|---|---|---|

4. Recommend which approach best fits this project's scope and feel, and why
5. Save the result, sources included, to `Docs/qq/<branch-name>/<topic>_design-research.md` (or wherever the project already keeps research notes; branch name from `git branch --show-current | tr '/' '_'`). If the project's instructions ask for research notes to be committed, commit that file alone, following them; otherwise leave it for `/qq:commit-push`

## Notes

- Focus on the **player experience**, not implementation — "RimWorld uses a bill queue per workbench that lets players set min/max thresholds" is good; "WorkGiver_DoBill class" is not
- Prefer games the team has likely played or that are well-documented
- Include at least one game from a different genre if it solves the same design problem in an interesting way
- Tag every conclusion with its source: official material (dev blog, GDC talk, postmortem; link it), third-party analysis (link it), game source you actually read (for example, an open-source game), or own knowledge. If searching yields thin results, lean on your own knowledge of game design, tagged as such

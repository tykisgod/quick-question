---
description: "Search open-source communities and industry resources for solutions to the technical problem currently being discussed, and return a comparative analysis with a recommendation."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Search open-source communities and industry resources for solutions to the technical problem currently being discussed, and return a comparative analysis with a recommendation.

## Execution Steps

1. Extract keywords from the current problem (in English) and construct 2–3 search queries
2. Search for approaches in popular GitHub projects, Stack Overflow, and technical blogs
3. Organize results into a comparison table: Approach | Representative Projects | How It Works | Pros & Cons
4. Give a recommendation: which approach best fits our project, and why

## Notes

- Prioritize finding approaches from **similar types of projects** (Unity games, C# projects, monorepos)
- If the problem is general (e.g. git hooks), also reference best practices from non-Unity projects
- Do not just provide links — provide key conclusions
- If there is no industry consensus, state that directly

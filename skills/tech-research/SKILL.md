---
description: "Search GitHub, Stack Overflow, and technical blogs for solutions to a technical implementation problem. Returns a comparative analysis with a recommendation. Use when facing a technical decision, choosing a library, or looking for proven patterns in similar projects."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Search for **technical implementation** solutions to the problem currently being discussed.

Arguments: $ARGUMENTS

## Process

1. Extract keywords (in English), construct 2-3 search queries
2. Search GitHub projects, Stack Overflow, technical blogs using WebSearch
3. Organize into a comparison table:

| Approach | Representative Projects | How It Works | Pros | Cons |
|---|---|---|---|---|

4. Recommend which approach best fits this project, and why

## Notes

- Prioritize approaches from **similar project types** (same engine, same language, similar scale)
- Do not just provide links — provide key conclusions
- If there is no industry consensus, state that directly

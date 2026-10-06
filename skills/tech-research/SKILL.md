---
description: "Search GitHub, Stack Overflow, and technical blogs for solutions to a technical implementation problem. Returns a comparative analysis with a recommendation. Use when facing a technical decision, choosing a library, or looking for proven patterns in similar projects."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Search for **technical implementation** solutions to the problem currently being discussed.

Arguments: $ARGUMENTS

## Process

1. Search in English. Check primary sources first (official docs, the library's or engine's source and README), then GitHub projects, Stack Overflow, and technical blogs using WebSearch
2. Organize into a comparison table:

| Approach | Representative Projects | How It Works | Pros | Cons |
|---|---|---|---|---|

3. Recommend which approach best fits this project, and why
4. Save the result, sources included, to `Docs/qq/<branch-name>/<topic>_tech-research.md` (or wherever the project already keeps research notes; branch name from `git branch --show-current | tr '/' '_'`). If the project's instructions ask for research notes to be committed, commit that file alone, following them; otherwise leave it for `/qq:commit-push`

## Notes

- Prioritize approaches from **similar project types** (same engine, same language, similar scale)
- Tag every conclusion with its source: official docs, source code you actually read, third-party post or answer (link each), or own knowledge
- If there is no industry consensus, state that directly

---
description: "Explain the architecture and logic of a specified module or design in plain, approachable language."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Explain the architecture and logic of a specified module or design in plain, approachable language.

Arguments: module or design name (e.g., "PlayerController", "inventory system", "save system")

## Behavior

1. **Read design docs**: Start by checking for project documentation (e.g., `Docs/`, `Documentation/`, or `AGENTS.md`) to understand the design intent
2. **Read core code**: Find the key interfaces and implementation classes to understand the actual structure
3. **Explain in plain language**, following these principles:
   - Start with a real-world analogy to build intuition
   - Then break down the concrete code structure (use a tree diagram or simple illustration)
   - Explain "why it was designed this way" not just "what it is"
   - If there is a history of evolution (changed from A to B), explain the motivation
   - Point out common pitfalls or misconceptions
4. **Do not**:
   - Do not paste large blocks of source code; use pseudocode or key lines instead
   - Do not pile on design pattern terminology (say "each ship has its own service container", not "per-instance service locator pattern with dependency injection")
   - Do not assume the reader knows the project history

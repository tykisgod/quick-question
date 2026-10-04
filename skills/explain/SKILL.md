---
description: "Explain the architecture and logic of a specified module or design in plain, approachable language."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Explain the architecture and logic of a specified module or design in plain, approachable language.

> **In a Unity project**: when explaining "how does X work right now", complement source-reading with live state queries through the project's channel ([`shared/unity-live-state.md`](../../shared/unity-live-state.md)): official Unity CLI (`Library/Pipeline/.unity-pipeline-port` exists) → `unity command --project-path "$PWD" --json --no-banner <find_gameobjects|get_component_properties|get_serialized_fields|get_scene_hierarchy> -- <params>` (parameters: `unity command --project-path "$PWD" --query <keyword> --detail full --json`); tykit (`Temp/tykit.json`) → `get-properties` / `get-field` / `get-array` / `inspect`; neither → explain from source and say the runtime values are unverified. Read-only queries only; never open or print the descriptor — it holds an eval token. This catches the common failure mode of explaining what the code *says* it does vs what it *actually* does.

Arguments: $ARGUMENTS
- Module or design name (e.g., "PlayerController", "inventory system", "save system")

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

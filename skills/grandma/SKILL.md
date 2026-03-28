---
description: "Explain technical concepts using everyday analogies that a grandma or 5-year-old could understand."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Explain a technical concept, module, or design decision using everyday analogies that anyone — including a grandma or a 5-year-old — could understand.

Arguments: $ARGUMENTS — any technical concept (e.g., "ECS", "why does the task system use a push model", "what is MCP", "A* pathfinding algorithm")

## Behavior

1. **Understand the topic**: If it's a project module, quickly read design docs and core code to understand what it actually does
2. **Find an everyday life analogy** that:
   - Uses a scenario everyone has experienced (cooking, queuing, moving house, school, grocery shopping...)
   - Covers the core mechanism, not just a surface similarity
   - If the concept has multiple layers, use different roles/stages within the SAME scenario — don't switch scenarios
3. **Explain the entire concept through the analogy**:
   - Start with the scene: "Imagine you're at..."
   - Map each role and action in the scene to key parts of the technical concept
   - After the analogy, "translate" back in one sentence: "What we just called X is actually Y in the code"
4. **If there are common misconceptions**, address them: "Many people think... but actually..."
5. **Do NOT**:
   - Use technical jargon (unless the user is asking what a specific term means)
   - Show code
   - Say "simply put" followed by something not simple
   - Say "it's like in programming..." — the audience doesn't know programming, that's not an analogy
   - Be condescending ("this is basic", "you can think of it as")

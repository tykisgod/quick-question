---
description: "Generate a technical implementation plan from a game design document or a brief description. Outputs architecture, interfaces, ordered steps with file paths."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Generate a technical implementation plan for Unity. This is NOT a game design document — it translates an existing design into an engineering plan that `/qq:execute` can consume.

Arguments: $ARGUMENTS
- A file path to a game design document
- A brief description (1-2 sentences) of what to build
- No arguments: check conversation context for a recent design discussion

## 1. Understand the Input

**Best case:** user provides a game design document (from `Docs/qq/`, `Docs/design/`, Notion export, or inline). Read it fully, extract the technical requirements.

**Minimal case:** user gives a one-liner like "add a health system" or "weapons need ammo reloading". Ask 3-5 targeted technical questions before proceeding:

- What existing systems does this interact with? (or: let me explore the codebase to find out)
- Any data format preferences? (ScriptableObject, CSV config, etc.)
- Any hard constraints? (no singletons, must work with existing event bus, etc.)

Do NOT ask more than 5 questions. If something is unclear, explore the codebase to find the answer yourself. Prefer reading code over asking the user.

## 2. Explore the Codebase

Before writing the plan, understand what already exists:

- Read CLAUDE.md for coding standards
- Read AGENTS.md for architecture layers and module boundaries (if it exists)
- Explore the relevant directories (`Assets/Scripts/`, service modules, existing interfaces)
- Check .asmdef structure to understand module boundaries
- Identify existing patterns the new code should follow (event bus, service locator, dependency injection, etc.)

This step is critical — do not design in a vacuum.

## 3. Write the Plan

Output a single markdown document following this format. Keep it concise — 1-3 pages max. No filler.

```markdown
# [Feature Name] — Implementation Plan

## Goal
One sentence. What technical capability is added.

## Architecture
```mermaid
graph LR
    A[ComponentA] --> B[ComponentB]
    B --> C[ComponentC]
```

## Key Types
| Type | Kind | Purpose |
|------|------|---------|
| `Foo` | MonoBehaviour | Does X |
| `Bar` | ScriptableObject | Stores Y |
| `IFoo` | interface | Contract for X |

## Interfaces
```csharp
public interface IFoo {
    void DoSomething(SomeEvent e);
    float Value { get; }
    event Action<float> OnValueChanged;
}
```

## Data Schema
Any new config fields, serialized data, or save structures.
Use actual field names and types.

## Steps
Ordered, each step is a shippable increment. Include:
- Exact file paths (create or modify)
- What to implement
- Dependencies on previous steps
- Done criteria (how to verify this step works)

1. **Create IFoo interface** — `Assets/Scripts/Systems/IFoo.cs`
   - Define the contract shown above
   - No deps
   - Done: compiles

2. **Implement FooSystem** — `Assets/Scripts/Systems/FooSystem.cs`
   - MonoBehaviour implementing IFoo
   - [SerializeField] private fields for config
   - Depends on: step 1
   - Done: compiles + can attach to GameObject

3. **Wire into existing BarSystem** — `Assets/Scripts/Systems/BarSystem.cs`
   - Add IFoo dependency, call on trigger
   - Depends on: step 1, 2
   - Done: compiles + integration test passes

4. **Tests** — `Assets/Tests/EditMode/FooSystemTests.cs`
   - Test damage calculation, edge cases (zero, negative, overflow)
   - Depends on: step 2
   - Done: `/qq:add-tests` can implement this coverage without ambiguity, then all tests green

## Constraints
- What NOT to do (anti-patterns to avoid)
- Assembly definition placement
- Execution order dependencies
- Existing systems that must not break

## Testing Strategy
- EditMode: [what pure logic to test]
- PlayMode: [what integration to test]

## Open Questions
- Anything unresolved that might change the plan
```

## 4. Save the Plan

Get branch name: `git branch --show-current | tr '/' '_'`

Save to `Docs/qq/<branch-name>/<feature-name>_implementation.md`.

## 5. Record Decisions

After saving the plan, record key technical decisions:
```bash
qq-decisions.py add --project . --phase plan --key "<decision>" --value "<choice>" --reason "<why>"
```
Record architecture choices, pattern decisions, key interface designs.

## 6. Handoff

Plan review is mandatory before execution. Do NOT offer `/qq:execute` directly.

First, check if Codex CLI is available by running `which codex 2>/dev/null || where codex 2>/dev/null`.

- **Codex available** → recommend `/qq:codex-plan-review` (cross-model review catches blind spots that same-model review misses)
- **Codex not available** → recommend `/qq:claude-plan-review`

**`--auto` mode:** run `qq-execute-checkpoint.py pipeline-advance --project . --completed-skill "/qq:plan" --next-skill "/qq:codex-plan-review" --plan-doc "<saved-plan-path>"`, then run the check and invoke the appropriate review skill with `--auto`.

## Self-Review (REQUIRED before saving)

Before saving the plan, verify:
1. **File paths:** Every step has exact file paths (create or modify), not descriptions
2. **Step size:** Each step touches 1-3 files, not more. If a step is too big, split it.
3. **Dependencies:** The depends-on chain is correct — no step uses something not yet created
4. **Compile independence:** Each step compiles on its own after implementation
5. **Interface signatures:** Actual code signatures are written, not prose descriptions
6. **No placeholders:** No "TBD", "TODO", "implement later", or "similar to step N"

If any check fails, fix the plan before saving.

## Notes

- The plan must be consumable by `/qq:execute` — ordered steps with file paths and done criteria
- Test steps must be concrete enough that `/qq:add-tests` can implement them without re-planning
- Write actual interface signatures in the plan, not prose descriptions
- Use Mermaid for architecture diagrams (GitHub renders them)
- If the design doc is ambiguous, call it out in Open Questions — don't guess silently
- Follow existing project patterns. If the project uses a service container, use it. If it uses events, use events. Don't introduce new patterns unless the design requires it.
- When facing a non-trivial technical decision (e.g., choosing a pathfinding algorithm, structuring a state machine), invoke `/qq:tech-research` to search for proven approaches before committing to one in the plan.
- Concise over comprehensive. A 1-page plan that an engineer can follow beats a 10-page plan nobody reads.

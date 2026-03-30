# AGENTS.md

## Refactoring Authority

This repository explicitly allows aggressive refactoring when it improves the design.

- Large-scale refactors, full rewrites, file moves, and architectural cleanup are allowed.
- Backward compatibility is not required unless a task explicitly asks for it.
- Prefer the cleanest end-state over incremental compatibility layers.
- Remove obsolete code paths instead of preserving them out of habit.

## Default Engineering Bias

- Optimize for clarity, fewer layers, and stronger core abstractions.
- If the current shape is fighting the design, rewrite it instead of patching around it.
- Keep migration logic only when there is a real user or release requirement.

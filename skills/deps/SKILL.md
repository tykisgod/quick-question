---
description: "Analyze the .asmdef dependency relationships of all Service modules in the project."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Analyze the .asmdef dependency relationships of all Service modules in the project.

## Execution Steps

### 1. Collect All .asmdef Files

Use Glob to find `Assets/**/*.asmdef`, excluding Tests and Editor asmdefs (filenames containing `.Tests.`, `.Editor.`, or `.PlayModeTests.`).

### 2. Build GUID → Name Mapping

For each .asmdef file:
- Read the .asmdef to get the `name` field
- Read the corresponding .asmdef.meta to get the `guid` field
- Build a GUID → Name lookup table

### 3. Parse Dependency Relationships

For each .asmdef:
- Read the GUIDs in the `references` array
- Convert to human-readable names via the lookup table
- Record: `ServiceA → [depends on ServiceB, depends on ServiceC]`

### 4. Detect Issues

**Circular dependency detection:**
- Run DFS on the dependency graph to detect cycles
- If cycles exist, list the full circular path

**Layer violation detection:**
Read the project's `AGENTS.md` for the defined architecture layers and dependency direction. If no layer definition exists, infer layers from the dependency graph (modules with no dependencies are Layer 0, their dependents are Layer 1, etc.).
Detect any cases where a lower layer depends on a higher layer.

### 5. Output

```
## Service Dependency Relationships

### Dependency Graph
Game.Core (Layer 0)
  <- Game.Player
  <- Game.AI
  <- ...

Game.Player (Layer 1)
  -> Game.Core
  <- Game.UI

...

### Circular Dependencies
(if any) A -> B -> C -> A

### Layer Violations
(if any) Service.Common depends on Service.Container (lower layer depends on higher layer)

### Dependency Health
- Total modules: N
- Average dependencies: X
- Most dependencies: ServiceName (Y dependencies)
- No issues: OK
```

## Optional Arguments

If the user specifies a service name (e.g. "Weapon"), only analyze the dependency chain for that service (both upstream and downstream) rather than a full analysis.

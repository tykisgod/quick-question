---
description: "Perform a project-specific code review on the specified scope."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Perform a project-specific code review on the specified scope.

The user may provide: file paths, directories, or "recent changes" to define the review scope. If nothing is specified, review files modified in the current git diff.

## Review Rules

### Anti-Pattern Detection

1. **FindObjectOfType / FindObjectsOfType**
   - Severity: High
   - Alternative: use the appropriate Registry/Manager singleton for your project
   - Exception: Editor code (`Assets/Editor/`, inside `#if UNITY_EDITOR` blocks) may use these

2. **Message system calls with untyped `object[]` parameters**
   - Severity: Medium
   - Alternative: strongly-typed interfaces or events

3. **Accessing shared data in Awake/Start**
   - Severity: High
   - Alternative: implement the appropriate lifecycle interface and access data in the ready callback

4. **Caching a read-only interface reference then mutating through it**
   - Severity: High
   - Alternative: read-only access only

5. **Incorrect namespace conventions**
   - Severity: Medium
   - Check that namespaces follow the project's established naming scheme

6. **Unsolicited UI code changes**
   - Severity: Notice
   - UI code should not be modified unless the user explicitly requested it

### Architecture Checks

7. **Circular dependency risk**
   - Check that new `using` directives do not violate the project's established dependency direction

8. **Missing .asmdef references**
   - If a file uses a namespace from another Service module, verify the corresponding .asmdef reference exists

### Code Quality

9. **Excessive null checks**
   - Project style: minimal null checks, rely on exceptions to surface problems
   - Only validate at system boundaries (user input, external APIs)

10. **Missing documentation comments**
    - Public classes and complex methods should have summary comments

## Project-Specific Rules

Add your project's coding standards and anti-patterns here. Example:
- No raw SQL queries
- All public APIs must have documentation

## Output Format

Group output by severity:

```
## 🔴 Critical Issues (must fix)
- [file:line] Issue description → suggested fix

## 🟡 Suggestions
- [file:line] Issue description → suggested fix

## ✅ Code Quality Highlights
- Brief list of things done well
```

## Execution

1. Determine review scope (user-specified or git diff)
2. Read all relevant files
3. Check each rule above
4. Output results in the format above
5. If critical issues are found, ask whether to auto-fix them

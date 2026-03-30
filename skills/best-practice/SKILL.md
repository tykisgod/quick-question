---
description: "Quick Unity best-practice check — run after editing C# files to catch anti-patterns, performance issues, and runtime safety problems."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Quick best-practice check for Unity C# code. Run this right after editing code — it scans for anti-patterns, performance traps, and runtime safety issues against 18 rules.

Arguments: $ARGUMENTS

## Scope Detection

Intelligently determine what to check:

1. **If the user specified files or a scope** → use that
2. **If .cs files were edited in this conversation** → check those files
3. **If there are uncommitted changes** → `git diff --name-only HEAD -- '*.cs'`
4. **If none of the above** → ask the user what to check

Do NOT review the entire codebase by default. Focus on what just changed.

## Review Rules

## Deterministic Policy Layer

If `./scripts/qq-policy-check.sh` exists, run it first against the selected scope:

```bash
./scripts/qq-policy-check.sh --json <files...>
```

Treat those results as the first-pass findings. Do not ask the model to rediscover the same high-confidence issues from scratch. Use the model for:

- additional contextual review
- prioritization
- explanation
- fix suggestions

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

5. **SendMessage / BroadcastMessage / SendMessageUpwards**
   - Severity: Medium
   - Uses reflection, no compile-time safety, string-based (typos cause silent failures)
   - Alternative: C# events, UnityEvents, or interface-based dispatch

6. **Unsolicited UI code changes**
   - Severity: Notice
   - UI code should not be modified unless the user explicitly requested it

### Performance

7. **GetComponent in Update / FixedUpdate / LateUpdate**
   - Severity: High
   - GetComponent uses native interop + type lookup per call; in hot loops this causes measurable CPU overhead and GC pressure
   - Alternative: cache component references in Awake/Start or use `[SerializeField]`
   - Also flag GetComponent inside OnCollision*, OnTrigger*

8. **Per-frame heap allocations**
   - Severity: High
   - Flag inside Update/FixedUpdate/LateUpdate: `new List`, `new Dictionary`, string `+` or `$""` interpolation, `.ToString()`, LINQ queries (`.Where`, `.Select`, `.ToList`), lambda closures
   - Alternative: pre-allocate and reuse, use StringBuilder, use non-alloc APIs

9. **Coroutines started without cleanup**
   - Severity: High
   - StartCoroutine without corresponding StopCoroutine or StopAllCoroutines in OnDisable causes orphan coroutines when objects are pooled or re-enabled
   - Alternative: cache coroutine references, stop in OnDisable

10. **`gameObject.tag ==` string comparison**
    - Severity: Medium
    - Allocates a string on the heap every call
    - Alternative: use `CompareTag()` (allocation-free)

### Runtime Safety

11. **Event subscription without unsubscription**
    - Severity: High
    - Every `+=` event subscription must have a matching `-=` unsubscription
    - Subscribe in OnEnable, unsubscribe in OnDisable; failing to do so causes memory leaks and double-firing

12. **Missing [RequireComponent] for GetComponent dependencies**
    - Severity: Medium
    - If Awake/Start calls `GetComponent<T>()` and the result is used without null check, the class should have `[RequireComponent(typeof(T))]`
    - Makes hidden dependencies explicit and auto-adds them in the Inspector

### Architecture Checks

13. **Circular dependency risk**
    - Check that new `using` directives do not violate the project's established dependency direction

14. **Missing .asmdef references**
    - If a file uses a namespace from another Service module, verify the corresponding .asmdef reference exists

15. **Incorrect namespace conventions**
    - Severity: Medium
    - Check that namespaces follow the project's established naming scheme

16. **Public fields instead of [SerializeField] private**
    - Severity: Medium
    - Public fields on MonoBehaviours break encapsulation; any script can modify them
    - Alternative: `[SerializeField] private` for Inspector-assigned fields

### Code Quality

17. **Excessive null checks**
    - Project style: minimal null checks, rely on exceptions to surface problems
    - Only validate at system boundaries (user input, external APIs)

18. **Missing documentation comments**
    - Public classes and complex methods should have summary comments

## Project-Specific Rules

Add your project's coding standards and anti-patterns here. Example:
- No raw SQL queries
- All public APIs must have documentation

## Output Format

Group output by severity:

```
## 🔴 Critical (High severity — must fix)
- [file:line] Issue description → suggested fix

## 🟠 Moderate (Medium severity — should fix)
- [file:line] Issue description → suggested fix

## 🟡 Suggestions (Notice — nice to fix)
- [file:line] Issue description → suggested fix

## ✅ Code Quality Highlights
- Brief list of things done well
```

## Execution

1. Determine scope (see Scope Detection above)
2. Run `./scripts/qq-policy-check.sh --json` if available
3. Read all relevant .cs files
4. Check each of the 18 rules above, but treat deterministic policy findings as already-established
5. Also read AGENTS.md (if it exists) for project-specific architecture rules
6. Merge deterministic findings with model findings in the output format above
7. If critical issues are found, ask whether to auto-fix them

## Handoff

After the check completes, recommend the next step:

- **No issues found** → "Clean. Want to run `/qq:test` to verify, or `/qq:claude-code-review` for a deeper review?"
- **Issues found and fixed** → "Fixed N issues. Want to re-run `/qq:best-practice` to confirm, or proceed to `/qq:test`?"
- **Issues found, user declined fix** → "N issues remain. Proceed to `/qq:test` anyway, or fix first?"

**`--auto` mode:** skip asking, take the strictest path:
→ auto-fix all issues → re-run self until clean → `/qq:claude-code-review --auto`

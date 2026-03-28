---
description: "Review changes from the most recent interaction (skills, configs, settings, and other lightweight changes) for quality and consistency."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Review changes from the most recent interaction (skills, configs, settings, and other lightweight changes) for quality and consistency.

## Steps

1. Look back at the files changed in the most recent interaction and list them
2. Read the current content of each file and check for:
   - Logical correctness (are references correct, are step numbers sequential)
   - Consistency (does the style match existing content)
   - Omissions (are there related files that were missed)
   - Redundancy (unnecessary blank lines, duplicate content)
3. If issues are found, fix them directly
4. Output a brief review conclusion
5. Clear the skill change marker: `rm -f /tmp/claude-skill-modified-*`

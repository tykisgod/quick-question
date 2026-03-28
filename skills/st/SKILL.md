---
description: "Run the full test pipeline: EditMode unit tests → PlayMode integration tests. Each layer must pass before proceeding to the next."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Run the full test pipeline: EditMode unit tests → PlayMode integration tests. Each layer must pass before proceeding to the next.

## Execution Steps

### Step 0: Run /qq:test (gate)

Execute the full `/qq:test` flow (clear console → mark Editor.log → EditMode → PlayMode → check runtime errors).

- If **all pass and no errors**: report success to the user
- If **any failures or errors**: follow /qq:test's flow to present results to the user, then **ask** whether to fix or skip

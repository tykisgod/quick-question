---
description: "Review a game design document from an implementer's perspective — check self-consistency, playability, buildability, and codebase gaps. Use after writing a design doc, or when you want to validate an existing design against the current codebase."
---

Respond in the user's preferred language (detect from their recent messages, or fall back to the language setting in CLAUDE.md).

Review a game design document from an implementer's perspective.

Arguments: $ARGUMENTS (path to a design document, or empty to use the most recent design doc in `Docs/qq/`)

## Process

1. **Find the document:** if a path is given, read it. Otherwise, find the most recent `*_design.md` in `Docs/qq/`.
2. **Spawn a review subagent** using the Agent tool. The subagent should:
   - Read [design-reviewer-prompt.md](design-reviewer-prompt.md) for the full review checklist
   - Read the design document
   - **Independently** explore the codebase (Services, configs, existing design docs) to verify claims — do not rely solely on what the document says exists
   - Output the review in the format specified in the reviewer prompt
3. **Verify the findings:** as the main agent, independently spot-check the subagent's claims against the codebase. The subagent may misread code or reference stale information. For each finding, confirm or reject it with your own evidence before presenting to the user.
4. **Present the verified review** to the user — only include findings you confirmed. Note any subagent findings you rejected and why.
5. **If verdict is HAS GAPS or NEEDS REWORK:** revise the document together with the user. Re-run the subagent review after revisions. Loop until SOLID or the user explicitly accepts the gaps.
6. **If verdict is SOLID:** confirm and recommend `/qq:plan`. **If invoked with `--auto` (or called from a skill running in `--auto` mode):** invoke `/qq:plan --auto <document-path>` directly.

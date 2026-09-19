---
name: maliang-orchestrator
description: New Python-driven game dev pipeline orchestrator project, separate from qq, at E:\dpp_new\maliang-orchestrator (GitHub: tykisgod/maliang-orchestrator)
type: project
---

Maliang (马良) is a Python-driven, agent-agnostic game dev pipeline orchestrator.

**Why:** Replace agent-driven control flow (like qq's skill/hook model) with deterministic Python state machine. LLMs called as stateless functions, not driving the loop.

**How to apply:** When user references maliang, the repo is at `E:\dpp_new\maliang-orchestrator`. GitHub: `tykisgod/maliang-orchestrator` (private). It's completely separate from qq — not a rewrite, not a v2.

Key architecture decisions (from brainstorming 2026-04-04):
- Fine-grained agent calls (each plan substep = one call) — user chose option B
- PausePolicy (auto/guided/manual) — same state machine, different pause points
- External deps with blocking/placeholder — bidirectional art pipeline
- File-based inbox/outbox transport (v1)
- 147 tests, TDD throughout, 5 rounds of Codex cross-model review

Tech: Python 3.12+, asyncio, pydantic, typer, starlette, ruamel.yaml, claude-agent-sdk

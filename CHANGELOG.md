# Changelog

All notable changes to quick-question are documented here.

## [1.0.0] — 2026-03-28

### Added
- 18 slash commands (`/qq:*`) covering testing, code review, analysis, and utilities
- Auto-compilation hook — edit a `.cs` file, compilation runs automatically
- Smart compilation stack: tykit (HTTP) → Editor trigger → batch mode fallback
- Cross-model code review: Claude + Codex with verification loop (Tribunal pattern)
- Claude-only code review and plan review (no Codex dependency)
- tykit — HTTP server inside Unity Editor for AI agent control
- Codex Review Gate — blocks edits while review verification is pending
- Skill review enforcement — Stop hook blocks session end until `/qq:self-review` runs
- `/qq:brief` — architecture diff + PR checklist (merged from brief-arch + brief-checklist)
- `/qq:full-brief` — run brief + timeline in parallel (4 docs total)
- `/qq:timeline` — commit history timeline with phase analysis
- `/qq:deps` — `.asmdef` dependency graph + matrix + health check
- `/qq:doc-tidy` — scan repo docs, analyze organization, suggest cleanup
- `/qq:doc-drift` — compare design docs vs code, find inconsistencies
- `/qq:grandma` — explain any concept using everyday analogies
- `/qq:explain` — explain module architecture in plain language
- `/qq:research` — search open-source solutions for current problem
- Multi-language README (English, 中文, 日本語, 한국어)
- Plugin marketplace SEO optimization
- `test.sh` — self-test script (shellcheck + JSON + structural checks)
- GitHub Actions CI workflow
- Issue templates (bug report + feature request)

### Fixed
- `install.sh` now copies `scripts/hooks/` subdirectory
- `install.sh` output uses current skill names (`/qq:test`, `/qq:commit-push`)
- Duplicate scripts in tykit `Scripts~/` replaced with symlinks
- Review Gate documentation accuracy (`.cs` and `Docs/*.md`, not "all edits")
- Git added to Prerequisites (hard dependency)
- Claude-only review skills now read `AGENTS.md` for architecture rules
- `claude-plan-review` fallback glob excludes generated review artifacts

## [0.1.0] — 2026-03-27

### Added
- Initial release — Unity Agent Harness for Claude Code
- Core skills: test, st, commit-push, codex-code-review, codex-plan-review, code-review, self-review, explain, research, changes
- Hook system: auto-compile, skill review enforcement
- EvalServer (tykit) UPM package
- `install.sh` installer
- Claude Code Plugin format (plugin.json, marketplace.json)

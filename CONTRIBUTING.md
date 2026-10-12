# Contributing to quick-question

Thanks for your interest in contributing!

## Getting Started

```bash
git clone https://github.com/tykisgod/quick-question.git
cd quick-question
./test.sh  # Run self-tests
```

## Project Structure

- `skills/<name>/SKILL.md` — Skill definitions (Claude Code prompts)
- `scripts/*.sh` — Shell scripts run by hooks and skills
- `hooks/hooks.json` — Hook definitions (auto-compile, review gate, skill enforcement)
- `packages/com.tyk.tykit/` — Unity UPM package (HTTP server)

## Adding a New Skill

1. Create `skills/<name>/SKILL.md`
2. Add the frontmatter: `---\ndescription: ...\n---`
3. Write the skill prompt
4. Run `/qq:self-review` to validate
5. Update the Commands table in `README.md` (both English and Chinese sections)

## Shell Script Conventions

- Use `set -euo pipefail`
- Source `unity-common.sh` for shared functions
- Comments in Chinese (author preference); user-facing output in English
- Run `shellcheck -S error` before committing

## Testing

```bash
./test.sh                    # Full self-test suite
shellcheck scripts/*.sh      # Lint shell scripts
```

### Pre-push hook (optional)

The repo ships a pre-push hook in `.githooks/pre-push` that runs the same quick checks as CI before a push: the JSON files parse, and the `plugin.json` version matches the newest `CHANGELOG.md` entry. Git does not run it until you point your clone at that directory:

```bash
git config core.hooksPath .githooks   # turn it on for this clone
git config --unset core.hooksPath     # turn it off again
```

It does not run `./test.sh`; run that yourself before opening a PR.

## Pull Requests

- One logical change per PR
- Include a clear description of what changed and why
- Ensure `./test.sh` passes
- Update `CHANGELOG.md` if adding features or fixing bugs

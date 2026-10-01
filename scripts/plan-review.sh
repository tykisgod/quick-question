#!/usr/bin/env bash
# plan-review.sh — Send a design document to Codex CLI for review
#
# Usage:
#   ./scripts/plan-review.sh <document>                    # Default review
#   ./scripts/plan-review.sh <document> "custom prompt"    # Custom prompt
#
# Environment:
#   QQ_CODEX_EFFORT — reasoning effort (any level the configured model supports; `config` = inherit
#                     config.toml; unset = the model's highest supported level, fallback high).
#                     Low effort or reasoning=none produces shallow reviews.
#
# Output:
#   Review saved to <document_name>_review.md (same directory)
#   Also printed to stdout

set -euo pipefail

DOC_FILE="${1:?Usage: $0 <document> [custom_prompt]}"
CUSTOM_PROMPT="${2:-}"
CODEX_EFFORT="${QQ_CODEX_EFFORT:-}"

source "$(dirname "$0")/codex-common.sh"

# Resolve effort (scripts/codex-common.sh): explicit -> validated against the configured model's
# supported levels; unset -> that model's highest level (reviews want the deepest reasoning; the
# effort in config.toml is usually the desktop app's interactive default, often low); `config` -> inherit.
qq_codex_resolve_effort "$CODEX_EFFORT" || exit 1
CODEX_EFFORT="$QQ_CODEX_EFFORT_RESOLVED"

if [[ ! -f "$DOC_FILE" ]]; then
  echo "Error: file not found: $DOC_FILE" >&2
  exit 1
fi

if ! command -v codex &>/dev/null; then
  echo "Error: codex CLI not found. Install with: npm install -g @openai/codex" >&2
  exit 1
fi

# Output file: foo.md -> foo_review.md
DIR=$(dirname "$DOC_FILE")
BASE=$(basename "$DOC_FILE" .md)
REVIEW_FILE="${DIR}/${BASE}_review.md"

# Resolve absolute path for the document
DOC_ABS_PATH="$(cd "$DIR" && pwd)/$( basename "$DOC_FILE")"

# Resolve project root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Build review prompt
if [[ -n "$CUSTOM_PROMPT" ]]; then
  REVIEW_PROMPT="$CUSTOM_PROMPT"
else
  REVIEW_PROMPT="Review the following design document / implementation plan.

Review criteria:
1. Architecture: Is the design clean, well-decoupled, and maintainable?
2. Correctness: Are there logical flaws, contradictions, or missing edge cases?
3. Completeness: Are there missing call sites, migration steps, or integration points?
4. Feasibility: Can this be implemented as described without hidden blockers?

Classify each finding by severity: [Critical] [Moderate] [Suggestion]
For anything you're unsure about, mark it [Uncertain] — do NOT guess.
Be concise. Only output review findings, nothing else."
fi

# Tell Codex to read files from disk instead of inlining content
FULL_PROMPT="${REVIEW_PROMPT}

---

## Project Standards

Read the CLAUDE.md file at the project root for coding standards.

---

## Document Under Review

Read ${DOC_ABS_PATH} for the full document content."

echo ">>> codex exec (plan-review: ${DOC_FILE}, reasoning=${CODEX_EFFORT:-config})" >&2

# Prompt goes through stdin, not argv (long argv is truncated on Windows). See scripts/codex-common.sh.
PROMPT_FILE="$(mktemp "${QQ_TEMP_DIR:-/tmp}/qq-plan-review-prompt.XXXXXX")"
printf '%s\n' "$FULL_PROMPT" > "$PROMPT_FILE"
CODEX_STATUS=0
qq_codex_run "$PROMPT_FILE" "$REVIEW_FILE" || CODEX_STATUS=$?
rm -f "$PROMPT_FILE"
if (( CODEX_STATUS != 0 )); then
  echo ">>> codex exec failed (exit ${CODEX_STATUS}); partial output kept in ${REVIEW_FILE}" >&2
  exit "$CODEX_STATUS"
fi

echo "" >&2
echo ">>> Review saved to: ${REVIEW_FILE}" >&2

#!/usr/bin/env bash
# plan-review.sh — Send a design document to Codex CLI for review
#
# Usage:
#   ./scripts/plan-review.sh <document>                    # Default review
#   ./scripts/plan-review.sh <document> "custom prompt"    # Custom prompt
#
# Environment:
#   QQ_CODEX_EFFORT — reasoning effort (low/medium/high/ultra; unset = inherit config.toml, fallback high)
#                     Codex defaults to `none` which produces shallow reviews.
#                     Always force at least medium for meaningful review.
#
# Output:
#   Review saved to <document_name>_review.md (same directory)
#   Also printed to stdout

set -euo pipefail

DOC_FILE="${1:?Usage: $0 <document> [custom_prompt]}"
CUSTOM_PROMPT="${2:-}"
CODEX_EFFORT="${QQ_CODEX_EFFORT:-}"

# Resolve effort:
#   explicit (env/flag) -> validate & pass through (now includes ultra)
#   unset -> respect a non-none model_reasoning_effort in ~/.codex/config.toml (do NOT downgrade
#            a user who configured e.g. ultra); otherwise force high (codex default `none` is shallow)
resolve_codex_effort() {
  if [[ -n "$CODEX_EFFORT" ]]; then
    case "$CODEX_EFFORT" in
      low|medium|high|ultra) ;;
      *) echo "Error: effort must be low/medium/high/ultra (got: $CODEX_EFFORT)" >&2; exit 1 ;;
    esac
    return
  fi
  local cfg
  cfg=$(grep -oE '^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"[^"]+"' \
        "$HOME/.codex/config.toml" 2>/dev/null | sed 's/.*"\(.*\)"/\1/')
  if [[ -n "$cfg" && "$cfg" != "none" ]]; then
    CODEX_EFFORT=""   # inherit config.toml (shown as reasoning=config)
  else
    CODEX_EFFORT="high"
  fi
}
resolve_codex_effort

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

EFFORT_ARGS=()
[[ -n "$CODEX_EFFORT" ]] && EFFORT_ARGS=(-c "model_reasoning_effort=\"${CODEX_EFFORT}\"")
codex exec \
  --sandbox read-only \
  "${EFFORT_ARGS[@]}" \
  "$FULL_PROMPT" | tee "$REVIEW_FILE"

echo "" >&2
echo ">>> Review saved to: ${REVIEW_FILE}" >&2

#!/usr/bin/env bash
# claude-plan-review.sh — Send a design document to Claude CLI for review
#
# Usage:
#   ./scripts/claude-plan-review.sh <document>                    # Default review
#   ./scripts/claude-plan-review.sh <document> "custom prompt"    # Custom prompt
#
# Output:
#   Review saved to <document_name>_claude_review.md (same directory)
#   Also printed to stdout

set -euo pipefail

source "$(dirname "$0")/platform/detect.sh"
source "$(dirname "$0")/review-prompts.sh"

DOC_FILE="${1:?Usage: $0 <document> [custom_prompt]}"
CUSTOM_PROMPT="${2:-}"

if [[ ! -f "$DOC_FILE" ]]; then
  echo "Error: file not found: $DOC_FILE" >&2
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "Error: claude CLI not found. Install Claude Code CLI first." >&2
  exit 1
fi

# Output file: foo.md -> foo_claude_review.md
DIR=$(dirname "$DOC_FILE")
BASE=$(basename "$DOC_FILE" .md)
REVIEW_FILE="${DIR}/${BASE}_claude_review.md"

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

# Tell Claude to read files from disk instead of inlining content
FULL_PROMPT="${REVIEW_PROMPT}

$(qq_review_provenance_section)

---

## Project Standards

Read the CLAUDE.md file at the project root for coding standards.

---

## Document Under Review

Read ${DOC_ABS_PATH} for the full document content."

echo ">>> Sending ${DOC_FILE} to Claude for review..." >&2

claude -p "$FULL_PROMPT" | tee "$REVIEW_FILE"

echo "" >&2
echo ">>> Review saved to: ${REVIEW_FILE}" >&2

# 审查真跑完了才立审查门（按会话 id；见 platform/detect.sh 的 qq_review_gate_open）
qq_review_gate_open

#!/usr/bin/env bash
# claude-review.sh — Send code changes to Claude CLI for review
#
# Usage:
#   ./scripts/claude-review.sh                           # Default: main...HEAD
#   ./scripts/claude-review.sh --base main               # Custom base branch
#   ./scripts/claude-review.sh --commits                 # Last commit only
#   ./scripts/claude-review.sh --ext "*.py"              # Filter by extension
#   ./scripts/claude-review.sh --prompt "custom prompt"  # Custom prompt
#   ./scripts/claude-review.sh --files "a.cs b.cs"       # Specific files
#   ./scripts/claude-review.sh --spec design.md --spec plan.md  # Also check the code against these specs (repeatable)
#
# Output:
#   Review saved to Docs/<branch>/claude-code-review_<timestamp>.md
#   Also printed to stdout

set -euo pipefail

source "$(dirname "$0")/platform/detect.sh"
source "$(dirname "$0")/review-prompts.sh"

if ! command -v claude &>/dev/null; then
  echo "Error: claude CLI not found. Install Claude Code CLI first." >&2
  exit 1
fi

# Auto-detect default base branch: develop > main > master
BASE_BRANCH=""
for candidate in develop main master; do
  if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
    BASE_BRANCH="$candidate"
    break
  fi
done
MODE="branch"
EXT_FILTER=""
CUSTOM_PROMPT=""
FILES_LIST=()
SPEC_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)    BASE_BRANCH="$2"; shift 2 ;;
    --commits) MODE="commits"; shift ;;
    --ext)     EXT_FILTER="$2"; shift 2 ;;
    --prompt)  CUSTOM_PROMPT="$2"; shift 2 ;;
    --files)   IFS=' ' read -ra FILES_LIST <<< "$2"; MODE="files"; shift 2 ;;
    --spec)    SPEC_FILES+=("$2"); shift 2 ;;
    --auto)    shift ;;  # 技能层的流水线开关（/qq:*-code-review --auto 续跑时会原样带进来），脚本不用
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --spec 给的是审查方要去读的文件：先确认存在，再换成绝对路径（审查进程按路径自己读）。
# 外面包一层长度判断：macOS 自带 bash 3.2 在 set -u 下展开空数组会报 unbound variable。
if (( ${#SPEC_FILES[@]} > 0 )); then
  for i in "${!SPEC_FILES[@]}"; do
    spec="${SPEC_FILES[$i]}"
    if [[ ! -f "$spec" ]]; then
      echo "Error: spec file not found: $spec" >&2
      exit 1
    fi
    SPEC_FILES[i]="$(cd "$(dirname "$spec")" && pwd)/$(basename "$spec")"
  done
fi

# Validate base branch looks like a git ref (prevent flag injection)
if [[ "$BASE_BRANCH" == -* ]]; then
  echo "Error: invalid base branch: $BASE_BRANCH" >&2
  exit 1
fi

# Build diff command args
DIFF_ARGS=()
if [[ -n "$EXT_FILTER" ]]; then
  DIFF_ARGS+=(-- "$EXT_FILTER")
fi

case "$MODE" in
  branch)
    DIFF=$(git diff "${BASE_BRANCH}...HEAD" "${DIFF_ARGS[@]+"${DIFF_ARGS[@]}"}")
    DIFF_DESC="${BASE_BRANCH}...HEAD"
    ;;
  commits)
    DIFF=$(git diff "HEAD~1...HEAD" "${DIFF_ARGS[@]+"${DIFF_ARGS[@]}"}")
    DIFF_DESC="HEAD~1...HEAD"
    ;;
  files)
    DIFF=""
    for f in "${FILES_LIST[@]}"; do
      if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        file_diff=$(git diff HEAD -- "$f")
        if [[ -n "$file_diff" ]]; then
          DIFF="${DIFF}${file_diff}"$'\n'
        fi
      elif [[ -f "$f" ]]; then
        # 未跟踪的新文件：生成合成 diff
        DIFF="${DIFF}$(git diff --no-index /dev/null "$f" 2>/dev/null || true)"$'\n'
      fi
    done
    DIFF_DESC="files: ${FILES_LIST}"
    ;;
esac

# Fallback: if branch diff is empty, try uncommitted changes
if [[ -z "$DIFF" && "$MODE" == "branch" ]]; then
  echo ">>> No committed changes (${DIFF_DESC}). Trying uncommitted changes..." >&2
  UNCOMMITTED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
  UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null || true)
  ALL_FILES=$(printf '%s\n%s' "$UNCOMMITTED_FILES" "$UNTRACKED_FILES" | sort -u | grep -v '^$' || true)
  if [[ -n "$ALL_FILES" ]]; then
    MODE="files"
    FILES_LIST=()
    while IFS= read -r line; do FILES_LIST+=("$line"); done <<< "$ALL_FILES"
    for f in "${FILES_LIST[@]}"; do
      if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
        file_diff=$(git diff HEAD -- "$f")
        if [[ -n "$file_diff" ]]; then
          DIFF="${DIFF}${file_diff}"$'\n'
        fi
      elif [[ -f "$f" ]]; then
        DIFF="${DIFF}$(git diff --no-index /dev/null "$f" 2>/dev/null || true)"$'\n'
      fi
    done
    DIFF_DESC="uncommitted changes (${#FILES_LIST[@]} files)"
  fi
fi

if [[ -z "$DIFF" ]]; then
  echo "No code changes found (${DIFF_DESC})" >&2
  exit 0
fi

# branch 模式只审已提交的分支 diff：工作区里改了没提交的、新建没跟踪的都不在其中，提醒一句（想审它们用 --files）。
# 不数 Docs/：上一轮审查报告就写在 Docs/<分支>/ 下，算进来会每轮误报。
if [[ "$MODE" == "branch" ]]; then
  UNCOMMITTED_COUNT=$( { git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } \
    | grep -v '^Docs/' | sort -u | grep -c . || true)
  if (( UNCOMMITTED_COUNT > 0 )); then
    echo ">>> Note: ${UNCOMMITTED_COUNT} uncommitted or untracked file(s) are not in this diff (${DIFF_DESC}); pass --files to review them" >&2
  fi
fi

# Output file — sanitize branch name to prevent path traversal
BRANCH=$(git branch --show-current | tr '/' '_')
TIMESTAMP=$(date +"%Y-%m-%d-%H%M")
OUT_DIR="Docs/${BRANCH}"
mkdir -p "$OUT_DIR"
REVIEW_FILE="${OUT_DIR}/claude-code-review_${TIMESTAMP}.md"

# Write diff to temp file so Claude reads it from disk (avoids ARG_MAX)
DIFF_FILE=$(mktemp "$QQ_TEMP_DIR/code-review-diff-XXXXXXXX")
printf '%s' "$DIFF" > "$DIFF_FILE"

# Build review prompt
if [[ -n "$CUSTOM_PROMPT" ]]; then
  REVIEW_PROMPT="$CUSTOM_PROMPT"
else
  REVIEW_PROMPT="Review the following code changes.

Review criteria:
1. Bugs: Logic errors, off-by-one, null derefs, race conditions
2. Architecture: Dependency violations, coupling issues, layering breaks
3. Performance: O(N^2) in hot paths, unnecessary allocations, missing cleanup
4. Security: Injection, XSS, unsafe deserialization (if applicable)
5. Style: Violations of project coding standards (see below)

Classify each finding by severity: [Critical] [Moderate] [Suggestion]
For each finding, cite the specific file and line range.
For anything you're unsure about, mark it [Uncertain] — do NOT guess.
Be concise. Only output review findings."
fi

SPEC_SECTION=""
if (( ${#SPEC_FILES[@]} > 0 )); then
  SPEC_SECTION="
$(qq_review_spec_section "${SPEC_FILES[@]}")
"
fi

# Tell Claude to read files from disk instead of inlining content
FULL_PROMPT="${REVIEW_PROMPT}

---

## Project Context

Read the CLAUDE.md file at the project root for coding standards.
Read the AGENTS.md file at the project root for architecture rules (if it exists).

## Unity Best-Practice Checklist (18 rules — check every one)

Anti-Patterns:
1. [High] FindObjectOfType in runtime code — use Registry/Manager (Editor code exempt)
2. [Moderate] Untyped object[] message parameters — use strongly-typed interfaces
3. [High] Accessing shared data in Awake/Start — use lifecycle ready callbacks
4. [High] Caching read-only interface then mutating through it
5. [Moderate] SendMessage/BroadcastMessage — use C# events or interfaces
6. [Notice] Unsolicited UI code changes

Performance:
7. [High] GetComponent in Update/FixedUpdate/LateUpdate — cache in Awake/Start
8. [High] Per-frame heap allocations (new List, string concat, LINQ, closures in Update)
9. [High] Coroutines started without cleanup in OnDisable
10. [Moderate] gameObject.tag == string comparison — use CompareTag()

Runtime Safety:
11. [High] Event subscription without matching unsubscription
12. [Moderate] Missing [RequireComponent] for GetComponent dependencies

Architecture:
13. Circular dependency risk (check using directives)
14. Missing .asmdef references
15. [Moderate] Incorrect namespace conventions
16. [Moderate] Public fields instead of [SerializeField] private

Code Quality:
17. Excessive null checks (project style: minimal, trust contracts)
18. Missing documentation comments on public classes

$(qq_review_test_quality_section)
${SPEC_SECTION}
---

## Code Changes (${DIFF_DESC})

Read ${DIFF_FILE} for the full diff."

echo ">>> Sending code changes (${DIFF_DESC}) to Claude for review..." >&2
echo ">>> Diff written to ${DIFF_FILE} ($(wc -l < "$DIFF_FILE") lines)" >&2

claude -p "$FULL_PROMPT" | tee "$REVIEW_FILE"

rm -f "$DIFF_FILE"

echo "" >&2
echo ">>> Review saved to: ${REVIEW_FILE}" >&2

# 审查真跑完了才立审查门（按会话 id；见 platform/detect.sh 的 qq_review_gate_open）
qq_review_gate_open

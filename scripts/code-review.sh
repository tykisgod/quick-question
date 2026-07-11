#!/usr/bin/env bash
# code-review.sh — Send code changes to Codex CLI for review
#
# Usage:
#   ./scripts/code-review.sh                           # Default: main...HEAD
#   ./scripts/code-review.sh --base main               # Custom base branch
#   ./scripts/code-review.sh --commits                 # Last commit only (HEAD~1...HEAD)
#   ./scripts/code-review.sh --ext "*.py"              # Filter by extension
#   ./scripts/code-review.sh --prompt "custom prompt"  # Custom prompt
#   ./scripts/code-review.sh --files "a.cs b.cs"       # Specific files
#   ./scripts/code-review.sh --effort high             # Override reasoning effort (low/medium/high)
#
# Environment:
#   QQ_CODEX_EFFORT — default reasoning effort (default: high)
#                     Reviews with reasoning=none (Codex default) return shallow "No findings"
#                     results. Always force at least medium for meaningful review.
#
# Output:
#   Review saved to Docs/<branch>/codex-code-review_<timestamp>.md
#   Also printed to stdout

set -euo pipefail

source "$(dirname "$0")/platform/detect.sh"

if ! command -v codex &>/dev/null; then
  echo "Error: codex CLI not found. Install with: npm install -g @openai/codex" >&2
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
# Reasoning effort — resolved after arg parsing (see resolve_codex_effort):
# explicit env/flag passes through (low/medium/high/ultra); unset inherits a non-none
# config.toml value; otherwise forced to high (`none` gives shallow reviews).
CODEX_EFFORT="${QQ_CODEX_EFFORT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)    BASE_BRANCH="$2"; shift 2 ;;
    --commits) MODE="commits"; shift ;;
    --ext)     EXT_FILTER="$2"; shift 2 ;;
    --prompt)  CUSTOM_PROMPT="$2"; shift 2 ;;
    --files)   IFS=' ' read -ra FILES_LIST <<< "$2"; MODE="files"; shift 2 ;;
    --effort)  CODEX_EFFORT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

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
  cfg=$(grep -oE '^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"[^"]+"'         "$HOME/.codex/config.toml" 2>/dev/null | sed 's/.*"\(.*\)"//')
  if [[ -n "$cfg" && "$cfg" != "none" ]]; then
    CODEX_EFFORT=""   # inherit config.toml (shown as reasoning=config)
  else
    CODEX_EFFORT="high"
  fi
}
resolve_codex_effort

# Validate base branch looks like a git ref (prevent flag injection)
if [[ "$BASE_BRANCH" == -* ]]; then
  echo "Error: invalid base branch: $BASE_BRANCH" >&2
  exit 1
fi

# Output file — sanitize branch name to prevent path traversal
BRANCH=$(git branch --show-current | tr '/' '_')
TIMESTAMP=$(date +"%Y-%m-%d-%H%M")
OUT_DIR="Docs/${BRANCH}"
mkdir -p "$OUT_DIR"
REVIEW_FILE="${OUT_DIR}/codex-code-review_${TIMESTAMP}.md"

# Build the review prompt body
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

PROMPT_BODY="${REVIEW_PROMPT}

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
18. Missing documentation comments on public classes"

# ═══════════════════════════════════════════════════════════════════════════
# 为什么用 `codex exec` 而不是 `codex review`：
#
# `codex review` 子命令看起来更合适（自带 git diff 感知 + review 专属 prompting），
# bc146cb 曾经切过去。后来退回来有两个原因：
#
# 1. codex-cli 0.118.x 的 clap 解析器冲突：`--base` / `--commit` / `--uncommitted`
#    与 `[PROMPT]` positional 参数被标记为互斥（尽管 --help 同时列出两者），任何带
#    自定义 PROMPT 的调用都会直接报错：
#      error: the argument '--base <BRANCH>' cannot be used with '[PROMPT]'
#    连 `-` 读 stdin 的写法也同样被拒。
#
# 2. `codex review` 原生不支持 --files / --ext 这类更灵活的 scope——而我们经常
#    需要对特定文件或未提交变更做 review，不只是 branch diff。灵活性本身就让
#    `codex exec` 成为更合适的长期方案。
#
# 所以统一走 `codex exec` + 手工构造 diff，prompt 和 Unity 18 条 checklist 通过
# FULL_PROMPT 直接注入。Force `model_reasoning_effort=high` 避免默认 `none` 返回
# 浅层 "No findings" 结果。
# ═══════════════════════════════════════════════════════════════════════════

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
    DIFF_DESC="files: ${FILES_LIST[*]}"
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
    mapfile -t FILES_LIST <<< "$ALL_FILES"
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

# Write diff to temp file so Codex reads it from disk (avoids ARG_MAX)
DIFF_FILE=$(mktemp "$QQ_TEMP_DIR/code-review-diff-XXXXXXXX")
printf '%s' "$DIFF" > "$DIFF_FILE"

FULL_PROMPT="${PROMPT_BODY}

---

## Code Changes (${DIFF_DESC})

Read ${DIFF_FILE} for the full diff."

echo ">>> codex exec (${DIFF_DESC}, reasoning=${CODEX_EFFORT:-config})" >&2
echo ">>> Diff written to ${DIFF_FILE} ($(wc -l < "$DIFF_FILE") lines)" >&2

EFFORT_ARGS=()
[[ -n "$CODEX_EFFORT" ]] && EFFORT_ARGS=(-c "model_reasoning_effort=\"${CODEX_EFFORT}\"")
codex exec \
  --sandbox read-only \
  "${EFFORT_ARGS[@]}" \
  "$FULL_PROMPT" | tee "$REVIEW_FILE"

rm -f "$DIFF_FILE"

echo "" >&2
echo ">>> Review saved to: ${REVIEW_FILE}" >&2

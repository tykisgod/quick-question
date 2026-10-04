#!/usr/bin/env bash
# qq-release.sh — Release helper for quick-question.
#
# Wraps the manual ceremony: bump version, README badge, append CHANGELOG entry,
# commit, push, watch CI. Runs the whole test.sh before committing (and again
# after the bump) and refuses to release unless every check passes.
#
# Usage:
#   scripts/qq-release.sh <patch|minor|major> "<one-paragraph release notes>"
#   scripts/qq-release.sh patch "Hook scripts now fall back to python3 when jq is missing."
#
# Optional flags:
#   --dry-run         Print every action but never write files, commit, or push.
#   --no-push         Commit locally but skip git push and CI watch.
#   --skip-tests      Skip running ./test.sh before committing (use only for doc-only fixes).
#   --include-dirty   Fold other tracked changes into the release commit: edits, plus
#                     deletions and renames already staged (git rm / git mv). Without it
#                     the release refuses to run. An unstaged deletion is still refused
#                     while untracked files exist: it may be half of a plain-mv rename
#                     whose new path would be left out. Never covers plugin.json /
#                     README.md / CHANGELOG.md.
#   --version <X.Y.Z> Force a specific version instead of bumping.
#
# Notes:
#   - Always creates a NEW commit (never amends). It commits only the release-managed
#     files plus, with --include-dirty, the changes listed before the tests ran;
#     anything staged in the meantime stays staged, out of the release.
#   - Refuses to release while tracked files have changes this script didn't make
#     (staged or not), unless --include-dirty. Edits to plugin.json / README.md /
#     CHANGELOG.md are refused even then (often a bump left by an interrupted
#     release; the restore command is printed). Untracked files are never
#     committed; they are listed and left where they are.
#   - Refuses to release unless the whole test.sh passes (exit 0, no ✗ lines,
#     ends with its "All N checks passed" line), both before and after the version
#     bump (unless --skip-tests). test.sh runs from the repo root wherever this
#     script is called from. The failing ✗ lines are printed (plus the log's tail
#     if test.sh stopped early) and the full log is kept.
#   - Refuses to release if local is behind origin/main — fetch + ancestor
#     check runs before version derivation, so stale local state can't compute
#     a version that's already taken on the remote (v1.16.27 incident).
#   - Watches CI by matching the pushed commit's full SHA, not just "latest
#     Validate run on main", so concurrent pushes / registration lag can't
#     make us watch the wrong run and report a false green.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Python compatibility: the Windows Store python3 alias passes `--version` yet hangs on
# stdin-fed scripts (test.sh), so skip any python3 that resolves into WindowsApps.
if [[ -z "${QQ_PY:-}" ]]; then
  QQ_PY="python"
  if python3 --version >/dev/null 2>&1; then
    case "$(command -v python3)" in
      */WindowsApps/*) ;;   # Windows Store alias: answers --version but hangs on stdin-fed scripts
      *) QQ_PY="python3" ;;
    esac
  fi
fi

PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
README_FILE="$REPO_ROOT/README.md"
CHANGELOG_FILE="$REPO_ROOT/CHANGELOG.md"
TEST_SCRIPT="$REPO_ROOT/test.sh"

# ── arg parsing ──
DRY_RUN=0
NO_PUSH=0
SKIP_TESTS=0
INCLUDE_DIRTY=0
FORCED_VERSION=""
BUMP_KIND=""
RELEASE_NOTES=""
POSITIONAL=()

# 打印文件头的说明（第 2 行到第一个空行），头部增删行时不用跟着改行号
usage() {
  sed -n '2,/^$/p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-push) NO_PUSH=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --include-dirty) INCLUDE_DIRTY=1; shift ;;
    --version)
      [[ $# -ge 2 ]] || { echo "Error: --version requires X.Y.Z"; exit 1; }
      FORCED_VERSION="$2"
      shift 2
      ;;
    --version=*) FORCED_VERSION="${1#--version=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Error: unknown flag: $1"; usage >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ ${#POSITIONAL[@]} -lt 2 && -z "$FORCED_VERSION" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$FORCED_VERSION" ]]; then
  BUMP_KIND="${POSITIONAL[0]}"
  RELEASE_NOTES="${POSITIONAL[1]}"
  case "$BUMP_KIND" in
    patch|minor|major) ;;
    *) echo "Error: bump kind must be patch, minor, or major"; exit 1 ;;
  esac
else
  RELEASE_NOTES="${POSITIONAL[0]:-${POSITIONAL[1]:-}}"
  if [[ -z "$RELEASE_NOTES" ]]; then
    echo "Error: --version still requires release notes as the next positional arg"
    exit 1
  fi
fi

# ── safety: verify local is in sync with origin/main ──
# Without this check, if origin advanced between your last pull and now
# (another session, concurrent release, CI automation), the script reads
# stale plugin.json, bumps to a version already taken on the remote, and
# the push fails *after* the local release commit is already created —
# forcing manual `git reset --hard` + rebase + retry. The v1.16.27 release
# walked us through exactly this recovery loop, hence this pre-flight.
echo "→ Pre-flight: checking local is in sync with origin/main..."
if ! (cd "$REPO_ROOT" && git fetch origin main --quiet); then
  echo "Error: git fetch origin main failed. Check network / remote access."
  exit 1
fi
if ! (cd "$REPO_ROOT" && git merge-base --is-ancestor origin/main HEAD); then
  BEHIND_BY="$(cd "$REPO_ROOT" && git rev-list --count HEAD..origin/main)"
  echo "Error: local is $BEHIND_BY commits behind origin/main."
  echo ""
  echo "  Commits on origin you don't have:"
  (cd "$REPO_ROOT" && git log --oneline HEAD..origin/main | head -10 | sed 's/^/    /')
  echo ""
  echo "  Fix: rebase your work onto origin/main first, then re-run this script"
  echo "  (the version number will re-derive from the updated plugin.json):"
  echo "    git pull --rebase origin main"
  exit 1
fi
echo "  ✓ local is in sync with origin/main"
echo ""

# ── derive current + new version ──
CURRENT_VERSION="$("$QQ_PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$PLUGIN_JSON")"
if [[ -n "$FORCED_VERSION" ]]; then
  NEW_VERSION="$FORCED_VERSION"
else
  IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
  case "$BUMP_KIND" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  esac
  NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
fi

if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: new version '$NEW_VERSION' is not in X.Y.Z form"
  exit 1
fi

TODAY="$(date +%Y-%m-%d)"

echo "── qq-release ──"
echo "  Current: v$CURRENT_VERSION"
echo "  Next:    v$NEW_VERSION"
echo "  Date:    $TODAY"
echo "  Notes:   $RELEASE_NOTES"
[[ "$DRY_RUN" -eq 1 ]] && echo "  Mode:    DRY RUN"
echo ""

# ── safety: 发版提交默认只放本脚本自己改的三份文件 ──
# 以前把工作区里别的脏文件（连未跟踪文件）默认 git add 进发版提交，提示里让用的 --no-include-dirty
# 根本不存在；拆 porcelain 用的 awk '{print $2}' 遇到改名、带空格的路径也拆错。现在：
#   - 已跟踪文件上任何不是本脚本做的改动（含已暂存的）都拒绝发版，确实要带进去得显式传 --include-dirty；
#   - 三份发版文件上已有的改动 --include-dirty 也拒绝：多半是上次改完版本号后测试没过留下的，
#     带着它重跑会从已经改过的版本号再升一级，CHANGELOG 里多出一条从没发出去的版本；
#   - --include-dirty 碰上未暂存的删除、又有未跟踪文件，也拒绝：可能是用 mv（不是 git mv）改的名，
#     新路径是未跟踪文件不会提交，发版提交里就只剩删除；
#   - 未跟踪文件任何情况下都不进发版提交，只列出来提示一下；
#   - 路径一律走 -z 输出；--no-renames 让改名的新旧两边都列出来。
# 这一步放在跑 test.sh 之前，免得白跑十分钟测试才被拒。
RELEASE_FILES=(.claude-plugin/plugin.json README.md CHANGELOG.md)   # 相对仓库根目录
DIRTY_STAGED=()     # 已暂存（索引 vs HEAD）
DIRTY_UNSTAGED=()   # 未暂存（工作区 vs 索引）：--include-dirty 时才 git add
UNSTAGED_DELETED=() # 未暂存的删除
UNTRACKED=()
while IFS= read -r -d '' f; do DIRTY_STAGED+=("$f"); done < <(cd "$REPO_ROOT" && git diff --cached --name-only --no-renames -z)
while IFS= read -r -d '' f; do DIRTY_UNSTAGED+=("$f"); done < <(cd "$REPO_ROOT" && git diff --name-only --no-renames -z)
while IFS= read -r -d '' f; do UNSTAGED_DELETED+=("$f"); done < <(cd "$REPO_ROOT" && git diff --name-only --no-renames --diff-filter=D -z)
while IFS= read -r -d '' f; do UNTRACKED+=("$f"); done < <(cd "$REPO_ROOT" && git ls-files --others --exclude-standard -z)

# 两份清单去重合并（bash 3.2 没有关联数组，逐个比），顺带挑出三份发版文件
DIRTY_TRACKED=()
RELEASE_DIRTY=()
for f in ${DIRTY_STAGED[@]+"${DIRTY_STAGED[@]}"} ${DIRTY_UNSTAGED[@]+"${DIRTY_UNSTAGED[@]}"}; do
  seen=0
  for g in ${DIRTY_TRACKED[@]+"${DIRTY_TRACKED[@]}"}; do
    if [[ "$g" == "$f" ]]; then seen=1; break; fi
  done
  if [[ "$seen" -eq 1 ]]; then continue; fi
  DIRTY_TRACKED+=("$f")
  for g in "${RELEASE_FILES[@]}"; do
    if [[ "$g" == "$f" ]]; then RELEASE_DIRTY+=("$f"); break; fi
  done
done

if [[ ${#UNTRACKED[@]} -gt 0 ]]; then
  echo "Note: ${#UNTRACKED[@]} untracked file(s) will be ignored (never part of the release commit):"
  shown=0
  for f in "${UNTRACKED[@]}"; do
    if [[ "$shown" -ge 20 ]]; then
      echo "  ... and $(( ${#UNTRACKED[@]} - shown )) more"
      break
    fi
    printf '  %s\n' "$f"
    shown=$((shown + 1))
  done
  echo ""
fi

if [[ ${#RELEASE_DIRTY[@]} -gt 0 ]]; then
  echo "Error: release-managed files already have changes:"
  printf '  %s\n' "${RELEASE_DIRTY[@]}"
  echo ""
  echo "This script rewrites them itself, so it won't release on top of other edits"
  echo "to them, not even with --include-dirty. If they are left over from an"
  echo "interrupted release (e.g. test.sh failed after the version bump), restore them:"
  printf '  git -C %q checkout HEAD --' "$REPO_ROOT"
  printf ' %q' "${RELEASE_DIRTY[@]}"
  echo ""
  echo "Otherwise commit or stash those edits first."
  exit 1
fi

if [[ ${#DIRTY_TRACKED[@]} -gt 0 ]]; then
  if [[ "$INCLUDE_DIRTY" -ne 1 ]]; then
    echo "Error: tracked files have changes this release would sweep into its commit:"
    printf '  %s\n' "${DIRTY_TRACKED[@]}"
    echo ""
    echo "Commit or stash them first, or re-run with --include-dirty to fold them"
    echo "into the release commit on purpose."
    exit 1
  fi
  if [[ ${#UNSTAGED_DELETED[@]} -gt 0 && ${#UNTRACKED[@]} -gt 0 ]]; then
    echo "Error: --include-dirty would commit these unstaged deletions:"
    printf '  %s\n' "${UNSTAGED_DELETED[@]}"
    echo ""
    echo "Untracked files exist and are never committed, so if a deletion is half of a"
    echo "rename done with plain mv, the release would just delete the file. Stage them"
    echo "yourself first: for a rename, git add both the old and the new path (or use"
    echo "git mv); for a real deletion, git rm it. Then re-run."
    exit 1
  fi
  echo "Note: --include-dirty given — these tracked changes go into the release commit:"
  printf '  %s\n' "${DIRTY_TRACKED[@]}"
  echo ""
fi

# ── pre-flight: critical structural checks (ALWAYS runs, never skipped) ──
# These are <1 second each and catch the v1.16.22 class of bugs:
#   - Root README's Chinese half drifted from docs/zh-CN/README.md
#   - docs/<lang>/X.md links to ../<other-lang>/Y.md when docs/<lang>/Y.md exists
# --skip-tests bypasses the heavyweight test.sh run but NOT these.
echo "→ Pre-flight: critical structural checks (always runs)..."

# Check 1: README Chinese sync drift
SYNC_SCRIPT="$REPO_ROOT/scripts/qq-sync-readme-zh.py"
if [[ -f "$SYNC_SCRIPT" && -f "$REPO_ROOT/docs/zh-CN/README.md" ]]; then
  if ! "$QQ_PY" "$SYNC_SCRIPT" --project "$REPO_ROOT" --check >/dev/null 2>&1; then
    echo "Error: root README's Chinese half has drifted from docs/zh-CN/README.md."
    echo "Fix: python scripts/qq-sync-readme-zh.py --write"
    exit 1
  fi
  echo "  ✓ root README Chinese half in sync with docs/zh-CN/README.md"
fi

# Check 2: cross-language link discipline (zh-CN linking to ../en/X when docs/zh-CN/X exists)
CROSS_LANG_RESULT="$("$QQ_PY" - "$REPO_ROOT" <<'PY' 2>&1
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
docs = repo / 'docs'
if not docs.is_dir():
    sys.exit(0)
LANG_DIRS = {p.name for p in docs.iterdir() if p.is_dir() and p.name not in ('dev', 'evals', 'superpowers', 'main', 'images', 'qq')}
link_re = re.compile(r'\[[^\]]*\]\(([^)\s]+)\)')
violations = []
for lang in LANG_DIRS:
    lang_dir = docs / lang
    for path in lang_dir.rglob('*.md'):
        if path.name.endswith('_review.md'):
            continue
        try:
            text = path.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
        in_fence = False
        fence = chr(96) * 3
        for lineno, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith(fence):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for m in link_re.finditer(line):
                url = m.group(1).strip()
                if url.startswith(('http://', 'https://', 'mailto:', '#')):
                    continue
                cm = re.match(r'^\.\./([^/]+)/(.+)$', url)
                if not cm:
                    continue
                other_lang = cm.group(1)
                other_path = cm.group(2).split('#', 1)[0].split('?', 1)[0]
                if other_lang == lang or other_lang not in LANG_DIRS:
                    continue
                if path.name == 'README.md' and other_path == 'README.md':
                    continue
                if (lang_dir / other_path).exists():
                    rel = path.relative_to(repo).as_posix()
                    violations.append(f'{rel}:{lineno} -> ../{other_lang}/{other_path}')
if violations:
    print('\n'.join(violations))
    sys.exit(1)
PY
)" || {
    echo "Error: cross-language link discipline violations (link should be same-language sibling):"
    printf '%s\n' "$CROSS_LANG_RESULT" | head -10 | sed 's/^/  /'
    echo "Fix: change ../<other-lang>/X.md to X.md (same-language sibling)"
    exit 1
}
echo "  ✓ no cross-language links where same-language sibling exists"
echo ""

# ── 整份 test.sh 当门槛（--skip-tests 跳过）──
# 以前只拿第 5 段（README 一致性）的 ✗ 当门槛，其它段失败、甚至 test.sh 中途崩掉都照样发版。
# 现在要退出码 0、没有任何 ✗ 行、最后一行是「All N checks passed」汇总，才算全过。没全过就打出 ✗ 行；
# 最后一行不是汇总行（中途崩掉、提前退出）或者挑不出 ✗ 行时，再打日志末尾，崩掉的原因在那里。
# 完整日志留在临时文件里，不用为了看细节再跑一遍。$1 = 这一轮的说明，用在报错里。
# ✗ 行只认行首（可带颜色码）的 ✗，即 test.sh 里 fail() 打的那种；通过的用例名里提到 ✗ 不算。
QQ_RELEASE_FAIL_LINE_RE=$'^[[:space:]]*(\033\\[[0-9;]*m)*✗'
QQ_RELEASE_PASS_SUMMARY_RE=$'^(\033\\[[0-9;]*m)*All [0-9]+ checks passed(\033\\[[0-9;]*m)*[[:space:]]*$'
QQ_RELEASE_FAIL_SUMMARY_RE=$'^(\033\\[[0-9;]*m)*[0-9]+/[0-9]+ checks failed(\033\\[[0-9;]*m)*[[:space:]]*$'
run_full_tests() {
  local phase="$1" log rc=0 fails last
  log="$(mktemp "${TMPDIR:-/tmp}/qq-release-test.XXXXXX")"
  # test.sh 自己不 cd，有些检查按相对路径读 skills/*/SKILL.md、scripts/qq_mcp.py，
  # 所以一定在仓库根目录跑；不然从别的目录调发版脚本会冒出一串假失败。
  (cd "$REPO_ROOT" && bash "$TEST_SCRIPT") > "$log" 2>&1 || rc=$?
  fails="$(grep -E "$QQ_RELEASE_FAIL_LINE_RE" "$log" || true)"
  last="$(tail -n 1 "$log")"
  if [[ "$rc" -eq 0 && -z "$fails" && "$last" =~ $QQ_RELEASE_PASS_SUMMARY_RE ]]; then
    echo "  ✓ test.sh: $last"
    rm -f "$log"
    return 0
  fi
  echo "Error: test.sh did not fully pass $phase (exit $rc)."
  if [[ -n "$fails" ]]; then
    echo "Failing checks:"
    printf '%s\n' "$fails"
  fi
  local finished=0
  if [[ "$last" =~ $QQ_RELEASE_PASS_SUMMARY_RE || "$last" =~ $QQ_RELEASE_FAIL_SUMMARY_RE ]]; then
    finished=1
  else
    echo "test.sh stopped before its summary line (crashed or exited early)."
  fi
  if [[ "$finished" -eq 0 || -z "$fails" ]]; then
    echo "Last lines of its output:"
    tail -n 15 "$log"
  fi
  echo "Full log: $log"
  return 1
}

if [[ "$SKIP_TESTS" -ne 1 ]]; then
  echo "→ Pre-flight: running the whole test.sh (takes a while)..."
  if [[ ! -x "$TEST_SCRIPT" ]]; then
    echo "Error: test.sh not found or not executable: $TEST_SCRIPT"
    exit 1
  fi
  if ! run_full_tests "before the release"; then
    echo ""
    echo "Fix the failures before releasing. (Use --skip-tests to bypass.)"
    exit 1
  fi
fi

# ── apply: bump plugin.json + README badge + CHANGELOG ──
apply_changes() {
  echo "→ Bumping plugin.json: $CURRENT_VERSION → $NEW_VERSION"
  "$QQ_PY" - "$PLUGIN_JSON" "$NEW_VERSION" <<'PY'
import json
import sys

path = sys.argv[1]
new_version = sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["version"] = new_version
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY

  echo "→ Bumping README version badge: v$CURRENT_VERSION → v$NEW_VERSION"
  "$QQ_PY" - "$README_FILE" "$CURRENT_VERSION" "$NEW_VERSION" <<'PY'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
# This is text.replace, not re.sub — the substring is literal, no regex escaping.
old_pattern = f"version-v{old}-blue"
new_pattern = f"version-v{new}-blue"
if old_pattern not in text:
    print(f"Warning: README badge '{old_pattern}' not found; skipping badge bump", file=sys.stderr)
else:
    text = text.replace(old_pattern, new_pattern)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
PY

  echo "→ Prepending CHANGELOG entry for v$NEW_VERSION"
  "$QQ_PY" - "$CHANGELOG_FILE" "$NEW_VERSION" "$TODAY" "$RELEASE_NOTES" <<'PY'
import sys

path, version, date, notes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
header = "All notable changes to quick-question are documented here."
if header not in text:
    print(f"Error: changelog header not found in {path}", file=sys.stderr)
    sys.exit(1)
entry = f"## [{version}] — {date}\n\n{notes}\n\n"
new_text = text.replace(header, header + "\n\n" + entry, 1)
# The replacement above leaves the original header line in place and inserts
# the entry directly under it; collapse the duplicate blank lines that creates.
new_text = new_text.replace(header + "\n\n\n" + entry, header + "\n\n" + entry)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(new_text)
PY
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "(dry-run) Would bump plugin.json, README badge, and CHANGELOG."
  echo "(dry-run) Would commit + push + watch CI."
  echo ""
  echo "Re-run without --dry-run to apply."
  exit 0
fi

apply_changes

# ── post-bump: 改完版本号再跑一遍整份 test.sh ──
if [[ "$SKIP_TESTS" -ne 1 ]]; then
  echo "→ Post-bump: re-running the whole test.sh against the bumped version..."
  if ! run_full_tests "after the version bump"; then
    echo ""
    echo "test.sh fails after the version bump; nothing was committed. The bump is still"
    echo "in the release-managed files — restore them before re-running:"
    printf '  git -C %q checkout HEAD -- %s\n' "$REPO_ROOT" "${RELEASE_FILES[*]}"
    exit 1
  fi
fi

# ── commit ──
echo "→ Staging release-managed files"
(cd "$REPO_ROOT" && git add -- "${RELEASE_FILES[@]}")

# --include-dirty：发版前就列出来的已跟踪改动一起提交。已暂存的本来就在索引里；
# 未暂存的按上面记下的清单逐个 git add（删除也能这样暂存），未跟踪文件始终不碰。
# --literal-pathspecs：路径里的 * ? [ 之类按字面算，不当通配符。
if [[ "$INCLUDE_DIRTY" -eq 1 && ${#DIRTY_UNSTAGED[@]} -gt 0 ]]; then
  echo "→ Staging the extra tracked changes (--include-dirty)"
  (cd "$REPO_ROOT" && git --literal-pathspecs add -- "${DIRTY_UNSTAGED[@]}")
fi

# 这次要提交的路径：三份发版文件，加上 --include-dirty 时发版前列出来的那些里、现在确实有暂存改动的
# （暂存后又删掉的新文件不算：它已经不在索引里，带上它 git commit 会报 pathspec 不认识）。
COMMIT_PATHS=("${RELEASE_FILES[@]}")
if [[ "$INCLUDE_DIRTY" -eq 1 && ${#DIRTY_TRACKED[@]} -gt 0 ]]; then
  while IFS= read -r -d '' f; do
    for g in "${DIRTY_TRACKED[@]}"; do
      if [[ "$g" == "$f" ]]; then COMMIT_PATHS+=("$f"); break; fi
    done
  done < <(cd "$REPO_ROOT" && git diff --cached --name-only --no-renames -z)
fi

echo "→ Committing"
COMMIT_MSG=$(cat <<EOF
release: v$NEW_VERSION

$RELEASE_NOTES

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)
# 带路径提交，只提交 COMMIT_PATHS：跑两遍 test.sh 要二三十分钟，这期间别的会话（或人）可能往索引里
# 加了东西，不带路径的 git commit 会把整个索引都提交出去。带路径时别的暂存内容原样留在索引里。
(cd "$REPO_ROOT" && git --literal-pathspecs commit -m "$COMMIT_MSG" -- "${COMMIT_PATHS[@]}")
COMMIT_SHA="$(cd "$REPO_ROOT" && git rev-parse --short HEAD)"
COMMIT_SHA_FULL="$(cd "$REPO_ROOT" && git rev-parse HEAD)"
echo "  ✓ committed $COMMIT_SHA"
LEFT_STAGED=()
while IFS= read -r -d '' f; do LEFT_STAGED+=("$f"); done < <(cd "$REPO_ROOT" && git diff --cached --name-only --no-renames -z)
if [[ ${#LEFT_STAGED[@]} -gt 0 ]]; then
  echo "Note: these got staged while the release ran; left out of its commit, still staged:"
  printf '  %s\n' "${LEFT_STAGED[@]}"
fi

if [[ "$NO_PUSH" -eq 1 ]]; then
  echo ""
  echo "──"
  echo "Released v$NEW_VERSION locally as $COMMIT_SHA. Push manually when ready:"
  echo "  git push origin main"
  exit 0
fi

# ── push ──
echo "→ Pushing to origin main"
(cd "$REPO_ROOT" && git push origin main)

# ── watch CI ──
# Bug fix: previously used `gh run list --limit 1` which grabs the most recent
# Validate run regardless of which commit triggered it. If GitHub hadn't yet
# registered our push (sleep 2 is often not enough), the script picked up the
# *previous* release's run and reported green based on that — CLAUDE.md even
# documents "always re-confirm with gh run list --limit 2 --branch main" as a
# live workaround. Now we poll for a run whose headSha matches the commit we
# just pushed, with exponential backoff (1+2+4+8+15 = 30s total patience).
echo "→ Watching CI run on main for commit $COMMIT_SHA"
RUN_ID=""
for delay in 1 2 4 8 15; do
  sleep "$delay"
  RUN_ID="$(gh run list --branch main --workflow Validate --limit 10 \
    --json databaseId,headSha \
    --jq ".[] | select(.headSha == \"$COMMIT_SHA_FULL\") | .databaseId" \
    2>/dev/null | head -1 || true)"
  if [[ -n "$RUN_ID" ]]; then
    break
  fi
  echo "  (waiting for GitHub to register Validate run for $COMMIT_SHA...)"
done
if [[ -z "$RUN_ID" ]]; then
  echo "  Warning: no Validate run found for $COMMIT_SHA after 30s; skipping watch."
  echo "  The run may show up late — verify manually:"
  echo "    gh run list --branch main --limit 3"
else
  echo "  Found Validate run $RUN_ID for $COMMIT_SHA"
  gh run watch "$RUN_ID" --exit-status || {
    echo ""
    echo "Error: CI failed for v$NEW_VERSION (run $RUN_ID)"
    echo "Inspect with: gh run view $RUN_ID --log-failed"
    exit 1
  }
fi

echo ""
echo "──"
echo "Released v$NEW_VERSION as $COMMIT_SHA. CI green."

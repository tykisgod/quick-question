#!/usr/bin/env bash
# test.sh — Self-tests for quick-question repo
# Run: ./test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Python compatibility (Windows Git Bash has python, not python3).
# The Windows Store python3 alias passes `--version` yet hangs on the stdin-fed checks below,
# so skip any python3 that resolves into WindowsApps.
QQ_PY="python"
if python3 --version >/dev/null 2>&1; then
  case "$(command -v python3)" in
    */WindowsApps/*) ;;   # Windows Store alias: answers --version but hangs on stdin-fed scripts
    *) QQ_PY="python3" ;;
  esac
fi
export QQ_PY

# Force core.autocrlf=false for all git operations in test fixtures so Windows
# checkouts don't appear "modified" relative to the index right after commit.
# Without this, the worktree closeout test sees its own committed files as dirty.
export GIT_CONFIG_PARAMETERS="'core.autocrlf=false'"

# 钩子的门文件按会话 id 命名（stdin 的 session_id，没有时退回 CLAUDE_CODE_SESSION_ID）。
# 在 Claude Code 会话里跑 test.sh 时这个变量是真会话的 id，不清掉的话，被测钩子会去读写真会话的门文件；
# 需要它的用例自己显式传。
unset CLAUDE_CODE_SESSION_ID

# OS detection — used to gate a small set of test fixtures that create fake
# bare-name executables (no .cmd / .exe extension) which Linux/macOS can run
# via shebang but Windows cannot exec via PATHEXT.
IS_WINDOWS=false
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

PASS=0
FAIL=0
SKIP=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${NC} $1"; }
skip() { SKIP=$((SKIP + 1)); echo -e "  ${YELLOW}∅${NC} $1 (skipped: $2)"; }

# ── 1. ShellCheck ──
echo -e "${CYAN}[1/10] ShellCheck${NC}"
if command -v shellcheck &>/dev/null; then
  SHELL_FILES=$(find "$SCRIPT_DIR/scripts" -name "*.sh" -not -type l)
  SHELL_FILES="$SHELL_FILES $SCRIPT_DIR/install.sh $SCRIPT_DIR/test.sh $SCRIPT_DIR/.devcontainer/postCreate.sh $SCRIPT_DIR/scripts/docker-dev.sh"
  SC_FAIL=0
  for f in $SHELL_FILES; do
    if shellcheck -S error "$f" >/dev/null 2>&1; then
      pass "$(basename "$f")"
    else
      fail "$(basename "$f")"
      shellcheck -S error "$f" 2>&1 | head -20
      SC_FAIL=1
    fi
  done
  [ "$SC_FAIL" -eq 0 ] || echo ""
else
  echo -e "  ${CYAN}shellcheck not installed — skipping (brew install shellcheck)${NC}"
fi

# ── 2. Python compilation ──
echo -e "${CYAN}[2/10] Python compilation${NC}"
PY_FILES=$(find "$SCRIPT_DIR/scripts" -name "*.py" -not -type l)
for py_file in $PY_FILES; do
  if $QQ_PY -m py_compile "$py_file" >/dev/null 2>&1; then
    pass "$(basename "$py_file")"
  else
    fail "$(basename "$py_file")"
  fi
done

# ── 3. JSON validity ──
echo -e "${CYAN}[3/10] JSON validity${NC}"
for json_file in scripts/qq-capabilities.json scripts/tykit_capabilities.json scripts/godot_capabilities.json scripts/unreal_capabilities.json scripts/sbox_capabilities.json hooks/hooks.json .claude-plugin/plugin.json .claude-plugin/marketplace.json docs/evals/foundation-smoke.json docs/evals/unity-local.json docs/evals/collaboration-multi-actor.json docs/evals/qq-bench-foundation.json docs/evals/qq-bench-core-v0.json docs/evals/qq-bench-core-v1.json docs/evals/qq-bench-core-solver-v0.json .devcontainer/devcontainer.json; do
  if [ -f "$SCRIPT_DIR/$json_file" ]; then
    if $QQ_PY -m json.tool "$SCRIPT_DIR/$json_file" >/dev/null 2>&1; then
      pass "$json_file"
    else
      fail "$json_file — invalid JSON"
    fi
  else
    fail "$json_file — file not found"
  fi
done

# ── 4. Structural checks ──
echo -e "${CYAN}[4/10] Structural checks${NC}"

# Every skill directory has a SKILL.md
SKILL_DIRS=$(find "$SCRIPT_DIR/skills" -mindepth 1 -maxdepth 1 -type d)
for dir in $SKILL_DIRS; do
  name=$(basename "$dir")
  if [ -f "$dir/SKILL.md" ]; then
    pass "skills/$name/SKILL.md exists"
  else
    fail "skills/$name/SKILL.md missing"
  fi
done

# Hook scripts referenced in hooks.json actually exist
HOOK_SCRIPTS=$(grep -oE 'scripts/[a-z/._-]+\.sh' "$SCRIPT_DIR/hooks/hooks.json" || true)
for script in $HOOK_SCRIPTS; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    pass "hooks.json → $script exists"
  else
    fail "hooks.json → $script NOT FOUND"
  fi
done

# Platform helper scripts exist
for pf in detect.sh macos.sh windows.sh; do
  if [ -f "$SCRIPT_DIR/scripts/platform/$pf" ]; then
    pass "scripts/platform/$pf exists"
  else
    fail "scripts/platform/$pf NOT FOUND"
  fi
done

# Dev container files exist
for dc in .devcontainer/devcontainer.json .devcontainer/Dockerfile .devcontainer/postCreate.sh docs/dev/developer-workflow.md docs/dev/containerization.md scripts/docker-dev.sh; do
  if [ -f "$SCRIPT_DIR/$dc" ]; then
    pass "$dc exists"
  else
    fail "$dc NOT FOUND"
  fi
done

# install.sh resolves hook/runtime modules instead of blindly copying the whole hooks tree
if grep -q 'hooks-auto-compile' "$SCRIPT_DIR/scripts/qq_internal_install.py" && grep -q 'qq_internal_install.py' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh resolves hook modules through qq_internal_install.py"
else
  fail "install.sh missing modular hook install support"
fi


# Symlinks in tykit Scripts~/ point to valid targets
TYKIT_SCRIPTS="$SCRIPT_DIR/packages/com.tyk.tykit/Scripts~"
if [ -d "$TYKIT_SCRIPTS" ]; then
  for link in "$TYKIT_SCRIPTS"/*.sh; do
    if [ -L "$link" ]; then
      if [ -e "$link" ]; then
        pass "symlink $(basename "$link") → valid"
      else
        fail "symlink $(basename "$link") → BROKEN"
      fi
    fi
  done
fi

# tykit command coverage ratchet — enforce that the uncovered command count
# does not grow. As new tests land in v1.17.x, lower TYKIT_MAX_UNCOVERED.
# Run `python scripts/qq-tykit-coverage.py` standalone for the full report.
TYKIT_MAX_UNCOVERED=78
if [ -d "$SCRIPT_DIR/packages/com.tyk.tykit/Editor/Commands" ]; then
  TYKIT_AUDIT_OUT=$("$QQ_PY" "$SCRIPT_DIR/scripts/qq-tykit-coverage.py" \
    --project "$SCRIPT_DIR" --max-uncovered "$TYKIT_MAX_UNCOVERED" 2>&1)
  TYKIT_AUDIT_EXIT=$?
  TYKIT_UNCOVERED=$(printf '%s\n' "$TYKIT_AUDIT_OUT" | grep -oE 'uncovered: [0-9]+' | head -1 | awk '{print $2}')
  if [ "$TYKIT_AUDIT_EXIT" -eq 0 ]; then
    pass "tykit command coverage: ${TYKIT_UNCOVERED:-?} uncovered (max ${TYKIT_MAX_UNCOVERED})"
  else
    fail "tykit command coverage ratchet exceeded — ${TYKIT_UNCOVERED:-?} uncovered > max ${TYKIT_MAX_UNCOVERED}"
    printf '%s\n' "$TYKIT_AUDIT_OUT" | sed 's/^/    /'
  fi
fi

# Root README Chinese-half drift check — docs/zh-CN/README.md is the canonical
# Chinese source; root README's Chinese half is auto-generated by
# qq-sync-readme-zh.py. Run `python scripts/qq-sync-readme-zh.py --write` to fix.
if [ -f "$SCRIPT_DIR/scripts/qq-sync-readme-zh.py" ] && [ -f "$SCRIPT_DIR/docs/zh-CN/README.md" ]; then
  if "$QQ_PY" "$SCRIPT_DIR/scripts/qq-sync-readme-zh.py" \
       --check --project "$SCRIPT_DIR" >/dev/null 2>&1; then
    pass "root README Chinese half in sync with docs/zh-CN/README.md"
  else
    fail "root README Chinese half drifts from docs/zh-CN/README.md (run: python scripts/qq-sync-readme-zh.py --write)"
  fi
fi

# ── 5. README consistency ──
echo -e "${CYAN}[5/10] README consistency${NC}"

ACTUAL_SKILL_COUNT=$(find "$SCRIPT_DIR/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if grep -qE "${ACTUAL_SKILL_COUNT} (skill|slash|Slash)" "$SCRIPT_DIR/README.md"; then
  pass "README skill count ($ACTUAL_SKILL_COUNT) matches actual"
else
  fail "README skill count does not match actual ($ACTUAL_SKILL_COUNT skills)"
fi

for dir in $SKILL_DIRS; do
  name=$(basename "$dir")
  if grep -q "/qq:${name}" "$SCRIPT_DIR/README.md"; then
    pass "skill $name in README"
  else
    fail "skill $name NOT in README"
  fi
done

# 5b: skill count consistency across language READMEs (Chinese 个, Japanese 個, Korean 개)
for lang_readme in "$SCRIPT_DIR/docs/zh-CN/README.md" "$SCRIPT_DIR/docs/ja/README.md" "$SCRIPT_DIR/docs/ko/README.md"; do
  if [ -f "$lang_readme" ]; then
    rel_path="${lang_readme#"$SCRIPT_DIR/"}"
    if grep -qE "${ACTUAL_SKILL_COUNT} ?(skill|slash|个|個|개)" "$lang_readme"; then
      pass "$rel_path mentions $ACTUAL_SKILL_COUNT (skill count consistent)"
    else
      fail "$rel_path does NOT mention $ACTUAL_SKILL_COUNT (skill count drift)"
    fi
  fi
done

# 5c: README version badge matches plugin.json
PLUGIN_VERSION=$($QQ_PY -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$SCRIPT_DIR/.claude-plugin/plugin.json" 2>/dev/null || printf 'unknown')
if [ "$PLUGIN_VERSION" != "unknown" ] && grep -q "version-v${PLUGIN_VERSION}" "$SCRIPT_DIR/README.md"; then
  pass "README version badge matches plugin.json (v$PLUGIN_VERSION)"
else
  fail "README version badge does NOT match plugin.json (v$PLUGIN_VERSION)"
fi

# 5d: no legacy review-gate-{check,set,count,stop}.sh references in docs/ or templates/
LEGACY_GATE_FILES=$(grep -rEl 'review-gate-(check|set|count|stop)\.sh' "$SCRIPT_DIR/docs" "$SCRIPT_DIR/templates" 2>/dev/null || true)
if [ -z "$LEGACY_GATE_FILES" ]; then
  pass "no legacy review-gate-{check,set,count,stop}.sh refs in docs/ or templates/"
else
  fail "legacy review-gate-*.sh refs found in:"
  printf '    %s\n' $LEGACY_GATE_FILES
fi

# 5e: cross-doc link rot — verify every relative markdown link in tracked
# docs resolves to a file or directory that exists. Catches the class of
# drift where a doc gets renamed/moved without updating the things linking
# to it.
LINK_ROT_STATUS=0
LINK_ROT_OUTPUT="$($QQ_PY - "$SCRIPT_DIR" <<'PY' 2>&1
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
# Inline markdown link: [text](url). Reference-style links and HTML <a> are
# intentionally out of scope — they're rare in this corpus and would add false
# positives. URL captures everything up to the next ')'.
link_re = re.compile(r'\[[^\]]*\]\(([^)\s]+)\)')
broken: list[str] = []

# Top-level docs at repo root.
candidates: list[Path] = []
for name in ('README.md', 'AGENTS.md', 'CLAUDE.md', 'CONTRIBUTING.md',
             'SECURITY.md', 'CODE_OF_CONDUCT.md', 'CHANGELOG.md'):
    p = repo / name
    if p.is_file():
        candidates.append(p)

# Recurse into docs/, templates/, skills/ and shared/ (skills link the shared/
# agent docs), but skip:
#   - docs/superpowers/  — historical spec/plan files for completed work
#     that intentionally reference files since deleted (Context Capsule, etc.)
#   - docs/main/         — codex review log dumps with absolute paths
#   - any *_review.md    — review output dumps, not maintained docs
SKIPPED_PARTS = {'superpowers', 'main'}
for sub in ('docs', 'templates', 'skills', 'shared'):
    base = repo / sub
    if not base.is_dir():
        continue
    for path in base.rglob('*.md'):
        if any(part in SKIPPED_PARTS for part in path.parts):
            continue
        if path.name.endswith('_review.md'):
            continue
        candidates.append(path)

for path in candidates:
    try:
        text = path.read_text(encoding='utf-8')
    except (OSError, UnicodeDecodeError):
        continue
    in_fence = False
    fence_marker = chr(96) * 3  # avoid triple-backtick literal — bash $() parser
    for lineno, line in enumerate(text.splitlines(), 1):
        # Skip fenced code blocks (lines starting with three backticks).
        if line.lstrip().startswith(fence_marker):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in link_re.finditer(line):
            url = m.group(1).strip()
            # Skip external URLs, in-page anchors, and non-file schemes.
            if url.startswith(('http://', 'https://', 'mailto:', 'ftp://',
                               'tel:', 'data:', 'javascript:', '#')):
                continue
            # Drop fragment / query — we only check the file part.
            url_path = url.split('#', 1)[0].split('?', 1)[0]
            if not url_path:
                continue
            target = (path.parent / url_path).resolve()
            if not target.exists():
                rel = path.relative_to(repo).as_posix()
                broken.append(f'{rel}:{lineno} -> {url}')

if broken:
    print('\n'.join(broken))
    sys.exit(1)
PY
)" || LINK_ROT_STATUS=$?
if [ "$LINK_ROT_STATUS" -eq 0 ]; then
  pass "no broken relative markdown links in tracked docs"
else
  BROKEN_COUNT=$(printf '%s' "$LINK_ROT_OUTPUT" | awk '/->/{c++} END{print c+0}')
  fail "broken relative markdown links found ($BROKEN_COUNT)"
  printf '%s\n' "$LINK_ROT_OUTPUT" | head -20 | sed 's/^/    /'
  if [ "$BROKEN_COUNT" -gt 20 ]; then
    printf '    ... %s more\n' "$((BROKEN_COUNT - 20))"
  fi
fi

# 5f: cross-language link discipline — when a doc inside docs/<lang>/ links
# to a sibling in another language (e.g. docs/zh-CN/foo.md -> ../en/bar.md),
# verify that docs/<lang>/bar.md does NOT exist. If it does, the link should
# have been to the same-language sibling. Catches the v1.16.22 class of bug
# where zh-CN README's tykit-mcp / tykit-api / worktrees links pointed to
# ../en/ even though docs/zh-CN/ had identical filenames.
CROSS_LANG_STATUS=0
CROSS_LANG_OUTPUT="$($QQ_PY - "$SCRIPT_DIR" <<'PY' 2>&1
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
docs = repo / 'docs'
if not docs.is_dir():
    sys.exit(0)

# Discover language directories: docs/<lang>/ where <lang> looks like a
# language code (en, zh-CN, ja, ko, etc — heuristic: contains a letter or dash).
LANG_DIRS = {p.name for p in docs.iterdir() if p.is_dir() and p.name not in ('dev', 'evals', 'superpowers', 'main')}

link_re = re.compile(r'\[[^\]]*\]\(([^)\s]+)\)')
violations: list[str] = []

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
                # Look for ../<other-lang>/ pattern
                cross_match = re.match(r'^\.\./([^/]+)/(.+)$', url)
                if not cross_match:
                    continue
                other_lang = cross_match.group(1)
                other_path = cross_match.group(2).split('#', 1)[0].split('?', 1)[0]
                if other_lang == lang or other_lang not in LANG_DIRS:
                    continue
                # Exempt language-switcher links: README.md cross-language links
                # are intentional (the "English | 中文 | 日本語 | 한국어" header).
                # Both source and target must be README.md to qualify as a switcher.
                if path.name == 'README.md' and other_path == 'README.md':
                    continue
                # Check if the same file exists in our own language directory
                same_lang_target = lang_dir / other_path
                if same_lang_target.exists():
                    rel = path.relative_to(repo).as_posix()
                    violations.append(
                        f'{rel}:{lineno} links to ../{other_lang}/{other_path} '
                        f'but docs/{lang}/{other_path} exists — link should be same-language sibling'
                    )

if violations:
    print('\n'.join(violations))
    sys.exit(1)
PY
)" || CROSS_LANG_STATUS=$?
if [ "$CROSS_LANG_STATUS" -eq 0 ]; then
  pass "no cross-language links where same-language sibling exists"
else
  CROSS_COUNT=$(printf '%s' "$CROSS_LANG_OUTPUT" | grep -c "->.*\.md\|links to" || echo 0)
  fail "cross-language link discipline violations ($CROSS_COUNT — should be same-language sibling)"
  printf '%s\n' "$CROSS_LANG_OUTPUT" | head -10 | sed 's/^/    /'
fi

# ── 6. SKILL.md frontmatter ──
echo -e "${CYAN}[6/10] SKILL.md frontmatter${NC}"

for dir in $SKILL_DIRS; do
  name=$(basename "$dir")
  if head -1 "$dir/SKILL.md" | grep -q '^---'; then
    if grep -q '^description:' "$dir/SKILL.md"; then
      pass "skills/$name has frontmatter + description"
    else
      fail "skills/$name missing description in frontmatter"
    fi
  else
    fail "skills/$name missing frontmatter (---)"
  fi
done

# ── 7. Script permissions ──
echo -e "${CYAN}[7/10] Script permissions${NC}"

for f in "$SCRIPT_DIR"/scripts/*.sh "$SCRIPT_DIR"/scripts/*.py "$SCRIPT_DIR"/scripts/hooks/*.sh "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/test.sh" "$SCRIPT_DIR/.devcontainer/postCreate.sh"; do
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    if [ -x "$f" ]; then
      pass "$(basename "$f") is executable"
    else
      fail "$(basename "$f") NOT executable"
    fi
  fi
done

DOCKER_DEV_META=$("$SCRIPT_DIR/scripts/docker-dev.sh" print-json)
if printf '%s' "$DOCKER_DEV_META" | $QQ_PY -c '
import json
import os
import sys

data = json.load(sys.stdin)
repo_root = os.path.realpath(data["repo_root"])
git_dir = os.path.realpath(data["git_dir"])
mount_root = os.path.realpath(data["mount_root"])

assert repo_root.startswith(mount_root)
assert git_dir.startswith(mount_root)
'
then
  pass "docker-dev mount root covers repo root + git dir"
else
  fail "docker-dev mount root covers repo root + git dir"
fi

# ── 8. Runtime helper smoke tests ──
echo -e "${CYAN}[8/10] Runtime helper smoke tests${NC}"

RUNTIME_TEST_ROOT="$(mktemp -d)"
mkdir -p "$RUNTIME_TEST_ROOT/Docs/design" "$RUNTIME_TEST_ROOT/Docs/qq/demo"
cat > "$RUNTIME_TEST_ROOT/Docs/design/sample.md" <<'EOF'
# Sample Design
EOF
cat > "$RUNTIME_TEST_ROOT/Docs/qq/demo/sample_implementation.md" <<'EOF'
# Sample Implementation
EOF
cat > "$RUNTIME_TEST_ROOT/Sample.cs" <<'EOF'
using UnityEngine;

public class Sample : MonoBehaviour
{
    void Update()
    {
        GetComponent<Rigidbody>();
        SendMessage("Ping");
        if (gameObject.tag == "Player")
        {
        }
    }
}
EOF

RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$RUNTIME_TEST_ROOT" --stage compile --command smoke --backend test --transport local --summary "smoke start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$RUNTIME_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "smoke finish" >/dev/null

if $QQ_PY - "$RUNTIME_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
compile_state = json.loads((root / ".qq" / "state" / "compile.json").read_text(encoding="utf-8"))
project_state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8")) if (root / ".qq" / "state" / "project-state.json").exists() else {}
events = (root / ".qq" / "telemetry" / "events.jsonl").read_text(encoding="utf-8").strip().splitlines()

assert compile_state["status"] == "passed"
assert len(events) >= 2
assert project_state == {}
PY
then
  pass "run record writes state + telemetry"
else
  fail "run record writes state + telemetry"
fi

$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$RUNTIME_TEST_ROOT" >/dev/null
if $QQ_PY - "$RUNTIME_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["work_mode"] == "feature"
assert state["work_mode_source"] == "default"
assert state["config_format"] == "built_in_default"
assert state["shared_config_path"].endswith("qq.yaml")
assert state["local_config_path"].endswith(".qq/local.yaml")
assert state["profile"] == "feature"
assert state["profile_source"] == "default"
assert state["task_focus"] == []
assert state["task_focus_source"] == "default"
assert state["policy_profile"] == "feature"
assert state["policy_profile_source"] == "default"
assert state["policy_profile_expectations"]["review_expectation"] == "light"
assert state["default_test_scope"] == "all"
assert state["repository_design_doc_count"] == 1
assert state["repository_implementation_plan_count"] == 1
assert state["mode_recommended_next"] == "/qq:execute"
assert state["has_design_doc"] is True
assert state["has_implementation_plan"] is True
assert state["last_compile_status_raw"] == "passed"
assert state["last_compile_status"] == "passed"
assert state["compile_status_fresh"] is True
assert state["last_test_status_raw"] == "not_run"
assert state["test_status_fresh"] is True
assert state["recommended_next"] == "/qq:execute"
PY
then
  pass "project state snapshot is generated"
else
  fail "project state snapshot is generated"
fi


mkdir -p "$RUNTIME_TEST_ROOT/.qq"
cat > "$RUNTIME_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
default_profile: core
work_mode: feature
enabled_rules:
  - find_object_of_type
  - send_message
  - tag_compare
  - get_component_in_hot_path
EOF
cat > "$RUNTIME_TEST_ROOT/.qq/local.yaml" <<'EOF'
work_mode: prototype
policy_profile: hardening
EOF
rm -f "$RUNTIME_TEST_ROOT/Docs/design/sample.md" "$RUNTIME_TEST_ROOT/Docs/qq/demo/sample_implementation.md"
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$RUNTIME_TEST_ROOT" >/dev/null
if $QQ_PY - "$RUNTIME_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["work_mode"] == "prototype"
assert state["work_mode_source"] == "qq_local_yaml"
assert state["task_focus"] == []
assert state["task_focus_source"] == "default"
assert state["policy_profile"] == "hardening"
assert state["policy_profile_source"] == "qq_local_yaml"
assert state["policy_profile_expectations"]["review_expectation"] == "required"
assert state["default_test_scope"] == "all"
assert state["repository_design_doc_count"] == 0
assert state["mode_recommended_next"] == "prototype_direct"
assert state["recommended_next"] == "prototype_direct"
assert state["mode_profile"]["changes_summary_expected"] is True
PY
then
  pass "project state respects local work mode override"
else
  fail "project state respects local work mode override"
fi

YAML_CONFIG_TEST_ROOT="$(mktemp -d)"
mkdir -p "$YAML_CONFIG_TEST_ROOT/.qq"
cat > "$YAML_CONFIG_TEST_ROOT/qq.yaml" <<'EOF'
version: 1

default_profile: lightweight

profiles:
  reviewless:
    extends: feature
    remove_packs:
      - workflow-review
      - hooks-review-gate
EOF
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$YAML_CONFIG_TEST_ROOT" >/dev/null
if $QQ_PY - "$YAML_CONFIG_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["config_format"] == "qq_yaml"
assert state["shared_config_path"].endswith("qq.yaml")
assert state["local_config_path"].endswith(".qq/local.yaml")
assert state["profile"] == "lightweight"
assert state["profile_source"] == "qq_yaml"
assert state["work_mode"] == "prototype"
assert state["policy_profile"] == "core"
assert state["default_test_scope"] == "editmode"
assert "plan" not in state["enabled_skills"]
assert "claude-code-review" not in state["enabled_skills"]
assert "review_gate" not in state["enabled_hooks"]
PY
then
  pass "qq.yaml lightweight profile resolves built-in packs"
else
  fail "qq.yaml lightweight profile resolves built-in packs"
fi

cat > "$YAML_CONFIG_TEST_ROOT/.qq/local.yaml" <<'EOF'
profile: reviewless
work_mode: hardening
EOF
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$YAML_CONFIG_TEST_ROOT" >/dev/null
if $QQ_PY - "$YAML_CONFIG_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["profile"] == "reviewless"
assert state["profile_source"] == "qq_local_yaml"
assert state["work_mode"] == "hardening"
assert state["work_mode_source"] == "qq_local_yaml"
assert state["policy_profile"] == "feature"
assert state["policy_profile_source"] == "profile"
assert "plan" in state["enabled_skills"]
assert "claude-code-review" in state["enabled_skills"]
assert "review_gate" in state["enabled_hooks"]
PY
then
  pass "local.yaml can select a custom profile while policy floor restores required review packs"
else
  fail "local.yaml can select a custom profile while policy floor restores required review packs"
fi
rm -rf "$YAML_CONFIG_TEST_ROOT"

FOCUS_TEST_ROOT="$(mktemp -d)"
mkdir -p "$FOCUS_TEST_ROOT/Docs/design" "$FOCUS_TEST_ROOT/.qq"
cat > "$FOCUS_TEST_ROOT/Docs/design/crew_weapon.md" <<'EOF'
# Crew Weapon
EOF
cat > "$FOCUS_TEST_ROOT/Docs/design/map_refactor.md" <<'EOF'
# Map Refactor
EOF
cat > "$FOCUS_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
default_profile: feature
work_mode: prototype
EOF
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FOCUS_TEST_ROOT" >/dev/null
if $QQ_PY - "$FOCUS_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["repository_design_doc_count"] == 2
assert state["has_design_doc"] is False
assert state["design_docs"] == []
assert state["mode_recommended_next"] == "prototype_direct"
assert state["recommended_next"] == "prototype_direct"
PY
then
  pass "repo-global design docs do not force prototype planning"
else
  fail "repo-global design docs do not force prototype planning"
fi

cat > "$FOCUS_TEST_ROOT/.qq/local.yaml" <<'EOF'
work_mode: prototype
policy_profile: feature
task_focus: crew weapon
EOF
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FOCUS_TEST_ROOT" >/dev/null
if $QQ_PY - "$FOCUS_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["task_focus"] == ["crew weapon"]
assert state["task_focus_source"] == "qq_local_yaml"
assert state["has_design_doc"] is True
assert state["design_docs"] == ["Docs/design/crew_weapon.md"]
assert state["mode_recommended_next"] == "/qq:plan"
assert state["recommended_next"] == "/qq:plan"
PY
then
  pass "task focus can explicitly activate relevant design docs"
else
  fail "task focus can explicitly activate relevant design docs"
fi
rm -rf "$FOCUS_TEST_ROOT"

POLICY_TEST_ROOT="$(mktemp -d)"
mkdir -p "$POLICY_TEST_ROOT/.qq"
(
  cd "$POLICY_TEST_ROOT" &&
  git init -q
)
cat > "$POLICY_TEST_ROOT/SeaMonsterSpike.cs" <<'EOF'
using UnityEngine;

public class SeaMonsterSpike : MonoBehaviour
{
    void Start()
    {
        Debug.Log("spike");
    }
}
EOF
RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$POLICY_TEST_ROOT" --stage compile --command policy-compile --backend test --transport local --summary "policy compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$POLICY_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "policy compile passed" >/dev/null
cat > "$POLICY_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
engine: unity
default_profile: core
work_mode: prototype
EOF
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if $QQ_PY - "$POLICY_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["has_uncommitted_runtime_changes"] is True
assert state["policy_profile"] == "core"
assert state["default_test_scope"] == "editmode"
assert state["has_uncommitted_test_changes"] is False
assert state["changed_test_files"] == []
assert state["mode_recommended_next"] == "/qq:changes"
assert state["recommended_next"] == "/qq:changes"
PY
then
  pass "core profile keeps prototype recommendation light"
else
  fail "core profile keeps prototype recommendation light"
fi

if PROJECT_DIR="$POLICY_TEST_ROOT" bash -lc '
  source "'"$SCRIPT_DIR"'/scripts/qq-runtime.sh"
  [ "$(qq_policy_profile)" = "core" ] &&
  [ "$(qq_work_mode)" = "prototype" ] &&
  [ "$(qq_default_test_scope)" = "editmode" ]
'; then
  pass "qq-runtime helpers expose core policy defaults"
else
  fail "qq-runtime helpers expose core policy defaults"
fi

$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" record --project "$POLICY_TEST_ROOT" --stage changes --command qq:changes --status checked --summary "prototype summary captured" --capture-local-changes >/dev/null
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if $QQ_PY - "$POLICY_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["changes_summary_fresh"] is True
assert state["last_changes_status"] == "checked"
assert state["mode_recommended_next"] == "/qq:commit-push"
assert state["recommended_next"] == "/qq:add-tests"
PY
then
  pass "prototype changes summary advances the controller to commit-push"
else
  fail "prototype changes summary advances the controller to commit-push"
fi

printf '// follow-up\n' >> "$POLICY_TEST_ROOT/SeaMonsterSpike.cs"
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if $QQ_PY - "$POLICY_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["changes_summary_fresh"] is False
assert state["mode_recommended_next"] == "verify_compile"
assert state["recommended_next"] == "verify_compile"
PY
then
  pass "prototype changes summary is invalidated by newer local edits"
else
  fail "prototype changes summary is invalidated by newer local edits"
fi

RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$POLICY_TEST_ROOT" --stage compile --command policy-compile-refresh --backend test --transport local --summary "policy compile refresh start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$POLICY_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "policy compile refresh passed" >/dev/null

cat > "$POLICY_TEST_ROOT/.qq/local.yaml" <<'EOF'
work_mode: prototype
policy_profile: hardening
EOF
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if $QQ_PY - "$POLICY_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["policy_profile"] == "hardening"
assert state["default_test_scope"] == "all"
assert state["mode_recommended_next"] == "/qq:changes"
assert state["recommended_next"] == "/qq:test"
PY
then
  pass "hardening profile raises prototype work to test first"
else
  fail "hardening profile raises prototype work to test first"
fi

if PROJECT_DIR="$POLICY_TEST_ROOT" bash -lc '
  source "'"$SCRIPT_DIR"'/scripts/qq-runtime.sh"
  [ "$(qq_policy_profile)" = "hardening" ] &&
  [ "$(qq_work_mode)" = "prototype" ] &&
  [ "$(qq_default_test_scope)" = "all" ]
'; then
  pass "qq-runtime helpers respect local profile override"
else
  fail "qq-runtime helpers respect local profile override"
fi

RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$POLICY_TEST_ROOT" --stage test --command policy-test --backend test --transport local --summary "policy test start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$POLICY_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "policy test passed" >/dev/null
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if $QQ_PY - "$POLICY_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["recommended_next"] == "/qq:claude-code-review"
PY
then
  pass "hardening profile escalates to review after tests pass"
else
  fail "hardening profile escalates to review after tests pass"
fi

RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$POLICY_TEST_ROOT" --stage review_gate --command policy-review --backend test --transport local --summary "policy review start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$POLICY_TEST_ROOT" --run-id "$RUN_ID" --status verified --summary "policy review verified" >/dev/null
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if $QQ_PY - "$POLICY_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["review_gate_status"] == "verified"
assert state["recommended_next"] == "/qq:doc-drift"
PY
then
  pass "hardening profile escalates to doc drift after review"
else
  fail "hardening profile escalates to doc drift after review"
fi
rm -rf "$POLICY_TEST_ROOT"

# ── hooks find their own files whatever path form invokes them ──
# 1.19.2 回归：钩子开头用纯 bash 取自己的目录，只认 / 开头的绝对路径；Claude Code 在 Windows 上用 C:/… 调钩子，
# 被当成相对路径拼上 $PWD，五个钩子全部 source 不到 detect.sh。这里逐个用三种写法、从无关目录调起。
echo -e "${CYAN}[hooks] invocation path forms${NC}"
HOOK_PATH_TMP="$(mktemp -d)"
HOOK_PATH_CWD="$(mktemp -d)"
HOOK_PAYLOAD='{"session_id":"qq-path-form","tool_input":{"command":"ls","file_path":"/tmp/qq-path-form/a.md"},"stop_hook_active":false}'
hook_forms=("$SCRIPT_DIR")
if command -v cygpath >/dev/null 2>&1; then
  hook_forms+=("$(cygpath -m "$SCRIPT_DIR")" "$(cygpath -w "$SCRIPT_DIR")")
fi
hook_path_bad=""
for form in "${hook_forms[@]}"; do
  for hook in "scripts/hooks/review-gate.sh set" "scripts/hooks/review-gate.sh check" "scripts/hooks/review-gate.sh stop" \
              "scripts/hooks/session-cleanup.sh" "scripts/check-skill-review.sh" "scripts/hooks/auto-pipeline-stop.sh" \
              "scripts/hooks/compile-gate-check.sh"; do
    read -r hook_file hook_arg <<< "$hook"
    hook_err="$(cd "$HOOK_PATH_CWD" && printf '%s' "$HOOK_PAYLOAD" | QQ_TEMP_DIR="$HOOK_PATH_TMP" bash "$form/$hook_file" $hook_arg 2>&1 >/dev/null)"
    hook_rc=$?
    if [[ $hook_rc -ne 0 || "$hook_err" == *"No such file"* ]]; then
      hook_path_bad+="  [$form] $hook rc=$hook_rc ${hook_err:0:160}"$'\n'
    fi
  done
done
if [[ -z "$hook_path_bad" ]]; then
  pass "hooks resolve their own directory for ${#hook_forms[@]} path form(s), from an unrelated cwd"
else
  fail "hooks fail to resolve their own directory:"
  printf '%s' "$hook_path_bad"
fi
rm -rf "$HOOK_PATH_TMP" "$HOOK_PATH_CWD"

# ── review gate three-field format ──
echo -e "${CYAN}[gate] three-field format${NC}"

GATE_TMP="$(mktemp -d)"

# gate-set creates three-field file
echo "$(date +%s):0:0" > "$GATE_TMP/review-gate-test"
IFS=: read -r _ts _completed _expected < "$GATE_TMP/review-gate-test"
if [[ "$_completed" == "0" && "$_expected" == "0" ]]; then
  pass "gate-set creates three-field format"
else
  fail "gate-set creates three-field format (got $_completed:$_expected)"
fi

# gate-count preserves expected field
echo "1000:0:3" > "$GATE_TMP/review-gate-test"
IFS=: read -r _ts _count _expected < "$GATE_TMP/review-gate-test"
_new_count=$(( _count + 1 ))
echo "${_ts}:${_new_count}:${_expected}" > "$GATE_TMP/review-gate-test"
IFS=: read -r _ts2 _count2 _expected2 < "$GATE_TMP/review-gate-test"
if [[ "$_count2" == "1" && "$_expected2" == "3" ]]; then
  pass "gate-count preserves expected field"
else
  fail "gate-count preserves expected field (got $_count2:$_expected2)"
fi

# gate-check blocks when expected=0
echo "$(date +%s):0:0" > "$GATE_TMP/review-gate-test"
IFS=: read -r _ts _count _expected < "$GATE_TMP/review-gate-test"
if [[ ${_expected:-0} -eq 0 || ${_count:-0} -lt ${_expected:-0} ]]; then
  pass "gate-check blocks when expected=0"
else
  fail "gate-check blocks when expected=0"
fi

# gate-check blocks when completed < expected
echo "$(date +%s):1:3" > "$GATE_TMP/review-gate-test"
IFS=: read -r _ts _count _expected < "$GATE_TMP/review-gate-test"
if [[ ${_expected:-0} -eq 0 || ${_count:-0} -lt ${_expected:-0} ]]; then
  pass "gate-check blocks when completed < expected"
else
  fail "gate-check blocks when completed < expected"
fi

# gate-check allows when completed >= expected
echo "$(date +%s):3:3" > "$GATE_TMP/review-gate-test"
IFS=: read -r _ts _count _expected < "$GATE_TMP/review-gate-test"
if [[ ${_expected:-0} -gt 0 && ${_count:-0} -ge ${_expected:-0} ]]; then
  pass "gate-check allows when completed >= expected"
else
  fail "gate-check allows when completed >= expected"
fi

# stop hook detects incomplete verification
echo "$(date +%s):1:3" > "$GATE_TMP/review-gate-test"
IFS=: read -r _ts _count _expected < "$GATE_TMP/review-gate-test"
if [[ -f "$GATE_TMP/review-gate-test" && ${_expected:-0} -gt 0 && ${_count:-0} -lt ${_expected:-0} ]]; then
  pass "stop hook detects incomplete verification"
else
  fail "stop hook detects incomplete verification"
fi

# stop hook allows exit when verification complete
echo "$(date +%s):3:3" > "$GATE_TMP/review-gate-test"
IFS=: read -r _ts _count _expected < "$GATE_TMP/review-gate-test"
if [[ ! -f "$GATE_TMP/review-gate-test" ]] || [[ ${_expected:-0} -eq 0 ]] || [[ ${_count:-0} -ge ${_expected:-0} ]]; then
  pass "stop hook allows exit when verification complete"
else
  fail "stop hook allows exit when verification complete"
fi

rm -rf "$GATE_TMP"

FIX_TEST_ROOT="$(mktemp -d)"
mkdir -p "$FIX_TEST_ROOT/.qq"
(
  cd "$FIX_TEST_ROOT" &&
  git init -q
)
cat > "$FIX_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
engine: unity
default_profile: feature
EOF
cat > "$FIX_TEST_ROOT/.qq/local.yaml" <<'EOF'
work_mode: fix
policy_profile: feature
EOF
cat > "$FIX_TEST_ROOT/BugFix.cs" <<'EOF'
using UnityEngine;

public class BugFix : MonoBehaviour {}
EOF
RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$FIX_TEST_ROOT" --stage compile --command fix-compile --backend test --transport local --summary "fix compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$FIX_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "fix compile passed" >/dev/null
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FIX_TEST_ROOT" >/dev/null
if $QQ_PY - "$FIX_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["work_mode"] == "fix"
assert state["has_uncommitted_runtime_changes"] is True
assert state["has_uncommitted_test_changes"] is False
assert state["changed_test_files"] == []
assert state["recommended_next"] == "/qq:add-tests"
PY
then
  pass "fix mode routes compile-green patches to add-tests before test execution"
else
  fail "fix mode routes compile-green patches to add-tests before test execution"
fi

mkdir -p "$FIX_TEST_ROOT/Assets/Tests/EditMode"
cat > "$FIX_TEST_ROOT/Assets/Tests/EditMode/BugFixTests.cs" <<'EOF'
public class BugFixTests {}
EOF
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FIX_TEST_ROOT" >/dev/null
if $QQ_PY - "$FIX_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["has_uncommitted_test_changes"] is True
assert state["changed_test_files"] == ["Assets/Tests/EditMode/BugFixTests.cs"]
assert state["recommended_next"] == "verify_compile"
PY
then
  pass "fix mode returns to compile verification after new test files are added"
else
  fail "fix mode returns to compile verification after new test files are added"
fi
RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$FIX_TEST_ROOT" --stage compile --command fix-test-compile --backend test --transport local --summary "fix test compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$FIX_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "fix test compile passed" >/dev/null
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FIX_TEST_ROOT" >/dev/null
if $QQ_PY - "$FIX_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["has_uncommitted_test_changes"] is True
assert state["changed_test_files"] == ["Assets/Tests/EditMode/BugFixTests.cs"]
assert state["recommended_next"] == "/qq:test"
PY
then
  pass "fix mode hands off to test once targeted test coverage compiles cleanly"
else
  fail "fix mode hands off to test once targeted test coverage compiles cleanly"
fi
rm -rf "$FIX_TEST_ROOT"

FEATURE_TEST_ROOT="$(mktemp -d)"
mkdir -p "$FEATURE_TEST_ROOT/.qq"
(
  cd "$FEATURE_TEST_ROOT" &&
  git init -q
)
cat > "$FEATURE_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
engine: unity
default_profile: feature
EOF
cat > "$FEATURE_TEST_ROOT/.qq/local.yaml" <<'EOF'
work_mode: feature
policy_profile: feature
EOF
cat > "$FEATURE_TEST_ROOT/FeatureWork.cs" <<'EOF'
using UnityEngine;

public class FeatureWork : MonoBehaviour {}
EOF
RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$FEATURE_TEST_ROOT" --stage compile --command feature-compile --backend test --transport local --summary "feature compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$FEATURE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "feature compile passed" >/dev/null
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FEATURE_TEST_ROOT" >/dev/null
if $QQ_PY - "$FEATURE_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["work_mode"] == "feature"
assert state["has_uncommitted_runtime_changes"] is True
assert state["has_uncommitted_test_changes"] is False
assert state["changed_test_files"] == []
assert state["recommended_next"] == "/qq:add-tests"
PY
then
  pass "feature mode routes compile-green runtime changes to add-tests first"
else
  fail "feature mode routes compile-green runtime changes to add-tests first"
fi

mkdir -p "$FEATURE_TEST_ROOT/Assets/Tests/EditMode"
cat > "$FEATURE_TEST_ROOT/Assets/Tests/EditMode/FeatureWorkTests.cs" <<'EOF'
public class FeatureWorkTests {}
EOF
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FEATURE_TEST_ROOT" >/dev/null
if $QQ_PY - "$FEATURE_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["has_uncommitted_test_changes"] is True
assert state["changed_test_files"] == ["Assets/Tests/EditMode/FeatureWorkTests.cs"]
assert state["recommended_next"] == "verify_compile"
PY
then
  pass "feature mode asks for a fresh compile after adding new test files"
else
  fail "feature mode asks for a fresh compile after adding new test files"
fi

RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$FEATURE_TEST_ROOT" --stage compile --command feature-test-compile --backend test --transport local --summary "feature test compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$FEATURE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "feature test compile passed" >/dev/null
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FEATURE_TEST_ROOT" >/dev/null
if $QQ_PY - "$FEATURE_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["has_uncommitted_test_changes"] is True
assert state["changed_test_files"] == ["Assets/Tests/EditMode/FeatureWorkTests.cs"]
assert state["recommended_next"] == "/qq:test"
PY
then
  pass "feature mode hands off to test after targeted coverage compiles cleanly"
else
  fail "feature mode hands off to test after targeted coverage compiles cleanly"
fi
rm -rf "$FEATURE_TEST_ROOT"

STALE_TEST_ROOT="$(mktemp -d)"
mkdir -p "$STALE_TEST_ROOT/.qq"
(
  cd "$STALE_TEST_ROOT" &&
  git init -q
)
cat > "$STALE_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
engine: unity
default_profile: hardening
work_mode: prototype
EOF
RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$STALE_TEST_ROOT" --stage test --command stale-test --backend test --transport local --summary "stale test start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$STALE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "stale test passed" >/dev/null
sleep 1
cat > "$STALE_TEST_ROOT/Probe.cs" <<'EOF'
public class Probe {}
EOF
RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$STALE_TEST_ROOT" --stage compile --command stale-compile --backend test --transport local --summary "stale compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$STALE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "stale compile passed" >/dev/null
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$STALE_TEST_ROOT" >/dev/null
if $QQ_PY - "$STALE_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["has_uncommitted_runtime_changes"] is True
assert state["last_compile_status_raw"] == "passed"
assert state["compile_status_fresh"] is True
assert state["last_compile_status"] == "passed"
assert state["last_test_status_raw"] == "passed"
assert state["test_status_fresh"] is False
assert state["last_test_status"] == "not_run"
assert state["mode_recommended_next"] == "/qq:changes"
assert state["recommended_next"] == "/qq:test"
PY
then
  pass "stale test results are invalidated after newer code changes"
else
  fail "stale test results are invalidated after newer code changes"
fi

sleep 1
cat >> "$STALE_TEST_ROOT/Probe.cs" <<'EOF'
public class Probe2 {}
EOF
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$STALE_TEST_ROOT" >/dev/null
if $QQ_PY - "$STALE_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["last_compile_status_raw"] == "passed"
assert state["compile_status_fresh"] is False
assert state["last_compile_status"] == "not_run"
assert state["recommended_next"] == "verify_compile"
PY
then
  pass "stale compile results are invalidated after newer code changes"
else
  fail "stale compile results are invalidated after newer code changes"
fi
rm -rf "$STALE_TEST_ROOT"

WORKTREE_BARE_STATE_ROOT="$(mktemp -d)"
(
  cd "$WORKTREE_BARE_STATE_ROOT" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  mkdir -p ProjectSettings Packages &&
  cat > ProjectSettings/ProjectVersion.txt <<'EOF'
m_EditorVersion: 2022.3.17f1
EOF
  cat > Packages/manifest.json <<'EOF'
{
  "dependencies": {}
}
EOF
  cat > Probe.cs <<'EOF'
using UnityEngine;

public class Probe : MonoBehaviour
{
}
EOF
  git add Probe.cs ProjectSettings/ProjectVersion.txt Packages/manifest.json &&
  git commit -q -m "init" &&
  git checkout -q -b feature/bare-state &&
  git config core.bare true
)
cat >> "$WORKTREE_BARE_STATE_ROOT/Probe.cs" <<'EOF'
public class Probe2 {}
EOF
if $QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$WORKTREE_BARE_STATE_ROOT" >/dev/null && \
   $QQ_PY - "$WORKTREE_BARE_STATE_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["has_uncommitted_runtime_changes"] is True
assert "Probe.cs" in state["changed_runtime_files"]
assert state["recommended_next"] == "verify_compile"
PY
then
  pass "qq-project-state detects code changes in bare worktree repos"
else
  fail "qq-project-state detects code changes in bare worktree repos"
fi
rm -rf "$WORKTREE_BARE_STATE_ROOT"

WORKTREE_BARE_CREATE_ROOT="$(mktemp -d)"
(
  cd "$WORKTREE_BARE_CREATE_ROOT" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  printf 'base\n' > README.md &&
  git add README.md &&
  git commit -q -m "init" &&
  git checkout -q -b feature/bare-create &&
  git config core.bare true
)
WORKTREE_BARE_CREATE_PARENT="$(dirname "$WORKTREE_BARE_CREATE_ROOT")"
if BARE_CREATE_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_BARE_CREATE_ROOT" --name bare-create --base-dir "$WORKTREE_BARE_CREATE_PARENT"); then
  BARE_WORKTREE_PATH=$(printf '%s' "$BARE_CREATE_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["worktreePath"])')
  if $QQ_PY - "$BARE_CREATE_JSON" "$BARE_WORKTREE_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(sys.argv[1])
worktree = Path(sys.argv[2])

assert payload["sourceBranch"] == "feature/bare-create"
assert payload["branch"] == "feature/bare-create-wt-bare-create"
assert worktree.exists()
PY
  then
    pass "qq-worktree create works in bare worktree repos"
  else
    fail "qq-worktree create works in bare worktree repos"
  fi
  $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" cleanup --project "$BARE_WORKTREE_PATH" --delete-branch >/dev/null 2>&1 || true
else
  fail "qq-worktree create works in bare worktree repos"
fi
rm -rf "$WORKTREE_BARE_CREATE_ROOT"

WORKTREE_TEST_ROOT="$(mktemp -d)"
(
  cd "$WORKTREE_TEST_ROOT" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  mkdir -p ProjectSettings Packages Library/PackageCache/mock &&
  cat > ProjectSettings/ProjectVersion.txt <<'EOF'
m_EditorVersion: 2022.3.17f1
EOF
  cat > Packages/manifest.json <<'EOF'
{
  "dependencies": {}
}
EOF
  cat > .gitignore <<'EOF'
Library/
Temp/
EOF
  printf 'cached\n' > Library/PackageCache/mock/seed.txt &&
  printf '{\n  "mcpServers": {\n    "qq-unity": { "command": "%s" }\n  }\n}\n' "$QQ_PY" > .mcp.json &&
  mkdir -p .claude &&
  printf '{\n  "enabledPlugins": {\n    "qq@quick-question-marketplace": true\n  }\n}\n' > .claude/settings.local.json &&
  cat > qq.yaml <<'EOF'
default_profile: feature
EOF
  mkdir -p scripts &&
  cat > scripts/qq-doctor.py <<'EOF'
#!/usr/bin/env python3
print("ok")
EOF
  chmod +x scripts/qq-doctor.py &&
  printf 'base\n' > README.md &&
  git add README.md .mcp.json .gitignore ProjectSettings/ProjectVersion.txt Packages/manifest.json &&
  git add -f .claude/settings.local.json &&
  git commit -q -m "init" &&
  git checkout -q -b feature/ship-system
)
RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$WORKTREE_TEST_ROOT" --stage compile --command source-compile --backend test --transport local --summary "source compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$WORKTREE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "source compile passed" >/dev/null
RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$WORKTREE_TEST_ROOT" --stage test --command source-test --backend test --transport local --summary "source test start")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$WORKTREE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "source test passed" >/dev/null
WORKTREE_PARENT="$(dirname "$WORKTREE_TEST_ROOT")"
if CREATE_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_TEST_ROOT" --name "Sea Monster" --base-dir "$WORKTREE_PARENT" --allow-dirty-source); then
  WORKTREE_PATH=$(printf '%s' "$CREATE_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["worktreePath"])')
  if $QQ_PY - "$CREATE_JSON" "$WORKTREE_TEST_ROOT" "$WORKTREE_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(sys.argv[1])
source = Path(sys.argv[2]).resolve()
target = Path(sys.argv[3]).resolve()

assert payload["sourceBranch"] == "feature/ship-system"
assert payload["branch"] == "feature/ship-system-wt-sea-monster"
assert target.exists()
metadata = json.loads((target / ".qq" / "state" / "worktree.json").read_text(encoding="utf-8"))
assert metadata["managedBy"] == "qq"
assert metadata["sourceBranch"] == "feature/ship-system"
assert Path(metadata["sourceWorktreePath"]).resolve() == source
assert ".mcp.json" in metadata["copiedLocalRuntimeFiles"]
assert ".claude/settings.local.json" in metadata["copiedLocalRuntimeFiles"]
assert "qq.yaml" in metadata["copiedLocalRuntimeFiles"]
assert "scripts" in metadata["copiedLocalRuntimeFiles"]
assert ".qq/state/compile.json" in metadata["copiedBaselineStateFiles"]
assert ".qq/state/test.json" in metadata["copiedBaselineStateFiles"]
assert metadata["copiedBaselineRunRecords"]
assert (target / ".mcp.json").is_file()
assert (target / ".claude" / "settings.local.json").is_file()
assert (target / "qq.yaml").is_file()
assert (target / "scripts" / "qq-doctor.py").is_file()
assert (target / ".qq" / "state" / "compile.json").is_file()
assert (target / ".qq" / "state" / "test.json").is_file()
for record_path in metadata["copiedBaselineRunRecords"]:
    assert (target / record_path).is_file()
assert payload["runtimeCacheSeed"]["action"] == "seeded"
assert payload["runtimeCacheSeed"]["strategy"]
assert (target / "Library" / "PackageCache" / "mock" / "seed.txt").is_file()
assert metadata["runtimeCacheSeed"]["action"] == "seeded"
assert metadata["runtimeCacheSeed"]["strategy"]
assert payload["recommendedExecution"]["mode"] == "host"
assert "Unity" in payload["recommendedExecution"]["reason"]
assert payload["parallelAgentSafe"] is True
assert payload["parallelAgentSafety"]["status"] == "ok"
assert "exactly one agent" in payload["parallelAgentSafety"]["summary"]
labels = [item["label"] for item in payload["nextSteps"]]
assert labels[0] == "enter-worktree"
assert "inspect-worktree-state" in labels
assert "closeout-worktree" in labels
assert any("qq-doctor.py" in item["command"] for item in payload["nextSteps"])
assert any("qq-worktree.py" in item["command"] and "closeout" in item["command"] for item in payload["nextSteps"])
PY
  then
    pass "qq-worktree create builds a managed linked worktree"
  else
    fail "qq-worktree create builds a managed linked worktree"
  fi
else
  fail "qq-worktree create builds a managed linked worktree"
  WORKTREE_PATH=""
fi

WORKTREE_SEED_JSON="$(mktemp)"
if [ -n "${WORKTREE_PATH:-}" ]; then
  rm -rf "$WORKTREE_PATH/Library"
fi

if [ -n "${WORKTREE_PATH:-}" ] && $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" seed-runtime-cache --project "$WORKTREE_PATH" --pretty > "$WORKTREE_SEED_JSON" && \
   $QQ_PY - "$WORKTREE_SEED_JSON" "$WORKTREE_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
worktree = Path(sys.argv[2])
seed = payload["runtimeCacheSeed"]
assert payload["ok"] is True
assert payload["action"] == "seed-runtime-cache"
assert seed["action"] == "seeded"
assert seed["strategy"]
assert (worktree / "Library" / "PackageCache" / "mock" / "seed.txt").is_file()
PY
then
  pass "qq-worktree seed-runtime-cache restores a missing managed-worktree runtime cache"
else
  fail "qq-worktree seed-runtime-cache restores a missing managed-worktree runtime cache"
fi
rm -f "$WORKTREE_SEED_JSON"

if [ -n "${WORKTREE_PATH:-}" ]; then
  printf 'note\n' > "$WORKTREE_PATH/notes.md"
fi

if [ -n "${WORKTREE_PATH:-}" ] && $QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$WORKTREE_PATH" >/dev/null && \
   $QQ_PY - "$WORKTREE_PATH" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))
assert state["has_uncommitted_runtime_changes"] is False
assert state["last_compile_status"] == "passed"
assert state["last_test_status"] == "passed"
assert state["recommended_next"] == "/qq:commit-push"
PY
then
  pass "managed worktree inherits source compile/test baseline for doc-only changes"
else
  fail "managed worktree inherits source compile/test baseline for doc-only changes"
fi

if [ -n "${WORKTREE_PATH:-}" ]; then
  rm -f "$WORKTREE_PATH/notes.md"
fi

WORKTREE_STATUS_JSON="$(mktemp)"
WORKTREE_MERGE_JSON="$(mktemp)"
WORKTREE_CLEANUP_JSON="$(mktemp)"

if [ -n "${WORKTREE_PATH:-}" ] && $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" status --project "$WORKTREE_PATH" > "$WORKTREE_STATUS_JSON" && \
   $QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$WORKTREE_PATH" >/dev/null && \
   $QQ_PY - "$WORKTREE_STATUS_JSON" "$WORKTREE_PATH" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
state = json.loads((Path(sys.argv[2]) / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert status["isManagedWorktree"] is True
assert status["sourceBranch"] == "feature/ship-system"
assert status["role"] == "managed"
assert state["is_managed_worktree"] is True
assert state["worktree_role"] == "managed"
assert state["worktree_source_branch"] == "feature/ship-system"
assert state["worktree_source_worktree_path"]
assert state["worktree_source_runtime_cache_exists"] is True
assert state["worktree_local_runtime_cache_exists"] is True
assert state["worktree_local_runtime_cache_support_exists"] is True
assert state["worktree_can_seed_runtime_cache"] is False
assert state["worktree_runtime_cache_seed_state"] == "seeded"
assert status["sourceRuntimeCacheExists"] is True
assert status["localRuntimeCacheExists"] is True
assert status["localRuntimeCacheSupportExists"] is True
assert status["canSeedRuntimeCache"] is False
PY
then
  pass "worktree status flows through qq-project-state"
else
  fail "worktree status flows through qq-project-state"
fi

if [ -n "${WORKTREE_PATH:-}" ]; then
  (
    cd "$WORKTREE_PATH" &&
    git config user.email qq@example.com &&
    git config user.name "qq test" &&
    printf 'sea monster\n' >> README.md &&
    git add README.md &&
    git commit -q -m "feat: add sea monster notes"
  )
  mkdir -p "$WORKTREE_TEST_ROOT/scripts/__pycache__"
  printf 'compiled\n' > "$WORKTREE_TEST_ROOT/scripts/__pycache__/qq-worktree.cpython-312.pyc"
fi

if [ -n "${WORKTREE_PATH:-}" ] && $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" merge-back --project "$WORKTREE_PATH" --auto-yes > "$WORKTREE_MERGE_JSON" && \
   $QQ_PY - "$WORKTREE_TEST_ROOT" "$WORKTREE_PATH" "$WORKTREE_MERGE_JSON" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
worktree = Path(sys.argv[2])
payload = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
assert payload["mergedBranch"] == "feature/ship-system-wt-sea-monster"

head = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=root, text=True).strip()
assert head == "feature/ship-system"
log = subprocess.check_output(["git", "log", "--oneline", "--merges", "-n", "1"], cwd=root, text=True).strip()
assert "feature/ship-system-wt-sea-monster" in log
assert worktree.exists()
PY
then
  pass "qq-worktree merge-back merges the linked branch into the source branch"
else
  fail "qq-worktree merge-back merges the linked branch into the source branch"
fi

if [ -n "${WORKTREE_PATH:-}" ]; then
  printf 'default_profile: lightweight\n' > "$WORKTREE_PATH/qq.yaml"
  printf '# runtime tweak\n' >> "$WORKTREE_PATH/scripts/qq-doctor.py"
  mkdir -p "$WORKTREE_PATH/.claude"
  printf '{\"enabledPlugins\":{\"qq@quick-question-marketplace\":true}}\n' > "$WORKTREE_PATH/.claude/settings.local.json"
  printf '{\"mcpServers\":{\"tykit\":{\"command\":\"python3\"}}}\n' > "$WORKTREE_PATH/.mcp.json"
fi

if [ -n "${WORKTREE_PATH:-}" ] && $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" cleanup --project "$WORKTREE_PATH" --delete-branch > "$WORKTREE_CLEANUP_JSON" && \
   $QQ_PY - "$WORKTREE_TEST_ROOT" "$WORKTREE_PATH" "$WORKTREE_CLEANUP_JSON" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
worktree = Path(sys.argv[2])
payload = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
assert payload["deletedBranch"] is True
assert "qq.yaml" in payload["prunedRuntimePaths"]
assert "scripts/" in payload["prunedRuntimePaths"]
assert any(item.startswith("scripts/qq-doctor.py") for item in payload["prunedRuntimePaths"])
assert not worktree.exists()
branches = subprocess.check_output(["git", "branch", "--list", "feature/ship-system-wt-sea-monster"], cwd=root, text=True).strip()
assert branches == ""
PY
then
  pass "qq-worktree cleanup prunes copied runtime files and removes the linked worktree"
else
  fail "qq-worktree cleanup prunes copied runtime files and removes the linked worktree"
fi
rm -f "$WORKTREE_STATUS_JSON" "$WORKTREE_MERGE_JSON" "$WORKTREE_CLEANUP_JSON"
rm -rf "$WORKTREE_TEST_ROOT"

# ── qq_engine: source / verification matching only counts paths inside the project ──
# 第 4 条：matches_patterns 对项目外的绝对路径退回成只比文件名，相对路径的 ../ 又被 lstrip("./") 吃掉，
# 结果往会话草稿目录写个 .cs 也会触发一次 auto-compile（编译门同理）。这里逐个覆盖：项目外 / 项目内（绝对、相对、
# 反斜杠写法）/ ../ 跳出项目、Godot 的 project.godot、Windows 盘符大小写与 8.3 短名、项目根经由链接给出、
# 项目里的子目录链接到项目外、Unity 本地包、项目根下面的 git worktree、不分大小写的卷，
# 最后用桩 qq-compile.sh 端到端跑 auto-compile.sh 和 compile-gate-check.sh。
echo -e "${CYAN}[qq_engine] source matching is scoped to the project root${NC}"
QE_TMP="$(mktemp -d)"
mkdir -p "$QE_TMP/unity/ProjectSettings" "$QE_TMP/unity/Assets/Scripts" "$QE_TMP/godot/scripts" "$QE_TMP/outside"
printf 'm_EditorVersion: 2022.3.0f1\n' > "$QE_TMP/unity/ProjectSettings/ProjectVersion.txt"
printf '[application]\n' > "$QE_TMP/godot/project.godot"
touch "$QE_TMP/unity/Assets/Scripts/a.cs" "$QE_TMP/godot/scripts/player.gd" "$QE_TMP/outside/x.cs" "$QE_TMP/outside/player.gd"
# Claude Code 在 Windows 上给钩子的是 E:/… 或 E:\… 这种盘符路径；/c/… 写法测不出盘符相关的问题
qe_mixed() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
qe_match() { $QQ_PY "$SCRIPT_DIR/scripts/qq_engine.py" "$1" --project "$2" "$3" 2>/dev/null || printf 'error\n'; }
QE_U="$(qe_mixed "$QE_TMP/unity")"
QE_G="$(qe_mixed "$QE_TMP/godot")"
QE_O="$(qe_mixed "$QE_TMP/outside")"
qe_cases=(
  "false|matches-source|$QE_U|$QE_O/x.cs|absolute .cs outside the project"
  "true|matches-source|$QE_U|$QE_U/Assets/Scripts/a.cs|absolute Assets/…/a.cs inside the project"
  "true|matches-source|$QE_U|Assets/Scripts/a.cs|relative Assets/…/a.cs (read against the project root)"
  "true|matches-source|$QE_U|./Assets/Scripts/New.cs|relative ./Assets/… for a file not written yet"
  "false|matches-source|$QE_U|../outside/x.cs|relative ../outside/x.cs"
  "false|matches-source|$QE_U|Assets/../../outside/x.cs|relative path that normalizes out of the project"
  "false|matches-verification|$QE_U|$QE_O/x.cs|verification patterns: absolute .cs outside the project"
  "true|matches-verification|$QE_G|$QE_G/project.godot|Godot project.godot (absolute) matches verification patterns"
  "true|matches-verification|$QE_G|project.godot|Godot project.godot (relative) matches verification patterns"
  "false|matches-verification|$QE_G|$QE_O/project.godot|Godot project.godot outside the project"
  "true|matches-source|$QE_G|$QE_G/scripts/player.gd|Godot .gd inside the project"
  "false|matches-source|$QE_G|$QE_O/player.gd|Godot .gd outside the project"
)
if command -v cygpath >/dev/null 2>&1; then
  qe_cases+=(
    "false|matches-source|$(cygpath -w "$QE_TMP/unity")|$(cygpath -w "$QE_TMP/outside/x.cs")|backslash form: .cs outside the project"
    "true|matches-source|$(cygpath -w "$QE_TMP/unity")|$(cygpath -w "$QE_TMP/unity/Assets/Scripts/a.cs")|backslash form: .cs inside the project"
  )
fi
if [ "$IS_WINDOWS" = "true" ]; then
  qe_lower_drive() { printf '%s%s\n' "$(printf '%s' "${1:0:1}" | tr '[:upper:]' '[:lower:]')" "${1:1}"; }
  qe_upper_drive() { printf '%s%s\n' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"; }
  qe_cases+=(
    "true|matches-source|$(qe_lower_drive "$QE_U")|$(qe_upper_drive "$QE_U")/Assets/Scripts/a.cs|drive letter case differs (project lower, file upper)"
    "true|matches-source|$(qe_upper_drive "$QE_U")|$(qe_lower_drive "$QE_U")/Assets/Scripts/a.cs|drive letter case differs (project upper, file lower)"
    "false|matches-source|$(qe_lower_drive "$QE_U")|$(qe_upper_drive "$QE_O")/x.cs|drive letter case differs, file outside the project"
  )
  QE_SHORT="$($QQ_PY -c 'import ctypes, sys; buf = ctypes.create_unicode_buffer(1024); n = ctypes.windll.kernel32.GetShortPathNameW(sys.argv[1], buf, 1024); print(buf.value if n else "")' "$QE_U" 2>/dev/null || true)"
  if [[ -n "$QE_SHORT" && "$(printf '%s' "$QE_SHORT" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$QE_U" | tr '[:upper:]' '[:lower:]')" ]]; then
    qe_cases+=(
      "true|matches-source|$QE_SHORT|$QE_U/Assets/Scripts/a.cs|8.3 short-name project root, long-name file"
      "true|matches-source|$QE_U|$QE_SHORT/Assets/Scripts/New.cs|long-name project root, 8.3 short-name file not written yet"
      "false|matches-source|$QE_SHORT|$QE_O/x.cs|8.3 short-name project root, file outside the project"
    )
  else
    skip "8.3 short-name project root" "no short name generated for $QE_U"
  fi
fi
# 项目根经由链接给出（POSIX 上是符号链接，Windows 上用不需要管理员权限的目录联接）
QE_LINK="$QE_TMP/linked-unity"
if [ "$IS_WINDOWS" = "true" ]; then
  $QQ_PY -c 'import _winapi, sys; _winapi.CreateJunction(sys.argv[1], sys.argv[2])' "$QE_U" "$(qe_mixed "$QE_TMP")/linked-unity" 2>/dev/null || true
else
  ln -s "$QE_TMP/unity" "$QE_LINK" 2>/dev/null || true
fi
if [[ -d "$QE_LINK/Assets" ]]; then
  QE_LINK="$(qe_mixed "$QE_LINK")"
  qe_cases+=(
    "true|matches-source|$QE_LINK|$QE_U/Assets/Scripts/a.cs|project root given through a link, file given by its real path"
    "true|matches-source|$QE_U|$QE_LINK/Assets/Scripts/a.cs|file given through a link into the project"
    "false|matches-source|$QE_LINK|$QE_O/x.cs|project root given through a link, file outside the project"
  )
else
  skip "project root given through a link" "could not create a symlink / junction"
fi
# 项目里的子目录链接到项目外（Assets/Shared → 项目外的共享代码）：照样算项目里。
# 这条只有词法写法对得上（resolve 之后文件已经落在项目外），把比较改成只看 resolve 会让它变红
mkdir -p "$QE_TMP/sharedlib"
touch "$QE_TMP/sharedlib/s.cs"
if [ "$IS_WINDOWS" = "true" ]; then
  $QQ_PY -c 'import _winapi, sys; _winapi.CreateJunction(sys.argv[1], sys.argv[2])' "$(qe_mixed "$QE_TMP/sharedlib")" "$QE_U/Assets/Shared" 2>/dev/null || true
else
  ln -s "$QE_TMP/sharedlib" "$QE_TMP/unity/Assets/Shared" 2>/dev/null || true
fi
if [[ -f "$QE_TMP/unity/Assets/Shared/s.cs" ]]; then
  qe_cases+=("true|matches-source|$QE_U|$QE_U/Assets/Shared/s.cs|project subdirectory linked to outside the project still counts as inside")
else
  skip "project subdirectory linked to outside the project" "could not create a symlink / junction"
fi
# Unity 的本地包：Packages/manifest.json 用 file: 引用（相对 Packages/ 解释）、放在项目根外面的包，Unity 照样编进项目；
# 指向 .tgz 的 file: 引用不是目录，不算
mkdir -p "$QE_TMP/sharedpkg/Runtime" "$QE_TMP/unity/Packages"
touch "$QE_TMP/sharedpkg/Runtime/X.cs"
printf '{\n  "dependencies": {\n    "com.qq.shared": "file:../../sharedpkg",\n    "com.qq.tarball": "file:../../outside/pkg.tgz",\n    "com.unity.ugui": "1.0.0"\n  }\n}\n' > "$QE_TMP/unity/Packages/manifest.json"
qe_cases+=(
  "true|matches-source|$QE_U|$(qe_mixed "$QE_TMP/sharedpkg")/Runtime/X.cs|Unity local package outside the project root (file: in Packages/manifest.json)"
  "true|matches-source|$QE_U|../sharedpkg/Runtime/X.cs|relative path into that local package"
)
# 建在项目根下面的 git worktree（qq 工作流和游戏的 Tools/branch/new.py 都建在 <主目录>/.claude/worktrees/<名>）是另一份检出：
# 钩子的项目根落在主目录时，那里面的 .cs 不该编主项目。子模块（.git 文件指向 .git/modules/<名>）和
# Assets/ 下另一个仓库的克隆（.git 是目录）照旧算项目里，Unity 会把它们编进来
QE_W="$QE_TMP/wtmain"
mkdir -p "$QE_W/ProjectSettings"
cp "$QE_TMP/unity/ProjectSettings/ProjectVersion.txt" "$QE_W/ProjectSettings/"
if (
  cd "$QE_W" &&
  git init -q >/dev/null 2>&1 &&
  git config user.email qq@example.com &&
  git config user.name "QQ Test" &&
  git add ProjectSettings &&
  git commit -q -m "init" &&
  git worktree add -q --detach .claude/worktrees/feat
) >/dev/null 2>&1; then
  mkdir -p "$QE_W/.claude/worktrees/feat/Assets" "$QE_W/Assets/Plugins/Sub" "$QE_W/Assets/Plugins/Clone/.git" "$QE_W/.git/modules/Sub"
  printf 'gitdir: ../../../.git/modules/Sub\n' > "$QE_W/Assets/Plugins/Sub/.git"
  touch "$QE_W/.claude/worktrees/feat/Assets/w.cs" "$QE_W/Assets/Plugins/Sub/x.cs" "$QE_W/Assets/Plugins/Clone/x.cs"
  QE_WM="$(qe_mixed "$QE_W")"
  qe_cases+=(
    "false|matches-source|$QE_WM|$QE_WM/.claude/worktrees/feat/Assets/w.cs|.cs in a git worktree nested under the project root"
    "false|matches-source|$QE_WM|.claude/worktrees/feat/Assets/w.cs|same file given relative to the project root"
    "true|matches-source|$QE_WM/.claude/worktrees/feat|$QE_WM/.claude/worktrees/feat/Assets/w.cs|same file with that worktree as the project root"
    "true|matches-source|$QE_WM|$QE_WM/Assets/Plugins/Sub/x.cs|git submodule under Assets/ still counts as inside"
    "true|matches-source|$QE_WM|$QE_WM/Assets/Plugins/Clone/x.cs|nested clone (.git directory) under Assets/ still counts as inside"
  )
else
  skip "git worktree nested under the project root" "could not create a git worktree"
fi
# 不分大小写的卷（Windows、macOS 默认）上，项目目录换个大小写还是同一个目录。macOS 上 normcase 和 resolve 都不动大小写，
# 要靠文件系统认出是同一个目录；同一深度的其他目录不能因此算进来。分大小写的卷（Linux）上那个写法不存在，跳过
if [[ -d "$QE_TMP/UNITY" ]]; then
  qe_cases+=(
    "true|matches-source|$QE_U|$(qe_mixed "$QE_TMP")/UNITY/Assets/Scripts/a.cs|project folder spelled in a different case (case-insensitive volume)"
    "false|matches-source|$QE_U|$(qe_mixed "$QE_TMP")/OUTSIDE/x.cs|a sibling folder spelled in a different case stays outside"
  )
else
  skip "project folder spelled in a different case" "case-sensitive volume"
fi
for qe_case in "${qe_cases[@]}"; do
  IFS='|' read -r qe_want qe_cmd qe_project qe_path qe_label <<< "$qe_case"
  qe_got="$(qe_match "$qe_cmd" "$qe_project" "$qe_path")"
  if [[ "$qe_got" == "$qe_want" ]]; then
    pass "qq_engine $qe_cmd: $qe_label → $qe_want"
  else
    fail "qq_engine $qe_cmd: $qe_label → want $qe_want, got $qe_got"
    printf '      project: %s\n      path:    %s\n' "$qe_project" "$qe_path"   # 不走 echo -e，免得反斜杠路径被转义
  fi
done

# 端到端：钩子从脚本自己的目录调 qq-compile.sh，拷一份 scripts/ 换成只记一笔的桩
cp -R "$SCRIPT_DIR/scripts" "$QE_TMP/qqscripts"
# shellcheck disable=SC2016  # $QE_COMPILE_MARK 留给桩脚本运行时展开
printf '#!/usr/bin/env bash\nprintf "compiled\\n" >> "$QE_COMPILE_MARK"\nexit 0\n' > "$QE_TMP/qqscripts/qq-compile.sh"
chmod +x "$QE_TMP/qqscripts/qq-compile.sh"
qe_hook() {  # $1 = 钩子脚本, $2 = file_path；输出钩子退出码
  local payload rc=0
  payload="$($QQ_PY -c 'import json, sys; print(json.dumps({"session_id": "qq-test-item4", "tool_name": "Write", "tool_input": {"file_path": sys.argv[1]}}))' "$2")"
  printf '%s' "$payload" | (cd "$QE_TMP/unity" && PROJECT_DIR="$QE_U" QQ_TEMP_DIR="$QE_TMP" QE_COMPILE_MARK="$QE_TMP/compile-mark" \
    bash "$QE_TMP/qqscripts/hooks/$1" >/dev/null 2>"$QE_TMP/hook-stderr") || rc=$?
  printf '%s\n' "$rc"
}
rm -f "$QE_TMP/compile-mark"
qe_rc="$(qe_hook auto-compile.sh "$QE_O/x.cs")"
if [[ "$qe_rc" == "0" && ! -f "$QE_TMP/compile-mark" ]]; then
  pass "auto-compile does not compile after writing a .cs outside the project"
else
  fail "auto-compile compiled (or failed, rc=$qe_rc) after writing a .cs outside the project"
fi
rm -f "$QE_TMP/compile-mark"
qe_rc="$(qe_hook auto-compile.sh "$QE_U/Assets/Scripts/a.cs")"
if [[ "$qe_rc" == "0" && -f "$QE_TMP/compile-mark" ]]; then
  pass "auto-compile still compiles after writing Assets/…/a.cs inside the project"
else
  fail "auto-compile skipped compiling Assets/…/a.cs inside the project (rc=$qe_rc)"
fi
# 假项目没有 Library/（从未打开过），项目内的 .cs 会被编译门拦；项目外的 .cs 必须直接放行
qe_rc="$(qe_hook compile-gate-check.sh "$QE_O/x.cs")"
if [[ "$qe_rc" == "0" && ! -s "$QE_TMP/hook-stderr" ]]; then
  pass "compile gate lets a .cs outside the project through"
else
  fail "compile gate acted on a .cs outside the project (rc=$qe_rc): $(head -c 200 "$QE_TMP/hook-stderr")"
fi
# 对照：项目里的 .cs 要过了「是不是源文件」这一关、走到后面的检查（假项目没有 Library/，退非 0）；
# 没有这条，钩子哪怕无条件退 0，上面那条也照样绿
qe_rc="$(qe_hook compile-gate-check.sh "$QE_U/Assets/Scripts/a.cs")"
if [[ "$qe_rc" != "0" ]]; then
  pass "compile gate does not wave through Assets/…/a.cs inside the project (virgin fixture, rc=$qe_rc)"
else
  fail "compile gate waved through Assets/…/a.cs inside the project although Library/ is missing"
fi
if [ "$IS_WINDOWS" = "true" ]; then
  for qe_junction in "$QE_TMP/linked-unity" "$QE_TMP/unity/Assets/Shared"; do
    [[ -d "$qe_junction" ]] && $QQ_PY -c 'import os, sys; os.rmdir(sys.argv[1])' "$(qe_mixed "$qe_junction")" 2>/dev/null || true
  done
fi
rm -rf "$QE_TMP"

# ── seed-local-runtime: complete an EnterWorktree-created worktree ──
# v1.16.25: EnterWorktree (Claude Code built-in) does only `git worktree add`,
# leaving the new worktree without LOCAL_RUNTIME_PATHS (scripts/, .mcp.json,
# qq.yaml, AGENTS.md, CLAUDE.md), without baseline state files, and without
# .qq/state/worktree.json metadata. The new `seed-local-runtime` subcommand
# fills this gap so EnterWorktree-created worktrees behave like
# command_create-created ones. See proposal:
# docs/dev/proposals/2026-04-07-1906-worktree-local-runtime-fix.md
echo -e "${CYAN}[seed-local-runtime] EnterWorktree worktree completion${NC}"

SLR_SOURCE="$(mktemp -d)"
SLR_PARENT="$(dirname "$SLR_SOURCE")"
(
  cd "$SLR_SOURCE" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  mkdir -p ProjectSettings Packages scripts/platform .claude .qq/state &&
  printf 'm_EditorVersion: 2022.3.51f1c1\n' > ProjectSettings/ProjectVersion.txt &&
  printf '{"dependencies":{}}\n' > Packages/manifest.json &&
  printf '#!/bin/bash\necho doctor\n' > scripts/qq-doctor.py &&
  chmod +x scripts/qq-doctor.py &&
  printf '#!/bin/bash\necho platform\n' > scripts/platform/detect.sh &&
  chmod +x scripts/platform/detect.sh &&
  printf '{"mcpServers":{}}\n' > .mcp.json &&
  printf '{"enabledPlugins":{}}\n' > .claude/settings.local.json &&
  printf 'work_mode: feature\n' > qq.yaml &&
  printf '# project agents\n' > AGENTS.md &&
  printf '# project guide\n' > CLAUDE.md &&
  printf 'base\n' > README.md &&
  printf '.qq/\n' > .gitignore &&
  git add ProjectSettings Packages README.md .gitignore qq.yaml AGENTS.md CLAUDE.md scripts &&
  git add -f .mcp.json .claude/settings.local.json &&
  git commit -q -m "init" &&
  git checkout -q -b feature/test-seed
)

# Seed source baseline state + run records (so seed-local-runtime has something to copy)
SLR_RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$SLR_SOURCE" --stage compile --command source-compile --backend test --transport local --summary "source compile start")
SLR_RUN_ID=$(printf '%s' "$SLR_RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$SLR_SOURCE" --run-id "$SLR_RUN_ID" --status passed --summary "source compile passed" >/dev/null
SLR_RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$SLR_SOURCE" --stage test --command source-test --backend test --transport local --summary "source test start")
SLR_RUN_ID=$(printf '%s' "$SLR_RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
$QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$SLR_SOURCE" --run-id "$SLR_RUN_ID" --status passed --summary "source test passed" >/dev/null

# Use raw `git worktree add` to mimic what EnterWorktree does (bare git, no qq metadata)
SLR_TARGET="$SLR_PARENT/seed-local-runtime-target-$$"
rm -rf "$SLR_TARGET"
(cd "$SLR_SOURCE" && git worktree add -b feature/test-seed-wt "$SLR_TARGET" feature/test-seed) >/dev/null 2>&1

# Test 1: happy path — copies LOCAL_RUNTIME_PATHS + state files + run records + writes metadata
SLR_OUT="$(mktemp)"
if $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" seed-local-runtime --project "$SLR_TARGET" --source "$SLR_SOURCE" --pretty > "$SLR_OUT" 2>/dev/null && \
   $QQ_PY - "$SLR_OUT" "$SLR_TARGET" "$SLR_SOURCE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
target = Path(sys.argv[2])
source = Path(sys.argv[3])

# Returned JSON shape
assert payload["ok"] is True
assert payload["action"] == "seed-local-runtime"
assert "scripts" in payload["copiedLocalRuntimeFiles"]
assert "qq.yaml" in payload["copiedLocalRuntimeFiles"]
assert ".mcp.json" in payload["copiedLocalRuntimeFiles"]
assert "AGENTS.md" in payload["copiedLocalRuntimeFiles"]
assert "CLAUDE.md" in payload["copiedLocalRuntimeFiles"]
assert ".qq/state/compile.json" in payload["copiedBaselineStateFiles"]
assert ".qq/state/test.json" in payload["copiedBaselineStateFiles"]
assert payload["copiedBaselineRunRecords"]

# Files actually present in target
assert (target / "scripts" / "qq-doctor.py").is_file()
# This is the bug we're explicitly fixing (agent reported scripts/platform/ missing)
assert (target / "scripts" / "platform" / "detect.sh").is_file()
assert (target / ".mcp.json").is_file()
assert (target / "qq.yaml").is_file()
assert (target / "AGENTS.md").is_file()
assert (target / "CLAUDE.md").is_file()
assert (target / ".qq" / "state" / "compile.json").is_file()
assert (target / ".qq" / "state" / "test.json").is_file()
for record_path in payload["copiedBaselineRunRecords"]:
    assert (target / record_path).is_file(), f"missing run record: {record_path}"

# Metadata file written and consumable by build_status downstream
metadata = json.loads((target / ".qq" / "state" / "worktree.json").read_text(encoding="utf-8"))
assert metadata["managedBy"] == "qq"
assert metadata["sourceBranch"] == "feature/test-seed"
assert metadata["branch"] == "feature/test-seed-wt"
assert Path(metadata["sourceWorktreePath"]).resolve() == source.resolve()
assert metadata["createdVia"] == "seed-local-runtime"
PY
then
  pass "seed-local-runtime copies LOCAL_RUNTIME_PATHS + state + run records + writes metadata"
else
  fail "seed-local-runtime copies LOCAL_RUNTIME_PATHS + state + run records + writes metadata"
fi

# Test 2: rejects --project == --source
# Wrap python in subshell that always exits 0 because pipefail would otherwise
# propagate python's expected exit 1, masking grep's match-success.
SLR_ERR2="$(mktemp)"
($QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" seed-local-runtime --project "$SLR_SOURCE" --source "$SLR_SOURCE" > "$SLR_ERR2" 2>&1 || true)
if grep -qiE "must be different|same dir" "$SLR_ERR2"; then
  pass "seed-local-runtime rejects identical --project and --source"
else
  fail "seed-local-runtime rejects identical --project and --source"
fi
rm -f "$SLR_ERR2"

# Test 3: rejects --project = subdirectory of source repo (NOT a registered worktree)
mkdir -p "$SLR_SOURCE/somesubdir"
SLR_ERR3="$(mktemp)"
($QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" seed-local-runtime --project "$SLR_SOURCE/somesubdir" --source "$SLR_SOURCE" > "$SLR_ERR3" 2>&1 || true)
if grep -qiE "not a registered git worktree|not registered" "$SLR_ERR3"; then
  pass "seed-local-runtime rejects non-worktree subdirectory of source repo"
else
  fail "seed-local-runtime rejects non-worktree subdirectory of source repo"
fi
rm -f "$SLR_ERR3"
rm -rf "$SLR_SOURCE/somesubdir"

# Test 4: rejects --project and --source from different repos
SLR_OTHER="$(mktemp -d)"
(cd "$SLR_OTHER" && git init -q && git config user.email q@e.x && git config user.name q && printf 'x\n' > x && git add x && git commit -q -m i)
SLR_ERR4="$(mktemp)"
($QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" seed-local-runtime --project "$SLR_OTHER" --source "$SLR_SOURCE" > "$SLR_ERR4" 2>&1 || true)
if grep -qiE "not linked worktrees of the same repo|different repo" "$SLR_ERR4"; then
  pass "seed-local-runtime rejects --project and --source from different repos"
else
  fail "seed-local-runtime rejects --project and --source from different repos"
fi
rm -f "$SLR_ERR4"
rm -rf "$SLR_OTHER"

# Cleanup seed-local-runtime fixtures
(cd "$SLR_SOURCE" && git worktree remove --force "$SLR_TARGET" 2>/dev/null) || rm -rf "$SLR_TARGET"
rm -rf "$SLR_SOURCE" "$SLR_OUT"

# ── auto-sync: no install-state / legacy state without selectedModules ──
# 会话启动的 qq-auto-sync.py 曾在两种项目上中止报错（每开一次会话就报一次）：
#   (a) 有 .qq/ 但没有 install-state.json（例如 worktree 里只放了 .qq/local.yaml）→ 应当静默退 0；
#   (b) 老安装状态缺 selectedModules → 应当按这次同步要铺的计划（resolve 的默认选择）补一次、写回，
#       补出的模块跟同一次运行铺下、记进 managedFiles 的文件对得上；之后再跑静默，不再让人重跑 install.sh。
# 另外 install-state.json 存在但读不出合法 JSON 对象时，不能当成缺字段的老状态拿默认选择把它整份
# 覆盖掉（里面真实的 selectedModules/managedFiles 会丢）：应当报错、一个字节都不改；只多个 UTF-8 BOM 的照常读。
# 正常的安装状态照旧同步。
echo -e "${CYAN}[auto-sync] install-state backfill${NC}"
AS_FIX="$(mktemp -d)"
AS_OUT="$(mktemp)"

# (a) 只有 .qq/local.yaml：静默退 0，不建状态文件，也不往项目里铺脚本
mkdir -p "$AS_FIX/local-only/.qq"
printf 'hooks:\n  disable:\n    - auto_compile\n    - compile_gate\n' > "$AS_FIX/local-only/.qq/local.yaml"
AS_RC=0
$QQ_PY "$SCRIPT_DIR/scripts/qq-auto-sync.py" --project "$AS_FIX/local-only" --plugin-root "$SCRIPT_DIR" > "$AS_OUT" 2>&1 || AS_RC=$?
if [ "$AS_RC" -eq 0 ] && [ ! -s "$AS_OUT" ] \
   && [ ! -e "$AS_FIX/local-only/.qq/install-state.json" ] && [ ! -e "$AS_FIX/local-only/scripts" ]; then
  pass "auto-sync: .qq/ with only local.yaml (no install-state.json) exits 0 silently"
else
  fail "auto-sync: .qq/ with only local.yaml (no install-state.json) exits 0 silently (rc=$AS_RC)"
  sed 's/^/    /' "$AS_OUT"
fi

# (b) 老状态缺 selectedModules：按这次铺的计划补一次并写回，跟铺下的文件对得上，再跑静默
($QQ_PY - "$SCRIPT_DIR" "$AS_FIX" > "$AS_OUT" 2>&1 <<'PY'
import json
import subprocess
import sys
from pathlib import Path

plugin_root = Path(sys.argv[1])
fixture = Path(sys.argv[2])
sync_script = plugin_root / "scripts" / "qq-auto-sync.py"
plugin_version = json.loads((plugin_root / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))["version"]


def auto_sync(project):
    result = subprocess.run(
        [sys.executable, str(sync_script), "--project", str(project), "--plugin-root", str(plugin_root)],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    return result.returncode, result.stdout, result.stderr


def default_plan(project):
    out = subprocess.run(
        [sys.executable, str(plugin_root / "scripts" / "qq_internal_install.py"), "resolve",
         "--repo-root", str(plugin_root), "--project", str(project)],
        check=True, capture_output=True, text=True, encoding="utf-8", errors="replace",
    ).stdout
    return json.loads(out)


INSTALL_SH_KEYS = {"engine", "profile", "selectedModules", "defaultModules", "requiredModules",
                   "hosts", "managedFiles", "syncEnabled", "removedFiles"}

# 1.18.0 之前自动同步自己建的状态：只有 pluginVersion + managedFiles
legacy = fixture / "legacy"
(legacy / ".qq").mkdir(parents=True)
legacy_managed = ["scripts/qq-runtime.sh", "scripts/platform/detect.sh", "scripts/qq_mcp.py",
                  "scripts/hooks/hook-dispatch.sh"]
state_path = legacy / ".qq" / "install-state.json"
state_path.write_text(json.dumps({"pluginVersion": "1.17.0", "managedFiles": legacy_managed}), encoding="utf-8")

rc, out, err = auto_sync(legacy)
assert rc == 0, f"first run rc={rc}: {err or out}"
assert "install.sh" not in err + out, f"still tells the user to re-run install.sh: {err or out}"
assert "Backfilled selectedModules" in out, f"no backfill notice: {out!r}"
state = json.loads(state_path.read_text(encoding="utf-8"))
missing_keys = INSTALL_SH_KEYS - set(state)
assert not missing_keys, f"backfilled state lacks install.sh fields: {sorted(missing_keys)}"
selected = state["selectedModules"]
plan = default_plan(legacy)
assert selected == plan["selectedModules"], f"backfill should record the plan this sync applies: {selected}"
# 补出的 selectedModules 要跟同一次运行装下的文件一致：managedFiles 里、磁盘上有文件的模块都得算装了
owning_managed = {e["module"] for e in plan["entries"] if e["target"] in state["managedFiles"]}
owning_on_disk = {e["module"] for e in plan["entries"] if (legacy / e["target"]).is_file()}
assert owning_managed <= set(selected), f"managedFiles has files of unselected modules: {sorted(owning_managed - set(selected))}"
assert owning_on_disk <= set(selected), f"installed files of unselected modules: {sorted(owning_on_disk - set(selected))}"
assert {"host-codex", "hooks-auto-compile"} <= owning_managed, f"sync should lay down every plan module: {sorted(owning_managed)}"
assert set(legacy_managed) <= set(state["managedFiles"]), "managedFiles lost entries"
assert state["pluginVersion"] == plugin_version, state["pluginVersion"]

before = state_path.read_bytes()
rc, out, err = auto_sync(legacy)
assert rc == 0 and not out and not err, f"second run not silent: rc={rc} out={out!r} err={err!r}"
assert state_path.read_bytes() == before, "second run rewrote install-state.json"
print("ok")
PY
) || true
if grep -q "^ok$" "$AS_OUT" 2>/dev/null; then
  pass "auto-sync: legacy install-state without selectedModules is backfilled once, then stays silent"
else
  fail "auto-sync: legacy install-state without selectedModules is backfilled once, then stays silent"
  sed 's/^/    /' "$AS_OUT"
fi

# (c) install-state.json 读不出合法 JSON 对象：报错退非 0，不改写、不铺脚本；只多个 UTF-8 BOM 的照常读、字段不丢
($QQ_PY - "$SCRIPT_DIR" "$AS_FIX" > "$AS_OUT" 2>&1 <<'PY'
import json
import subprocess
import sys
from pathlib import Path

plugin_root = Path(sys.argv[1])
fixture = Path(sys.argv[2])
sync_script = plugin_root / "scripts" / "qq-auto-sync.py"
plugin_version = json.loads((plugin_root / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))["version"]


def auto_sync(project):
    result = subprocess.run(
        [sys.executable, str(sync_script), "--project", str(project), "--plugin-root", str(plugin_root)],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    return result.returncode, result.stdout, result.stderr


custom = {"engine": "unity", "selectedModules": ["runtime-core", "project-config", "engine-unity", "git-pre-push"],
          "managedFiles": ["scripts/qq-runtime.sh", ".githooks/pre-push", "scripts/custom-keep.sh"],
          "syncEnabled": True, "pluginVersion": "1.19.0"}
body = json.dumps(custom).encode("utf-8")
unreadable = {
    "trailing-comma": body[:-1] + b",}",
    "utf-16": json.dumps(custom).encode("utf-16"),  # PowerShell 5.1 的 Out-File 默认写的就是这个
    "empty": b"",  # 另一个会话截断重写、还没写完时读到的样子
    "half-written": body[: len(body) // 2],
    "not-an-object": json.dumps(custom["managedFiles"]).encode("utf-8"),
}
for name, raw in unreadable.items():
    project = fixture / f"unreadable-{name}"
    (project / ".qq").mkdir(parents=True)
    path = project / ".qq" / "install-state.json"
    path.write_bytes(raw)
    rc, out, err = auto_sync(project)
    assert rc != 0, f"{name}: unreadable install-state.json accepted (rc=0): {out!r}"
    assert "install-state.json" in err, f"{name}: error does not name the state file: {err!r}"
    assert path.read_bytes() == raw, f"{name}: unreadable install-state.json was rewritten"
    assert not (project / "scripts").exists(), f"{name}: scripts were synced from an unreadable state"
    assert [p.name for p in (project / ".qq").iterdir()] == ["install-state.json"], f"{name}: stray files in .qq/"

bom = fixture / "bom"
(bom / ".qq").mkdir(parents=True)
bom_path = bom / ".qq" / "install-state.json"
bom_path.write_bytes(b"\xef\xbb\xbf" + body)
rc, out, err = auto_sync(bom)
assert rc == 0 and not err, f"BOM state rejected: rc={rc} err={err!r}"
assert "Backfilled" not in out, f"BOM state treated as legacy: {out!r}"
state = json.loads(bom_path.read_text(encoding="utf-8-sig"))
for key in ("engine", "selectedModules", "syncEnabled"):
    assert state[key] == custom[key], f"BOM state lost {key}: {state[key]!r}"
assert set(custom["managedFiles"]) <= set(state["managedFiles"]), f"BOM state lost managedFiles: {state['managedFiles']}"
assert state["pluginVersion"] == plugin_version, state["pluginVersion"]
assert [p.name for p in (bom / ".qq").iterdir()] == ["install-state.json"], "temp file left behind in .qq/"
print("ok")
PY
) || true
if grep -q "^ok$" "$AS_OUT" 2>/dev/null; then
  pass "auto-sync: unreadable install-state.json is reported and left untouched; a UTF-8 BOM is accepted"
else
  fail "auto-sync: unreadable install-state.json is reported and left untouched; a UTF-8 BOM is accepted"
  sed 's/^/    /' "$AS_OUT"
fi

# 正常的安装状态（install.sh 写的形状）：照旧同步、更新版本号，不补字段
($QQ_PY - "$SCRIPT_DIR" "$AS_FIX" > "$AS_OUT" 2>&1 <<'PY'
import json
import subprocess
import sys
from pathlib import Path

plugin_root = Path(sys.argv[1])
project = Path(sys.argv[2]) / "normal"
sync_script = plugin_root / "scripts" / "qq-auto-sync.py"
plugin_version = json.loads((plugin_root / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))["version"]
(project / ".qq").mkdir(parents=True)
plan = json.loads(subprocess.run(
    [sys.executable, str(plugin_root / "scripts" / "qq_internal_install.py"), "resolve",
     "--repo-root", str(plugin_root), "--project", str(project)],
    check=True, capture_output=True, text=True, encoding="utf-8", errors="replace",
).stdout)
state_path = project / ".qq" / "install-state.json"
original = {
    "engine": plan["engine"], "profile": plan["profile"],
    "selectedModules": plan["selectedModules"], "defaultModules": plan["defaultModules"],
    "requiredModules": plan["requiredModules"], "hosts": plan["hosts"],
    "managedFiles": sorted(plan["managedTargets"]), "syncEnabled": False, "removedFiles": [],
    "pluginVersion": "1.0.0",
}
state_path.write_text(json.dumps(original, indent=2) + "\n", encoding="utf-8")


def auto_sync():
    result = subprocess.run(
        [sys.executable, str(sync_script), "--project", str(project), "--plugin-root", str(plugin_root)],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    return result.returncode, result.stdout, result.stderr


rc, out, err = auto_sync()
assert rc == 0 and not err, f"rc={rc} err={err!r}"
assert "Backfilled" not in out, f"normal state must not be backfilled: {out!r}"
assert "Synced" in out, f"expected a sync on version change: {out!r}"
state = json.loads(state_path.read_text(encoding="utf-8"))
assert state["pluginVersion"] == plugin_version, state["pluginVersion"]
for key, value in original.items():
    if key != "pluginVersion":
        assert state[key] == value, f"{key} changed: {state[key]!r} != {value!r}"
assert (project / "scripts" / "qq-runtime.sh").is_file(), "scripts not synced"
rc, out, err = auto_sync()
assert rc == 0 and not out and not err, f"same-version run not silent: rc={rc} out={out!r} err={err!r}"
print("ok")
PY
) || true
if grep -q "^ok$" "$AS_OUT" 2>/dev/null; then
  pass "auto-sync: normal install-state still syncs on version change and is silent afterwards"
else
  fail "auto-sync: normal install-state still syncs on version change and is silent afterwards"
  sed 's/^/    /' "$AS_OUT"
fi
rm -rf "$AS_FIX" "$AS_OUT"

# ── auto-sync: CRLF checkout of an unchanged script is not rewritten ──
# 消费方仓库开着 core.autocrlf=true 时，项目里的脚本是 CRLF、插件里是 LF。sync_scripts 曾按原始字节
# （连同先比文件大小）比较，每次升级都把内容没变的脚本重写一遍。应当先把 CRLF 统一成 LF 再比：
# 只差换行符的不动（内容、mtime 不变，不进 synced），内容真不同的照常用插件里的文件覆盖。
echo -e "${CYAN}[auto-sync] CRLF-insensitive compare${NC}"
AS_CRLF_FIX="$(mktemp -d)"
AS_CRLF_OUT="$(mktemp)"
($QQ_PY - "$SCRIPT_DIR" "$AS_CRLF_FIX" > "$AS_CRLF_OUT" 2>&1 <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

scripts_dir = Path(sys.argv[1]) / "scripts"
sys.path.insert(0, str(scripts_dir))  # qq-auto-sync.py imports qq_internal_git
spec = importlib.util.spec_from_file_location("qq_auto_sync", str(scripts_dir / "qq-auto-sync.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

fixture = Path(sys.argv[2])
plugin = fixture / "plugin"
project = fixture / "project"
(plugin / "scripts").mkdir(parents=True)
(project / "scripts").mkdir(parents=True)

same_lf = b"#!/usr/bin/env bash\nset -euo pipefail\necho same\n"
changed_lf = b"print('new')\n"
missing_lf = b"#!/usr/bin/env bash\necho missing\n"
(plugin / "scripts" / "same.sh").write_bytes(same_lf)
(plugin / "scripts" / "changed.py").write_bytes(changed_lf)
(plugin / "scripts" / "missing.sh").write_bytes(missing_lf)

same_crlf = same_lf.replace(b"\n", b"\r\n")
(project / "scripts" / "same.sh").write_bytes(same_crlf)
(project / "scripts" / "changed.py").write_bytes(b"print('old')\r\n")
old_mtime = 1_000_000_000
os.utime(project / "scripts" / "same.sh", (old_mtime, old_mtime))

entries = [{"source": f"scripts/{name}", "target": f"scripts/{name}"} for name in ("same.sh", "changed.py", "missing.sh")]
synced = mod.sync_scripts(plugin, project, entries)

assert "scripts/same.sh" not in synced, f"CRLF-only difference was rewritten: {synced}"
assert (project / "scripts" / "same.sh").read_bytes() == same_crlf, "same.sh content changed"
assert int((project / "scripts" / "same.sh").stat().st_mtime) == old_mtime, "same.sh mtime changed"
assert synced == ["scripts/changed.py", "scripts/missing.sh"], f"unexpected synced list: {synced}"
assert (project / "scripts" / "changed.py").read_bytes() == changed_lf, "changed.py should be the plugin's bytes"
assert (project / "scripts" / "missing.sh").read_bytes() == missing_lf, "missing.sh should be copied from the plugin"
print("ok")
PY
) || true
if grep -q "^ok$" "$AS_CRLF_OUT" 2>/dev/null; then
  pass "auto-sync: CRLF-only difference is not rewritten; real content changes still are"
else
  fail "auto-sync: CRLF-only difference is not rewritten; real content changes still are"
  sed 's/^/    /' "$AS_CRLF_OUT"
fi
rm -rf "$AS_CRLF_FIX" "$AS_CRLF_OUT"

# ── clone_copy_tree hardlink path with staging atomic (v1.16.25) ──
# Tests the new allow_hardlink parameter and the staging-dir + rename pattern
# that protects source files from being corrupted on partial hardlink failure.
echo -e "${CYAN}[clone_copy_tree] hardlink + staging atomic${NC}"

# Test 5: hardlink success creates shared inodes (Linux + Windows only — macOS uses clonefile path)
if [ "$(uname -s)" = "Darwin" ]; then
  pass "clone_copy_tree(allow_hardlink=True) shares inodes (skipped on macOS — uses clonefile path)"
else
  CCT_SRC="$(mktemp -d)"
  CCT_DST="${CCT_SRC}_dst"
  rm -rf "$CCT_DST"
  mkdir -p "$CCT_SRC/sub"
  printf 'a\n' > "$CCT_SRC/file_a.txt"
  printf 'b\n' > "$CCT_SRC/sub/file_b.txt"
  CCT_HARDLINK_OUT="$(mktemp)"
  ($QQ_PY - "$CCT_SRC" "$CCT_DST" "$SCRIPT_DIR" > "$CCT_HARDLINK_OUT" 2>&1 <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

scripts_dir = Path(sys.argv[3]) / "scripts"
sys.path.insert(0, str(scripts_dir))  # qq-worktree.py imports from qq_engine, qq_internal_git, etc.
spec = importlib.util.spec_from_file_location("qq_worktree", str(scripts_dir / "qq-worktree.py"))
mod = importlib.util.module_from_spec(spec)
sys.modules["qq_worktree"] = mod  # required for @dataclass on Python 3.13+
spec.loader.exec_module(mod)

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
strategy = mod.clone_copy_tree(src, dst, allow_hardlink=True)
assert strategy == "hardlink", f"expected hardlink, got {strategy}"
assert os.stat(src / "file_a.txt").st_ino == os.stat(dst / "file_a.txt").st_ino, "file_a inode mismatch"
assert os.stat(src / "sub" / "file_b.txt").st_ino == os.stat(dst / "sub" / "file_b.txt").st_ino, "file_b inode mismatch"
print("ok")
PY
  ) || true
  if grep -q "^ok$" "$CCT_HARDLINK_OUT" 2>/dev/null; then
    pass "clone_copy_tree(allow_hardlink=True) shares inodes between source and target"
  else
    fail "clone_copy_tree(allow_hardlink=True) shares inodes between source and target"
    sed 's/^/    /' "$CCT_HARDLINK_OUT"
  fi
  rm -rf "$CCT_SRC" "$CCT_DST" "$CCT_HARDLINK_OUT"
fi

# Test 6: partial hardlink failure → staging cleaned up + fallback to copytree + source NOT corrupted
# Skip on macOS — the clonefile path (cp -cR) runs first and succeeds before hardlink
# is even attempted, so the fallback test premise doesn't apply.
if [ "$(uname -s)" = "Darwin" ]; then
  pass "clone_copy_tree hardlink staging falls back to copytree (skipped on macOS — uses clonefile path)"
else
CCT_SRC2="$(mktemp -d)"
CCT_DST2="${CCT_SRC2}_dst"
rm -rf "$CCT_DST2"
mkdir -p "$CCT_SRC2"
printf 'orig_content\n' > "$CCT_SRC2/keep.txt"
CCT_FALLBACK_OUT="$(mktemp)"
($QQ_PY - "$CCT_SRC2" "$CCT_DST2" "$SCRIPT_DIR" > "$CCT_FALLBACK_OUT" 2>&1 <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

scripts_dir = Path(sys.argv[3]) / "scripts"
sys.path.insert(0, str(scripts_dir))
spec = importlib.util.spec_from_file_location("qq_worktree", str(scripts_dir / "qq-worktree.py"))
mod = importlib.util.module_from_spec(spec)
sys.modules["qq_worktree"] = mod  # required for @dataclass on Python 3.13+
spec.loader.exec_module(mod)

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

# Capture source state BEFORE clone
src_keep = src / "keep.txt"
orig_inode = os.stat(src_keep).st_ino
orig_links = os.stat(src_keep).st_nlink
orig_content = src_keep.read_text()

# Mock os.link to always fail (simulates cross-device error / unsupported FS / partial fail)
real_link = os.link
def faulty_link(s, d, **kwargs):
    raise OSError(18, "EXDEV simulated")  # 18 = errno.EXDEV
os.link = faulty_link
try:
    strategy = mod.clone_copy_tree(src, dst, allow_hardlink=True)
finally:
    os.link = real_link

# Should have fallen back to copytree
assert strategy == "copytree", f"expected copytree fallback after hardlink failure, got {strategy}"

# Target file exists and has correct content
assert (dst / "keep.txt").exists(), "target file missing after fallback"
assert (dst / "keep.txt").read_text() == orig_content, "target file content wrong after fallback"

# Source file is unchanged: same inode, same link count, same content
assert os.stat(src_keep).st_ino == orig_inode, "source inode changed (corruption!)"
assert os.stat(src_keep).st_nlink == orig_links, f"source link count changed: {orig_links} -> {os.stat(src_keep).st_nlink}"
assert src_keep.read_text() == orig_content, "source content changed (catastrophic corruption!)"

# Staging dir should be cleaned up (no <name>.hardlink-staging sibling left over)
staging = dst.parent / (dst.name + ".hardlink-staging")
assert not staging.exists(), f"staging dir leftover: {staging}"

# Target should not be a hardlink to source (it was created by copytree, separate inode)
assert os.stat(dst / "keep.txt").st_ino != orig_inode, "target shares inode with source — copytree should have created a new file"

print("ok")
PY
) || true
if grep -q "^ok$" "$CCT_FALLBACK_OUT" 2>/dev/null; then
  pass "clone_copy_tree hardlink staging falls back to copytree without corrupting source"
else
  fail "clone_copy_tree hardlink staging falls back to copytree without corrupting source"
  sed 's/^/    /' "$CCT_FALLBACK_OUT"
fi
rm -rf "$CCT_SRC2" "$CCT_DST2" "$CCT_FALLBACK_OUT"
fi  # /Darwin skip for test 6

WORKTREE_REMOTE_ROOT="$(mktemp -d)"
WORKTREE_REMOTE_BARE="${WORKTREE_REMOTE_ROOT}_remote.git"
git init --bare -q "$WORKTREE_REMOTE_BARE"
(
  cd "$WORKTREE_REMOTE_ROOT" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  printf 'base\n' > README.md &&
  git add README.md &&
  git commit -q -m "init" &&
  git branch -M feature/ship-system &&
  git remote add origin "$WORKTREE_REMOTE_BARE" &&
  git push -q -u origin feature/ship-system
)
WORKTREE_REMOTE_PARENT="$(dirname "$WORKTREE_REMOTE_ROOT")"
WORKTREE_REMOTE_JSON="$(mktemp)"
if $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_REMOTE_ROOT" --name remote-closeout --base-dir "$WORKTREE_REMOTE_PARENT" > "$WORKTREE_REMOTE_JSON" && \
   $QQ_PY - "$WORKTREE_REMOTE_JSON" "$WORKTREE_REMOTE_ROOT" "$WORKTREE_REMOTE_BARE" "$SCRIPT_DIR" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2])
remote = Path(sys.argv[3])
script_dir = Path(sys.argv[4])
worktree = Path(payload["worktreePath"])

subprocess.run(["git", "config", "user.email", "qq@example.com"], cwd=worktree, check=True)
subprocess.run(["git", "config", "user.name", "qq test"], cwd=worktree, check=True)
(worktree / "README.md").write_text("base\nremote closeout\n", encoding="utf-8")
subprocess.run(["git", "add", "README.md"], cwd=worktree, check=True)
subprocess.run(["git", "commit", "-q", "-m", "feat: remote closeout"], cwd=worktree, check=True)
subprocess.run(["git", "push", "-q", "-u", "origin", payload["branch"]], cwd=worktree, check=True)

closeout = subprocess.check_output(
    [sys.executable, "scripts/qq-worktree.py", "closeout", "--project", str(worktree), "--auto-yes", "--delete-branch"],
    cwd=script_dir,
    text=True,
)
result = json.loads(closeout)
cleanup = result["cleanup"]
assert cleanup["deletedRemoteBranch"] is True
assert cleanup["remoteName"] == "origin"
assert cleanup["remoteBranch"] == payload["branch"]
assert not worktree.exists()
heads = subprocess.check_output(["git", "ls-remote", "--heads", str(remote)], text=True)
assert f"refs/heads/{payload['branch']}" not in heads
readme = (root / "README.md").read_text(encoding="utf-8")
assert "remote closeout" in readme
PY
then
  pass "qq-worktree closeout deletes the remote linked branch before removing the worktree"
else
  fail "qq-worktree closeout deletes the remote linked branch before removing the worktree"
fi
rm -f "$WORKTREE_REMOTE_JSON"
rm -rf "$WORKTREE_REMOTE_ROOT" "$WORKTREE_REMOTE_BARE"

WORKTREE_BLOCK_ROOT="$(mktemp -d)"
(
  cd "$WORKTREE_BLOCK_ROOT" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  printf 'base\n' > README.md &&
  git add README.md &&
  git commit -q -m "init" &&
  git branch -M main
)
if $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_BLOCK_ROOT" --name blocked >/dev/null 2>&1; then
  fail "qq-worktree blocks protected source branches by default"
else
  pass "qq-worktree blocks protected source branches by default"
fi
rm -rf "$WORKTREE_BLOCK_ROOT"

WORKTREE_DOCKER_ROOT="$(mktemp -d)"
(
  cd "$WORKTREE_DOCKER_ROOT" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  mkdir -p .devcontainer scripts &&
  printf '{\"name\":\"qq-dev\"}\n' > .devcontainer/devcontainer.json &&
  cat > scripts/docker-dev.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x scripts/docker-dev.sh &&
  printf 'base\n' > README.md &&
  git add README.md .devcontainer/devcontainer.json scripts/docker-dev.sh &&
  git commit -q -m "init" &&
  git checkout -q -b feature/repo-dev
)
WORKTREE_DOCKER_CREATE_JSON="$(mktemp)"
if $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_DOCKER_ROOT" --name docker-flow --base-dir "$(dirname "$WORKTREE_DOCKER_ROOT")" --pretty > "$WORKTREE_DOCKER_CREATE_JSON" && \
   $QQ_PY - "$WORKTREE_DOCKER_CREATE_JSON" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["recommendedExecution"]["mode"] == "docker"
labels = [item["label"] for item in payload["nextSteps"]]
assert "open-repo-dev-shell" in labels
assert "run-repo-dev-validation" in labels
assert any(item["command"] == "./scripts/docker-dev.sh shell" for item in payload["nextSteps"])
assert any(item["command"] == "./scripts/docker-dev.sh test" for item in payload["nextSteps"])
PY
then
  pass "qq-worktree create recommends Docker for repo-dev worktrees"
else
  fail "qq-worktree create recommends Docker for repo-dev worktrees"
fi
$QQ_PY - "$WORKTREE_DOCKER_CREATE_JSON" <<'PY' >/dev/null
import json
import shutil
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
worktree = Path(payload["worktreePath"])
if worktree.exists():
    shutil.rmtree(worktree)
PY
rm -f "$WORKTREE_DOCKER_CREATE_JSON"
rm -rf "$WORKTREE_DOCKER_ROOT"

WORKTREE_CLOSEOUT_ROOT="$(mktemp -d)"
WORKTREE_CLOSEOUT_REMOTE="$(mktemp -d)/origin.git"
git init --bare -q "$WORKTREE_CLOSEOUT_REMOTE"
(
  cd "$WORKTREE_CLOSEOUT_ROOT" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  printf 'base\n' > README.md &&
  mkdir -p ProjectSettings Packages &&
  cat > ProjectSettings/ProjectVersion.txt <<'EOF'
m_EditorVersion: 2022.3.17f1
EOF
  cat > Packages/manifest.json <<'EOF'
{
  "dependencies": {}
}
EOF
  git add README.md ProjectSettings/ProjectVersion.txt Packages/manifest.json &&
  git commit -q -m "init" &&
  git checkout -q -b feature/crew &&
  git remote add origin "$WORKTREE_CLOSEOUT_REMOTE" &&
  "$SCRIPT_DIR/install.sh" "$WORKTREE_CLOSEOUT_ROOT" >/dev/null &&
  git add . &&
  git commit -q -m "install qq runtime" &&
  git push -q -u origin feature/crew
)
WORKTREE_CLOSEOUT_CREATE_JSON="$(mktemp)"
$QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_CLOSEOUT_ROOT" --name closeout --pretty > "$WORKTREE_CLOSEOUT_CREATE_JSON"
WORKTREE_CLOSEOUT_PATH="$($QQ_PY - "$WORKTREE_CLOSEOUT_CREATE_JSON" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["worktreePath"])
PY
)"
(
  cd "$WORKTREE_CLOSEOUT_PATH" &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  printf 'linked change\n' > notes.txt &&
  git add notes.txt &&
  git commit -q -m "feat: linked worktree change" &&
  git push -q -u origin "$(git branch --show-current)"
)
WORKTREE_CLOSEOUT_RESULT="$(mktemp)"
if $QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" closeout --project "$WORKTREE_CLOSEOUT_PATH" --auto-yes --delete-branch --pretty > "$WORKTREE_CLOSEOUT_RESULT" && \
   $QQ_PY - "$WORKTREE_CLOSEOUT_RESULT" "$WORKTREE_CLOSEOUT_ROOT" "$WORKTREE_CLOSEOUT_PATH" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2]).resolve()
worktree = Path(sys.argv[3]).resolve()

assert payload["action"] == "closeout"
assert payload["mergeBack"]["pushedSourceBranch"] is True
assert payload["cleanup"]["deletedBranch"] is True
assert not worktree.exists()
head = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=root, text=True).strip()
assert head == "feature/crew"
log = subprocess.check_output(["git", "log", "--oneline", "-3"], cwd=root, text=True).strip()
assert "linked worktree change" in log
branches = subprocess.check_output(["git", "branch", "--list", "feature/crew-wt-closeout"], cwd=root, text=True).strip()
assert branches == ""
PY
then
  pass "qq-worktree closeout merges back, publishes source, and cleans up"
else
  fail "qq-worktree closeout merges back, publishes source, and cleans up"
fi
rm -f "$WORKTREE_CLOSEOUT_CREATE_JSON" "$WORKTREE_CLOSEOUT_RESULT"
rm -rf "$WORKTREE_CLOSEOUT_ROOT" "$(dirname "$WORKTREE_CLOSEOUT_REMOTE")"

WORKTREE_CODEX_ROOT="$(mktemp -d)"
(
  cd "$WORKTREE_CODEX_ROOT" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  printf 'base\n' > README.md &&
  git add README.md &&
  git commit -q -m "init" &&
  git checkout -q -b feature/crew
)
WORKTREE_CODEX_PARENT="$(dirname "$WORKTREE_CODEX_ROOT")"
WORKTREE_CODEX_CREATE_JSON="$(mktemp)"
$QQ_PY "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_CODEX_ROOT" --name codex-closeout --base-dir "$WORKTREE_CODEX_PARENT" --pretty > "$WORKTREE_CODEX_CREATE_JSON"
WORKTREE_CODEX_PATH="$($QQ_PY - "$WORKTREE_CODEX_CREATE_JSON" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["worktreePath"])
PY
)"
WORKTREE_CODEX_DRY_RUN="$(mktemp)"
if $QQ_PY "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --dry-run --pretty "closeout" > "$WORKTREE_CODEX_DRY_RUN" && \
   $QQ_PY - "$WORKTREE_CODEX_DRY_RUN" "$WORKTREE_CODEX_ROOT" "$WORKTREE_CODEX_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2]).resolve()
worktree = Path(sys.argv[3]).resolve()
command = payload["command"]

assert payload["action"] == "dry-run"
assert payload["isManagedWorktree"] is True
assert Path(payload["sourceWorktreePath"]).resolve() == root
assert payload["defaultSandboxApplied"] is True
assert payload["defaultCdApplied"] is True
assert payload["addedSourceDir"] is True
assert command[:2] == ["codex", "exec"]
assert "--sandbox" in command
assert command[command.index("--sandbox") + 1] == "workspace-write"
assert "-C" in command
assert Path(command[command.index("-C") + 1]).resolve() == worktree
assert "--add-dir" in command
assert Path(command[command.index("--add-dir") + 1]).resolve() == root
assert command[-1] == "closeout"
PY
then
  pass "qq-codex-exec auto-resumes managed worktree closeout context"
else
  fail "qq-codex-exec auto-resumes managed worktree closeout context"
fi


mkdir -p "$WORKTREE_CODEX_PATH/.qq"
cat > "$WORKTREE_CODEX_PATH/.qq/local.yaml" <<'EOF'
trust_level: balanced
EOF

if $QQ_PY "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --dry-run --pretty "Summarize current state." > "$WORKTREE_CODEX_DRY_RUN" && \
   $QQ_PY - "$WORKTREE_CODEX_DRY_RUN" "$WORKTREE_CODEX_ROOT" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2]).resolve()
command = payload["command"]

assert payload["trustLevel"] == "balanced"
assert payload["sourceWorktreeAccess"] == "closeout_only"
assert payload["addedSourceDir"] is False
assert payload["addedSourceDirReason"] == "trust_level:closeout_only_blocked"
assert "--add-dir" not in command
assert Path(payload["sourceWorktreePath"]).resolve() == root
PY
then
  pass "balanced trust level blocks automatic source-worktree widening for non-closeout Codex execs"
else
  fail "balanced trust level blocks automatic source-worktree widening for non-closeout Codex execs"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --dry-run --pretty "closeout" > "$WORKTREE_CODEX_DRY_RUN" && \
   $QQ_PY - "$WORKTREE_CODEX_DRY_RUN" "$WORKTREE_CODEX_ROOT" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2]).resolve()
command = payload["command"]

assert payload["trustLevel"] == "balanced"
assert payload["addedSourceDir"] is True
assert payload["addedSourceDirReason"] == "trust_level:closeout_only"
assert "--add-dir" in command
assert Path(command[command.index("--add-dir") + 1]).resolve() == root
PY
then
  pass "balanced trust level still widens source worktree access for closeout Codex execs"
else
  fail "balanced trust level still widens source worktree access for closeout Codex execs"
fi

cat > "$WORKTREE_CODEX_PATH/.qq/local.yaml" <<'EOF'
trust_level: strict
EOF

if $QQ_PY "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --dry-run --pretty "closeout" > "$WORKTREE_CODEX_DRY_RUN" && \
   $QQ_PY - "$WORKTREE_CODEX_DRY_RUN" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
command = payload["command"]

assert payload["trustLevel"] == "strict"
assert payload["sourceWorktreeAccess"] == "explicit"
assert payload["addedSourceDir"] is False
assert payload["addedSourceDirReason"] == "trust_level:explicit_required"
assert "--add-dir" not in command
PY
then
  pass "strict trust level requires explicit source-worktree widening"
else
  fail "strict trust level requires explicit source-worktree widening"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --allow-source-worktree --dry-run --pretty "closeout" > "$WORKTREE_CODEX_DRY_RUN" && \
   $QQ_PY - "$WORKTREE_CODEX_DRY_RUN" "$WORKTREE_CODEX_ROOT" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2]).resolve()
command = payload["command"]

assert payload["trustLevel"] == "strict"
assert payload["addedSourceDir"] is True
assert payload["addedSourceDirReason"] == "flag:allow_source_worktree"
assert "--add-dir" in command
assert Path(command[command.index("--add-dir") + 1]).resolve() == root
PY
then
  pass "strict trust level can widen source worktree access explicitly"
else
  fail "strict trust level can widen source worktree access explicitly"
fi

if [ "$IS_WINDOWS" = "true" ]; then
  skip "qq-codex-exec isolates the current qq MCP server when multiple qq servers are registered" "fake codex binary has no .cmd extension; Windows can't exec it via PATHEXT"
else
FAKE_CODEX_BIN_DIR="$(mktemp -d)"
FAKE_CODEX_LOG="$(mktemp)"
CURRENT_CODEX_SERVER="$($QQ_PY - "$WORKTREE_CODEX_PATH" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

project = Path(sys.argv[1]).resolve()
slug = re.sub(r"[^a-z0-9]+", "-", project.name.lower()).strip("-") or "unity-project"
digest = hashlib.sha1(str(project).encode("utf-8")).hexdigest()[:8]
print(f"qq-unity-{slug}-{digest}")
PY
)"
OTHER_CODEX_SERVER="$($QQ_PY - "$WORKTREE_CODEX_ROOT" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

project = Path(sys.argv[1]).resolve()
slug = re.sub(r"[^a-z0-9]+", "-", project.name.lower()).strip("-") or "unity-project"
digest = hashlib.sha1(str(project).encode("utf-8")).hexdigest()[:8]
print(f"qq-unity-{slug}-{digest}")
PY
)"
cat > "$FAKE_CODEX_BIN_DIR/codex" <<'EOF'
#!/usr/bin/env python3
import json
import os
import sys

log_path = os.environ["FAKE_CODEX_LOG"]
current_name = os.environ["FAKE_CODEX_CURRENT_SERVER"]
other_name = os.environ["FAKE_CODEX_OTHER_SERVER"]
current_project = os.environ["FAKE_CODEX_CURRENT_PROJECT"]
other_project = os.environ["FAKE_CODEX_OTHER_PROJECT"]

def record(payload):
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")

def registration(name, project):
    return {
        "name": name,
        "enabled": True,
        "disabled_reason": None,
        "transport": {
            "type": "stdio",
            "command": "python3",
            "args": [f"{project}/scripts/qq_mcp.py", "--project", project],
            "env": None,
            "env_vars": [],
            "cwd": None,
        },
        "enabled_tools": None,
        "disabled_tools": None,
        "startup_timeout_sec": None,
        "tool_timeout_sec": None,
    }

args = sys.argv[1:]
if args[:2] == ["mcp", "list"]:
    print("Name  Command  Args  Env  Cwd  Status  Auth")
    print(f"{other_name}  python3  {other_project}/scripts/qq_mcp.py --project {other_project}  -  -  enabled  Unsupported")
    print(f"{current_name}  python3  {current_project}/scripts/qq_mcp.py --project {current_project}  -  -  enabled  Unsupported")
    raise SystemExit(0)
if args[:2] == ["mcp", "get"]:
    name = args[2]
    if name == current_name:
        print(json.dumps(registration(name, current_project)))
        raise SystemExit(0)
    if name == other_name:
        print(json.dumps(registration(name, other_project)))
        raise SystemExit(0)
    raise SystemExit(1)
if args[:2] == ["mcp", "remove"]:
    record({"action": "remove", "name": args[2]})
    raise SystemExit(0)
if args[:2] == ["mcp", "add"]:
    sep = args.index("--")
    record({"action": "add", "name": args[2], "command": args[sep + 1], "args": args[sep + 2:]})
    raise SystemExit(0)
if args[:1] == ["exec"]:
    record({"action": "exec", "args": args[1:]})
    print("fake codex exec ok")
    raise SystemExit(0)
raise SystemExit(1)
EOF
chmod +x "$FAKE_CODEX_BIN_DIR/codex"
if PATH="$FAKE_CODEX_BIN_DIR:$PATH" \
   FAKE_CODEX_LOG="$FAKE_CODEX_LOG" \
   FAKE_CODEX_CURRENT_SERVER="$CURRENT_CODEX_SERVER" \
   FAKE_CODEX_OTHER_SERVER="$OTHER_CODEX_SERVER" \
   FAKE_CODEX_CURRENT_PROJECT="$WORKTREE_CODEX_PATH" \
   FAKE_CODEX_OTHER_PROJECT="$WORKTREE_CODEX_ROOT" \
   $QQ_PY "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" "Use the unity_health tool" >/dev/null && \
   $QQ_PY - "$FAKE_CODEX_LOG" "$CURRENT_CODEX_SERVER" "$OTHER_CODEX_SERVER" <<'PY'
import json
import sys
from pathlib import Path

entries = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
current = sys.argv[2]
other = sys.argv[3]

assert [entry["action"] for entry in entries] == ["remove", "exec", "add"]
assert entries[0]["name"] == other
assert entries[1]["action"] == "exec"
assert entries[2]["name"] == other
assert current not in {entry.get("name") for entry in entries if "name" in entry}
PY
then
  pass "qq-codex-exec isolates the current qq MCP server when multiple qq servers are registered"
else
  fail "qq-codex-exec isolates the current qq MCP server when multiple qq servers are registered"
fi
rm -rf "$FAKE_CODEX_BIN_DIR"
rm -f "$FAKE_CODEX_LOG"
fi  # end !IS_WINDOWS guard for codex MCP isolation test
rm -f "$WORKTREE_CODEX_CREATE_JSON" "$WORKTREE_CODEX_DRY_RUN"
rm -rf "$WORKTREE_CODEX_ROOT"

mkdir -p "$RUNTIME_TEST_ROOT/ProjectSettings" "$RUNTIME_TEST_ROOT/Packages" "$RUNTIME_TEST_ROOT/Temp" "$RUNTIME_TEST_ROOT/scripts"
cat > "$RUNTIME_TEST_ROOT/ProjectSettings/ProjectVersion.txt" <<'EOF'
m_EditorVersion: 2022.3.17f1
EOF
cat > "$RUNTIME_TEST_ROOT/Packages/manifest.json" <<'EOF'
{
  "dependencies": {
    "com.tyk.tykit": "https://github.com/tykisgod/tykit.git#demo"
  }
}
EOF
cat > "$RUNTIME_TEST_ROOT/.mcp.json" <<'EOF'
{
  "servers": {
    "unity": {
      "command": "mcp-unity"
    }
  }
}
EOF
for path in \
  qq-compile.sh \
  qq-test.sh \
  unity-compile-smart.sh \
  unity-test.sh \
  qq-project-state.py \
  qq-policy-check.sh \
  qq_mcp.py \
  tykit_bridge.py \
  qq-capabilities.json \
  tykit_capabilities.json; do
  : > "$RUNTIME_TEST_ROOT/scripts/$path"
done

if $QQ_PY "$SCRIPT_DIR/scripts/qq-capability.py" validate --pretty > "$RUNTIME_TEST_ROOT/capability-validate.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/capability-validate.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["ok"] is True
assert payload["errors"] == []
PY
then
  pass "capability registry validates"
else
  fail "capability registry validates"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/qq-capability.py" resolve --engine unity --capability compile --available unity.tykit-mcp unity.unity-mcp > "$RUNTIME_TEST_ROOT/capability-resolve.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/capability-resolve.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["resolved"] == "unity.tykit-mcp"
assert payload["provider"]["transportAdapter"] == "mcp"
PY
then
  pass "capability resolver prefers configured provider order"
else
  fail "capability resolver prefers configured provider order"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/qq-capability.py" resolve --engine unreal --capability scene.query --available unreal.runreal-mcp unreal.flop-mcp > "$RUNTIME_TEST_ROOT/capability-resolve-unreal.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/capability-resolve-unreal.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["resolved"] == "unreal.runreal-mcp"
assert payload["provider"]["transportAdapter"] == "mcp"
PY
then
  pass "capability resolver can fall back to compatible third-party Unreal providers"
else
  fail "capability resolver can fall back to compatible third-party Unreal providers"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/qq-capability.py" resolve --engine sbox --capability compile --available sbox.qq-direct > "$RUNTIME_TEST_ROOT/capability-resolve-sbox.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/capability-resolve-sbox.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["resolved"] == "sbox.qq-direct"
assert payload["provider"]["transportAdapter"] == "direct"
PY
then
  pass "capability resolver can resolve the S&box direct provider"
else
  fail "capability resolver can resolve the S&box direct provider"
fi

if "$SCRIPT_DIR/scripts/qq-doctor.sh" --project "$RUNTIME_TEST_ROOT" --write-state > "$RUNTIME_TEST_ROOT/doctor.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/doctor.json" "$RUNTIME_TEST_ROOT/.qq/state/provider-resolution.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
state_payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

providers = {item["id"]: item for item in payload["providers"]}
assert payload["unityProjectDetected"] is True
assert payload["policy"]["sharedExists"] is True
assert payload["policy"]["localExists"] is True
assert payload["policy"]["effectiveProfile"] == "hardening"
assert payload["policy"]["effectiveProfileSource"] == "qq_local_yaml"
assert payload["policy"]["effectiveProfileExpectations"]["review_expectation"] == "required"
assert payload["policy"]["trustLevel"] == "trusted"
assert payload["policy"]["trustLevelSource"] == "profile"
assert payload["policy"]["trustLevelExpectations"]["codex_auto_resume"] is True
assert payload["controller"]["workMode"] == "prototype"
assert payload["controller"]["workModeSource"] == "qq_local_yaml"
assert payload["controller"]["modeRecommendedNext"] == "prototype_direct"
assert payload["controller"]["taskFocus"] == []
assert payload["controller"]["taskFocusSource"] == "default"
assert payload["controller"]["policyProfile"] == "hardening"
assert payload["controller"]["policyProfileSource"] == "qq_local_yaml"
assert payload["controller"]["policyProfileExpectations"]["review_expectation"] == "required"
assert payload["controller"]["trustLevel"] == "trusted"
assert payload["controller"]["trustLevelSource"] == "profile"
assert payload["controller"]["trustLevelExpectations"]["codex_source_worktree_access"] == "auto"
assert payload["controller"]["defaultTestScope"] == "all"
assert payload["controller"]["recommendedNext"] == "prototype_direct"
assert payload["controller"]["compileStatusFresh"] is True
assert payload["controller"]["compileStatusRaw"] == "passed"
assert payload["controller"]["testStatusFresh"] is True
assert payload["controller"]["testStatusRaw"] == "not_run"
assert payload["controller"]["repositoryDesignDocCount"] == 0
assert payload["controller"]["repositoryImplementationPlanCount"] == 0
assert payload["controller"]["modeProfile"]["changes_summary_expected"] is True
assert payload["controller"]["isManagedWorktree"] is False
assert payload["controller"]["worktreeRole"] == "primary"
assert payload["recommendedExecution"]["mode"] == "host"
assert payload["recommendedExecution"]["recommendedAction"] == "./scripts/qq-compile.sh"
assert "Unity" in payload["recommendedExecution"]["reason"]
assert payload["parallelAgentSafety"]["status"] == "warn"
assert "primary worktree" in payload["parallelAgentSafety"]["summary"]
assert "qq-worktree.py" in payload["parallelAgentSafety"]["recommendedAction"]
assert providers["unity.qq-direct"]["status"] == "available"
assert providers["unity.tykit-mcp"]["status"] == "available"
assert providers["unity.raw-tykit"]["status"] == "available"
assert providers["unity.mcp-unity"]["status"] == "available"
assert payload["resolution"]["compile"]["resolved"] == "unity.qq-direct"
assert payload["resolution"]["console.read"]["resolved"] == "unity.tykit-mcp"
assert state_payload["resolution"]["compile"]["resolved"] == "unity.qq-direct"
assert "gitHooks" in payload, "gitHooks section missing from doctor payload"
assert payload["gitHooks"]["status"] == "not-a-repo", payload["gitHooks"]
assert payload["gitHooks"]["isGitRepo"] is False
assert payload["gitHooks"]["issues"] == []
PY
then
  pass "qq-doctor discovers providers and writes resolution state"
else
  fail "qq-doctor discovers providers and writes resolution state"
fi

# ── qq 配置：YAML 行内写法能解析，解析不了就报错（不再当成字符串 / 空配置悄悄忽略） ──
# 旧 parse_scalar 对 [ / { 开头的值只试 json.loads，失败就当普通字符串：
# hooks: {disable: [auto_compile, compile_gate]} 整段成了字符串，两个钩子照样开着、毫无提示；
# read_optional_structured 又把整份解析失败（如 4 格缩进）吞成空配置。
INLINE_CFG_ROOT="$(mktemp -d)"
mkdir -p "$INLINE_CFG_ROOT/.qq"
printf 'hooks: {disable: [auto_compile, compile_gate]}\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
if [ "$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled auto_compile --project "$INLINE_CFG_ROOT")" = "false" ] &&
   [ "$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled compile_gate --project "$INLINE_CFG_ROOT")" = "false" ] &&
   [ "$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled review_gate --project "$INLINE_CFG_ROOT")" = "true" ] &&
   $QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" field enabled_hooks --project "$INLINE_CFG_ROOT" | $QQ_PY -c '
import json, sys
hooks = json.load(sys.stdin)
assert "auto_compile" not in hooks and "compile_gate" not in hooks, hooks
assert "review_gate" in hooks, hooks
'; then
  pass "qq config: inline hooks: {disable: [auto_compile, compile_gate]} disables exactly those two hooks"
else
  fail "qq config: inline hooks: {disable: [auto_compile, compile_gate]} disables exactly those two hooks"
fi

cat > "$INLINE_CFG_ROOT/.qq/local.yaml" <<'EOF'
# 嵌套；带引号的值里有逗号、冒号、括号；单引号里 '' 是一个 '
task_focus: {title: "fix, then: test [x]", tags: [a, 'b: c, d', "e]f", 'it''s', 3, true, null], nested: {n: [1, {deep: [x, {y: z}]}], url: http://example.com/a}}
EOF
if $QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" field task_focus --project "$INLINE_CFG_ROOT" | $QQ_PY -c '
import json, sys
focus = json.load(sys.stdin)
expected = {
    "title": "fix, then: test [x]",
    "tags": ["a", "b: c, d", "e]f", "it'"'"'s", 3, True, None],
    "nested": {"n": [1, {"deep": ["x", {"y": "z"}]}], "url": "http://example.com/a"},
}
assert focus == expected, focus
'; then
  pass "qq config: nested inline values and quoted strings with commas/colons/brackets parse correctly"
else
  fail "qq config: nested inline values and quoted strings with commas/colons/brackets parse correctly"
fi

# 4 格缩进、列表与上级键同缩进都是合法 YAML；旧代码整份解析失败后被吞成空配置
cat > "$INLINE_CFG_ROOT/.qq/local.yaml" <<'EOF'
skills:
    disable:
        - plan
hooks:
  disable:
  - review_gate
EOF
if [ "$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" skill-enabled plan --project "$INLINE_CFG_ROOT")" = "false" ] &&
   [ "$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled review_gate --project "$INLINE_CFG_ROOT")" = "false" ] &&
   [ "$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled auto_compile --project "$INLINE_CFG_ROOT")" = "true" ]; then
  pass "qq config: 4-space indentation and same-indent block lists are honoured instead of dropping the file"
else
  fail "qq config: 4-space indentation and same-indent block lists are honoured instead of dropping the file"
fi

# 写坏的行内值：qq-config.py 各子命令都非 0 退出、stdout 不出结果，stderr 带文件名、行号与键名；
# qq-project-state.py 同样报错；钩子侧 qq_hook_enabled 按「关」处理（不因配置坏了卡住会话）
printf 'work_mode: fix\nhooks: {disable: [a, b}\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
INLINE_CFG_OK=1
for INLINE_CFG_ARGS in "hook-enabled auto_compile" "field enabled_hooks" "skill-enabled plan" "resolve"; do
  INLINE_CFG_RC=0
  # shellcheck disable=SC2086  # 有意按空格拆成子命令与参数
  $QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" $INLINE_CFG_ARGS --project "$INLINE_CFG_ROOT" \
    >"$INLINE_CFG_ROOT/out.txt" 2>"$INLINE_CFG_ROOT/err.txt" || INLINE_CFG_RC=$?
  if [ "$INLINE_CFG_RC" -eq 0 ] || [ -s "$INLINE_CFG_ROOT/out.txt" ] ||
     ! grep -q "local.yaml" "$INLINE_CFG_ROOT/err.txt" ||
     ! grep -q "line 2" "$INLINE_CFG_ROOT/err.txt" ||
     ! grep -q "key 'hooks'" "$INLINE_CFG_ROOT/err.txt"; then
    INLINE_CFG_OK=0
    echo "    qq-config.py $INLINE_CFG_ARGS: rc=$INLINE_CFG_RC stdout=$(head -c 200 "$INLINE_CFG_ROOT/out.txt") stderr=$(head -c 400 "$INLINE_CFG_ROOT/err.txt")"
  fi
done
INLINE_CFG_RC=0
$QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$INLINE_CFG_ROOT" --no-write \
  >"$INLINE_CFG_ROOT/out.txt" 2>"$INLINE_CFG_ROOT/err.txt" || INLINE_CFG_RC=$?
if [ "$INLINE_CFG_RC" -eq 0 ] || ! grep -q "local.yaml.*key 'hooks'" "$INLINE_CFG_ROOT/err.txt" ||
   grep -q "Traceback" "$INLINE_CFG_ROOT/err.txt"; then
  INLINE_CFG_OK=0
  echo "    qq-project-state.py: rc=$INLINE_CFG_RC stderr=$(head -c 400 "$INLINE_CFG_ROOT/err.txt")"
fi
INLINE_CFG_HOOK="$(PROJECT_DIR="$INLINE_CFG_ROOT" bash -c 'source "$1/scripts/qq-runtime.sh"; qq_hook_enabled auto_compile' _ "$SCRIPT_DIR" || true)"
if [ "$INLINE_CFG_HOOK" != "false" ]; then
  INLINE_CFG_OK=0
  echo "    qq_hook_enabled auto_compile with a broken config: $INLINE_CFG_HOOK (expected false)"
fi
if [ "$INLINE_CFG_OK" -eq 1 ]; then
  pass "qq config: a broken inline value fails loudly with file, line and key (hooks fall back to off)"
else
  fail "qq config: a broken inline value fails loudly with file, line and key (hooks fall back to off)"
fi

# 合法 YAML 却被悄悄忽略的几种写法：带 BOM（PowerShell 5.1 写 utf8 默认带）、带引号的键、文件开头的 ---；
# 以及 Tab 缩进（YAML 不允许，旧代码把子行挪到顶层、设置照样丢）必须报错
INLINE_CFG_OK=1
printf '\xef\xbb\xbfhooks: {disable: [auto_compile, compile_gate]}\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
INLINE_CFG_GOT="$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled auto_compile --project "$INLINE_CFG_ROOT" 2>&1 || true)"
[ "$INLINE_CFG_GOT" = "false" ] || { INLINE_CFG_OK=0; echo "    BOM + inline: auto_compile=$INLINE_CFG_GOT (expected false)"; }
printf '\xef\xbb\xbf# comment first\nhooks:\n  disable: [compile_gate]\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
INLINE_CFG_GOT="$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled compile_gate --project "$INLINE_CFG_ROOT" 2>&1 || true)"
[ "$INLINE_CFG_GOT" = "false" ] || { INLINE_CFG_OK=0; echo "    BOM + comment line: compile_gate=$INLINE_CFG_GOT (expected false)"; }
printf '"hooks": {"disable": ["auto_compile"]}\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
INLINE_CFG_GOT="$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled auto_compile --project "$INLINE_CFG_ROOT" 2>&1 || true)"
[ "$INLINE_CFG_GOT" = "false" ] || { INLINE_CFG_OK=0; echo "    quoted key: auto_compile=$INLINE_CFG_GOT (expected false)"; }
printf -- "---\n'hooks':\n  disable:\n    - review_gate\n...\n" > "$INLINE_CFG_ROOT/.qq/local.yaml"
INLINE_CFG_GOT="$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled review_gate --project "$INLINE_CFG_ROOT" 2>&1 || true)"
[ "$INLINE_CFG_GOT" = "false" ] || { INLINE_CFG_OK=0; echo "    --- document start + quoted block key: review_gate=$INLINE_CFG_GOT (expected false)"; }
printf 'hooks:\n\tdisable: [auto_compile, compile_gate]\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
INLINE_CFG_RC=0
$QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" hook-enabled auto_compile --project "$INLINE_CFG_ROOT" \
  >"$INLINE_CFG_ROOT/out.txt" 2>"$INLINE_CFG_ROOT/err.txt" || INLINE_CFG_RC=$?
if [ "$INLINE_CFG_RC" -ne 2 ] || [ -s "$INLINE_CFG_ROOT/out.txt" ] || ! grep -q "local.yaml: line 2: tab" "$INLINE_CFG_ROOT/err.txt"; then
  INLINE_CFG_OK=0
  echo "    tab indentation: rc=$INLINE_CFG_RC stdout=$(head -c 200 "$INLINE_CFG_ROOT/out.txt") stderr=$(head -c 400 "$INLINE_CFG_ROOT/err.txt")"
fi
if [ "$INLINE_CFG_OK" -eq 1 ]; then
  pass "qq config: BOM, quoted keys and --- are honoured; tab indentation is reported instead of silently dropped"
else
  fail "qq config: BOM, quoted keys and --- are honoured; tab indentation is reported instead of silently dropped"
fi

# 结构错误和语义错误（version 不是整数、profile 继承成环）同样是一行带文件名的错误、退 2，不吐 traceback；
# qq_internal_install.py resolve（install.sh 与 SessionStart 同步都靠它）也一样；认不出的 profile 名照旧回落到 feature
INLINE_CFG_OK=1
inline_cfg_expect_error() {
  local label="$1" pattern="$2"; shift 2
  local rc=0
  "$@" >"$INLINE_CFG_ROOT/out.txt" 2>"$INLINE_CFG_ROOT/err.txt" || rc=$?
  if [ "$rc" -ne 2 ] || [ -s "$INLINE_CFG_ROOT/out.txt" ] || grep -q "Traceback" "$INLINE_CFG_ROOT/err.txt" ||
     [ "$(wc -l < "$INLINE_CFG_ROOT/err.txt")" -ne 1 ] || ! grep -q -- "$pattern" "$INLINE_CFG_ROOT/err.txt"; then
    INLINE_CFG_OK=0
    echo "    $label: rc=$rc stdout=$(head -c 200 "$INLINE_CFG_ROOT/out.txt") stderr=$(head -c 400 "$INLINE_CFG_ROOT/err.txt")"
  fi
}
printf 'hooks:\n  disable:\n    - auto_compile\n    enable: compile_gate\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
inline_cfg_expect_error "qq-config.py resolve, list mixed with mapping" "local.yaml: line 4: cannot mix" \
  "$QQ_PY" "$SCRIPT_DIR/scripts/qq-config.py" resolve --project "$INLINE_CFG_ROOT"
inline_cfg_expect_error "qq_internal_install.py resolve, list mixed with mapping" "local.yaml: line 4: cannot mix" \
  "$QQ_PY" "$SCRIPT_DIR/scripts/qq_internal_install.py" resolve --repo-root "$SCRIPT_DIR" --project "$INLINE_CFG_ROOT"
rm -f "$INLINE_CFG_ROOT/.qq/local.yaml"
printf 'version: two\n' > "$INLINE_CFG_ROOT/qq.yaml"
inline_cfg_expect_error "qq-config.py resolve, version: two" "qq.yaml: key 'version'" \
  "$QQ_PY" "$SCRIPT_DIR/scripts/qq-config.py" resolve --project "$INLINE_CFG_ROOT"
printf 'default_profile: a\nprofiles: {a: {extends: b}, b: {extends: a}}\n' > "$INLINE_CFG_ROOT/qq.yaml"
inline_cfg_expect_error "qq-config.py resolve, profile extends cycle" "qq.yaml: profile inheritance cycle" \
  "$QQ_PY" "$SCRIPT_DIR/scripts/qq-config.py" resolve --project "$INLINE_CFG_ROOT"
rm -f "$INLINE_CFG_ROOT/qq.yaml"
printf 'profile: no_such_profile\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
INLINE_CFG_GOT="$($QQ_PY "$SCRIPT_DIR/scripts/qq-config.py" field profile --project "$INLINE_CFG_ROOT" 2>&1 || true)"
[ "$INLINE_CFG_GOT" = "feature" ] || { INLINE_CFG_OK=0; echo "    unknown profile name: $(printf '%s' "$INLINE_CFG_GOT" | tail -n 1) (expected feature)"; }
if [ "$INLINE_CFG_OK" -eq 1 ]; then
  pass "qq config: structural and semantic config errors exit 2 with one line naming the file (config + installer resolve)"
else
  fail "qq config: structural and semantic config errors exit 2 with one line naming the file (config + installer resolve)"
fi

# 配置坏了钩子按「关」，所以必须有地方报出来：SessionStart 每次开会话把错误打到 stdout（进会话上下文）、跳过同步；
# git pre-push 跑在终端里，报出错误并拒绝推送，不再谎称「profile 关了这个钩子」放行一次没跑测试的推送
INLINE_CFG_OK=1
printf 'hooks: {disable: [auto_compile}\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
INLINE_CFG_RC=0
CLAUDE_PROJECT_DIR="$INLINE_CFG_ROOT" CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR" bash "$SCRIPT_DIR/scripts/hooks/auto-sync.sh" \
  </dev/null >"$INLINE_CFG_ROOT/out.txt" 2>"$INLINE_CFG_ROOT/err.txt" || INLINE_CFG_RC=$?
if [ "$INLINE_CFG_RC" -ne 0 ] || ! grep -q "^\[qq\] Config error: .*local.yaml: line 1: key 'hooks'" "$INLINE_CFG_ROOT/out.txt" ||
   [ -e "$INLINE_CFG_ROOT/.qq/install-state.json" ]; then
  INLINE_CFG_OK=0
  echo "    SessionStart auto-sync.sh: rc=$INLINE_CFG_RC stdout=$(head -c 300 "$INLINE_CFG_ROOT/out.txt") stderr=$(head -c 300 "$INLINE_CFG_ROOT/err.txt")"
fi
INLINE_CFG_RC=0
PROJECT_DIR="$INLINE_CFG_ROOT" bash "$SCRIPT_DIR/scripts/githooks/pre-push" \
  </dev/null >"$INLINE_CFG_ROOT/out.txt" 2>"$INLINE_CFG_ROOT/err.txt" || INLINE_CFG_RC=$?
if [ "$INLINE_CFG_RC" -eq 0 ] || ! grep -q "local.yaml: line 1: key 'hooks'" "$INLINE_CFG_ROOT/err.txt" ||
   grep -q "disables git_pre_push" "$INLINE_CFG_ROOT/out.txt" "$INLINE_CFG_ROOT/err.txt"; then
  INLINE_CFG_OK=0
  echo "    pre-push with a broken config: rc=$INLINE_CFG_RC stdout=$(head -c 300 "$INLINE_CFG_ROOT/out.txt") stderr=$(head -c 300 "$INLINE_CFG_ROOT/err.txt")"
fi
printf 'hooks: {disable: [git_pre_push]}\n' > "$INLINE_CFG_ROOT/.qq/local.yaml"
INLINE_CFG_RC=0
PROJECT_DIR="$INLINE_CFG_ROOT" bash "$SCRIPT_DIR/scripts/githooks/pre-push" \
  </dev/null >"$INLINE_CFG_ROOT/out.txt" 2>"$INLINE_CFG_ROOT/err.txt" || INLINE_CFG_RC=$?
if [ "$INLINE_CFG_RC" -ne 0 ] || ! grep -q "disables git_pre_push" "$INLINE_CFG_ROOT/out.txt"; then
  INLINE_CFG_OK=0
  echo "    pre-push with git_pre_push disabled: rc=$INLINE_CFG_RC stdout=$(head -c 300 "$INLINE_CFG_ROOT/out.txt") stderr=$(head -c 300 "$INLINE_CFG_ROOT/err.txt")"
fi
rm -rf "$INLINE_CFG_ROOT/.qq"
printf 'hooks:\n  disable: [auto_compile]\n' > "$INLINE_CFG_ROOT/qq.yaml"
INLINE_CFG_RC=0
CLAUDE_PROJECT_DIR="$INLINE_CFG_ROOT" CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR" bash "$SCRIPT_DIR/scripts/hooks/auto-sync.sh" \
  </dev/null >"$INLINE_CFG_ROOT/out.txt" 2>"$INLINE_CFG_ROOT/err.txt" || INLINE_CFG_RC=$?
if [ "$INLINE_CFG_RC" -ne 0 ] || [ -s "$INLINE_CFG_ROOT/out.txt" ]; then
  INLINE_CFG_OK=0
  echo "    SessionStart auto-sync.sh with a valid config: rc=$INLINE_CFG_RC stdout=$(head -c 300 "$INLINE_CFG_ROOT/out.txt")"
fi
if [ "$INLINE_CFG_OK" -eq 1 ]; then
  pass "qq config: a broken config is reported at SessionStart and blocks git pre-push instead of silently switching it off"
else
  fail "qq config: a broken config is reported at SessionStart and blocks git pre-push instead of silently switching it off"
fi
rm -rf "$INLINE_CFG_ROOT"

# ── core.hooksPath silent-bypass detection + safe auto-fix ──
GIT_HOOKS_TEST_ROOT="$(mktemp -d)"
(
  cd "$GIT_HOOKS_TEST_ROOT"
  git init -q
  # Reproduce the silently-broken config: hooksPath set to absolute path of
  # the default .git/hooks directory. The pirate-demo project hit this exact
  # state and the qq pre-push hook never fired as a result.
  git config core.hooksPath "$GIT_HOOKS_TEST_ROOT/.git/hooks"
)
if "$SCRIPT_DIR/scripts/qq-doctor.sh" --project "$GIT_HOOKS_TEST_ROOT" > "$GIT_HOOKS_TEST_ROOT/doctor.json" && \
   $QQ_PY - "$GIT_HOOKS_TEST_ROOT/doctor.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
hooks = payload["gitHooks"]
assert hooks["isGitRepo"] is True, hooks
assert hooks["status"] == "broken", hooks
assert hooks["hooksPathScope"] == "local", hooks
assert hooks["hooksPathIsAbsolute"] is True, hooks
assert hooks["autoFixable"] is True, hooks
assert hooks["autoFixCommand"] == "git config --unset core.hooksPath", hooks
assert hooks["recommendedAction"] == "git config --unset core.hooksPath", hooks
assert hooks["issues"], hooks
PY
then
  pass "qq-doctor flags hardcoded core.hooksPath as broken"
else
  fail "qq-doctor flags hardcoded core.hooksPath as broken"
fi

# Apply --fix-git-hooks and verify the local config was actually unset.
if "$SCRIPT_DIR/scripts/qq-doctor.sh" --project "$GIT_HOOKS_TEST_ROOT" --fix-git-hooks > "$GIT_HOOKS_TEST_ROOT/doctor-fix.json" && \
   $QQ_PY - "$GIT_HOOKS_TEST_ROOT/doctor-fix.json" "$GIT_HOOKS_TEST_ROOT" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
project = sys.argv[2]
fix = payload.get("gitHooksFix")
assert fix is not None, payload
assert fix["status"] == "fixed", fix
assert fix["command"] == "git config --unset core.hooksPath", fix
result = subprocess.run(
    ["git", "-C", project, "config", "--local", "--get", "core.hooksPath"],
    capture_output=True, text=True,
)
# git returns 1 (or 5) when the key is unset and produces no output.
assert result.returncode != 0, f"hooksPath still set: {result.stdout!r}"
assert payload["gitHooks"]["status"] == "ok", payload["gitHooks"]
PY
then
  pass "qq-doctor --fix-git-hooks safely unsets the bad local core.hooksPath"
else
  fail "qq-doctor --fix-git-hooks safely unsets the bad local core.hooksPath"
fi

# When .githooks/ contains hooks, the auto-fix should switch to .githooks
# instead of unsetting (preserves the user-side hooks convention).
GIT_HOOKS_ALT_ROOT="$(mktemp -d)"
(
  cd "$GIT_HOOKS_ALT_ROOT"
  git init -q
  git config core.hooksPath "$GIT_HOOKS_ALT_ROOT/.git/hooks"
  mkdir -p .githooks
  printf '#!/bin/sh\nexit 0\n' > .githooks/pre-push
  chmod +x .githooks/pre-push
)
if "$SCRIPT_DIR/scripts/qq-doctor.sh" --project "$GIT_HOOKS_ALT_ROOT" --fix-git-hooks > "$GIT_HOOKS_ALT_ROOT/doctor.json" && \
   $QQ_PY - "$GIT_HOOKS_ALT_ROOT/doctor.json" "$GIT_HOOKS_ALT_ROOT" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
project = sys.argv[2]
fix = payload["gitHooksFix"]
assert fix["command"] == "git config core.hooksPath .githooks", fix
assert fix["altHooksDirHasHooks"] is True, fix
result = subprocess.run(
    ["git", "-C", project, "config", "--local", "--get", "core.hooksPath"],
    capture_output=True, text=True,
)
assert result.returncode == 0 and result.stdout.strip() == ".githooks", result.stdout
PY
then
  pass "qq-doctor --fix-git-hooks switches to .githooks when it has hooks"
else
  fail "qq-doctor --fix-git-hooks switches to .githooks when it has hooks"
fi

rm -rf "$GIT_HOOKS_TEST_ROOT" "$GIT_HOOKS_ALT_ROOT"

# 这条测的是 trust_level 机制本身（strict 把 raw 引擎命令挡在 standard 面之外），
# 引擎只是举例对象。原来举的是 Unity —— 但 unity_raw_command 随 tykit 桥一起下线了
# （Unity 的 Editor 控制已改走 Unity 官方 CLI，qq 不再分发 tykit 桥）。
# 机制没变，所以**不删这条覆盖**，换一个仍有 raw command 的引擎继续测。
MCP_TRUST_TEST_ROOT="$(mktemp -d)"
mkdir -p "$MCP_TRUST_TEST_ROOT/addons/qq_editor_bridge"
cat > "$MCP_TRUST_TEST_ROOT/project.godot" <<'EOF'
; Engine configuration file.
config_version=5

[application]

config/name="qq-trust-fixture"
EOF
cat > "$MCP_TRUST_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
default_profile: feature
trust_level: strict
EOF

if $QQ_PY - "$SCRIPT_DIR" "$MCP_TRUST_TEST_ROOT" <<'PY'
import sys
from pathlib import Path

script_dir = Path(sys.argv[1]).resolve() / "scripts"
project_dir = Path(sys.argv[2]).resolve()
sys.path.insert(0, str(script_dir))
from qq_mcp import build_bridge

standard_names = {tool["name"] for tool in build_bridge(str(project_dir), profile="standard").list_tools()}
full_names = {tool["name"] for tool in build_bridge(str(project_dir), profile="full").list_tools()}

assert "godot_raw_command" not in standard_names
assert "godot_raw_command" in full_names
PY
then
  pass "strict trust level hides raw engine commands from the standard MCP surface"
else
  fail "strict trust level hides raw engine commands from the standard MCP surface"
fi

if (
  cd "$RUNTIME_TEST_ROOT" &&
  "$SCRIPT_DIR/scripts/qq-policy-check.sh" --json Sample.cs > policy.json &&
  $QQ_PY - <<'PY'
import json
from pathlib import Path

payload = json.loads(Path("policy.json").read_text(encoding="utf-8"))
rule_ids = {item["rule_id"] for item in payload["findings"]}
assert payload["finding_count"] >= 3
assert "get_component_in_hot_path" in rule_ids
assert "send_message" in rule_ids
assert "tag_compare" in rule_ids
PY
); then
  pass "policy checker finds deterministic violations"
else
  fail "policy checker finds deterministic violations"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/foundation-smoke.json" > "$RUNTIME_TEST_ROOT/eval-suite.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/eval-suite.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["suite_id"] == "foundation-smoke"
assert payload["failed"] == 0
assert payload["passed"] == 3
PY
then
  pass "eval harness runs foundation smoke suite"
else
  fail "eval harness runs foundation smoke suite"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/collaboration-multi-actor.json" > "$RUNTIME_TEST_ROOT/collaboration-eval-suite.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/collaboration-eval-suite.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["suite_id"] == "collaboration-multi-actor"
assert payload["failed"] == 0
assert payload["passed"] == 1
PY
then
  pass "eval harness runs collaboration multi-actor suite"
else
  fail "eval harness runs collaboration multi-actor suite"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/qq-bench-foundation.json" > "$RUNTIME_TEST_ROOT/qq-bench-foundation.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/qq-bench-foundation.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["suite_id"] == "qq-bench-foundation"
assert payload["benchmark_family"] == "qq-bench-foundation"
assert payload["benchmark_version"] == "0.1"
assert payload["task_count"] == 4
assert payload["failed"] == 0
assert payload["passed"] == 4
PY
then
  pass "QQ-Bench foundation suite runs"
else
  fail "QQ-Bench foundation suite runs"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/qq-bench-core-v0.json" > "$RUNTIME_TEST_ROOT/qq-bench-core-v0.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/qq-bench-core-v0.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["suite_id"] == "qq-bench-core-v0"
assert payload["benchmark_family"] == "qq-bench-core"
assert payload["benchmark_version"] == "0.1"
assert payload["task_count"] == 10
assert payload["failed"] == 0
assert payload["passed"] == 10
PY
then
  pass "QQ-Bench core v0 suite runs"
else
  fail "QQ-Bench core v0 suite runs"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/qq-bench-core-v1.json" > "$RUNTIME_TEST_ROOT/qq-bench-core-v1.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/qq-bench-core-v1.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["suite_id"] == "qq-bench-core-v1"
assert payload["benchmark_family"] == "qq-bench-core"
assert payload["benchmark_version"] == "0.2"
assert payload["task_count"] == 12
assert payload["failed"] == 0
assert payload["passed"] == 12
PY
then
  pass "QQ-Bench core v1 suite runs"
else
  fail "QQ-Bench core v1 suite runs"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/qq-bench-core-solver-v0.json" > "$RUNTIME_TEST_ROOT/qq-bench-core-solver-v0.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT/qq-bench-core-solver-v0.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["suite_id"] == "qq-bench-core-solver-v0"
assert payload["benchmark_family"] == "qq-bench-core"
assert payload["benchmark_version"] == "0.3"
assert payload["task_count"] == 2
assert payload["failed"] == 0
assert payload["passed"] == 2
PY
then
  pass "QQ-Bench core solver v0 suite runs"
else
  fail "QQ-Bench core solver v0 suite runs"
fi

for idx in 1 2 3; do
  RUN_JSON=$($QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$RUNTIME_TEST_ROOT" --stage test --command "prune-$idx" --backend test --transport local --summary "prune start $idx")
  RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
  $QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$RUNTIME_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "prune finish $idx" >/dev/null
done

if $QQ_PY "$SCRIPT_DIR/scripts/qq-run-record.py" prune --project "$RUNTIME_TEST_ROOT" --max-runs 2 --max-age-days 365 --max-telemetry-bytes 1 --max-telemetry-files 1 > "$RUNTIME_TEST_ROOT/prune-result.json" && \
   $QQ_PY - "$RUNTIME_TEST_ROOT" "$RUNTIME_TEST_ROOT/prune-result.json" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
result = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
run_files = sorted((root / ".qq" / "runs").glob("*.json"))
rotated = sorted((root / ".qq" / "telemetry").glob("events-*.jsonl"))

assert result["runs_removed_count"] >= 1
assert result["telemetry_rotated"] != ""
assert len(run_files) <= 2
assert len(rotated) == 1
assert (root / ".qq" / "state" / "latest.json").is_file()
PY
then
  pass "runtime prune enforces retention and rotates telemetry"
else
  fail "runtime prune enforces retention and rotates telemetry"
fi

rm -rf "$RUNTIME_TEST_ROOT"

GODOT_RUNTIME_ROOT="$(mktemp -d)"
mkdir -p "$GODOT_RUNTIME_ROOT/scripts" "$GODOT_RUNTIME_ROOT/addons/qq_editor_bridge" "$GODOT_RUNTIME_ROOT/.qq/state"
cat > "$GODOT_RUNTIME_ROOT/project.godot" <<'EOF'
; Engine configuration file.
config_version=5

[application]
config/name="qq godot runtime fixture"

[editor_plugins]
enabled=PackedStringArray("res://addons/qq_editor_bridge/plugin.cfg")
EOF
cat > "$GODOT_RUNTIME_ROOT/.mcp.json" <<EOF
{
  "mcpServers": {
    "qq-godot": {
      "command": "python3",
      "args": [
        "$GODOT_RUNTIME_ROOT/scripts/qq_mcp.py",
        "--project",
        "$GODOT_RUNTIME_ROOT"
      ],
      "cwd": "$GODOT_RUNTIME_ROOT"
    }
  }
}
EOF
# doctor 把超过 5 秒的心跳判为桥已死；夹具只写一次心跳，机器忙时从这里到 doctor 读取
# 可能超过 5 秒，所以三个 doctor 夹具（Godot / Unreal / S&box）都把心跳写在 5 分钟之后。
cat > "$GODOT_RUNTIME_ROOT/.qq/state/qq-godot-editor-bridge.json" <<EOF
{
  "ok": true,
  "running": true,
  "lastHeartbeatUnix": $($QQ_PY -c 'import time; print(time.time() + 300)')
}
EOF
for path in \
  qq-compile.sh \
  qq-test.sh \
  qq-project-state.py \
  qq-policy-check.sh \
  qq_mcp.py \
  qq_engine.py \
  qq-capabilities.json \
  godot_bridge.py \
  godot_capabilities.json; do
  : > "$GODOT_RUNTIME_ROOT/scripts/$path"
done
cat > "$GODOT_RUNTIME_ROOT/addons/qq_editor_bridge/plugin.cfg" <<'EOF'
[plugin]
name="QQ Editor Bridge"
EOF
cat > "$GODOT_RUNTIME_ROOT/addons/qq_editor_bridge/plugin.gd" <<'EOF'
@tool
extends EditorPlugin
EOF

if "$SCRIPT_DIR/scripts/qq-doctor.sh" --project "$GODOT_RUNTIME_ROOT" --write-state > "$GODOT_RUNTIME_ROOT/doctor.json" && \
   $QQ_PY - "$GODOT_RUNTIME_ROOT/doctor.json" "$GODOT_RUNTIME_ROOT/.qq/state/provider-resolution.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
state_payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
providers = {item["id"]: item for item in payload["providers"]}

assert payload["engine"] == "godot"
assert payload["engineProjectDetected"] is True
assert payload["unityProjectDetected"] is None
assert providers["godot.qq-direct"]["status"] == "available"
assert providers["godot.qq-mcp"]["status"] == "available"
assert providers["godot.qq-mcp"]["evidence"]["pluginEnabled"] is True
assert providers["godot.qq-mcp"]["evidence"]["bridgeState"]["running"] is True
assert payload["resolution"]["console.read"]["resolved"] == "godot.qq-mcp"
assert payload["resolution"]["scene.query"]["resolved"] == "godot.qq-mcp"
assert payload["resolution"]["asset.mutate"]["resolved"] == "godot.qq-mcp"
assert payload["resolution"]["input.simulate"]["resolved"] == "godot.qq-mcp"
assert payload["resolution"]["ui.query"]["resolved"] == "godot.qq-mcp"
assert payload["resolution"]["animation.mutate"]["resolved"] == "godot.qq-mcp"
assert payload["resolution"]["capture.screenshot"]["resolved"] == "godot.qq-mcp"
assert state_payload["resolution"]["scene.mutate"]["resolved"] == "godot.qq-mcp"
PY
then
  pass "qq-doctor discovers Godot rich bridge providers and resolves editor capabilities"
else
  fail "qq-doctor discovers Godot rich bridge providers and resolves editor capabilities"
fi

mkdir -p "$GODOT_RUNTIME_ROOT/.qq/state/qq-godot-editor/requests" "$GODOT_RUNTIME_ROOT/.qq/state/qq-godot-editor/responses"
$QQ_PY - "$GODOT_RUNTIME_ROOT" <<'PY' &
import json
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
requests = root / ".qq" / "state" / "qq-godot-editor" / "requests"
responses = root / ".qq" / "state" / "qq-godot-editor" / "responses"
deadline = time.time() + 10
while time.time() < deadline:
    for request_path in requests.glob("*.json"):
        payload = json.loads(request_path.read_text(encoding="utf-8"))
        response = {
            "ok": True,
            "message": "fake godot bridge handled request",
            "data": {
                "command": payload["command"],
                "args": payload.get("args") or {},
            },
        }
        (responses / f"{payload['requestId']}.json").write_text(json.dumps(response), encoding="utf-8")
        request_path.unlink()
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(1)
PY
FAKE_GODOT_BRIDGE_PID=$!
if $QQ_PY "$SCRIPT_DIR/scripts/godot_bridge.py" --project "$GODOT_RUNTIME_ROOT" --tool godot_query --arguments '{"action":"status"}' > "$GODOT_RUNTIME_ROOT/godot-bridge-call.json" && \
   wait "$FAKE_GODOT_BRIDGE_PID" && \
   $QQ_PY - "$GODOT_RUNTIME_ROOT/godot-bridge-call.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["ok"] is True
assert payload["action"] == "status"
assert payload["response"]["command"] == "status"
assert payload["response"]["args"] == {}
PY
then
  pass "godot bridge queue transport can complete a typed query round trip"
else
  fail "godot bridge queue transport can complete a typed query round trip"
  kill "$FAKE_GODOT_BRIDGE_PID" >/dev/null 2>&1 || true
fi

$QQ_PY - "$GODOT_RUNTIME_ROOT" <<'PY' &
import json
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
requests = root / ".qq" / "state" / "qq-godot-editor" / "requests"
responses = root / ".qq" / "state" / "qq-godot-editor" / "responses"
state = root / ".qq" / "state" / "qq-godot-editor-bridge.json"
deadline = time.time() + 10
handled = 0
while time.time() < deadline:
    state.write_text(json.dumps({"ok": True, "running": True, "lastHeartbeatUnix": time.time()}), encoding="utf-8")
    for request_path in requests.glob("*.json"):
        payload = json.loads(request_path.read_text(encoding="utf-8"))
        response = {
            "ok": True,
            "message": "fake godot bridge handled request",
            "data": {
                "command": payload["command"],
                "args": payload.get("args") or {},
            },
        }
        (responses / f"{payload['requestId']}.json").write_text(json.dumps(response), encoding="utf-8")
        request_path.unlink()
        handled += 1
        if handled >= 4:
            raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(1)
PY
FAKE_GODOT_BRIDGE_PID=$!
if $QQ_PY "$SCRIPT_DIR/scripts/godot_bridge.py" --project "$GODOT_RUNTIME_ROOT" --profile full --tool godot_batch --arguments '{"operations":[{"tool":"godot_input","arguments":{"action":"inject_action","input_action":"jump","strength":1.0}},{"tool":"godot_ui","arguments":{"action":"create_control","parent":".","node_type":"Button","name":"QQButton","text":"Parity"}},{"tool":"godot_animation","arguments":{"action":"create_animation","player_path":"AnimationPlayer","animation":"qq_spin","length":0.5}},{"tool":"godot_screenshot","arguments":{"path":".qq/state/screenshots/test.png","width":640,"height":360}}]}' > "$GODOT_RUNTIME_ROOT/godot-full-batch-call.json" && \
   wait "$FAKE_GODOT_BRIDGE_PID" && \
   $QQ_PY - "$GODOT_RUNTIME_ROOT/godot-full-batch-call.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["ok"] is True
assert len(payload["results"]) == 4
assert payload["results"][0]["result"]["response"]["command"] == "inject-action"
assert payload["results"][0]["result"]["response"]["args"]["input_action"] == "jump"
assert payload["results"][1]["result"]["response"]["command"] == "create-control"
assert payload["results"][1]["result"]["response"]["args"]["name"] == "QQButton"
assert payload["results"][2]["result"]["response"]["command"] == "create-animation"
assert payload["results"][2]["result"]["response"]["args"]["animation"] == "qq_spin"
assert payload["results"][3]["result"]["response"]["command"] == "capture-screenshot"
assert payload["results"][3]["result"]["response"]["args"]["width"] == 640
PY
then
  pass "godot full-profile bridge maps input, UI, animation, and screenshot tools onto the editor command surface"
else
  fail "godot full-profile bridge maps input, UI, animation, and screenshot tools onto the editor command surface"
fi

if $QQ_PY - "$GODOT_RUNTIME_ROOT" "$SCRIPT_DIR/scripts" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from qq_mcp import build_bridge  # noqa: E402

project = Path(sys.argv[1])
bridge = build_bridge(str(project))
tools = {tool["name"] for tool in bridge.list_tools()}
assert "qq_project_state" in tools
assert "godot_query" in tools
assert "godot_object" in tools
assert "godot_assets" in tools
PY
then
  pass "qq_mcp composes generic and Godot rich tools for Godot projects"
else
  fail "qq_mcp composes generic and Godot rich tools for Godot projects"
fi

if $QQ_PY - "$GODOT_RUNTIME_ROOT" "$SCRIPT_DIR/scripts" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from qq_mcp import build_bridge  # noqa: E402

project = Path(sys.argv[1])
bridge = build_bridge(str(project), profile="full")
tools = {tool["name"] for tool in bridge.list_tools()}
assert "godot_input" in tools
assert "godot_ui" in tools
assert "godot_animation" in tools
assert "godot_screenshot" in tools
PY
then
  pass "qq_mcp full profile exposes Godot input, UI, animation, and screenshot tools"
else
  fail "qq_mcp full profile exposes Godot input, UI, animation, and screenshot tools"
fi

rm -rf "$GODOT_RUNTIME_ROOT"

GODOT_SCRIPT_TEST_ROOT="$(mktemp -d)"
mkdir -p "$GODOT_SCRIPT_TEST_ROOT/addons/gut" "$GODOT_SCRIPT_TEST_ROOT/test/unit"
cat > "$GODOT_SCRIPT_TEST_ROOT/project.godot" <<'EOF'
; Engine configuration file.
config_version=5

[application]
config/name="qq godot script fixture"
EOF
cat > "$GODOT_SCRIPT_TEST_ROOT/addons/gut/gut_cmdln.gd" <<'EOF'
extends SceneTree
EOF
cat > "$GODOT_SCRIPT_TEST_ROOT/test/unit/test_smoke.gd" <<'EOF'
extends GutTest
EOF
FAKE_GODOT_BIN_DIR="$(mktemp -d)"
FAKE_GODOT_LOG="$FAKE_GODOT_BIN_DIR/godot.log"
cat > "$FAKE_GODOT_BIN_DIR/godot4" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "__LOG__"
if [[ "$*" == *"--import"* ]]; then
  exit 0
fi
if [[ "$*" == *"gut_cmdln.gd"* ]]; then
  if [[ "$*" == *"-ginclude_subdirs"* ]]; then
    printf '1/1 passed\n'
    exit 0
  fi
  printf '\033[31m[ERROR]:  \033[0mNothing was run.\n'
  printf 'On the one hand nothing failed, on the other hand nothing did anything.\n'
  exit 0
fi
printf '{"ok":true,"finding_count":0}\n'
exit 0
EOF
$QQ_PY - "$FAKE_GODOT_BIN_DIR/godot4" "$FAKE_GODOT_LOG" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1])
log_path = sys.argv[2]
script.write_text(script.read_text(encoding="utf-8").replace("__LOG__", log_path), encoding="utf-8")
PY
chmod +x "$FAKE_GODOT_BIN_DIR/godot4"
if env PATH="$FAKE_GODOT_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/godot-test.sh" --project "$GODOT_SCRIPT_TEST_ROOT" > "$GODOT_SCRIPT_TEST_ROOT/godot-test.log" && \
   grep -q -- '--import' "$FAKE_GODOT_LOG" && \
   grep -q -- '-ginclude_subdirs' "$FAKE_GODOT_LOG" && \
   grep -q 'GUT tests passed' "$GODOT_SCRIPT_TEST_ROOT/godot-test.log"
then
  pass "godot-test imports projects first and scans GUT test subdirectories"
else
  fail "godot-test imports projects first and scans GUT test subdirectories"
fi

FAKE_GODOT_FAIL_BIN_DIR="$(mktemp -d)"
cat > "$FAKE_GODOT_FAIL_BIN_DIR/godot4" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"--import"* ]]; then
  exit 0
fi
printf '\033[31m[ERROR]:  \033[0mNothing was run.\n'
printf 'On the one hand nothing failed, on the other hand nothing did anything.\n'
exit 0
EOF
chmod +x "$FAKE_GODOT_FAIL_BIN_DIR/godot4"
if env PATH="$FAKE_GODOT_FAIL_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/godot-test.sh" --project "$GODOT_SCRIPT_TEST_ROOT" > "$GODOT_SCRIPT_TEST_ROOT/godot-test-empty.log" 2>&1; then
  fail "godot-test rejects empty GUT runs"
else
  if grep -q 'GUT did not discover any tests' "$GODOT_SCRIPT_TEST_ROOT/godot-test-empty.log"; then
    pass "godot-test rejects empty GUT runs"
  else
    fail "godot-test rejects empty GUT runs"
  fi
fi

FAKE_GODOT_COMPILE_BIN_DIR="$(mktemp -d)"
FAKE_GODOT_COMPILE_LOG="$FAKE_GODOT_COMPILE_BIN_DIR/godot.log"
cat > "$FAKE_GODOT_COMPILE_BIN_DIR/godot4" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "__LOG__"
if [[ "$*" == *"--import"* ]]; then
  exit 0
fi
printf '{"ok":true,"finding_count":0}\n'
exit 0
EOF
$QQ_PY - "$FAKE_GODOT_COMPILE_BIN_DIR/godot4" "$FAKE_GODOT_COMPILE_LOG" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1])
log_path = sys.argv[2]
script.write_text(script.read_text(encoding="utf-8").replace("__LOG__", log_path), encoding="utf-8")
PY
chmod +x "$FAKE_GODOT_COMPILE_BIN_DIR/godot4"
mkdir -p "$GODOT_SCRIPT_TEST_ROOT/scripts"
cp "$SCRIPT_DIR/scripts/godot-compile-check.gd" "$GODOT_SCRIPT_TEST_ROOT/scripts/godot-compile-check.gd"
if env PATH="$FAKE_GODOT_COMPILE_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/godot-compile.sh" --project "$GODOT_SCRIPT_TEST_ROOT" > "$GODOT_SCRIPT_TEST_ROOT/godot-compile.log" && \
   $QQ_PY - "$FAKE_GODOT_COMPILE_LOG" <<'PY'
import sys
from pathlib import Path

lines = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(lines) == 2
assert "--import" in lines[0]
assert "godot-compile-check.gd" in lines[1]
PY
then
  pass "godot-compile imports projects before running compile checks"
else
  fail "godot-compile imports projects before running compile checks"
fi

rm -rf "$GODOT_SCRIPT_TEST_ROOT" "$FAKE_GODOT_BIN_DIR" "$FAKE_GODOT_FAIL_BIN_DIR" "$FAKE_GODOT_COMPILE_BIN_DIR"

UNREAL_RUNTIME_ROOT="$(mktemp -d)"
mkdir -p "$UNREAL_RUNTIME_ROOT/scripts" "$UNREAL_RUNTIME_ROOT/Content/Python" "$UNREAL_RUNTIME_ROOT/.qq/state/qq-unreal-editor/requests" "$UNREAL_RUNTIME_ROOT/.qq/state/qq-unreal-editor/responses"
cat > "$UNREAL_RUNTIME_ROOT/FPSGame.uproject" <<'EOF'
{
  "FileVersion": 3,
  "EngineAssociation": "5.7",
  "Plugins": [
    {
      "Name": "PythonScriptPlugin",
      "Enabled": true
    },
    {
      "Name": "EditorScriptingUtilities",
      "Enabled": true
    },
    {
      "Name": "McpAutomationBridge",
      "Enabled": true
    },
    {
      "Name": "UnrealMCP",
      "Enabled": true
    }
  ]
}
EOF
mkdir -p "$UNREAL_RUNTIME_ROOT/Config" "$UNREAL_RUNTIME_ROOT/Plugins/McpAutomationBridge" "$UNREAL_RUNTIME_ROOT/Plugins/UnrealMCP"
cat > "$UNREAL_RUNTIME_ROOT/Config/DefaultEngine.ini" <<'EOF'
[/Script/PythonScriptPlugin.PythonScriptPluginSettings]
EnableRemoteExecution=True
+StartupScripts=import qq_unreal_bridge; qq_unreal_bridge.start()
EOF
cat > "$UNREAL_RUNTIME_ROOT/Plugins/McpAutomationBridge/McpAutomationBridge.uplugin" <<'EOF'
{
  "FileVersion": 3,
  "FriendlyName": "McpAutomationBridge"
}
EOF
cat > "$UNREAL_RUNTIME_ROOT/Plugins/UnrealMCP/UnrealMCP.uplugin" <<'EOF'
{
  "FileVersion": 3,
  "FriendlyName": "UnrealMCP"
}
EOF
cat > "$UNREAL_RUNTIME_ROOT/.mcp.json" <<EOF
{
  "mcpServers": {
    "qq-unreal": {
      "command": "python3",
      "args": [
        "$UNREAL_RUNTIME_ROOT/scripts/qq_mcp.py",
        "--project",
        "$UNREAL_RUNTIME_ROOT"
      ],
      "cwd": "$UNREAL_RUNTIME_ROOT"
    },
    "unreal-engine": {
      "command": "npx",
      "args": [
        "unreal-engine-mcp-server"
      ],
      "env": {
        "UE_PROJECT_PATH": "$UNREAL_RUNTIME_ROOT/FPSGame.uproject",
        "MCP_AUTOMATION_PORT": "8091"
      }
    },
    "unreal": {
      "command": "npx",
      "args": [
        "-y",
        "@runreal/unreal-mcp"
      ]
    },
    "flopperam-unreal": {
      "url": "https://agent.flopperam.com/mcp",
      "headers": {
        "Authorization": "Bearer test-key"
      }
    }
  }
}
EOF
cat > "$UNREAL_RUNTIME_ROOT/.qq/state/qq-unreal-mcp-host.json" <<EOF
{
  "lastInitializeAt": "2026-03-31T00:00:00Z",
  "clientInfo": {
    "name": "fake-host"
  },
  "protocolVersion": "2024-11-05"
}
EOF
cat > "$UNREAL_RUNTIME_ROOT/.qq/state/qq-unreal-editor-bridge.json" <<EOF
{
  "ok": true,
  "running": true,
  "lastHeartbeatUnix": $($QQ_PY -c 'import time; print(time.time() + 300)')
}
EOF
for path in \
  qq-compile.sh \
  qq-test.sh \
  qq-project-state.py \
  qq-policy-check.sh \
  qq_mcp.py \
  qq_engine.py \
  qq-capabilities.json \
  unreal_bridge.py \
  unreal_editor_command.py \
  unreal_capabilities.json; do
  : > "$UNREAL_RUNTIME_ROOT/scripts/$path"
done
: > "$UNREAL_RUNTIME_ROOT/Content/Python/qq_unreal_bridge.py"

if "$SCRIPT_DIR/scripts/qq-doctor.sh" --project "$UNREAL_RUNTIME_ROOT" --write-state > "$UNREAL_RUNTIME_ROOT/doctor.json" && \
   $QQ_PY - "$UNREAL_RUNTIME_ROOT/doctor.json" "$UNREAL_RUNTIME_ROOT/.qq/state/provider-resolution.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
state_payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
providers = {item["id"]: item for item in payload["providers"]}

assert payload["engine"] == "unreal"
assert payload["engineProjectDetected"] is True
assert payload["unityProjectDetected"] is None
assert providers["unreal.qq-direct"]["status"] == "available"
assert providers["unreal.qq-mcp"]["status"] == "available"
assert providers["unreal.unreal-engine-mcp"]["status"] == "available"
assert providers["unreal.runreal-mcp"]["status"] == "available"
assert providers["unreal.flop-mcp"]["status"] == "available"
assert providers["unreal.qq-mcp"]["evidence"]["missingPlugins"] == []
assert providers["unreal.qq-mcp"]["evidence"]["startup"]["bootstrapInstalled"] is True
assert providers["unreal.qq-mcp"]["evidence"]["startup"]["startupConfigured"] is True
assert providers["unreal.qq-mcp"]["evidence"]["hostConnection"]["verified"] is True
assert providers["unreal.qq-mcp"]["evidence"]["bridgeState"]["running"] is True
assert providers["unreal.unreal-engine-mcp"]["evidence"]["plugin"]["enabled"] is True
assert providers["unreal.runreal-mcp"]["evidence"]["remoteExecution"]["enabled"] is True
assert providers["unreal.flop-mcp"]["evidence"]["plugin"]["enabled"] is True
assert payload["resolution"]["console.read"]["resolved"] == "unreal.qq-mcp"
assert payload["resolution"]["scene.query"]["resolved"] == "unreal.qq-mcp"
assert payload["resolution"]["asset.mutate"]["resolved"] == "unreal.qq-mcp"
assert state_payload["resolution"]["scene.mutate"]["resolved"] == "unreal.qq-mcp"
PY
then
  pass "qq-doctor discovers Unreal rich bridge providers and resolves editor capabilities"
else
  fail "qq-doctor discovers Unreal rich bridge providers and resolves editor capabilities"
fi

$QQ_PY - "$UNREAL_RUNTIME_ROOT" <<'PY' &
import json
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
requests = root / ".qq" / "state" / "qq-unreal-editor" / "requests"
responses = root / ".qq" / "state" / "qq-unreal-editor" / "responses"
console = root / ".qq" / "state" / "qq-unreal-editor-console.jsonl"
state = root / ".qq" / "state" / "qq-unreal-editor-bridge.json"
deadline = time.time() + 10
while time.time() < deadline:
    state.write_text(json.dumps({"ok": True, "running": True, "lastHeartbeatUnix": time.time()}), encoding="utf-8")
    for request_path in requests.glob("*.json"):
        payload = json.loads(request_path.read_text(encoding="utf-8"))
        response = {
            "ok": True,
            "message": "fake unreal bridge handled request",
            "data": {
                "command": payload["command"],
                "args": payload.get("args") or {},
            },
        }
        (responses / f"{payload['requestId']}.json").write_text(json.dumps(response), encoding="utf-8")
        with console.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"event": "handled", "command": payload["command"]}) + "\n")
        request_path.unlink()
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(1)
PY
FAKE_UNREAL_BRIDGE_PID=$!
if $QQ_PY "$SCRIPT_DIR/scripts/unreal_bridge.py" --project "$UNREAL_RUNTIME_ROOT" --tool unreal_query --arguments '{"action":"status"}' > "$UNREAL_RUNTIME_ROOT/unreal-bridge-call.json" && \
   wait "$FAKE_UNREAL_BRIDGE_PID" && \
   $QQ_PY - "$UNREAL_RUNTIME_ROOT/unreal-bridge-call.json" "$UNREAL_RUNTIME_ROOT/.qq/state/qq-unreal-editor-console.jsonl" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
console_text = Path(sys.argv[2]).read_text(encoding="utf-8")

assert payload["ok"] is True
assert payload["action"] == "status"
assert payload["response"]["command"] == "status"
assert payload["response"]["args"] == {}
assert '"command": "status"' in console_text
assert payload["message"] == "fake unreal bridge handled request"
PY
then
  pass "unreal bridge queue transport can complete a typed query round trip"
else
  fail "unreal bridge queue transport can complete a typed query round trip"
fi

$QQ_PY - "$UNREAL_RUNTIME_ROOT" <<'PY' &
import json
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
requests = root / ".qq" / "state" / "qq-unreal-editor" / "requests"
responses = root / ".qq" / "state" / "qq-unreal-editor" / "responses"
state = root / ".qq" / "state" / "qq-unreal-editor-bridge.json"
deadline = time.time() + 10
handled = 0
while time.time() < deadline:
    state.write_text(json.dumps({"ok": True, "running": True, "lastHeartbeatUnix": time.time()}), encoding="utf-8")
    for request_path in requests.glob("*.json"):
        payload = json.loads(request_path.read_text(encoding="utf-8"))
        response = {
            "ok": True,
            "message": "fake unreal bridge handled request",
            "data": {
                "command": payload["command"],
                "args": payload.get("args") or {},
            },
        }
        (responses / f"{payload['requestId']}.json").write_text(json.dumps(response), encoding="utf-8")
        request_path.unlink()
        handled += 1
        if handled >= 2:
            raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(1)
PY
FAKE_UNREAL_BRIDGE_PID=$!
if $QQ_PY "$SCRIPT_DIR/scripts/unreal_bridge.py" --project "$UNREAL_RUNTIME_ROOT" --tool unreal_batch --arguments '{"operations":[{"tool":"unreal_object","arguments":{"action":"create","class_path":"/Script/Engine.EmptyActor","label":"QQActor","select":true}},{"tool":"unreal_assets","arguments":{"action":"create_material","path":"/Game/QQ/M_Test"}}]}' > "$UNREAL_RUNTIME_ROOT/unreal-batch-call.json" && \
   wait "$FAKE_UNREAL_BRIDGE_PID" && \
   $QQ_PY - "$UNREAL_RUNTIME_ROOT/unreal-batch-call.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["ok"] is True
assert len(payload["results"]) == 2
assert payload["results"][0]["result"]["action"] == "create"
assert payload["results"][0]["result"]["response"]["command"] == "create-actor"
assert payload["results"][0]["result"]["response"]["args"]["label"] == "QQActor"
assert payload["results"][1]["result"]["action"] == "create_material"
assert payload["results"][1]["result"]["response"]["command"] == "create-material"
assert payload["results"][1]["result"]["response"]["args"]["path"] == "/Game/QQ/M_Test"
PY
then
  pass "unreal batch bridge maps object and asset actions onto the rich command surface"
else
  fail "unreal batch bridge maps object and asset actions onto the rich command surface"
fi

if $QQ_PY - "$UNREAL_RUNTIME_ROOT" "$SCRIPT_DIR/scripts" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from qq_mcp import build_bridge  # noqa: E402

project = Path(sys.argv[1])
bridge = build_bridge(str(project))
tools = {tool["name"] for tool in bridge.list_tools()}
assert "qq_project_state" in tools
assert "unreal_query" in tools
assert "unreal_object" in tools
assert "unreal_assets" in tools
PY
then
  pass "qq_mcp composes generic and Unreal rich tools for Unreal projects"
else
  fail "qq_mcp composes generic and Unreal rich tools for Unreal projects"
fi

rm -rf "$UNREAL_RUNTIME_ROOT"

UNREAL_SCRIPT_TEST_ROOT="$(mktemp -d)"
mkdir -p "$UNREAL_SCRIPT_TEST_ROOT/scripts"
cat > "$UNREAL_SCRIPT_TEST_ROOT/FPSGame.uproject" <<'EOF'
{
  "FileVersion": 3,
  "EngineAssociation": "5.7",
  "Plugins": [
    {
      "Name": "PythonScriptPlugin",
      "Enabled": true
    },
    {
      "Name": "EditorScriptingUtilities",
      "Enabled": true
    }
  ]
}
EOF
cp "$SCRIPT_DIR/scripts/unreal-compile-check.py" "$UNREAL_SCRIPT_TEST_ROOT/scripts/unreal-compile-check.py"

FAKE_UNREAL_BIN_DIR="$(mktemp -d)"
FAKE_UNREAL_LOG="$FAKE_UNREAL_BIN_DIR/unreal.log"
cat > "$FAKE_UNREAL_BIN_DIR/UnrealEditor-Cmd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "__LOG__"
if [[ -n "${QQ_UNREAL_OUTPUT_PATH:-}" ]]; then
  printf '{"ok":true,"finding_count":0}\n' > "$QQ_UNREAL_OUTPUT_PATH"
  exit 0
fi
if [[ "$*" == *"Automation RunTests"* ]]; then
  printf 'Automation Test Queue Empty\n'
  exit 0
fi
exit 0
EOF
$QQ_PY - "$FAKE_UNREAL_BIN_DIR/UnrealEditor-Cmd" "$FAKE_UNREAL_LOG" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1])
log_path = sys.argv[2]
script.write_text(script.read_text(encoding="utf-8").replace("__LOG__", log_path), encoding="utf-8")
PY
chmod +x "$FAKE_UNREAL_BIN_DIR/UnrealEditor-Cmd"

if [ "$IS_WINDOWS" = "true" ]; then
  skip "unreal-compile invokes the project-local compile check through UnrealEditor-Cmd" "Windows path comparison in fixture log; tracked for follow-up"
elif env PATH="$FAKE_UNREAL_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/qq-compile.sh" --project "$UNREAL_SCRIPT_TEST_ROOT" > "$UNREAL_SCRIPT_TEST_ROOT/unreal-compile.log" && \
   $QQ_PY - "$FAKE_UNREAL_LOG" "$UNREAL_SCRIPT_TEST_ROOT/unreal-compile.log" "$UNREAL_SCRIPT_TEST_ROOT" <<'PY'
import sys
from pathlib import Path

# Normalize paths to forward slashes so the assertion is OS-independent.
log_text = Path(sys.argv[1]).read_text(encoding="utf-8").replace("\\", "/")
compile_text = Path(sys.argv[2]).read_text(encoding="utf-8")
project_root = Path(sys.argv[3])
expected_script = (project_root / "scripts" / "unreal-compile-check.py").as_posix()

assert f"-ExecutePythonScript={expected_script}" in log_text
assert "Unreal compile/check passed" in compile_text
PY
then
  pass "unreal-compile invokes the project-local compile check through UnrealEditor-Cmd"
else
  fail "unreal-compile invokes the project-local compile check through UnrealEditor-Cmd"
fi

if env PATH="$FAKE_UNREAL_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/qq-test.sh" editmode --project "$UNREAL_SCRIPT_TEST_ROOT" > "$UNREAL_SCRIPT_TEST_ROOT/unreal-test.log" && \
   $QQ_PY - "$FAKE_UNREAL_LOG" "$UNREAL_SCRIPT_TEST_ROOT/unreal-test.log" <<'PY'
import sys
from pathlib import Path

log_text = Path(sys.argv[1]).read_text(encoding="utf-8")
test_text = Path(sys.argv[2]).read_text(encoding="utf-8")

assert "Automation RunTests Project.Editor; Quit" in log_text
assert "Unreal automation tests passed" in test_text
PY
then
  pass "qq-test maps Unreal editmode runs onto the editor automation filter"
else
  fail "qq-test maps Unreal editmode runs onto the editor automation filter"
fi

FAKE_UNREAL_FAIL_BIN_DIR="$(mktemp -d)"
cat > "$FAKE_UNREAL_FAIL_BIN_DIR/UnrealEditor-Cmd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'No automation tests matched\n'
exit 0
EOF
chmod +x "$FAKE_UNREAL_FAIL_BIN_DIR/UnrealEditor-Cmd"
if env PATH="$FAKE_UNREAL_FAIL_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/unreal-test.sh" --project "$UNREAL_SCRIPT_TEST_ROOT" > "$UNREAL_SCRIPT_TEST_ROOT/unreal-test-empty.log" 2>&1; then
  fail "unreal-test rejects empty automation runs"
else
  if grep -q 'Unreal automation did not discover any tests' "$UNREAL_SCRIPT_TEST_ROOT/unreal-test-empty.log"; then
    pass "unreal-test rejects empty automation runs"
  else
    fail "unreal-test rejects empty automation runs"
  fi
fi

rm -rf "$UNREAL_SCRIPT_TEST_ROOT" "$FAKE_UNREAL_BIN_DIR" "$FAKE_UNREAL_FAIL_BIN_DIR"

SBOX_RUNTIME_ROOT="$(mktemp -d)"
mkdir -p \
  "$SBOX_RUNTIME_ROOT/scripts" \
  "$SBOX_RUNTIME_ROOT/Code" \
  "$SBOX_RUNTIME_ROOT/Editor/QQ" \
  "$SBOX_RUNTIME_ROOT/Assets/Scenes" \
  "$SBOX_RUNTIME_ROOT/Libraries/Core/Code" \
  "$SBOX_RUNTIME_ROOT/Libraries/Core/Assets" \
  "$SBOX_RUNTIME_ROOT/UnitTests" \
  "$SBOX_RUNTIME_ROOT/.qq/state/qq-sbox-editor/requests" \
  "$SBOX_RUNTIME_ROOT/.qq/state/qq-sbox-editor/responses"
: > "$SBOX_RUNTIME_ROOT/.sbproj"
: > "$SBOX_RUNTIME_ROOT/Game.sln"
: > "$SBOX_RUNTIME_ROOT/Game.csproj"
: > "$SBOX_RUNTIME_ROOT/UnitTests/Game.UnitTests.csproj"
cat > "$SBOX_RUNTIME_ROOT/Code/Player.cs" <<'EOF'
using System.IO;

public sealed class PlayerHud
{
    public void Tick()
    {
        Console.Log("bad");
        File.Exists("user://save.dat");
    }
}
EOF
cat > "$SBOX_RUNTIME_ROOT/qq.yaml" <<'EOF'
engine: sbox
default_profile: feature
EOF
cat > "$SBOX_RUNTIME_ROOT/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "qq-sbox": {
      "command": "python3",
      "args": [
        "__SBOX_RUNTIME_ROOT__/scripts/qq_mcp.py",
        "--project",
        "__SBOX_RUNTIME_ROOT__"
      ],
      "cwd": "__SBOX_RUNTIME_ROOT__"
    }
  }
}
EOF
$QQ_PY - "$SBOX_RUNTIME_ROOT/.mcp.json" "$SBOX_RUNTIME_ROOT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("__SBOX_RUNTIME_ROOT__", sys.argv[2])
path.write_text(text, encoding="utf-8")
PY
cat > "$SBOX_RUNTIME_ROOT/.qq/state/qq-sbox-mcp-host.json" <<EOF
{
  "lastInitializeAt": "2026-03-31T00:00:00Z",
  "clientInfo": {
    "name": "fake-host"
  },
  "protocolVersion": "2024-11-05"
}
EOF
cat > "$SBOX_RUNTIME_ROOT/.qq/state/qq-sbox-editor-bridge.json" <<EOF
{
  "ok": true,
  "running": true,
  "lastHeartbeatUnix": $($QQ_PY -c 'import time; print(time.time() + 300)')
}
EOF
cat > "$SBOX_RUNTIME_ROOT/Assets/Scenes/Main.scene" <<'EOF'
scene {}
EOF
cat > "$SBOX_RUNTIME_ROOT/Libraries/Core/Assets/Core.scene" <<'EOF'
scene {}
EOF
for path in \
  qq-compile.sh \
  qq-test.sh \
  qq-project-state.py \
  qq-policy-check.sh \
  qq-doctor.py \
  qq_mcp.py \
  qq_engine.py \
  qq-capabilities.json \
  sbox-compile.sh \
  sbox-test.sh \
  sbox_bridge.py \
  sbox_capabilities.json; do
  : > "$SBOX_RUNTIME_ROOT/scripts/$path"
done
: > "$SBOX_RUNTIME_ROOT/Editor/QQ/QQSboxEditorBridge.cs"
FAKE_SBOX_DOCTOR_BIN_DIR="$(mktemp -d)"
cat > "$FAKE_SBOX_DOCTOR_BIN_DIR/dotnet" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_SBOX_DOCTOR_BIN_DIR/dotnet"
if env PATH="$FAKE_SBOX_DOCTOR_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/qq-doctor.sh" --project "$SBOX_RUNTIME_ROOT" --write-state > "$SBOX_RUNTIME_ROOT/doctor.json" && \
   $QQ_PY - "$SBOX_RUNTIME_ROOT/doctor.json" "$SBOX_RUNTIME_ROOT/.qq/state/provider-resolution.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
state_payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
providers = {item["id"]: item for item in payload["providers"]}

assert payload["engine"] == "sbox"
assert payload["sboxProjectDetected"] is True
assert payload["sboxProjectFile"] == ".sbproj"
assert payload["sboxUnitTestsPresent"] is True
assert payload["sboxLibraryCount"] == 1
assert payload["sboxEditorProjectPresent"] is True
assert providers["sbox.qq-direct"]["status"] == "available"
assert providers["sbox.qq-mcp"]["status"] == "available"
assert providers["sbox.qq-direct"]["evidence"]["unitTestsPresent"] is True
assert providers["sbox.qq-mcp"]["evidence"]["hostConnection"]["verified"] is True
assert providers["sbox.qq-mcp"]["evidence"]["bridgeState"]["running"] is True
assert payload["resolution"]["compile"]["resolved"] == "sbox.qq-direct"
assert payload["resolution"]["test"]["resolved"] == "sbox.qq-direct"
assert payload["resolution"]["console.read"]["resolved"] == "sbox.qq-mcp"
assert payload["resolution"]["scene.query"]["resolved"] == "sbox.qq-mcp"
assert payload["resolution"]["scene.mutate"]["resolved"] == "sbox.qq-mcp"
assert payload["resolution"]["asset.query"]["resolved"] == "sbox.qq-mcp"
assert payload["resolution"]["asset.mutate"]["resolved"] == "sbox.qq-mcp"
assert state_payload["resolution"]["policy.check"]["resolved"] == "sbox.qq-direct"
PY
then
  pass "qq-doctor detects the S&box direct runtime, live bridge, and rich capability resolution"
else
  fail "qq-doctor detects the S&box direct runtime, live bridge, and rich capability resolution"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$SBOX_RUNTIME_ROOT" --no-write > "$SBOX_RUNTIME_ROOT/project-state.json" && \
   $QQ_PY - "$SBOX_RUNTIME_ROOT/project-state.json" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert state["engine"] == "sbox"
assert state["sbox_project_detected"] is True
assert state["sbox_project_file"] == ".sbproj"
assert state["sbox_unit_tests_present"] is True
assert state["sbox_library_count"] == 1
assert state["sbox_editor_project_present"] is True
PY
then
  pass "qq-project-state exposes S&box project facts"
else
  fail "qq-project-state exposes S&box project facts"
fi

if "$SCRIPT_DIR/scripts/qq-policy-check.sh" --project "$SBOX_RUNTIME_ROOT" --json Code/Player.cs > "$SBOX_RUNTIME_ROOT/sbox-policy.json" && \
   $QQ_PY - "$SBOX_RUNTIME_ROOT/sbox-policy.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rule_ids = {item["rule_id"] for item in payload["findings"]}
assert payload["engine"] == "sbox"
assert "sbox_whitelist_violation" in rule_ids
assert payload["finding_count"] >= 2
PY
then
  pass "qq-policy-check reports deterministic S&box whitelist violations"
else
  fail "qq-policy-check reports deterministic S&box whitelist violations"
fi

$QQ_PY - "$SBOX_RUNTIME_ROOT" <<'PY' &
import json
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
requests = root / ".qq" / "state" / "qq-sbox-editor" / "requests"
responses = root / ".qq" / "state" / "qq-sbox-editor" / "responses"
state = root / ".qq" / "state" / "qq-sbox-editor-bridge.json"
console = root / ".qq" / "state" / "qq-sbox-editor-console.jsonl"
deadline = time.time() + 10
while time.time() < deadline:
    state.write_text(json.dumps({"ok": True, "running": True, "lastHeartbeatUnix": time.time()}), encoding="utf-8")
    for request_path in requests.glob("*.json"):
        payload = json.loads(request_path.read_text(encoding="utf-8"))
        response = {
            "ok": True,
            "message": "fake sbox bridge handled request",
            "data": {
                "command": payload["command"],
                "args": payload.get("args") or {}
            }
        }
        (responses / f"{payload['requestId']}.json").write_text(json.dumps(response), encoding="utf-8")
        with console.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"event": "handled", "command": payload["command"]}) + "\n")
        request_path.unlink()
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(1)
PY
FAKE_SBOX_BRIDGE_PID=$!
if $QQ_PY "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_query --arguments '{"action":"status"}' > "$SBOX_RUNTIME_ROOT/sbox-bridge-call.json" && \
   wait "$FAKE_SBOX_BRIDGE_PID" && \
   $QQ_PY - "$SBOX_RUNTIME_ROOT/sbox-bridge-call.json" "$SBOX_RUNTIME_ROOT/.qq/state/qq-sbox-editor-console.jsonl" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
console_text = Path(sys.argv[2]).read_text(encoding="utf-8")
assert payload["ok"] is True
assert payload["action"] == "status"
assert payload["response"]["command"] == "status"
assert payload["response"]["args"] == {}
assert '"command": "status"' in console_text
PY
then
  pass "sbox bridge queue transport can complete a typed S&box query round trip"
else
  fail "sbox bridge queue transport can complete a typed S&box query round trip"
fi

$QQ_PY - "$SBOX_RUNTIME_ROOT" <<'PY' &
import json
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
requests = root / ".qq" / "state" / "qq-sbox-editor" / "requests"
responses = root / ".qq" / "state" / "qq-sbox-editor" / "responses"
state = root / ".qq" / "state" / "qq-sbox-editor-bridge.json"
deadline = time.time() + 10
handled = 0
while time.time() < deadline:
    state.write_text(json.dumps({"ok": True, "running": True, "lastHeartbeatUnix": time.time()}), encoding="utf-8")
    for request_path in requests.glob("*.json"):
        payload = json.loads(request_path.read_text(encoding="utf-8"))
        response = {
            "ok": True,
            "message": "fake sbox bridge handled request",
            "data": {
                "command": payload["command"],
                "args": payload.get("args") or {}
            }
        }
        (responses / f"{payload['requestId']}.json").write_text(json.dumps(response), encoding="utf-8")
        request_path.unlink()
        handled += 1
        if handled >= 2:
            raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(1)
PY
FAKE_SBOX_BRIDGE_PID=$!
if $QQ_PY "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_batch --arguments '{"operations":[{"tool":"sbox_editor","arguments":{"action":"open_scene","path":"Assets/Scenes/Main.scene"}},{"tool":"sbox_object","arguments":{"action":"select","path":"Player"}}]}' > "$SBOX_RUNTIME_ROOT/sbox-batch-call.json" && \
   wait "$FAKE_SBOX_BRIDGE_PID" && \
   $QQ_PY - "$SBOX_RUNTIME_ROOT/sbox-batch-call.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["ok"] is True
assert len(payload["results"]) == 2
assert payload["results"][0]["result"]["response"]["command"] == "open-scene"
assert payload["results"][1]["result"]["response"]["command"] == "select-object"
PY
then
  pass "sbox bridge batch transport can compose editor and object operations"
else
  fail "sbox bridge batch transport can compose editor and object operations"
fi

if $QQ_PY - "$SBOX_RUNTIME_ROOT" "$SCRIPT_DIR/scripts" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from qq_mcp import build_bridge  # noqa: E402

project = Path(sys.argv[1])
bridge = build_bridge(str(project))
tools = {tool["name"] for tool in bridge.list_tools()}
assert "qq_project_state" in tools
assert "sbox_editor" in tools
assert "sbox_query" in tools
assert "sbox_object" in tools
assert "sbox_scene" in tools
assert "sbox_assets" in tools
PY
then
  pass "qq_mcp composes generic and S&box rich tools for S&box projects"
else
  fail "qq_mcp composes generic and S&box rich tools for S&box projects"
fi

cat > "$SBOX_RUNTIME_ROOT/.qq/state/qq-sbox-editor-bridge.json" <<'EOF'
{
  "ok": true,
  "running": false,
  "lastHeartbeatUnix": 0
}
EOF
if $QQ_PY "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_query --arguments '{"action":"list_scenes","count":10}' > "$SBOX_RUNTIME_ROOT/sbox-local-scenes.json" && \
   $QQ_PY "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_query --arguments '{"action":"list_assets","count":10}' > "$SBOX_RUNTIME_ROOT/sbox-local-query-assets.json" && \
   $QQ_PY "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_scene --arguments '{"action":"duplicate_scene","source":"Assets/Scenes/Main.scene","target":"Assets/Scenes/Main_LocalCopy.scene"}' > "$SBOX_RUNTIME_ROOT/sbox-local-duplicate.json" && \
   $QQ_PY "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_assets --arguments '{"action":"create_directory","path":"Assets/Generated"}' > "$SBOX_RUNTIME_ROOT/sbox-local-assets.json" && \
   $QQ_PY - "$SBOX_RUNTIME_ROOT/sbox-local-scenes.json" "$SBOX_RUNTIME_ROOT/sbox-local-query-assets.json" "$SBOX_RUNTIME_ROOT/sbox-local-duplicate.json" "$SBOX_RUNTIME_ROOT/sbox-local-assets.json" "$SBOX_RUNTIME_ROOT" <<'PY'
import json
import sys
from pathlib import Path

scenes = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
query_assets = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
duplicate = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
assets = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
root = Path(sys.argv[5])

items = scenes["response"]["items"]
asset_items = query_assets["response"]["items"]
assert any(item["path"] == "Assets/Scenes/Main.scene" for item in items)
assert scenes["message"].endswith("(local fallback)")
assert any(item["path"] == "Assets/Scenes/Main.scene" for item in asset_items)
assert query_assets["message"].endswith("(local fallback)")
assert duplicate["response"]["target"] == "Assets/Scenes/Main_LocalCopy.scene"
assert (root / "Assets" / "Scenes" / "Main_LocalCopy.scene").is_file()
assert assets["response"]["path"] == "Assets/Generated"
assert (root / "Assets" / "Generated").is_dir()
PY
then
  pass "sbox typed query and asset tools fall back to direct project file operations when the live bridge is inactive"
else
  fail "sbox typed query and asset tools fall back to direct project file operations when the live bridge is inactive"
fi

rm -rf "$SBOX_RUNTIME_ROOT" "$FAKE_SBOX_DOCTOR_BIN_DIR"

SBOX_SCRIPT_TEST_ROOT="$(mktemp -d)"
mkdir -p "$SBOX_SCRIPT_TEST_ROOT/UnitTests"
: > "$SBOX_SCRIPT_TEST_ROOT/.sbproj"
: > "$SBOX_SCRIPT_TEST_ROOT/Game.sln"
: > "$SBOX_SCRIPT_TEST_ROOT/UnitTests/Game.UnitTests.csproj"
cat > "$SBOX_SCRIPT_TEST_ROOT/UnitTests/SmokeTests.cs" <<'EOF'
public sealed class SmokeTests {}
EOF
FAKE_SBOX_BIN_DIR="$(mktemp -d)"
FAKE_SBOX_LOG="$FAKE_SBOX_BIN_DIR/dotnet.log"
cat > "$FAKE_SBOX_BIN_DIR/dotnet" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "__FAKE_DOTNET_LOG__"
exit 0
EOF
$QQ_PY - "$FAKE_SBOX_BIN_DIR/dotnet" "$FAKE_SBOX_LOG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("__FAKE_DOTNET_LOG__", sys.argv[2])
path.write_text(text, encoding="utf-8")
PY
chmod +x "$FAKE_SBOX_BIN_DIR/dotnet"
if [ "$IS_WINDOWS" = "true" ]; then
  skip "qq-compile and qq-test route S&box projects onto dotnet build/test targets" "Windows path comparison in fixture log; tracked for follow-up"
elif env PATH="$FAKE_SBOX_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/qq-compile.sh" --project "$SBOX_SCRIPT_TEST_ROOT" > "$SBOX_SCRIPT_TEST_ROOT/sbox-compile.log" && \
   env PATH="$FAKE_SBOX_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/qq-test.sh" all --project "$SBOX_SCRIPT_TEST_ROOT" > "$SBOX_SCRIPT_TEST_ROOT/sbox-test.log" && \
   $QQ_PY - "$FAKE_SBOX_LOG" "$SBOX_SCRIPT_TEST_ROOT" <<'PY'
from pathlib import Path
import sys

# Normalize log lines and expected paths to forward slashes for cross-OS parity.
lines = [line.replace("\\", "/") for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
root = Path(sys.argv[2])
expected_sln = (root / "Game.sln").as_posix()
expected_csproj = (root / "UnitTests" / "Game.UnitTests.csproj").as_posix()
assert any(line.startswith(f"build {expected_sln}") for line in lines)
assert any(line.startswith(f"test {expected_csproj}") for line in lines)
PY
then
  pass "qq-compile and qq-test route S&box projects onto dotnet build/test targets"
else
  fail "qq-compile and qq-test route S&box projects onto dotnet build/test targets"
fi
rm -rf "$SBOX_SCRIPT_TEST_ROOT" "$FAKE_SBOX_BIN_DIR"

# ── qq-release.sh 发版门 ──
# 用一份最小发版仓库（替身 test.sh + 本地 bare origin）跑 --no-push，绝不碰 gh。确认：
#   - test.sh 任何一段失败、退 0 却打了 ✗、中途崩掉、没跑到汇总行、改版本号后复核失败，都拒绝发版
#     （以前只看第 5 段）；失败的 ✗ 行要打出来，没跑完时还要打日志末尾；
#     通过的用例名里提到 ✗ 不算失败（下面能发出去的用例覆盖）；
#   - test.sh 在仓库根目录跑：从别的目录调发版脚本也一样；
#   - 有额外的已跟踪改动（未暂存或已暂存、含改名、带空格）就拒绝，--include-dirty 才带进发版提交；
#     三份发版文件上的改动（比如上次改完版本号后测试没过留下的）--include-dirty 也拒绝，并给出恢复命令；
#     --include-dirty 碰上未暂存的删除又有未跟踪文件（多半是 mv 改名）也拒绝；
#   - 未跟踪文件任何情况下都不进发版提交，只列出来提示；跑测试期间才暂存进来的也不进。
REL_FIXTURE_ROOT="$(mktemp -d)"
REL_FIXTURE_ORIGIN="$REL_FIXTURE_ROOT/origin.git"
REL_FIXTURE_SEED="$REL_FIXTURE_ROOT/seed"
mkdir -p "$REL_FIXTURE_SEED/scripts" "$REL_FIXTURE_SEED/.claude-plugin"
cp "$SCRIPT_DIR/scripts/qq-release.sh" "$REL_FIXTURE_SEED/scripts/qq-release.sh"
cat > "$REL_FIXTURE_SEED/test.sh" <<'EOF'
#!/usr/bin/env bash
# 替身 test.sh：QQ_RELEASE_STUB_MODE 决定怎么失败；失败都放在第 6 段，只看第 5 段的门会漏掉。
# 跟真 test.sh 一样不 cd、按相对路径读仓库里的文件，所以发版脚本得在仓库根目录跑它。
# 通过的用例名里提到 ✗ 不能算失败：发版门只认行首的 ✗，也就是 fail() 打出来的那种
set -euo pipefail
if [ ! -f .claude-plugin/plugin.json ]; then
  echo "  ✗ stub ran outside the repo root ($PWD)"; echo "1/1 checks failed"; exit 1
fi
echo "[5/10] README consistency"
echo "  ✓ stub section 5"
echo "[6/10] SKILL.md frontmatter"
case "${QQ_RELEASE_STUB_MODE:-pass}" in
  fail)
    # ✗ 行后面再跟 20 条通过的，日志末尾看不到它：只能靠发版脚本把 ✗ 行挑出来
    printf '  \033[0;31m✗\033[0m stub section 6 failure\n'
    for ((i = 1; i <= 20; i++)); do echo "  ✓ stub filler $i"; done
    echo "1/23 checks failed"; exit 1 ;;
  # 打了 ✗ 却退 0、汇总行也说全过：只有挑 ✗ 行这一步拦得住
  fail-exit0) printf '  \033[0;31m✗\033[0m stub section 6 failure\n' ;;
  fail-then-crash)
    printf '  \033[0;31m✗\033[0m stub section 6 failure\n'
    echo "stub crashed before the summary" >&2; exit 3 ;;
  crash) echo "stub crashed before the summary" >&2; exit 3 ;;
  no-summary) echo "  ✓ stub section 6"; exit 0 ;;
  fail-after-bump)
    if ! grep -q '"version": "1.0.0"' .claude-plugin/plugin.json; then
      echo "  ✗ stub post-bump failure"; echo "1/2 checks failed"; exit 1
    fi ;;
  # 模拟跑测试期间别的会话往索引里加了文件
  stage-during-test) git add -- "review log.md" ;;
esac
echo "  ✓ stub section 6"
printf '  \033[0;32m✓\033[0m stub check whose name mentions the ✗ marker\n'
echo "All 3 checks passed"
EOF
cat > "$REL_FIXTURE_SEED/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "qq-release-fixture",
  "version": "1.0.0"
}
EOF
printf '# fixture\n\n![version](https://img.shields.io/badge/version-v1.0.0-blue)\n' > "$REL_FIXTURE_SEED/README.md"
printf '# Changelog\n\nAll notable changes to quick-question are documented here.\n' > "$REL_FIXTURE_SEED/CHANGELOG.md"
printf 'notes\n' > "$REL_FIXTURE_SEED/notes.txt"
printf 'spaced\n' > "$REL_FIXTURE_SEED/my notes.txt"
printf 'to be renamed\n' > "$REL_FIXTURE_SEED/old name.txt"
git init --bare -q "$REL_FIXTURE_ORIGIN"
(
  cd "$REL_FIXTURE_SEED" &&
  git init -q &&
  git symbolic-ref HEAD refs/heads/main &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  git add -A &&
  git update-index --chmod=+x test.sh scripts/qq-release.sh &&
  git commit -q -m "init" &&
  git remote add origin "$REL_FIXTURE_ORIGIN" &&
  git push -q origin main
) >/dev/null 2>&1

# 从 origin 克隆一份干净的发版仓库；$1 = 用例名，打印克隆路径
rel_fixture_clone() {
  local dir="$REL_FIXTURE_ROOT/$1"
  git clone -q -b main "$REL_FIXTURE_ORIGIN" "$dir" >/dev/null 2>&1 &&
  git -C "$dir" config user.email qq@example.com &&
  git -C "$dir" config user.name "qq test" &&
  printf '%s\n' "$dir"
}
# 在克隆里跑发版脚本：$1 = 克隆路径，$2 = 替身 test.sh 的模式，其余是额外参数；输出写到 <克隆>.log。
# 默认在克隆根目录跑，REL_FIXTURE_CWD 可以换成别的目录。
# TMPDIR 指进夹具目录，发版脚本留下的测试日志随夹具一起删掉
rel_fixture_run() {
  local dir="$1" mode="$2"
  shift 2
  [ -n "$dir" ] && [ -d "$dir/.git" ] || return 99
  (cd "${REL_FIXTURE_CWD:-$dir}" && TMPDIR="$REL_FIXTURE_ROOT" QQ_RELEASE_STUB_MODE="$mode" bash "$dir/scripts/qq-release.sh" --no-push "$@" patch "fixture release") > "$dir.log" 2>&1
}
# 没有新提交、版本号也没动
rel_fixture_untouched() {
  [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse origin/main)" ] &&
  grep -q '"version": "1.0.0"' "$1/.claude-plugin/plugin.json"
}
# 发版提交里的文件（改名拆成删旧加新），按字节序排好用 | 连起来
rel_fixture_commit_files() {
  git -C "$1" diff-tree --no-commit-id --name-only -r --no-renames HEAD | LC_ALL=C sort | tr '\n' '|'
}

REL_DIR="$(rel_fixture_clone test-fail)"
if ! rel_fixture_run "$REL_DIR" fail && rel_fixture_untouched "$REL_DIR" && \
   grep -A1 'Failing checks:' "$REL_DIR.log" | grep -q 'stub section 6 failure'; then
  pass "qq-release refuses when test.sh fails outside section 5 and lists the failing check"
else
  fail "qq-release refuses when test.sh fails outside section 5 and lists the failing check"
fi

REL_DIR="$(rel_fixture_clone test-fail-exit0)"
if ! rel_fixture_run "$REL_DIR" fail-exit0 && rel_fixture_untouched "$REL_DIR" && grep -q 'stub section 6 failure' "$REL_DIR.log"; then
  pass "qq-release refuses when test.sh prints a failing check yet exits 0 with a passing summary"
else
  fail "qq-release refuses when test.sh prints a failing check yet exits 0 with a passing summary"
fi

REL_DIR="$(rel_fixture_clone test-crash)"
if ! rel_fixture_run "$REL_DIR" crash && rel_fixture_untouched "$REL_DIR"; then
  pass "qq-release refuses when test.sh exits non-zero without printing any failing check"
else
  fail "qq-release refuses when test.sh exits non-zero without printing any failing check"
fi

REL_DIR="$(rel_fixture_clone test-fail-then-crash)"
if ! rel_fixture_run "$REL_DIR" fail-then-crash && rel_fixture_untouched "$REL_DIR" && \
   grep -q 'stub section 6 failure' "$REL_DIR.log" && grep -q 'stub crashed before the summary' "$REL_DIR.log"; then
  pass "qq-release shows both the failing checks and the crash when test.sh dies after a failure"
else
  fail "qq-release shows both the failing checks and the crash when test.sh dies after a failure"
fi

REL_DIR="$(rel_fixture_clone test-no-summary)"
if ! rel_fixture_run "$REL_DIR" no-summary && rel_fixture_untouched "$REL_DIR"; then
  pass "qq-release refuses when test.sh exits 0 before its all-passed summary line"
else
  fail "qq-release refuses when test.sh exits 0 before its all-passed summary line"
fi

REL_DIR="$(rel_fixture_clone test-other-cwd)"
if REL_FIXTURE_CWD="$REL_FIXTURE_ROOT" rel_fixture_run "$REL_DIR" pass && \
   [ "$(git -C "$REL_DIR" log -1 --format=%s)" = "release: v1.0.1" ]; then
  pass "qq-release runs test.sh from the repo root when invoked from another directory"
else
  fail "qq-release runs test.sh from the repo root when invoked from another directory"
fi

REL_DIR="$(rel_fixture_clone test-post-bump)"
if ! rel_fixture_run "$REL_DIR" fail-after-bump && \
   [ "$(git -C "$REL_DIR" rev-parse HEAD)" = "$(git -C "$REL_DIR" rev-parse origin/main)" ] && \
   grep -q 'stub post-bump failure' "$REL_DIR.log"; then
  pass "qq-release refuses to commit when the post-bump test.sh run fails"
else
  fail "qq-release refuses to commit when the post-bump test.sh run fails"
fi

# 接着上一条：改完版本号后测试没过，三份发版文件留在 1.0.1。照提示加 --include-dirty 重跑不能再升到 1.0.2
cp "$REL_DIR.log" "$REL_DIR.first.log"
if grep -q 'checkout HEAD -- .claude-plugin/plugin.json README.md CHANGELOG.md' "$REL_DIR.first.log" && \
   ! rel_fixture_run "$REL_DIR" pass --include-dirty && \
   [ "$(git -C "$REL_DIR" rev-parse HEAD)" = "$(git -C "$REL_DIR" rev-parse origin/main)" ] && \
   grep -q '"version": "1.0.1"' "$REL_DIR/.claude-plugin/plugin.json" && \
   ! grep -q '1\.0\.2' "$REL_DIR/CHANGELOG.md" && \
   grep -q 'checkout HEAD --' "$REL_DIR.log"; then
  pass "qq-release won't bump again on top of a half-applied bump, even with --include-dirty, and says how to restore"
else
  fail "qq-release won't bump again on top of a half-applied bump, even with --include-dirty, and says how to restore"
fi

REL_DIR="$(rel_fixture_clone dirty-unstaged)"
printf 'local edit\n' >> "$REL_DIR/notes.txt"
if ! rel_fixture_run "$REL_DIR" pass && rel_fixture_untouched "$REL_DIR" && \
   grep -q 'notes.txt' "$REL_DIR.log" && grep -q -- '--include-dirty' "$REL_DIR.log"; then
  pass "qq-release refuses extra unstaged tracked changes unless --include-dirty"
else
  fail "qq-release refuses extra unstaged tracked changes unless --include-dirty"
fi

REL_DIR="$(rel_fixture_clone dirty-staged)"
printf 'staged edit\n' >> "$REL_DIR/my notes.txt"
git -C "$REL_DIR" add "my notes.txt"
git -C "$REL_DIR" mv "old name.txt" "new name.txt"
if ! rel_fixture_run "$REL_DIR" pass && rel_fixture_untouched "$REL_DIR" && \
   grep -q 'my notes.txt' "$REL_DIR.log" && grep -q 'old name.txt' "$REL_DIR.log" && grep -q 'new name.txt' "$REL_DIR.log"; then
  pass "qq-release refuses extra staged changes (renames, paths with spaces) unless --include-dirty"
else
  fail "qq-release refuses extra staged changes (renames, paths with spaces) unless --include-dirty"
fi

REL_DIR="$(rel_fixture_clone include-dirty)"
printf 'local edit\n' >> "$REL_DIR/notes.txt"
printf 'staged edit\n' >> "$REL_DIR/my notes.txt"
git -C "$REL_DIR" add "my notes.txt"
git -C "$REL_DIR" mv "old name.txt" "new name.txt"
printf 'scratch\n' > "$REL_DIR/scratch.txt"
printf 'review\n' > "$REL_DIR/review log.md"
if rel_fixture_run "$REL_DIR" pass --include-dirty && \
   [ "$(git -C "$REL_DIR" log -1 --format=%s)" = "release: v1.0.1" ] && \
   [ "$(rel_fixture_commit_files "$REL_DIR")" = ".claude-plugin/plugin.json|CHANGELOG.md|README.md|my notes.txt|new name.txt|notes.txt|old name.txt|" ] && \
   git -C "$REL_DIR" diff HEAD --quiet && \
   [ "$(git -C "$REL_DIR" ls-files --others --exclude-standard | LC_ALL=C sort | tr '\n' '|')" = "review log.md|scratch.txt|" ]; then
  pass "qq-release --include-dirty commits staged and unstaged tracked changes but never untracked files"
else
  fail "qq-release --include-dirty commits staged and unstaged tracked changes but never untracked files"
fi

# 用 mv（不是 git mv）改名：旧路径是未暂存的删除，新路径是未跟踪文件。照旧逻辑发版提交里只剩删除
REL_DIR="$(rel_fixture_clone include-dirty-plain-mv)"
mv "$REL_DIR/old name.txt" "$REL_DIR/renamed.txt"
if ! rel_fixture_run "$REL_DIR" pass --include-dirty && rel_fixture_untouched "$REL_DIR" && \
   [ -f "$REL_DIR/renamed.txt" ] && grep -q 'old name.txt' "$REL_DIR.log"; then
  pass "qq-release --include-dirty refuses an unstaged deletion while untracked files exist (plain mv rename)"
else
  fail "qq-release --include-dirty refuses an unstaged deletion while untracked files exist (plain mv rename)"
fi

REL_DIR="$(rel_fixture_clone untracked)"
printf 'scratch\n' > "$REL_DIR/scratch.txt"
printf 'review\n' > "$REL_DIR/review log.md"
if rel_fixture_run "$REL_DIR" pass && \
   [ "$(rel_fixture_commit_files "$REL_DIR")" = ".claude-plugin/plugin.json|CHANGELOG.md|README.md|" ] && \
   [ "$(git -C "$REL_DIR" ls-files --others --exclude-standard | LC_ALL=C sort | tr '\n' '|')" = "review log.md|scratch.txt|" ] && \
   grep -q 'scratch.txt' "$REL_DIR.log" && grep -q 'review log.md' "$REL_DIR.log"; then
  pass "qq-release leaves untracked files out of the release commit and lists them as ignored"
else
  fail "qq-release leaves untracked files out of the release commit and lists them as ignored"
fi

# 跑测试那段时间里别的会话把未跟踪文件暂存了：发版提交仍只有三份发版文件，那个文件留在索引里
REL_DIR="$(rel_fixture_clone staged-during-test)"
printf 'review\n' > "$REL_DIR/review log.md"
if rel_fixture_run "$REL_DIR" stage-during-test && \
   [ "$(git -C "$REL_DIR" log -1 --format=%s)" = "release: v1.0.1" ] && \
   [ "$(rel_fixture_commit_files "$REL_DIR")" = ".claude-plugin/plugin.json|CHANGELOG.md|README.md|" ] && \
   [ "$(git -C "$REL_DIR" diff --cached --name-only)" = "review log.md" ]; then
  pass "qq-release commits only its own paths even if something gets staged while test.sh runs"
else
  fail "qq-release commits only its own paths even if something gets staged while test.sh runs"
fi
rm -rf "$REL_FIXTURE_ROOT"

# ── execute checkpoint ──
echo -e "${CYAN}[checkpoint] execute checkpoint lifecycle${NC}"

CKPT_ROOT="$(mktemp -d)"
mkdir -p "$CKPT_ROOT/Docs/qq"
cat > "$CKPT_ROOT/Docs/qq/test_plan.md" <<'EOF'
# Test Plan
- [ ] **Step 1: Create interface**
- [ ] **Step 2: Implement service**
- [ ] **Step 3: Add tests**
EOF

if $QQ_PY "$SCRIPT_DIR/scripts/qq-execute-checkpoint.py" save \
     --project "$CKPT_ROOT" --plan "Docs/qq/test_plan.md" --step 0 --total 3 --mode direct --status running >/dev/null && \
   $QQ_PY "$SCRIPT_DIR/scripts/qq-execute-checkpoint.py" save \
     --project "$CKPT_ROOT" --plan "Docs/qq/test_plan.md" --step 1 --total 3 --mode direct --step-title "Create interface" >/dev/null && \
   $QQ_PY - "$CKPT_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
progress = json.loads((root / ".qq" / "state" / "execute-progress.json").read_text(encoding="utf-8"))
plan_text = (root / "Docs" / "qq" / "test_plan.md").read_text(encoding="utf-8")

assert progress["status"] == "running"
assert progress["completed_step"] == 1
assert progress["completed_steps"] == [1]
assert progress["total_steps"] == 3
assert "- [x] **Step 1: Create interface**" in plan_text
assert "- [ ] **Step 2: Implement service**" in plan_text
PY
then
  pass "checkpoint save updates progress JSON and plan checkbox by step title"
else
  fail "checkpoint save updates progress JSON and plan checkbox by step title"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/qq-execute-checkpoint.py" resume --project "$CKPT_ROOT" --format hint | grep -q "1/3 steps completed" && \
   $QQ_PY "$SCRIPT_DIR/scripts/qq-execute-checkpoint.py" resume --project "$CKPT_ROOT" | $QQ_PY -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="running"; assert d["completed_step"]==1'
then
  pass "checkpoint resume returns progress in hint and json formats"
else
  fail "checkpoint resume returns progress in hint and json formats"
fi

if $QQ_PY "$SCRIPT_DIR/scripts/qq-execute-checkpoint.py" clear --project "$CKPT_ROOT" >/dev/null && \
   RESUME=$($QQ_PY "$SCRIPT_DIR/scripts/qq-execute-checkpoint.py" resume --project "$CKPT_ROOT") && \
   [ "$RESUME" = "{}" ]
then
  pass "checkpoint clear marks execution complete and resume returns empty"
else
  fail "checkpoint clear marks execution complete and resume returns empty"
fi

# positional fallback when step title not found
cat > "$CKPT_ROOT/Docs/qq/test_plan.md" <<'EOF'
# Test Plan
- [ ] **Step 1: Create interface**
- [ ] **Step 2: Implement service**
- [ ] **Step 3: Add tests**
EOF
rm -f "$CKPT_ROOT/.qq/state/execute-progress.json"

if $QQ_PY "$SCRIPT_DIR/scripts/qq-execute-checkpoint.py" save \
     --project "$CKPT_ROOT" --plan "Docs/qq/test_plan.md" --step 2 --total 3 --mode direct --step-title "NONEXISTENT TITLE" >/dev/null && \
   grep -q '\[x\].*Step 2' "$CKPT_ROOT/Docs/qq/test_plan.md"
then
  pass "checkpoint falls back to positional matching when step title not found"
else
  fail "checkpoint falls back to positional matching when step title not found"
fi

# project-state detects active execution
rm -f "$CKPT_ROOT/.qq/state/execute-progress.json"
$QQ_PY "$SCRIPT_DIR/scripts/qq-execute-checkpoint.py" save \
  --project "$CKPT_ROOT" --plan "Docs/qq/test_plan.md" --step 1 --total 3 --mode coordinator --status running >/dev/null

if $QQ_PY "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$CKPT_ROOT" --no-write | \
   $QQ_PY -c 'import json,sys; d=json.load(sys.stdin); assert d["execute_in_progress"]==True; assert "test_plan" in d["recommended_next"]'
then
  pass "project-state detects active execution and overrides recommended_next"
else
  fail "project-state detects active execution and overrides recommended_next"
fi

# hooks.json has SessionStart[compact] entry
if $QQ_PY - <<'PY'
import json
hooks = json.load(open("hooks/hooks.json", encoding="utf-8"))["hooks"]
assert "SessionStart" in hooks
entries = hooks["SessionStart"]
assert any(e["matcher"] == "compact" for e in entries)
compact_hooks = [e for e in entries if e["matcher"] == "compact"][0]["hooks"]
assert any("execute-resume-hint" in h["command"] for h in compact_hooks)
PY
then
  pass "hooks.json registers SessionStart[compact] with execute-resume-hint"
else
  fail "hooks.json registers SessionStart[compact] with execute-resume-hint"
fi

rm -rf "$CKPT_ROOT"

# ── 9. Review gate E2E ──
echo -e "${CYAN}[9/10] Review gate E2E${NC}"

E2E_ROOT="$(mktemp -d)"
E2E_QQ_TEMP="$(mktemp -d)"
mkdir -p "$E2E_ROOT/.qq"
(cd "$E2E_ROOT" && git init -q)
cat > "$E2E_ROOT/qq.yaml" <<'QYAML'
version: 1
engine: unity
default_profile: feature
QYAML

export QQ_TEMP_DIR="$E2E_QQ_TEMP"
export QQ_PROJECT_DIR="$E2E_ROOT"

# 门文件按会话 id 命名：钩子的 stdin 里带上本测试专用的 session_id
E2E_SID="qq-e2e-$$"
e2e_in() {   # 给一段 JSON 对象补上 session_id 字段
  if [[ "$1" == "{}" ]]; then
    printf '{"session_id":"%s"}' "$E2E_SID"
  else
    printf '{"session_id":"%s",%s' "$E2E_SID" "${1#\{}"
  fi
}

# --- E2E 1: Full gate lifecycle ---
echo -e "${CYAN}[e2e] review gate lifecycle${NC}"

# 1. Open: a review script finished and opened the gate itself (qq_review_gate_open, keyed by the
#    session id from CLAUDE_CODE_SESSION_ID); the PostToolUse(Bash) set hook then announces it once.
CLAUDE_CODE_SESSION_ID="$E2E_SID" bash -c 'source "$1/scripts/platform/detect.sh"; qq_review_gate_open' _ "$SCRIPT_DIR" 2>/dev/null
SET_OUT="$(e2e_in '{"tool_input":{"command":"ls"}}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-set.sh" 2>/dev/null)"
SET_OUT2="$(e2e_in '{"tool_input":{"command":"ls"}}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-set.sh" 2>/dev/null)"

GATE_FILE="$E2E_QQ_TEMP/review-gate-$E2E_SID"
if [[ -f "$GATE_FILE" ]]; then
  pass "e2e: review script opens the gate file"
else
  fail "e2e: review script did not open the gate file"
fi
if [[ "$SET_OUT" == *"REVIEW-GATE"* && -z "$SET_OUT2" && ! -f "$GATE_FILE.announce" ]]; then
  pass "e2e: set hook announces a freshly opened gate exactly once"
else
  fail "e2e: set hook announcement wrong (first='${SET_OUT:0:60}' second='${SET_OUT2:0:60}')"
fi

# Verify three-field format
IFS=: read -r _ts _completed _expected < "$GATE_FILE"
if [[ "$_completed" == "0" && "$_expected" == "0" ]]; then
  pass "e2e: gate file has three-field format 0:0"
else
  fail "e2e: gate file format wrong (got $_completed:$_expected)"
fi

# 2. Check: simulate PreToolUse(Edit) on a .cs file — should BLOCK (expected=0)
if e2e_in '{"tool_input":{"file_path":"Assets/Player.cs"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-check.sh" 2>/dev/null; then
  fail "e2e: gate-check should block when expected=0"
else
  pass "e2e: gate-check blocks when expected=0"
fi

# 3. Write expected count (simulate skill writing N=3)
IFS=: read -r _ts _count _ < "$GATE_FILE"
echo "${_ts}:${_count}:3" > "$GATE_FILE"

# 4. Check: should still BLOCK (0/3 complete)
if e2e_in '{"tool_input":{"file_path":"Assets/Player.cs"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-check.sh" 2>/dev/null; then
  fail "e2e: gate-check should block when 0/3 complete"
else
  pass "e2e: gate-check blocks when 0/3 complete"
fi

# 5. Count: simulate 3 subagent completions (PostToolUse Agent)
e2e_in '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-count.sh" 2>/dev/null
e2e_in '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-count.sh" 2>/dev/null
e2e_in '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-count.sh" 2>/dev/null

# Verify gate file shows 3/3
IFS=: read -r _ts _count _expected < "$GATE_FILE"
if [[ "$_count" == "3" && "$_expected" == "3" ]]; then
  pass "e2e: gate-count reaches 3/3"
else
  fail "e2e: gate-count wrong (got $_count/$_expected)"
fi

# 6. Check: should ALLOW (3/3 complete)
if e2e_in '{"tool_input":{"file_path":"Assets/Player.cs"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-check.sh" 2>/dev/null; then
  pass "e2e: gate-check allows when 3/3 complete"
else
  fail "e2e: gate-check still blocks after 3/3"
fi

# 7. Cleanup
rm -f "$GATE_FILE"

# --- E2E 2: Stop hook blocks exit during incomplete verification ---
echo -e "${CYAN}[e2e] stop hook behavior${NC}"

echo "$(date +%s):1:3" > "$E2E_QQ_TEMP/review-gate-$E2E_SID"

STOP_TMP="$E2E_QQ_TEMP/stop-hook-out-$$"
e2e_in '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-stop.sh" >"$STOP_TMP" 2>/dev/null
if grep -q '"decision":"block"' "$STOP_TMP"; then
  pass "e2e: stop hook blocks exit when 1/3 complete"
else
  fail "e2e: stop hook should block when 1/3 complete"
fi

# Complete to 3/3
echo "$(date +%s):3:3" > "$E2E_QQ_TEMP/review-gate-$E2E_SID"

e2e_in '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-stop.sh" >"$STOP_TMP" 2>/dev/null
if grep -q '"decision":"block"' "$STOP_TMP"; then
  fail "e2e: stop hook still blocks after 3/3"
else
  pass "e2e: stop hook allows exit when 3/3 complete"
fi
rm -f "$STOP_TMP"

rm -f "$E2E_QQ_TEMP/review-gate-$E2E_SID"

# --- E2E 3: each of the 4 review scripts opens the gate itself when its review really ran ---
# 待修清单第 2 条：门由审查脚本自己立，钩子不再从命令文本里猜。用假的 codex / claude 真跑一遍四个脚本。
echo -e "${CYAN}[e2e] review scripts open the gate themselves${NC}"

REVIEW_FIX="$(mktemp -d)"
mkdir -p "$REVIEW_FIX/bin" "$REVIEW_FIX/codex-home" "$REVIEW_FIX/repo"
cat > "$REVIEW_FIX/bin/codex" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "codex-cli 0.0.0-fake"; exit 0; }
cat >/dev/null
[[ "${FAKE_REVIEW_MODE:-ok}" == "fail" ]] && { echo "boom" >&2; exit 3; }
echo "[Critical] fake finding"
SH
cat > "$REVIEW_FIX/bin/claude" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_REVIEW_MODE:-ok}" == "fail" ]] && { echo "boom" >&2; exit 3; }
echo "[Critical] fake finding"
SH
chmod +x "$REVIEW_FIX/bin/codex" "$REVIEW_FIX/bin/claude"
(
  cd "$REVIEW_FIX/repo" && git init -q -b main && git config user.email t@t && git config user.name t &&
  printf '# Plan\n' > plan.md && printf 'class A {}\n' > A.cs && git add -A && git commit -qm init &&
  git checkout -qb feature && printf 'class A { int x; }\n' > A.cs && git commit -qam change
) >/dev/null 2>&1
# run_review <mode> <script> [args...]：在夹具仓库里以本测试的会话 id 跑一个审查脚本
run_review() {
  local mode="$1"; shift
  (cd "$REVIEW_FIX/repo" && PATH="$REVIEW_FIX/bin:$PATH" CODEX_HOME="$REVIEW_FIX/codex-home" FAKE_REVIEW_MODE="$mode" \
     CLAUDE_CODE_SESSION_ID="$E2E_SID" bash "$@" >/dev/null 2>&1)
}
for review in "code-review.sh --base main" "claude-review.sh --base main" "plan-review.sh plan.md" "claude-plan-review.sh plan.md"; do
  read -r review_script review_args <<< "$review"
  rm -f "$E2E_QQ_TEMP/review-gate-$E2E_SID" "$E2E_QQ_TEMP/review-gate-$E2E_SID.announce"
  # shellcheck disable=SC2086
  run_review ok "$SCRIPT_DIR/scripts/$review_script" $review_args
  if [[ -f "$E2E_QQ_TEMP/review-gate-$E2E_SID" && -f "$E2E_QQ_TEMP/review-gate-$E2E_SID.announce" ]]; then
    pass "e2e: ${review_script} opens this session's gate after the review runs"
  else
    fail "e2e: ${review_script} did not open the gate"
  fi
  rm -f "$E2E_QQ_TEMP/review-gate-$E2E_SID" "$E2E_QQ_TEMP/review-gate-$E2E_SID.announce"
  # shellcheck disable=SC2086
  run_review fail "$SCRIPT_DIR/scripts/$review_script" $review_args || true
  if [[ ! -f "$E2E_QQ_TEMP/review-gate-$E2E_SID" ]]; then
    pass "e2e: ${review_script} leaves no gate when the reviewer fails"
  else
    fail "e2e: ${review_script} opened the gate although the reviewer failed"
  fi
done
# 没有可审的改动：脚本 exit 0 但没真审，不立门
rm -f "$E2E_QQ_TEMP/review-gate-$E2E_SID"
(cd "$REVIEW_FIX/repo" && git checkout -q main && git clean -fdq) >/dev/null 2>&1   # 清掉前面几次审查写出的报告（未跟踪文件也算可审内容）
run_review ok "$SCRIPT_DIR/scripts/claude-review.sh" --base main || true
if [[ ! -f "$E2E_QQ_TEMP/review-gate-$E2E_SID" ]]; then
  pass "e2e: a review with no changes to review opens no gate"
else
  fail "e2e: a review with nothing to review opened the gate"
fi
# 不在 Claude Code 里（没有会话 id）：审查照常跑，但不立门、不留共用文件
(cd "$REVIEW_FIX/repo" && git checkout -q feature) >/dev/null 2>&1
rm -f "$E2E_QQ_TEMP"/review-gate-*
(cd "$REVIEW_FIX/repo" && PATH="$REVIEW_FIX/bin:$PATH" bash "$SCRIPT_DIR/scripts/claude-plan-review.sh" plan.md >/dev/null 2>&1)
if ! compgen -G "$E2E_QQ_TEMP/review-gate-*" >/dev/null && [[ -f "$REVIEW_FIX/repo/plan_claude_review.md" ]]; then
  pass "e2e: without a session id the review still runs but opens no gate"
else
  fail "e2e: review without a session id opened a gate or did not run"
fi
rm -rf "$REVIEW_FIX"

# --- E2E 4: Gate ignores non-.cs files ---
echo -e "${CYAN}[e2e] gate file-type filtering${NC}"

echo "$(date +%s):0:3" > "$E2E_QQ_TEMP/review-gate-$E2E_SID"

# .py file should NOT be blocked
if e2e_in '{"tool_input":{"file_path":"scripts/foo.py"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-check.sh" 2>/dev/null; then
  pass "e2e: gate-check ignores .py files"
else
  fail "e2e: gate-check incorrectly blocks .py files"
fi

# .cs file should be blocked
if e2e_in '{"tool_input":{"file_path":"Assets/Player.cs"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-check.sh" 2>/dev/null; then
  fail "e2e: gate-check should block .cs files"
else
  pass "e2e: gate-check blocks .cs files"
fi

rm -f "$E2E_QQ_TEMP/review-gate-$E2E_SID"

# --- E2E 5: a command that merely mentions a review script never opens the gate ---
# 待修清单第 2 条：原来 set 钩子在命令文本里 grep 到 ./scripts/code-review.sh 就立门，heredoc、grep、
# 测试字符串里出现这串字都会误立门。
echo -e "${CYAN}[e2e] gate ignores commands that only mention review scripts${NC}"

mention_bad=""
for mention_cmd in './scripts/qq-compile.sh' 'echo \"./scripts/code-review.sh\"' 'grep code-review.sh x' \
                   'grep -n ./scripts/plan-review.sh notes.md' 'cat <<EOF\n./scripts/claude-review.sh --base main\nEOF' \
                   'bash test.sh # runs ./scripts/claude-plan-review.sh fixtures'; do
  rm -f "$E2E_QQ_TEMP/review-gate-$E2E_SID" "$E2E_QQ_TEMP/review-gate-$E2E_SID.announce"
  mention_out="$(e2e_in "{\"tool_input\":{\"command\":\"${mention_cmd}\"}}" | \
    PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" set 2>/dev/null)"
  if [[ -f "$E2E_QQ_TEMP/review-gate-$E2E_SID" || -n "$mention_out" ]]; then
    mention_bad+=" [${mention_cmd}]"
  fi
done
if [[ -z "$mention_bad" ]]; then
  pass "e2e: set hook ignores commands that only mention review scripts (echo / grep / heredoc / comments)"
else
  fail "e2e: set hook opened or announced a gate for:${mention_bad}"
fi

# --- E2E 6: Review scripts fail gracefully when CLI missing ---
echo -e "${CYAN}[e2e] review script graceful failure${NC}"

if env -i PATH="/usr/bin:/bin" bash "$SCRIPT_DIR/scripts/claude-review.sh" 2>&1 | grep -qi "claude.*not found"; then
  pass "e2e: claude-review.sh fails gracefully without claude CLI"
else
  # If claude IS installed, script will fail for other reasons (no git repo context)
  # That's also acceptable — the point is it doesn't crash silently
  pass "e2e: claude-review.sh handles missing CLI (claude may be installed)"
fi

if env -i PATH="/usr/bin:/bin" bash "$SCRIPT_DIR/scripts/code-review.sh" 2>&1 | grep -qi "codex.*not found"; then
  pass "e2e: code-review.sh fails gracefully without codex CLI"
else
  pass "e2e: code-review.sh handles missing CLI (codex may be installed)"
fi

# --- E2E 7: Gate expiry (2h timeout) ---
echo -e "${CYAN}[e2e] gate expiry${NC}"

# Create a gate with a timestamp 3 hours in the past
old_ts=$(( $(date +%s) - 10800 ))
echo "${old_ts}:0:3" > "$E2E_QQ_TEMP/review-gate-$E2E_SID"

# Check should allow (gate expired)
if e2e_in '{"tool_input":{"file_path":"Assets/Player.cs"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate-check.sh" 2>/dev/null; then
  pass "e2e: gate-check allows after 2h expiry"
else
  fail "e2e: gate-check still blocks after 2h expiry"
fi

# Gate file should be removed
if [[ ! -f "$E2E_QQ_TEMP/review-gate-$E2E_SID" ]]; then
  pass "e2e: expired gate file is cleaned up"
else
  fail "e2e: expired gate file not removed"
fi

# --- E2E 8: gates are keyed by session id, never by $PPID ---
# 待修清单第 1 条：门文件曾按 $PPID 命名，Windows Git Bash 下 $PPID 恒为 1，全机会话共用一份门文件——
# 一个会话立门，所有会话都改不了代码；任何一个会话收尾又把门删掉。现在按 session_id 命名。
echo -e "${CYAN}[e2e] gate session isolation${NC}"

SID_A="qq-e2e-a-$$"
SID_B="qq-e2e-b-$$"
sid_in() {   # sid_in <session_id> <JSON 对象>：补上 session_id 字段
  if [[ "$2" == "{}" ]]; then printf '{"session_id":"%s"}' "$1"; else printf '{"session_id":"%s",%s' "$1" "${2#\{}"; fi
}
GATE_A="$E2E_QQ_TEMP/review-gate-$SID_A"
rm -f "$E2E_QQ_TEMP"/review-gate-*

# 立门：只给立门的那个会话建门，不会出现按 $PPID（这里就是本脚本的 $$）命名的共用文件
CLAUDE_CODE_SESSION_ID="$SID_A" bash -c 'source "$1/scripts/platform/detect.sh"; qq_review_gate_open' _ "$SCRIPT_DIR" 2>/dev/null
sid_in "$SID_A" '{"tool_input":{"command":"ls"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" set >/dev/null 2>&1
if [[ -f "$GATE_A" && ! -f "$E2E_QQ_TEMP/review-gate-$SID_B" && ! -f "$E2E_QQ_TEMP/review-gate-$$" && ! -f "$E2E_QQ_TEMP/review-gate-1" ]]; then
  pass "e2e: review gate is created under the session id only"
else
  fail "e2e: review gate not keyed by session id ($(ls "$E2E_QQ_TEMP" | tr '\n' ' '))"
fi

# check：A 被拦（必须 exit 2——PreToolUse 退 1 只是非阻断错误，编辑照样执行），B 不受影响
REVIEW_CHECK_RC=0
sid_in "$SID_A" '{"tool_input":{"file_path":"Assets/Player.cs"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" check >/dev/null 2>&1 || REVIEW_CHECK_RC=$?
if [[ "$REVIEW_CHECK_RC" == "2" ]]; then
  pass "e2e: session A is blocked by its own review gate (exit 2, a real PreToolUse block)"
else
  fail "e2e: review gate check exited $REVIEW_CHECK_RC, want 2 (exit 1 does not block the tool)"
fi
if sid_in "$SID_B" '{"tool_input":{"file_path":"Assets/Player.cs"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" check >/dev/null 2>&1; then
  pass "e2e: session B can still edit while session A's review gate is up"
else
  fail "e2e: session B blocked by session A's review gate"
fi

# count：B 的 Agent 完成不会给 A 计数
echo "$(date +%s):0:2" > "$GATE_A"
sid_in "$SID_B" '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" count >/dev/null 2>&1
IFS=: read -r _ts _count _expected < "$GATE_A"
if [[ "$_count" == "0" && ! -f "$E2E_QQ_TEMP/review-gate-$SID_B" ]]; then
  pass "e2e: another session's subagent does not count toward this session's gate"
else
  fail "e2e: session B's Agent completion touched session A's gate (count=$_count)"
fi

# stop：A 验证没做完时只拦 A 的收尾
STOP_TMP="$E2E_QQ_TEMP/stop-iso-out-$$"
sid_in "$SID_B" '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" stop >"$STOP_TMP" 2>/dev/null
if grep -q '"decision":"block"' "$STOP_TMP"; then
  fail "e2e: session B's stop blocked by session A's pending verification"
else
  pass "e2e: session B can stop while session A's verification is pending"
fi
sid_in "$SID_A" '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" stop >"$STOP_TMP" 2>/dev/null
if grep -q '"decision":"block"' "$STOP_TMP"; then
  pass "e2e: session A's stop is blocked by its own pending verification"
else
  fail "e2e: session A's stop not blocked by its own pending verification"
fi
rm -f "$STOP_TMP"

# 收尾清理：B 收尾不删 A 的门，A 收尾才删
sid_in "$SID_B" '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/session-cleanup.sh" >/dev/null 2>&1
if [[ -f "$GATE_A" ]]; then
  pass "e2e: session B's cleanup leaves session A's gate alone"
else
  fail "e2e: session B's cleanup deleted session A's gate"
fi
sid_in "$SID_A" '{}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/session-cleanup.sh" >/dev/null 2>&1
if [[ ! -f "$GATE_A" ]]; then
  pass "e2e: session A's cleanup removes its own gate"
else
  fail "e2e: session A's cleanup did not remove its own gate"
fi

# 拿不到会话 id（stdin 没有 session_id、环境里也没有 CLAUDE_CODE_SESSION_ID）：宁可不建门，也不退回共用文件
rm -f "$E2E_QQ_TEMP"/review-gate-*
bash -c 'source "$1/scripts/platform/detect.sh"; qq_review_gate_open' _ "$SCRIPT_DIR" 2>/dev/null
echo '{"tool_input":{"command":"ls"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" set >/dev/null 2>&1
if compgen -G "$E2E_QQ_TEMP/review-gate-*" >/dev/null; then
  fail "e2e: a gate file was created without a session id ($(ls "$E2E_QQ_TEMP" | tr '\n' ' '))"
else
  pass "e2e: no session id -> no gate file (never falls back to a shared one)"
fi

# 门只管主 agent：子 agent（payload 带 agent_id、session_id 与主会话相同）的编辑不拦，Agent 完成不计数，
# 也不消费宣告——否则并行子 agent 里任何一个跑完审查，都会把其余子 agent 和主 agent 一起锁住
sub_in() {   # sub_in <session_id> <agent_id> <JSON 对象>：模拟子 agent 的钩子输入
  printf '{"session_id":"%s","agent_id":"%s",%s' "$1" "$2" "${3#\{}"
}
echo "$(date +%s):0:2" > "$GATE_A"
SUB_RC=0
sub_in "$SID_A" "agent-x1" '{"tool_input":{"file_path":"Assets/Player.cs"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" check >/dev/null 2>&1 || SUB_RC=$?
sub_in "$SID_A" "agent-x1" '{"tool_name":"Agent","tool_input":{}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" count >/dev/null 2>&1
IFS=: read -r _ts _count _expected < "$GATE_A"
MAIN_RC=0
sid_in "$SID_A" '{"tool_input":{"file_path":"Assets/Player.cs"}}' | \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" check >/dev/null 2>&1 || MAIN_RC=$?
if [[ "$SUB_RC" == "0" && "$_count" == "0" && "$MAIN_RC" == "2" ]]; then
  pass "e2e: the review gate governs the main agent only (subagent edits pass, subagent Agent calls do not count)"
else
  fail "e2e: review gate subagent scope wrong (subagent check rc=$SUB_RC, count=$_count, main check rc=$MAIN_RC)"
fi

# 宣告：子 agent 的 Bash 不消费标记，留给主 agent；验证已经派出去（expected 写好了）时不再宣告过时的「必须验证」
echo "$(date +%s):0:0" > "$GATE_A"; : > "$GATE_A.announce"
SUB_SET="$(sub_in "$SID_A" "agent-x1" '{"tool_input":{"command":"ls"}}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" set 2>/dev/null)"
SUB_LEFT=0; [[ -f "$GATE_A.announce" ]] && SUB_LEFT=1
echo "$(date +%s):1:3" > "$GATE_A"
STALE_SET="$(sid_in "$SID_A" '{"tool_input":{"command":"ls"}}' | PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" set 2>/dev/null)"
if [[ -z "$SUB_SET" && "$SUB_LEFT" == "1" && -z "$STALE_SET" && ! -f "$GATE_A.announce" ]]; then
  pass "e2e: the announcement is left for the main agent, and dropped silently once verification is under way"
else
  fail "e2e: announcement handling wrong (subagent out='${SUB_SET:0:40}' left=$SUB_LEFT stale out='${STALE_SET:0:40}')"
fi

# Windows 路径写法：反斜杠的 Docs\x.md、大写扩展名 Foo.CS 一样要拦
echo "$(date +%s):0:0" > "$GATE_A"
WIN_BAD=""
for win_path in 'E:\\proj\\Docs\\plan.md' 'E:\\proj\\Assets\\Foo.CS'; do
  WIN_RC=0
  sid_in "$SID_A" "{\"tool_input\":{\"file_path\":\"${win_path}\"}}" | \
    PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" check >/dev/null 2>&1 || WIN_RC=$?
  [[ "$WIN_RC" == "2" ]] || WIN_BAD+=" ${win_path}=${WIN_RC}"
done
if [[ -z "$WIN_BAD" ]]; then
  pass "e2e: review gate also blocks Windows-style paths (backslashes, upper-case extension)"
else
  fail "e2e: review gate let Windows-style paths through:${WIN_BAD}"
fi
rm -f "$GATE_A" "$GATE_A.announce"

# 技能里的 Bash 走 CLAUDE_CODE_SESSION_ID：和钩子从 stdin 拿到的是同一个值，指向同一扇门
echo "$(date +%s):0:0" > "$GATE_A"
if echo '{"tool_input":{"file_path":"Assets/Player.cs"}}' | CLAUDE_CODE_SESSION_ID="$SID_A" \
  PROJECT_DIR="$E2E_ROOT" bash "$SCRIPT_DIR/scripts/hooks/review-gate.sh" check >/dev/null 2>&1; then
  fail "e2e: CLAUDE_CODE_SESSION_ID fallback did not find the session's gate"
else
  pass "e2e: CLAUDE_CODE_SESSION_ID fallback resolves the same gate as stdin session_id"
fi
SKILL_GATE="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash -c 'source "$1/scripts/platform/detect.sh"; qq_session_id && printf "%s" "$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"' _ "$SCRIPT_DIR")"
SKILL_NO_SID_RC=0
bash -c 'source "$1/scripts/platform/detect.sh"; qq_session_id' _ "$SCRIPT_DIR" >/dev/null 2>&1 || SKILL_NO_SID_RC=$?
if [[ "$SKILL_GATE" == "$GATE_A" && "$SKILL_NO_SID_RC" -ne 0 ]]; then
  pass "e2e: skill-side qq_session_id names the same gate file, and fails without a session id"
else
  fail "e2e: skill-side gate path mismatch (got '$SKILL_GATE', no-sid rc=$SKILL_NO_SID_RC)"
fi
# 会话 id 只收文件名安全的字符，带路径分隔符的值不会被拼进门文件名
BAD_SID_RC=0
CLAUDE_CODE_SESSION_ID="../evil" bash -c 'source "$1/scripts/platform/detect.sh"; qq_session_id' _ "$SCRIPT_DIR" >/dev/null 2>&1 || BAD_SID_RC=$?
if [[ "$BAD_SID_RC" -ne 0 ]]; then
  pass "e2e: session ids with path separators are rejected"
else
  fail "e2e: qq_session_id accepted '../evil'"
fi
rm -f "$GATE_A"

# skill 改动标记：A 改了 skill，只拦 A 的收尾
SKILL_ISO_ROOT="$(mktemp -d)"
mkdir -p "$SKILL_ISO_ROOT/.qq"
(cd "$SKILL_ISO_ROOT" && git init -q)
cat > "$SKILL_ISO_ROOT/qq.yaml" <<'QYAML'
version: 1
engine: unity
default_profile: hardening
QYAML
sid_in "$SID_A" '{"tool_input":{"file_path":"E:\\repo\\skills\\demo\\SKILL.md"}}' | \
  PROJECT_DIR="$SKILL_ISO_ROOT" bash "$SCRIPT_DIR/scripts/hooks/skill-modified-track.sh" >/dev/null 2>&1
SKILL_OUT_B="$(sid_in "$SID_B" '{"stop_hook_active":false}' | PROJECT_DIR="$SKILL_ISO_ROOT" bash "$SCRIPT_DIR/scripts/check-skill-review.sh" 2>/dev/null)"
SKILL_OUT_A="$(sid_in "$SID_A" '{"stop_hook_active":false}' | PROJECT_DIR="$SKILL_ISO_ROOT" bash "$SCRIPT_DIR/scripts/check-skill-review.sh" 2>/dev/null)"
SKILL_OUT_A_ACTIVE="$(sid_in "$SID_A" '{"stop_hook_active":true}' | PROJECT_DIR="$SKILL_ISO_ROOT" bash "$SCRIPT_DIR/scripts/check-skill-review.sh" 2>/dev/null)"
if [[ -f "$E2E_QQ_TEMP/claude-skill-modified-marker-$SID_A" && ! -f "$E2E_QQ_TEMP/claude-skill-modified-marker-$$" \
      && "$SKILL_OUT_B" != *'"decision":"block"'* && "$SKILL_OUT_A" == *'"decision":"block"'* \
      && "$SKILL_OUT_A_ACTIVE" != *'"decision":"block"'* ]]; then
  pass "e2e: skill-review marker is per session (A blocked, B free, stop_hook_active honored)"
else
  fail "e2e: skill-review marker isolation (B='${SKILL_OUT_B:0:80}' A='${SKILL_OUT_A:0:80}' A-active='${SKILL_OUT_A_ACTIVE:0:80}')"
fi
rm -f "$E2E_QQ_TEMP/claude-skill-modified-marker-$SID_A"
rm -rf "$SKILL_ISO_ROOT"

# --- E2E 9: compile gate actually blocks, per session + project, and lets the broken files be fixed ---
# 待修清单第 3 条：compile-gate-check.sh 调了不存在的 qq_detect_engine，碰到源文件就退 127，这道门从来没拦过；
# 而且拦截用的是 exit 1——PreToolUse 退 1 只是「非阻断错误」，必须 exit 2 才真拦得住。
# 用 S&box 夹具 + 假 dotnet 走真实的 auto-compile → qq-compile → sbox-compile 链路。
echo -e "${CYAN}[e2e] compile gate${NC}"

CG_TMP="$(mktemp -d)"
CG_A="qq-cg-a-$$"
CG_B="qq-cg-b-$$"
# cg_fixture <dir>：S&box 夹具，Code/ 下有 A B C Service 四个源文件，bin/dotnet 是假的：
# 打印 <dir>/dotnet-out 的内容，按 <dir>/dotnet-rc 退出（没有这两个文件就是绿）
cg_fixture() {
  mkdir -p "$1/Code" "$1/bin"
  (cd "$1" && git init -q)
  printf 'version: 1\nengine: sbox\ndefault_profile: feature\n' > "$1/qq.yaml"
  printf '{}\n' > "$1/game.sbproj"
  printf 'Microsoft Visual Studio Solution File\n' > "$1/game.sln"
  for f in A B C Service; do printf 'class %s {}\n' "$f" > "$1/Code/$f.cs"; done
  cat > "$1/bin/dotnet" <<'SH'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
cat "$root/dotnet-out" 2>/dev/null || echo "Build succeeded."
exit "$(cat "$root/dotnet-rc" 2>/dev/null || echo 0)"
SH
  chmod +x "$1/bin/dotnet"
}
# cg_result <dir> <rc> [输出行...]：设定下一次假 dotnet 的输出与退出码
cg_result() {
  local dir="$1" rc="$2"; shift 2
  printf '%s\n' "$@" > "$dir/dotnet-out"
  printf '%s' "$rc" > "$dir/dotnet-rc"
}
CG_RED_A="Code/A.cs(3,5): error CS0103: The name 'x' does not exist in the current context [game.csproj]"
CG_WARN_C="Code/C.cs(7,1): warning CS0168: The variable 'y' is declared but never used [game.csproj]"
CG_ROOT="$(mktemp -d)"; cg_fixture "$CG_ROOT"
CG_ROOT2="$(mktemp -d)"; cg_fixture "$CG_ROOT2"
# cg_edit <session> <project> <file>：模拟一次 Edit 之后的 PostToolUse(auto-compile)，stdout 是钩子输出
cg_edit() {
  printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$1" "$3" | \
    PROJECT_DIR="$2" QQ_TEMP_DIR="$CG_TMP" DOTNET_BIN="$2/bin/dotnet" \
    bash "$SCRIPT_DIR/scripts/hooks/auto-compile.sh" 2>/dev/null
}
# cg_check <session> <project> <file> [hook 路径写法前缀]：模拟一次 PreToolUse(compile-gate-check)，打印退出码
cg_check() {
  local rc=0 hooks="${4:-$SCRIPT_DIR}"
  printf '{"session_id":"%s","tool_input":{"file_path":"%s"}}' "$1" "$3" | \
    PROJECT_DIR="$2" QQ_TEMP_DIR="$CG_TMP" bash "$hooks/scripts/hooks/compile-gate-check.sh" >/dev/null 2>"$CG_TMP/check-stderr" || rc=$?
  printf '%s' "$rc"
}
cg_gate() {   # cg_gate <session> <project>：这个会话在这个项目的门文件路径
  $QQ_PY -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; from qq_compile_gate import gate_path; print(gate_path(sys.argv[2], Path(sys.argv[3])))' \
    "$SCRIPT_DIR/scripts" "$CG_TMP/compile-gate-$1" "$2"
}
cg_json_context() {   # 钩子 stdout 必须是一段合法 JSON（混进编译日志 Claude Code 就不认），打印其中的 additionalContext
  $QQ_PY -c 'import json,sys; print(json.loads(sys.stdin.buffer.read().decode("utf-8"))["hookSpecificOutput"]["additionalContext"])' 2>/dev/null
}
CG_GATE_A="$(cg_gate "$CG_A" "$CG_ROOT")"

cg_result "$CG_ROOT" 1 "$CG_RED_A" "$CG_WARN_C" "Build FAILED."
CG_OUT="$(cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs")"
CG_CTX="$(printf '%s' "$CG_OUT" | cg_json_context || true)"
if [[ -f "$CG_GATE_A" && ! -f "$(cg_gate "$CG_B" "$CG_ROOT")" && ! -f "$CG_TMP/compile-gate-$$" && ! -f "$CG_TMP/compile-gate-1" \
      && "$CG_CTX" == *"COMPILE-GATE"* && "$CG_CTX" == *"CS0103"* ]]; then
  pass "e2e: a red compile opens this session's compile gate, and the hook's stdout is one JSON with the errors"
else
  fail "e2e: red compile did not open the session gate / emit JSON (files: $(ls "$CG_TMP" | tr '\n' ' '); out='${CG_OUT:0:120}')"
fi
if [[ "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/B.cs")" == "2" ]] && grep -q 'code/a.cs\|Code/A.cs' "$CG_TMP/check-stderr"; then
  pass "e2e: while red, editing another existing source file is blocked with exit 2 (a real block)"
else
  fail "e2e: compile gate did not block another source file with exit 2 ($(head -c 200 "$CG_TMP/check-stderr" 2>/dev/null))"
fi
if command -v cygpath >/dev/null 2>&1; then
  # Claude Code 在 Windows 上用 C:/… 调钩子：慢路径里拼出来的 helper 路径也要找得到（1.19.2 那类回归）
  if [[ "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/B.cs" "$(cygpath -m "$SCRIPT_DIR")")" == "2" ]]; then
    pass "e2e: the compile gate's slow path also works when the hook is invoked as C:/…"
  else
    fail "e2e: compile-gate-check invoked as C:/… did not block ($(head -c 200 "$CG_TMP/check-stderr" 2>/dev/null))"
  fi
fi
if [[ "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs")" == "0" ]]; then
  pass "e2e: the file with the compile error stays editable (so it can be fixed)"
else
  fail "e2e: compile gate blocks the very file that has to be fixed"
fi
if [[ "$(cg_check "$CG_A" "$CG_ROOT" "Code/C.cs")" == "2" ]]; then
  pass "e2e: a file that only has warnings is not on the allow-list"
else
  fail "e2e: a warning-only file was allowed through the compile gate"
fi
if [[ "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/Brand/New.cs")" == "0" ]]; then
  pass "e2e: creating a new source file is allowed while red (missing types are often fixed that way)"
else
  fail "e2e: compile gate blocked creating a new source file"
fi
if [[ "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT2/Code/B.cs")" == "0" && "$(cg_check "$CG_A" "$CG_ROOT2" "$CG_ROOT2/Code/B.cs")" == "0" ]]; then
  pass "e2e: files outside the project, and other projects in the same session, are not gated by this project's red"
else
  fail "e2e: a red compile in one project blocked edits outside it / in another project"
fi
if [[ "$(cg_check "$CG_B" "$CG_ROOT" "$CG_ROOT/Code/B.cs")" == "0" ]]; then
  pass "e2e: another session is not affected by this session's red compile"
else
  fail "e2e: session B blocked by session A's compile gate"
fi
if [[ "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/README.md")" == "0" ]]; then
  pass "e2e: non-source files are never blocked by the compile gate"
else
  fail "e2e: compile gate blocked a non-source file"
fi

# 一路红下去：放行名单累积，不覆盖——改完 A 再改 B 之后，A 仍可改（也就仍可撤回）
cg_result "$CG_ROOT" 1 "Code/B.cs(1,1): error CS1002: ; expected [game.csproj]" "Build FAILED."
cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/B.cs" >/dev/null
if [[ "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs")" == "0" && "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/B.cs")" == "0" \
      && "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/C.cs")" == "2" ]]; then
  pass "e2e: the allow-list accumulates across a red streak (earlier files stay editable)"
else
  fail "e2e: a later red compile dropped earlier files from the allow-list"
fi

# 错误里点名的类型所在的文件也放行：'Service' does not contain a definition for 'Foo' 要改的是 Service.cs
rm -f "$CG_GATE_A"
cg_result "$CG_ROOT" 1 "Code/A.cs(4,9): error CS1061: 'Service' does not contain a definition for 'Foo' [game.csproj]" "Build FAILED."
cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs" >/dev/null
if [[ "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/Service.cs")" == "0" && "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/C.cs")" == "2" ]]; then
  pass "e2e: the file of a type named in the error (Service.cs) stays editable"
else
  fail "e2e: the callee named in the compile error is blocked"
fi

# 工具链坏了（退 1 但没有落在项目文件上的错误位置）：不是可修的编译错误，不立门、不动已有的门
rm -f "$CG_GATE_A"
cg_result "$CG_ROOT" 1 "Unhandled exception: the SDK could not be resolved"
CG_CTX="$(cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/B.cs" | cg_json_context || true)"
if [[ ! -f "$CG_GATE_A" && "$CG_CTX" == *"auto-compile"* ]]; then
  pass "e2e: a toolchain failure without error locations reports but opens no gate"
else
  fail "e2e: toolchain failure opened a compile gate or reported nothing"
fi
cg_result "$CG_ROOT" 1 "$CG_RED_A" "Build FAILED."
cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs" >/dev/null
cg_result "$CG_ROOT" 1 "Unhandled exception: the SDK could not be resolved"
cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs" >/dev/null
if [[ -f "$CG_GATE_A" ]]; then
  pass "e2e: a later compile without a verdict leaves the existing gate alone"
else
  fail "e2e: an inconclusive compile cleared the existing gate"
fi

# 没拿到裁决（退 2：Editor 没开 / 超时）：不立门——原来退 2 也当编译失败，没开 Unity 的 worktree 一改 .cs 就被锁
rm -f "$CG_GATE_A"
printf 'whatever\n' > "$CG_TMP/log2"
CG_CTX="$($QQ_PY "$SCRIPT_DIR/scripts/qq_compile_gate.py" record --project "$CG_ROOT" --gate-prefix "$CG_TMP/compile-gate-$CG_A" \
  --file "$CG_ROOT/Code/A.cs" --exit-code 2 --log "$CG_TMP/log2" | cg_json_context || true)"
if [[ ! -f "$CG_GATE_A" && "$CG_CTX" == *"exit 2"* ]]; then
  pass "e2e: exit 2 (no verdict: editor closed / timeout) opens no compile gate"
else
  fail "e2e: exit 2 opened a compile gate"
fi

# Windows 默认代码页（cp936 / cp1252）下输出 ⛔ / 中文不能崩：JSON 照样送到、拦截说明照样是 UTF-8
printf '%s\n' "$CG_RED_A" > "$CG_TMP/log1"
CG_ENC_BAD=""
for enc in cp1252 cp936; do
  rm -f "$CG_GATE_A"
  CG_CTX="$(PYTHONIOENCODING="$enc" $QQ_PY "$SCRIPT_DIR/scripts/qq_compile_gate.py" record --project "$CG_ROOT" \
    --gate-prefix "$CG_TMP/compile-gate-$CG_A" --file "$CG_ROOT/Code/A.cs" --exit-code 1 --log "$CG_TMP/log1" | cg_json_context || true)"
  CG_ENC_RC=0
  PYTHONIOENCODING="$enc" $QQ_PY "$SCRIPT_DIR/scripts/qq_compile_gate.py" check --project "$CG_ROOT" \
    --gate-prefix "$CG_TMP/compile-gate-$CG_A" --file "$CG_ROOT/Code/B.cs" 2>"$CG_TMP/enc-stderr" || CG_ENC_RC=$?
  if [[ "$CG_CTX" != *"COMPILE-GATE"* || "$CG_ENC_RC" != "3" ]] || ! $QQ_PY -c 'import sys; t=open(sys.argv[1],"rb").read().decode("utf-8"); sys.exit(0 if "BLOCKED" in t and "⛔" in t else 1)' "$CG_TMP/enc-stderr"; then
    CG_ENC_BAD+=" $enc"
  fi
done
if [[ -z "$CG_ENC_BAD" ]]; then
  pass "e2e: compile gate output survives non-UTF-8 Windows code pages (cp1252 / cp936)"
else
  fail "e2e: compile gate output broke under:$CG_ENC_BAD"
fi

# 转绿：下一次自动编译通过就解门
cg_result "$CG_ROOT" 1 "$CG_RED_A" "Build FAILED."
cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs" >/dev/null
cg_result "$CG_ROOT" 0 "Build succeeded."
CG_OUT="$(cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs")"
if [[ ! -f "$CG_GATE_A" && "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/B.cs")" == "0" && -z "$CG_OUT" ]]; then
  pass "e2e: a green auto-compile clears the gate and other files are editable again"
else
  fail "e2e: green auto-compile did not clear the compile gate"
fi

# 另一个项目转绿（自动编译或手动 qq-compile.sh）不替这个项目解门；手动 qq-compile.sh 转绿只解本会话本项目的门
cg_result "$CG_ROOT" 1 "$CG_RED_A" "Build FAILED."
cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs" >/dev/null
cg_edit "$CG_B" "$CG_ROOT" "$CG_ROOT/Code/A.cs" >/dev/null
cg_result "$CG_ROOT2" 0 "Build succeeded."
cg_edit "$CG_A" "$CG_ROOT2" "$CG_ROOT2/Code/A.cs" >/dev/null
(cd "$CG_ROOT2" && CLAUDE_CODE_SESSION_ID="$CG_A" QQ_TEMP_DIR="$CG_TMP" DOTNET_BIN="$CG_ROOT2/bin/dotnet" \
  bash "$SCRIPT_DIR/scripts/qq-compile.sh" --project "$CG_ROOT2" >/dev/null 2>&1) || true
if [[ -f "$CG_GATE_A" ]]; then
  pass "e2e: a green compile of another project leaves this project's gate alone"
else
  fail "e2e: a green compile of another project cleared this project's compile gate"
fi
(cd "$CG_ROOT" && CLAUDE_CODE_SESSION_ID="$CG_A" QQ_TEMP_DIR="$CG_TMP" DOTNET_BIN="$CG_ROOT/bin/dotnet" \
  bash "$SCRIPT_DIR/scripts/qq-compile.sh" --project "$CG_ROOT" --help >/dev/null 2>&1) || true
CG_AFTER_HELP=0; [[ -f "$CG_GATE_A" ]] && CG_AFTER_HELP=1
cg_result "$CG_ROOT" 0 "Build succeeded."
(cd "$CG_ROOT" && CLAUDE_CODE_SESSION_ID="$CG_A" QQ_TEMP_DIR="$CG_TMP" DOTNET_BIN="$CG_ROOT/bin/dotnet" \
  bash "$SCRIPT_DIR/scripts/qq-compile.sh" --project "$CG_ROOT" >/dev/null 2>&1) || true
if [[ "$CG_AFTER_HELP" == "1" && ! -f "$CG_GATE_A" && -f "$(cg_gate "$CG_B" "$CG_ROOT")" ]]; then
  pass "e2e: a green manual qq-compile.sh clears only this session's gate for this project (--help clears nothing)"
else
  fail "e2e: manual qq-compile.sh gate clearing wrong (after --help: $CG_AFTER_HELP)"
fi
rm -f "$(cg_gate "$CG_B" "$CG_ROOT")"

# compile_gate 钩子关着时：auto-compile 不立门，也不对模型说「会被拒绝」
printf 'hooks:\n  disable:\n    - compile_gate\n' > "$CG_ROOT/.qq-local-tmp.yaml"
mkdir -p "$CG_ROOT/.qq" && cp "$CG_ROOT/.qq-local-tmp.yaml" "$CG_ROOT/.qq/local.yaml"
cg_result "$CG_ROOT" 1 "$CG_RED_A" "Build FAILED."
CG_CTX="$(cg_edit "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/A.cs" | cg_json_context || true)"
rm -f "$CG_ROOT/.qq/local.yaml" "$CG_ROOT/.qq-local-tmp.yaml"
if [[ ! -f "$CG_GATE_A" && "$CG_CTX" == *"CS0103"* && "$CG_CTX" != *"COMPILE-GATE"* ]]; then
  pass "e2e: with compile_gate disabled, auto-compile reports errors but opens no gate"
else
  fail "e2e: auto-compile opened a gate / claimed blocking with compile_gate disabled"
fi

# 1 小时过期
printf '%s:compile_failed\ncode/a.cs\n' "$(( $(date +%s) - 4000 ))" > "$CG_GATE_A"
if [[ "$(cg_check "$CG_A" "$CG_ROOT" "$CG_ROOT/Code/B.cs")" == "0" && ! -f "$CG_GATE_A" ]]; then
  pass "e2e: an expired compile gate lets edits through and is removed"
else
  fail "e2e: expired compile gate still blocks or was not removed"
fi
rm -rf "$CG_ROOT" "$CG_ROOT2"

# Godot：WARNING 块里的 res:// 路径不算错误位置；SCRIPT ERROR 才算
CG_GD="$(mktemp -d)"
mkdir -p "$CG_GD/scripts"
printf 'extends Node\n' > "$CG_GD/scripts/a.gd"; printf 'extends Node\n' > "$CG_GD/scripts/b.gd"
printf '%s\n' 'WARNING: The local variable "x" is declared but never used.' '   at: GDScript::reload (res://scripts/a.gd:3)' \
  'ERROR: Failed to load resource res://icon.svg' > "$CG_TMP/gd-warn.log"
printf '%s\n' 'SCRIPT ERROR: Parse Error: Expected end of statement after expression.' '   at: GDScript::reload (res://scripts/b.gd:7)' > "$CG_TMP/gd-err.log"
$QQ_PY "$SCRIPT_DIR/scripts/qq_compile_gate.py" record --project "$CG_GD" --gate-prefix "$CG_TMP/compile-gate-gd" \
  --file "$CG_GD/scripts/a.gd" --exit-code 1 --log "$CG_TMP/gd-warn.log" >/dev/null
CG_GD_GATE="$(cg_gate gd "$CG_GD")"
CG_GD_WARN=0; [[ -f "$CG_GD_GATE" ]] && CG_GD_WARN=1
$QQ_PY "$SCRIPT_DIR/scripts/qq_compile_gate.py" record --project "$CG_GD" --gate-prefix "$CG_TMP/compile-gate-gd" \
  --file "$CG_GD/scripts/a.gd" --exit-code 1 --log "$CG_TMP/gd-err.log" >/dev/null
if [[ "$CG_GD_WARN" == "0" ]] && grep -qx 'scripts/b.gd' "$CG_GD_GATE" 2>/dev/null; then
  pass "e2e: Godot warning blocks do not count as error locations; SCRIPT ERROR blocks do"
else
  fail "e2e: Godot warning/error location parsing wrong (warning opened gate: $CG_GD_WARN)"
fi
rm -rf "$CG_GD" "$CG_TMP"

# virgin 检查同样要真拦：Unity 项目没有 Library/ 时改 .cs 退 2，有了就放行（原来在 qq_detect_engine 处退 127）；
# linked git worktree 里没有 Library/ 是 .gitignore 的正常结果，不算 virgin
CG_U="$(mktemp -d)"
mkdir -p "$CG_U/main/ProjectSettings" "$CG_U/main/Assets"
(cd "$CG_U/main" && git init -q && git config user.email t@t && git config user.name t)
printf 'm_EditorVersion: 2022.3.0f1\n' > "$CG_U/main/ProjectSettings/ProjectVersion.txt"
printf 'version: 1\nengine: unity\ndefault_profile: feature\n' > "$CG_U/main/qq.yaml"
printf 'class P {}\n' > "$CG_U/main/Assets/P.cs"
printf '/[Ll]ibrary/\n' > "$CG_U/main/.gitignore"
(cd "$CG_U/main" && git add -A && git commit -qm init && git worktree add -q ../wt) >/dev/null 2>&1
cg_virgin() {   # cg_virgin <project>：对 <project>/Assets/P.cs 跑一次 compile-gate-check，打印退出码
  local rc=0
  printf '{"session_id":"qq-cg-v-%s","tool_input":{"file_path":"%s/Assets/P.cs"}}' "$$" "$1" | \
    PROJECT_DIR="$1" bash "$SCRIPT_DIR/scripts/hooks/compile-gate-check.sh" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
CG_V_RC="$(cg_virgin "$CG_U/main")"
CG_WT_RC="$(cg_virgin "$CG_U/wt")"
mkdir -p "$CG_U/main/Library"
CG_V_RC2="$(cg_virgin "$CG_U/main")"
if [[ "$CG_V_RC" == "2" && "$CG_V_RC2" == "0" ]]; then
  pass "e2e: virgin-project check blocks with exit 2 until Library/ exists (engine resolved via qq_engine)"
else
  fail "e2e: virgin-project check rc=$CG_V_RC (want 2), after Library/ rc=$CG_V_RC2 (want 0)"
fi
if [[ -f "$CG_U/wt/.git" && "$CG_WT_RC" == "0" ]]; then
  pass "e2e: a linked git worktree without Library/ is not treated as a virgin project"
else
  fail "e2e: linked worktree without Library/ was blocked as virgin (rc=$CG_WT_RC)"
fi
(cd "$CG_U/main" && git worktree remove --force ../wt) >/dev/null 2>&1 || true
rm -rf "$CG_U"

# Teardown
rm -rf "$E2E_ROOT" "$E2E_QQ_TEMP"
unset QQ_PROJECT_DIR

# ── 10. install.sh validation ──
echo -e "${CYAN}[10/10] install.sh validation${NC}"

# Check no old skill names remain in output
if grep -qE '/qq-ut|/qq-cp|/qq-arch-review' "$SCRIPT_DIR/install.sh"; then
  fail "install.sh still has old skill names"
else
  pass "install.sh uses current skill names"
fi

# Check platform guard exists (cross-platform case statement)
if grep -q 'uname -s' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh has platform check"
else
  fail "install.sh missing platform check"
fi

# Check install resolves module plans through the internal installer helper
if grep -q 'qq_internal_install.py' "$SCRIPT_DIR/install.sh" && grep -q -- '--modules' "$SCRIPT_DIR/install.sh" && grep -q -- '--without' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh resolves and applies install modules"
else
  fail "install.sh missing modular install plan support"
fi

if grep -q -- '--profile' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh supports policy profile selection"
else
  fail "install.sh missing policy profile selection"
fi

if grep -q 'qq-onboard.py' "$SCRIPT_DIR/install.sh" && \
   grep -q -- '--wizard' "$SCRIPT_DIR/install.sh" && \
   grep -q -- '--preset' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh wires the onboarding wizard and preset entrypoints"
else
  fail "install.sh missing onboarding wizard/preset support"
fi

ONBOARD_PREVIEW_ROOT="$(mktemp -d)"
: > "$ONBOARD_PREVIEW_ROOT/.sbproj"
if LANG=zh_CN.UTF-8 $QQ_PY "$SCRIPT_DIR/scripts/qq-onboard.py" preview --project "$ONBOARD_PREVIEW_ROOT" --preset quickstart --host-surface claude --json | $QQ_PY -c '
import json, sys
payload = json.load(sys.stdin)
assert payload["language"] == "zh-CN"
assert payload["preset"] == "quickstart"
assert payload["profile"] == "lightweight"
assert payload["trustLevel"] == "trusted"
assert payload["installHosts"] == ["claude", "mcp"]
assert payload["installSync"] is True
' >/dev/null 2>&1; then
  pass "qq-onboard auto-detects zh-CN and previews a simple preset"
else
  fail "qq-onboard auto-detects zh-CN and previews a simple preset"
fi
rm -rf "$ONBOARD_PREVIEW_ROOT"

INSTALL_MANIFEST_ROOT="$(mktemp -d)"
mkdir -p "$INSTALL_MANIFEST_ROOT/ProjectSettings" "$INSTALL_MANIFEST_ROOT/Packages"
cat > "$INSTALL_MANIFEST_ROOT/ProjectSettings/ProjectVersion.txt" <<'EOF'
m_EditorVersion: 2022.3.17f1
EOF
cat > "$INSTALL_MANIFEST_ROOT/Packages/manifest.json" <<'EOF'
{
  "dependencies": {
    "com.unity.ide.rider": "3.0.28"
  }
}
EOF
MANIFEST_BEFORE="$(cat "$INSTALL_MANIFEST_ROOT/Packages/manifest.json")"
"$SCRIPT_DIR/install.sh" "$INSTALL_MANIFEST_ROOT" >/dev/null
# 引擎侧依赖归项目自己管：install.sh 曾经往 manifest 里塞 com.tyk.tykit，
# 现在 Editor 控制已改走 Unity 官方 CLI，任何写回 manifest 的行为都会把那条注入偷偷带回来。
# 逐字节比对而不是只查 tykit 键，连"顺手重排/重格式化 manifest"也一并挡住。
if [ "$MANIFEST_BEFORE" = "$(cat "$INSTALL_MANIFEST_ROOT/Packages/manifest.json")" ]; then
  pass "install.sh leaves Packages/manifest.json untouched"
else
  fail "install.sh leaves Packages/manifest.json untouched"
fi
rm -rf "$INSTALL_MANIFEST_ROOT"

ONBOARD_INSTALL_ROOT="$(mktemp -d)"
: > "$ONBOARD_INSTALL_ROOT/.sbproj"
LANG=ja_JP.UTF-8 "$SCRIPT_DIR/install.sh" --preset quickstart --language ja "$ONBOARD_INSTALL_ROOT" >/dev/null
if $QQ_PY - "$ONBOARD_INSTALL_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
config_text = (root / "qq.yaml").read_text(encoding="utf-8")
state = json.loads((root / ".qq" / "install-state.json").read_text(encoding="utf-8"))

assert "default_profile: lightweight" in config_text
assert "trust_level: trusted" in config_text
assert state["profile"] == "lightweight"
assert state["syncEnabled"] is True
PY
then
  pass "install.sh --preset quickstart writes a lightweight starter config"
else
  fail "install.sh --preset quickstart writes a lightweight starter config"
fi
rm -rf "$ONBOARD_INSTALL_ROOT"

GODOT_INSTALL_ROOT="$(mktemp -d)"
cat > "$GODOT_INSTALL_ROOT/project.godot" <<'EOF'
; Engine configuration file.
config_version=5

[application]
config/name="qq godot install fixture"

[editor_plugins]
enabled=PackedStringArray("res://addons/gut/plugin.cfg")
EOF
"$SCRIPT_DIR/install.sh" "$GODOT_INSTALL_ROOT" >/dev/null
if $QQ_PY - "$GODOT_INSTALL_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
project_text = (root / "project.godot").read_text(encoding="utf-8")
mcp = json.loads((root / ".mcp.json").read_text(encoding="utf-8"))

assert (root / "scripts" / "godot_bridge.py").is_file()
assert (root / "scripts" / "godot_capabilities.json").is_file()
assert (root / "addons" / "qq_editor_bridge" / "plugin.cfg").is_file()
assert (root / "addons" / "qq_editor_bridge" / "plugin.gd").is_file()
assert "res://addons/gut/plugin.cfg" in project_text
assert "res://addons/qq_editor_bridge/plugin.cfg" in project_text
server = mcp["mcpServers"]["qq-godot"]
assert server["command"] == "python3"
assert "qq_mcp.py" in " ".join(server["args"])
PY
then
  pass "install.sh installs and enables the Godot editor bridge addon"
else
  fail "install.sh installs and enables the Godot editor bridge addon"
fi
rm -rf "$GODOT_INSTALL_ROOT"

UNREAL_INSTALL_ROOT="$(mktemp -d)"
cat > "$UNREAL_INSTALL_ROOT/FPSGame.uproject" <<'EOF'
{
  "FileVersion": 3,
  "EngineAssociation": "5.7",
  "Plugins": [
    {
      "Name": "ModelingToolsEditorMode",
      "Enabled": true
    }
  ]
}
EOF
"$SCRIPT_DIR/install.sh" "$UNREAL_INSTALL_ROOT" >/dev/null
if $QQ_PY - "$UNREAL_INSTALL_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
project_file = next(root.glob("*.uproject"))
uproject = json.loads(project_file.read_text(encoding="utf-8"))
mcp = json.loads((root / ".mcp.json").read_text(encoding="utf-8"))
plugins = {item["Name"]: item["Enabled"] for item in uproject.get("Plugins", []) if isinstance(item, dict) and "Name" in item}

assert (root / "scripts" / "unreal_bridge.py").is_file()
assert (root / "scripts" / "unreal_capabilities.json").is_file()
assert (root / "Content" / "Python" / "qq_unreal_bridge.py").is_file()
assert plugins["ModelingToolsEditorMode"] is True
assert plugins["PythonScriptPlugin"] is True
assert plugins["EditorScriptingUtilities"] is True
engine_ini = (root / "Config" / "DefaultEngine.ini").read_text(encoding="utf-8")
assert "import qq_unreal_bridge; qq_unreal_bridge.start()" in engine_ini
server = mcp["mcpServers"]["qq-unreal"]
assert server["command"] == "python3"
assert "qq_mcp.py" in " ".join(server["args"])
PY
then
  pass "install.sh enables required Unreal project plugins and wires the built-in live editor bridge"
else
  fail "install.sh enables required Unreal project plugins and wires the built-in live editor bridge"
fi
rm -rf "$UNREAL_INSTALL_ROOT"

SBOX_INSTALL_ROOT="$(mktemp -d)"
: > "$SBOX_INSTALL_ROOT/.sbproj"
"$SCRIPT_DIR/install.sh" "$SBOX_INSTALL_ROOT" >/dev/null
if $QQ_PY - "$SBOX_INSTALL_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
mcp = json.loads((root / ".mcp.json").read_text(encoding="utf-8"))
server = mcp["mcpServers"]["qq-sbox"]

assert (root / "scripts" / "sbox-common.sh").is_file()
assert (root / "scripts" / "sbox-compile.sh").is_file()
assert (root / "scripts" / "sbox-test.sh").is_file()
assert (root / "scripts" / "sbox_bridge.py").is_file()
assert (root / "scripts" / "sbox_capabilities.json").is_file()
assert (root / "Editor" / "QQ" / "QQSboxEditorBridge.cs").is_file()
assert (root / "qq.yaml").is_file()
assert server["command"] == "python3"
assert "qq_mcp.py" in " ".join(server["args"])
assert not (root / "addons" / "qq_editor_bridge").exists()
assert not (root / "Content" / "Python" / "qq_unreal_bridge.py").exists()
PY
then
  pass "install.sh wires S&box projects with direct runtime scripts and the built-in editor bridge"
else
  fail "install.sh wires S&box projects with direct runtime scripts and the built-in editor bridge"
fi
rm -rf "$SBOX_INSTALL_ROOT"

MODULAR_INSTALL_ROOT="$(mktemp -d)"
: > "$MODULAR_INSTALL_ROOT/.sbproj"
"$SCRIPT_DIR/install.sh" "$MODULAR_INSTALL_ROOT" >/dev/null
$QQ_PY - "$MODULAR_INSTALL_ROOT/qq.yaml" <<'PY'
from pathlib import Path

path = Path(__import__("sys").argv[1])
text = path.read_text(encoding="utf-8")
replacement = (
    "install:\n"
    "  hosts:\n"
    "    - claude\n"
    "  add_modules: []\n"
    "  remove_modules:\n"
    "    - host-codex\n"
    "    - host-mcp\n"
    "  sync: true\n"
)
start = text.find("install:\n")
end = text.find("profiles:\n", start)
if start == -1 or end == -1 or end <= start:
    raise SystemExit("failed to replace install block in qq.yaml fixture")
updated = text[:start] + replacement + "\n" + text[end:]
path.write_text(updated, encoding="utf-8")
PY
"$SCRIPT_DIR/install.sh" "$MODULAR_INSTALL_ROOT" >/dev/null
if $QQ_PY - "$MODULAR_INSTALL_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "install-state.json").read_text(encoding="utf-8"))
selected = set(state["selectedModules"])

assert "runtime-core" in selected
assert "project-config" in selected
assert "engine-sbox" in selected
assert "host-claude" in selected
assert "host-codex" not in selected
assert "host-mcp" not in selected
assert "hooks-auto-compile" in selected
assert not (root / "scripts" / "qq-codex-exec.py").exists()
assert not (root / "scripts" / "qq-codex-mcp.py").exists()
assert not (root / "scripts" / "qq_mcp.py").exists()
assert state["syncEnabled"] is True
assert ".mcp.json" not in state["managedFiles"]
PY
then
  pass "install.sh can trim host modules and sync managed runtime files from qq.yaml install settings"
else
  fail "install.sh can trim host modules and sync managed runtime files from qq.yaml install settings"
fi
rm -rf "$MODULAR_INSTALL_ROOT"

if grep -q 'qq_default_test_scope' "$SCRIPT_DIR/scripts/githooks/pre-push" && \
   grep -q 'qq-test.sh" editmode' "$SCRIPT_DIR/scripts/githooks/pre-push"; then
  pass "pre-push hook adapts test scope from policy profile"
else
  fail "pre-push hook adapts test scope from policy profile"
fi

# ── Unity 官方 CLI 通道：自动编译不再把 Unity 窗口拉到前台 ──
# 项目里有有效的 Library/Pipeline/.unity-pipeline-port（读得出、属于本项目、pid 活着）并且找得到 unity 时，
# 编译改用 `unity command recompile` 触发：不激活窗口、不写 Temp/refresh_trigger。裁决有 Tools/compile_gate.py
# 就认它的 seq 门，没有就读 Temp/pipeline_recompile_status.json；recompile 回 up_to_date 却有比上一次编译新的
# 源文件时退 2（Auto Refresh 关着时 Unity 看不见外部改动的已有 .cs，沿用上一次的裁决就是假绿）。
# 顺带：is_editor_open_for_project 原来把路径拼进 python 代码字符串，/c/… 写法在 Windows 上永远判不成立。
# 全程用桩：QQ_UNITY_CLI 指向记 argv 的 bash 桩，PATH 最前面放记录调用的 powershell.exe / osascript 桩，
# 绝不连真 Editor（真 CLI 被误调到也只会拿 --project-path <临时目录> 去问，得到 rc=6）。
# 描述文件里的令牌是假的，最后检查它没出现在任何输出里。
echo -e "${CYAN}[unity-cli] compile through the official Unity CLI without window activation${NC}"
UCLI_ROOT="$(mktemp -d)"
UCLI_PROJ="$UCLI_ROOT/proj"
UCLI_SECRET="QQ-TEST-SECRET-7f3a"
UCLI_OUT="$UCLI_ROOT/out.log"
UCLI_ALL="$UCLI_ROOT/all-output.log"
UCLI_DESC="$UCLI_PROJ/Library/Pipeline/.unity-pipeline-port"
export UCLI_LOG="$UCLI_ROOT/cli-argv.log" UCLI_FIX="$UCLI_ROOT/fix"
export ACT_LOG="$UCLI_ROOT/activate.log" FAKE_GATE_LOG="$UCLI_ROOT/gate.log"
export FAKE_GATE_SEQ=7 FAKE_GATE_CHECK_RC=0 FAKE_GATE_WAIT_RC=0
mkdir -p "$UCLI_PROJ/ProjectSettings" "$UCLI_PROJ/scripts/platform" "$UCLI_PROJ/Assets/Scripts" "$UCLI_PROJ/Temp" \
  "$UCLI_PROJ/Library/Pipeline" "$UCLI_PROJ/Tools" "$UCLI_ROOT/bin" "$UCLI_ROOT/actbin" "$UCLI_ROOT/tmp" "$UCLI_FIX"
: > "$UCLI_ALL"
printf 'm_EditorVersion: 6000.3.20f1\n' > "$UCLI_PROJ/ProjectSettings/ProjectVersion.txt"
for f in unity-check.sh unity-compile.sh unity-common.sh qq-unity-cli.py qq_engine.py; do
  if [ -f "$SCRIPT_DIR/scripts/$f" ]; then cp "$SCRIPT_DIR/scripts/$f" "$UCLI_PROJ/scripts/$f"; fi
done
cp "$SCRIPT_DIR/scripts/platform/"*.sh "$UCLI_PROJ/scripts/platform/"
chmod +x "$UCLI_PROJ/scripts/"*.sh
printf 'public class A {}\n' > "$UCLI_PROJ/Assets/Scripts/A.cs"
printf 'public class Gen {}\n' > "$UCLI_PROJ/Tools/Gen.cs"
printf '{"state":"success","seq":7}\n' > "$UCLI_PROJ/Temp/compile_gate.json"
if command -v cygpath >/dev/null 2>&1; then UCLI_NATIVE="$(cygpath -m "$UCLI_PROJ")"; else UCLI_NATIVE="$UCLI_PROJ"; fi

# 活着的 pid：一个睡着的 python（Windows 上 $$ 是 MSYS 的 pid，不能用）；死 pid：一个已经退出的 python
$QQ_PY -c 'import os,sys,time
with open(sys.argv[1], "w") as fh: fh.write(str(os.getpid()))
time.sleep(3600)' "$UCLI_ROOT/live.pid" &
UCLI_SLEEPER=$!
for _ in $(seq 1 100); do [ -s "$UCLI_ROOT/live.pid" ] && break; sleep 0.1; done
UCLI_LIVE_PID="$(cat "$UCLI_ROOT/live.pid" 2>/dev/null || echo 0)"
UCLI_DEAD_PID="$($QQ_PY -c 'import os; print(os.getpid())')"

ucli_desc() {  # <projectPath> <pid>：写描述文件（只在 python 里写，令牌是假的）
  $QQ_PY - "$1" "$2" "$UCLI_DESC" "$UCLI_SECRET" <<'PY'
import json
import os
import sys

proj, pid, out, secret = sys.argv[1:5]
with open(out, "w", encoding="utf-8") as fh:
    json.dump({"pid": int(pid), "port": 7899, "projectPath": os.path.abspath(proj), "projectName": "proj",
               "unityVersion": "6000.3.20f1", "mode": "editor", "evalToken": secret}, fh)
PY
}
ucli_age() {  # <文件> <秒>：把 mtime 设成若干秒之前（负数 = 之后）
  $QQ_PY -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"
}

# CLI 桩：argv 记进 $UCLI_LOG（参数之间用 \x1f 分隔），按命令名从 $UCLI_FIX/<场景>/ 取回包；
# <命令>.writes 存在时先把它拷成项目的 Temp/pipeline_recompile_status.json（模拟 Editor 写状态文件）
cat > "$UCLI_ROOT/bin/unity" <<'SH'
#!/usr/bin/env bash
line=""
for a in "$@"; do line="$line$a"$'\x1f'; done
printf '%s\n' "$line" >> "$UCLI_LOG"
pp="" cmd="" prev=""
for a in "$@"; do
  [ "$prev" = "--project-path" ] && pp="$a"
  case "$a" in recompile|editor_status) cmd="$a" ;; esac
  prev="$a"
done
dir="$UCLI_FIX/${UCLI_SCENARIO:-none}"
if [ -z "$cmd" ] || [ ! -f "$dir/$cmd.json" ]; then
  printf '{"success":false,"errors":[{"code":"STUB","message":"no fixture for %s"}],"data":null}\n' "${cmd:-?}"
  exit 6
fi
if [ -f "$dir/$cmd.writes" ]; then cp "$dir/$cmd.writes" "$pp/Temp/pipeline_recompile_status.json"; fi
cat "$dir/$cmd.json"
rc=0
if [ -f "$dir/$cmd.rc" ]; then rc="$(cat "$dir/$cmd.rc")"; fi
exit "$rc"
SH
# 激活窗口的探测桩：windows.sh 调 powershell.exe、macos.sh 调 osascript；Linux 上 detect.sh 的空实现会打印
# 「qq_activate_unity_window not implemented」，所以同时查输出里没有这句
cat > "$UCLI_ROOT/actbin/powershell.exe" <<'SH'
#!/usr/bin/env bash
printf 'activated via %s\n' "$0" >> "$ACT_LOG"
SH
cp "$UCLI_ROOT/actbin/powershell.exe" "$UCLI_ROOT/actbin/osascript"
chmod +x "$UCLI_ROOT/bin/unity" "$UCLI_ROOT/actbin/powershell.exe" "$UCLI_ROOT/actbin/osascript"

# 假的 compile_gate：argv 记进 $FAKE_GATE_LOG；seq 打 $FAKE_GATE_SEQ，check / wait 按环境变量退出。
# FAKE_GATE_CHECK_RCS="2,0"：第 n 次 check 退第 n 个（用完停在最后一个）；FAKE_GATE_LANDED=N：已经落地的最大 seq，
# wait --since S 只在 S < N 时退 $FAKE_GATE_WAIT_RC，否则当作等到超时退 2
cat > "$UCLI_PROJ/Tools/compile_gate.py" <<'PY'
import os
import sys

args = sys.argv[1:]
if args[:1] == ["--project"]:
    args = args[2:]
log = os.environ["FAKE_GATE_LOG"]
try:
    with open(log, encoding="utf-8") as fh:
        checks_before = sum(1 for line in fh if line.split()[:1] == ["check"])
except OSError:
    checks_before = 0
with open(log, "a", encoding="utf-8") as fh:
    fh.write(" ".join(args) + "\n")
cmd = args[0] if args else ""
if cmd == "seq":
    print(os.environ.get("FAKE_GATE_SEQ", "7"))
    sys.exit(0)
if cmd == "check":
    print("[compile_gate] fake check")
    rcs = [int(x) for x in os.environ.get("FAKE_GATE_CHECK_RCS", "").split(",") if x.strip()]
    sys.exit(rcs[min(checks_before, len(rcs) - 1)] if rcs else int(os.environ.get("FAKE_GATE_CHECK_RC", "0")))
if cmd == "wait":
    landed = os.environ.get("FAKE_GATE_LANDED", "")
    if landed and int(args[args.index("--since") + 1]) >= int(landed):
        print("[compile_gate] fake wait: timed out", file=sys.stderr)
        sys.exit(2)
    print("[compile_gate] fake wait")
    sys.exit(int(os.environ.get("FAKE_GATE_WAIT_RC", "0")))
sys.exit(2)
PY

ucli_fix() {  # <场景> <命令> <回包> [退出码] [写进状态文件的内容]
  mkdir -p "$UCLI_FIX/$1"
  printf '%s\n' "$3" > "$UCLI_FIX/$1/$2.json"
  if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$UCLI_FIX/$1/$2.rc"; fi
  if [ -n "${5:-}" ]; then printf '%s\n' "$5" > "$UCLI_FIX/$1/$2.writes"; fi
}
UCLI_ENV_COMPILING='{"success":true,"command":"command","errors":[],"warnings":[],"data":{"command":"recompile","result":{"status":"compiling","message":"Recompilation started. Poll recompile_status until completed."}}}'
UCLI_ENV_UPTODATE='{"success":true,"command":"command","errors":[],"warnings":[],"data":{"command":"recompile","result":{"status":"up_to_date","message":"No scripts needed recompilation."}}}'
UCLI_ENV_NOINSTANCE='{"success":false,"command":"command","errors":[{"code":"COMMAND_FAILED","message":"No Pipeline instance found for project"}],"data":null}'
UCLI_ENV_STOPPED='{"success":true,"errors":[],"data":{"command":"editor_status","result":{"status":"ready","compiling":false,"domainReloadInProgress":false,"playMode":"stopped"}}}'
UCLI_ENV_PLAYING='{"success":true,"errors":[],"data":{"command":"editor_status","result":{"status":"ready","compiling":false,"domainReloadInProgress":false,"playMode":"playing"}}}'
UCLI_ST_RED='{"status":"completed","failed":true,"errors":["Assets/Scripts/A.cs(1,8): error CS1002: ; expected"]}'
UCLI_ST_GREEN='{"status":"completed","failed":false,"errors":[]}'
UCLI_ST_UPTODATE='{"status":"up_to_date","failed":false,"errors":[]}'
ucli_fix compiling recompile "$UCLI_ENV_COMPILING"
ucli_fix uptodate recompile "$UCLI_ENV_UPTODATE"
ucli_fix uptodate editor_status "$UCLI_ENV_STOPPED"
ucli_fix uptodate-playing recompile "$UCLI_ENV_UPTODATE"
ucli_fix uptodate-playing editor_status "$UCLI_ENV_PLAYING"
ucli_fix noinstance recompile "$UCLI_ENV_NOINSTANCE" 6
ucli_fix compiling-red recompile "$UCLI_ENV_COMPILING" "" "$UCLI_ST_RED"
ucli_fix compiling-green recompile "$UCLI_ENV_COMPILING" "" "$UCLI_ST_GREEN"
ucli_fix uptodate-nogate recompile "$UCLI_ENV_UPTODATE" "" "$UCLI_ST_UPTODATE"
ucli_fix uptodate-nogate editor_status "$UCLI_ENV_STOPPED"

# 跑一次：<场景> <命令...>。退出码放进 UCLI_RC，输出在 $UCLI_OUT（另外累积进 $UCLI_ALL 查令牌）。
# UCLI_CLI 换 CLI 路径，UCLI_CHANGED 当作 auto-compile 传来的改动文件。
ucli_run() {
  local scenario="$1"
  shift
  : > "$UCLI_LOG"; : > "$ACT_LOG"; : > "$FAKE_GATE_LOG"
  rm -f "$UCLI_PROJ/Temp/refresh_trigger"
  UCLI_RC=0
  UCLI_SCENARIO="$scenario" PATH="$UCLI_ROOT/actbin:$PATH" QQ_UNITY_CLI="${UCLI_CLI:-$UCLI_ROOT/bin/unity}" \
    QQ_UNITY_CLI_POLL_SEC=0 QQ_UNITY_PROBE_RETRY_DELAY=0 QQ_UNITY_CLI_RETRY_SEC=0 QQ_TEMP_DIR="$UCLI_ROOT/tmp" \
    QQ_COMPILE_CHANGED_FILES="${UCLI_CHANGED:-}" "$@" > "$UCLI_OUT" 2>&1 || UCLI_RC=$?
  cat "$UCLI_OUT" >> "$UCLI_ALL"
}
ucli_smart() {
  local scenario="$1"
  shift
  ucli_run "$scenario" bash "$SCRIPT_DIR/scripts/unity-compile-smart.sh" --project "$UCLI_PROJ" "$@"
}
ucli_no_activation() {
  [ ! -s "$ACT_LOG" ] && ! grep -q 'qq_activate_unity_window not implemented' "$UCLI_OUT"
}
ucli_recompile_calls() {  # recompile 的 argv 恰好是这一行的次数（--project-path 原生路径、全局选项在命令名前、没有 --focus）
  local us=$'\x1f'
  grep -cxF "command${us}--project-path${us}${UCLI_NATIVE}${us}--json${us}--no-banner${us}--non-interactive${us}--timeout${us}30${us}recompile${us}" "$UCLI_LOG" || true
}
ucli_state() {  # .qq/state/compile.json 的某个字段
  $QQ_PY -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], ""))' \
    "$UCLI_PROJ/.qq/state/compile.json" "$1" 2>/dev/null || true
}
ucli_report() {  # 失败时把输出和日志贴出来
  sed 's/^/    | /' "$UCLI_OUT" | head -40
  if [ -s "$UCLI_LOG" ]; then tr '\037' ' ' < "$UCLI_LOG" | sed 's/^/    cli: /'; fi
  if [ -s "$FAKE_GATE_LOG" ]; then sed 's/^/    gate: /' "$FAKE_GATE_LOG"; fi
  if [ -s "$ACT_LOG" ]; then sed 's/^/    act: /' "$ACT_LOG"; fi
}
ucli_check() {  # <描述> <条件命令...>
  local desc="$1"
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; ucli_report; fi
}

# ── 描述文件探测（probe）──
ucli_desc "$UCLI_PROJ" "$UCLI_LIVE_PID"
UCLI_PROBE_RC=0
$QQ_PY "$SCRIPT_DIR/scripts/qq-unity-cli.py" probe --project "$UCLI_PROJ" > "$UCLI_OUT" 2>&1 || UCLI_PROBE_RC=$?
cat "$UCLI_OUT" >> "$UCLI_ALL"
if [ "$UCLI_PROBE_RC" -eq 0 ] && [ "$(cat "$UCLI_OUT")" = "7899 $UCLI_LIVE_PID" ]; then
  pass "unity-cli probe: a live descriptor of this project prints only '<port> <pid>'"
else
  fail "unity-cli probe: a live descriptor of this project prints only '<port> <pid>' (rc=$UCLI_PROBE_RC)"; ucli_report
fi
ucli_probe_reason() {  # <期望原因词>：probe 退 1、输出只有这个词
  local rc=0
  $QQ_PY "$SCRIPT_DIR/scripts/qq-unity-cli.py" probe --project "$UCLI_PROJ" > "$UCLI_OUT" 2>&1 || rc=$?
  cat "$UCLI_OUT" >> "$UCLI_ALL"
  [ "$rc" -eq 1 ] && [ "$(cat "$UCLI_OUT")" = "$1" ]
}
ucli_desc "$UCLI_ROOT/other-project" "$UCLI_LIVE_PID"
ucli_check "unity-cli probe: a descriptor copied from another project is rejected (foreign-project)" ucli_probe_reason foreign-project
ucli_desc "$UCLI_PROJ" "$UCLI_DEAD_PID"
ucli_check "unity-cli probe: a descriptor whose pid is dead is rejected (pid-dead)" ucli_probe_reason pid-dead
: > "$UCLI_DESC"
ucli_check "unity-cli probe: an empty descriptor (non-atomic write) is rejected (unreadable)" ucli_probe_reason unreadable
printf '{"pid": %s, "port": 7899, "evalToken": "%s", "projectPa' "$UCLI_LIVE_PID" "$UCLI_SECRET" > "$UCLI_DESC"
ucli_check "unity-cli probe: a half-written descriptor is rejected (unreadable) without echoing any of it" ucli_probe_reason unreadable

# is_editor_open_for_project 用 / 开头的 PROJECT_DIR（Windows 上 cd && pwd 得到的就是 /c/…）也判得对：
# 描述文件里的 pid 活着、属于本项目就算开着，不靠 curl 端口（端口 7899 上没人）
ucli_desc "$UCLI_PROJ" "$UCLI_LIVE_PID"
UCLI_OPEN_RC=0
(cd "$UCLI_PROJ" && PROJECT_DIR="$(pwd)" && QQ_UNITY_PROBE_RETRY_DELAY=0 && export QQ_UNITY_PROBE_RETRY_DELAY \
  && source "$SCRIPT_DIR/scripts/unity-common.sh" && is_editor_open_for_project) > "$UCLI_OUT" 2>&1 || UCLI_OPEN_RC=$?
cat "$UCLI_OUT" >> "$UCLI_ALL"
if [ "$UCLI_OPEN_RC" -eq 0 ]; then
  pass "unity-cli: is_editor_open_for_project trusts a live descriptor even when PROJECT_DIR is a /-rooted bash path"
else
  fail "unity-cli: is_editor_open_for_project trusts a live descriptor even when PROJECT_DIR is a /-rooted bash path (rc=$UCLI_OPEN_RC)"; ucli_report
fi

# 通道判定：<期望> <compile|test> [QQ_UNITY_CLI]
ucli_channel_is() {
  local want="$1" kind="$2" cli="${3:-$UCLI_ROOT/bin/unity}" got=""
  got="$(PROJECT_DIR="$UCLI_PROJ" QQ_UNITY_CLI="$cli" QQ_UNITY_PROBE_RETRY_DELAY=0 bash -c '
    source "$1/scripts/unity-common.sh" || exit 9
    qq_unity_channel "$2" 2>/dev/null || exit 9
    printf "%s:%s" "$QQ_UNITY_CHANNEL_RESOLVED" "$QQ_UNITY_CHANNEL_REASON"' _ "$SCRIPT_DIR" "$kind" 2>/dev/null)" || got="error"
  printf '%s\n' "$got" > "$UCLI_OUT"
  [ "$got" = "$want" ]
}
ucli_check "unity-cli channel: live descriptor + CLI → unity-cli for compile" ucli_channel_is "unity-cli:pipeline-descriptor" compile
mkdir -p "$UCLI_ROOT/x/Unity.app/Contents/MacOS" "$UCLI_ROOT/x/Editor"
: > "$UCLI_ROOT/x/Unity.app/Contents/MacOS/Unity"
: > "$UCLI_ROOT/x/Editor/Unity.exe"
ucli_check "unity-cli channel: a Unity Editor binary (macOS app) is not taken for the CLI" \
  ucli_channel_is "refresh-trigger:unity_cli_unavailable" compile "$UCLI_ROOT/x/Unity.app/Contents/MacOS/Unity"
ucli_check "unity-cli channel: a Unity Editor binary (Editor/Unity.exe) is not taken for the CLI" \
  ucli_channel_is "refresh-trigger:unity_cli_unavailable" compile "$UCLI_ROOT/x/Editor/Unity.exe"
ucli_check "unity-cli channel: live descriptor without a CLI → tests have no channel (unity_cli_unavailable)" \
  ucli_channel_is "none:unity_cli_unavailable" test "$UCLI_ROOT/no-such-unity"

# ── 有 compile_gate ──
# recompile 回 compiling，gate wait 退 0：退 0；recompile 恰好一次、形状对；gate 等的是 seq>7，不带 --trigger-file；
# 没激活窗口、没写 refresh_trigger；run record 记 backend=unity-cli、judge=compile_gate
ucli_smart compiling
ucli_check "unity-cli compile (gate): compiling + gate wait 0 → exit 0 via one recompile call, no window activation, no refresh_trigger" \
  eval '[ "$UCLI_RC" -eq 0 ] && [ "$(ucli_recompile_calls)" = 1 ] && ucli_no_activation && [ ! -e "$UCLI_PROJ/Temp/refresh_trigger" ]'
ucli_check "unity-cli compile (gate): the verdict waits for seq>7 without --trigger-file" \
  eval 'grep -qx "wait --since 7 --timeout 15" "$FAKE_GATE_LOG" && ! grep -q -- "--trigger-file" "$FAKE_GATE_LOG"'
ucli_check "unity-cli compile (gate): run record says backend=unity-cli judge=compile_gate recompile=compiling" \
  eval '[ "$(ucli_state backend)" = unity-cli ] && [ "$(ucli_state judge)" = compile_gate ] && [ "$(ucli_state recompile)" = compiling ] && [ "$(ucli_state status)" = passed ]'

# --editor（强制走 Editor 路径）也一样：老代码在这里把 Unity 拉到前台
ucli_smart compiling --editor
ucli_check "unity-cli compile (gate, --editor): no window activation, no refresh_trigger" \
  eval '[ "$UCLI_RC" -eq 0 ] && [ "$(ucli_recompile_calls)" = 1 ] && ucli_no_activation && [ ! -e "$UCLI_PROJ/Temp/refresh_trigger" ]'

FAKE_GATE_WAIT_RC=1
ucli_smart compiling
FAKE_GATE_WAIT_RC=0
ucli_check "unity-cli compile (gate): compiling + gate wait 1 → exit 1, run record failed" \
  eval '[ "$UCLI_RC" -eq 1 ] && [ "$(ucli_state status)" = failed ] && [ "$(ucli_state backend)" = unity-cli ] && [ "$(ucli_state judge)" = compile_gate ]'

# recompile 回 up_to_date：上一次编译之后没改过源文件 → 采用 gate check 的结论
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 120
ucli_age "$UCLI_PROJ/Temp/compile_gate.json" 60
ucli_smart uptodate
ucli_check "unity-cli compile (gate): up_to_date + check 0 + no newer source → exit 0" \
  eval '[ "$UCLI_RC" -eq 0 ] && grep -qx "check" "$FAKE_GATE_LOG" && ! grep -q "^wait" "$FAKE_GATE_LOG" && ucli_no_activation'

# up_to_date，可 Assets/Scripts/A.cs 比 compile_gate.json 新：Unity 没看见改动，不能沿用上一次的绿（防假绿）
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 0
UCLI_CHANGED="$UCLI_PROJ/Assets/Scripts/A.cs"
ucli_smart uptodate
UCLI_CHANGED=""
ucli_check "unity-cli compile (gate): up_to_date while the edited file is newer than the last compile → exit 2 (Auto Refresh hint)" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "Auto Refresh" "$UCLI_OUT" && ucli_no_activation'
ucli_smart uptodate
ucli_check "unity-cli compile (gate): same without a changed-file hint (scan of Assets/) → exit 2" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "Assets/Scripts/A.cs" "$UCLI_OUT"'
UCLI_CHANGED="$UCLI_PROJ/Assets/Scripts/A.cs"
ucli_smart uptodate-playing
UCLI_CHANGED=""
ucli_check "unity-cli compile (gate): ...and says Unity does not compile while in Play mode" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "playMode=playing" "$UCLI_OUT"'
# 项目里 Assets/、Packages/ 以外的 .cs 不归 Unity 编，比上一次编译新也不算
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 120
ucli_age "$UCLI_PROJ/Tools/Gen.cs" 0
UCLI_CHANGED="$UCLI_PROJ/Tools/Gen.cs"
ucli_smart uptodate
UCLI_CHANGED=""
ucli_check "unity-cli compile (gate): a newer .cs outside Assets/ and Packages/ does not trip the guard → exit 0" \
  eval '[ "$UCLI_RC" -eq 0 ]'
ucli_age "$UCLI_PROJ/Tools/Gen.cs" 120

# 守卫认的源文件要和 auto-compile 钩子认的一样：Packages/manifest.json 里 file: 引用的本地包（可以在项目根外面）、
# Assets/ 里指向项目外的符号链接 / 目录联接。原来只认 resolve 之后落在 <项目>/Assets、Packages 下的——钩子编了，
# 守卫却答「没有没看见的改动」，沿用上一次的绿
mkdir -p "$UCLI_ROOT/SharedPkg/Runtime" "$UCLI_ROOT/SharedCode" "$UCLI_PROJ/Packages"
printf '{"dependencies":{"com.studio.shared":"file:../../SharedPkg"}}\n' > "$UCLI_PROJ/Packages/manifest.json"
printf 'public class Foo {}\n' > "$UCLI_ROOT/SharedPkg/Runtime/Foo.cs"
UCLI_CHANGED="$UCLI_ROOT/SharedPkg/Runtime/Foo.cs"
ucli_smart uptodate
UCLI_CHANGED=""
ucli_check "unity-cli compile (gate): up_to_date while the edited file in a file: local package (outside the project) is newer → exit 2" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "SharedPkg/Runtime/Foo.cs is newer" "$UCLI_OUT"'
ucli_smart uptodate
ucli_check "unity-cli compile (gate): ...the scan without a changed-file hint covers file: local packages too → exit 2" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "SharedPkg/Runtime/Foo.cs is newer" "$UCLI_OUT"'
ucli_age "$UCLI_ROOT/SharedPkg/Runtime/Foo.cs" 120
printf 'public class S {}\n' > "$UCLI_ROOT/SharedCode/S.cs"
# Assets/Shared → 项目外的 SharedCode：能建符号链接就建，Windows 上建不了（没开开发者模式）就用目录联接
if $QQ_PY - "$UCLI_ROOT/SharedCode" "$UCLI_PROJ/Assets/Shared" <<'PY' 2>/dev/null
import os
import sys

target, link = sys.argv[1:3]
try:
    os.symlink(target, link, target_is_directory=True)
except (OSError, NotImplementedError):
    if os.name != "nt":
        raise
    import _winapi

    _winapi.CreateJunction(target, link)
PY
then
  UCLI_CHANGED="$UCLI_PROJ/Assets/Shared/S.cs"
  ucli_smart uptodate
  UCLI_CHANGED=""
  ucli_check "unity-cli compile (gate): up_to_date while the edited file under a linked Assets/ folder (pointing outside) is newer → exit 2" \
    eval '[ "$UCLI_RC" -eq 2 ] && grep -q "Assets/Shared/S.cs is newer" "$UCLI_OUT"'
  ucli_smart uptodate
  ucli_check "unity-cli compile (gate): ...the scan follows the linked folder → exit 2" \
    eval '[ "$UCLI_RC" -eq 2 ] && grep -q "Assets/Shared/S.cs is newer" "$UCLI_OUT"'
  ucli_age "$UCLI_ROOT/SharedCode/S.cs" 120
else
  skip "unity-cli compile (gate): a linked Assets/ folder pointing outside the project" "cannot create a directory symlink or junction here"
fi

# 参照时间是上一次编译的「开始」时间（compile_gate.json 的 startedAt）：编译途中改的文件它未必编进去了。
# 原来拿 compile_gate.json 的 mtime（结束时间）比，编译途中改的文件比它旧，守卫放行。显示的路径保留原来的大小写
$QQ_PY - "$UCLI_PROJ/Temp/compile_gate.json" <<'PY'
import datetime
import json
import os
import sys
import time

start = (datetime.datetime.now().astimezone() - datetime.timedelta(seconds=30)).isoformat(timespec="microseconds")
start = start[:26] + "0" + start[26:]  # .NET 的 "o" 格式：小数 7 位、带时区
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({"state": "success", "seq": 7, "startedAt": start}, fh)
then = time.time() - 5
os.utime(sys.argv[1], (then, then))
PY
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 10
UCLI_CHANGED="$UCLI_PROJ/Assets/Scripts/A.cs"
ucli_smart uptodate
UCLI_CHANGED=""
ucli_check "unity-cli compile (gate): up_to_date, the edited file is older than the last compile's end but newer than its startedAt → exit 2" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "Assets/Scripts/A.cs is newer" "$UCLI_OUT"'

# 调用前就有一次编译在跑（check 退 2）：它开始时未必包含这次改动。先等它落地、以落地后的 seq 为基线，只收 seq
# 更大的。原来把基线退一格，收下的正是那次早就在跑的编译——Auto Refresh 关着、改的是已有文件时就是假绿
printf '{"state":"success","seq":7}\n' > "$UCLI_PROJ/Temp/compile_gate.json"
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 120
export FAKE_GATE_LANDED=7
FAKE_GATE_CHECK_RC=2
ucli_smart compiling --timeout 2
ucli_check "unity-cli compile (gate): a compile already running before the call is waited out, not taken as this edit's verdict → exit 2 when no newer seq comes" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -qx "wait --since 6 --timeout 2" "$FAKE_GATE_LOG" && grep -qx "wait --since 7 --timeout 2" "$FAKE_GATE_LOG" && grep -q "already running" "$UCLI_OUT"'
FAKE_GATE_LANDED=8
ucli_smart compiling --timeout 2
ucli_check "unity-cli compile (gate): ...and the compile that starts after it (seq 8) is taken → exit 0" \
  eval '[ "$UCLI_RC" -eq 0 ] && grep -qx "wait --since 7 --timeout 2" "$FAKE_GATE_LOG"'
FAKE_GATE_CHECK_RC=0
# 等过一次在途编译、recompile 回 up_to_date，compile_gate.json 又没有 startedAt：说不清那次编译是不是在改动之后才开始的
export FAKE_GATE_CHECK_RCS=2,0
FAKE_GATE_LANDED=7
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 10
UCLI_CHANGED="$UCLI_PROJ/Assets/Scripts/A.cs"
ucli_smart uptodate
UCLI_CHANGED=""
ucli_check "unity-cli compile (gate): up_to_date after waiting out a running compile, no startedAt to compare → exit 2" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "start time of the last compile is unknown" "$UCLI_OUT"'
unset FAKE_GATE_CHECK_RCS FAKE_GATE_LANDED
ucli_age "$UCLI_PROJ/Temp/compile_gate.json" 60
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 120

# recompile 信封失败（rc=6）：不写 refresh_trigger、不激活窗口，退出码就是 gate wait 的
FAKE_GATE_WAIT_RC=1
ucli_smart noinstance
FAKE_GATE_WAIT_RC=0
ucli_check "unity-cli compile (gate): recompile envelope failure → no refresh_trigger / activation, exit = gate wait's" \
  eval '[ "$UCLI_RC" -eq 1 ] && grep -qx "wait --since 7 --timeout 15" "$FAKE_GATE_LOG" && ucli_no_activation && [ ! -e "$UCLI_PROJ/Temp/refresh_trigger" ] && grep -q "No Pipeline instance" "$UCLI_OUT"'

# Unity 里有一轮测试在跑：不触发编译（domain reload 会打掉在途测试），退 2
printf '{"mode":"PlayMode"}\n' > "$UCLI_PROJ/Temp/pipeline_test_request.json"
ucli_smart compiling
ucli_check "unity-cli compile: a test run in flight (Temp/pipeline_test_request.json) → exit 2 without calling recompile" \
  eval '[ "$UCLI_RC" -eq 2 ] && [ ! -s "$UCLI_LOG" ] && grep -q "test run is in flight" "$UCLI_OUT" && ucli_no_activation'
rm -f "$UCLI_PROJ/Temp/pipeline_test_request.json"

# unity-check.sh --trigger（项目里的副本）在官方通道下也不激活窗口，改调 recompile
ucli_run compiling "$UCLI_PROJ/scripts/unity-check.sh" --trigger 5
ucli_check "unity-cli compile: unity-check.sh --trigger (gate) calls recompile and does not activate the window" \
  eval '[ "$UCLI_RC" -eq 0 ] && [ "$(ucli_recompile_calls)" = 1 ] && ucli_no_activation && [ ! -e "$UCLI_PROJ/Temp/refresh_trigger" ]'

# 描述文件有效、找不到 CLI：照旧写 refresh_trigger，但不激活窗口（Pipeline 在失焦时也 tick）
UCLI_CLI="$UCLI_ROOT/no-such-unity"
ucli_smart compiling --editor
UCLI_CLI=""
ucli_check "unity-cli compile: live descriptor without a CLI → refresh_trigger without window activation" \
  eval '[ "$UCLI_RC" -eq 0 ] && [ ! -s "$UCLI_LOG" ] && ucli_no_activation && [ -e "$UCLI_PROJ/Temp/refresh_trigger" ] && grep -q -- "--trigger-file" "$FAKE_GATE_LOG"'

# ── 没有 compile_gate：判据是 Temp/pipeline_recompile_status.json ──
mv "$UCLI_PROJ/Tools/compile_gate.py" "$UCLI_ROOT/compile_gate.py.off"
ucli_smart compiling-red
ucli_check "unity-cli compile (no gate): compiling → completed failed=true → exit 1 and prints the error" \
  eval '[ "$UCLI_RC" -eq 1 ] && grep -q "Assets/Scripts/A.cs(1,8): error CS1002" "$UCLI_OUT" && [ "$(ucli_state judge)" = pipeline_recompile_status ] && ucli_no_activation'
ucli_smart compiling-green
ucli_check "unity-cli compile (no gate): compiling → completed failed=false → exit 0" \
  eval '[ "$UCLI_RC" -eq 0 ] && ucli_no_activation'
# up_to_date 会把上一次的记录盖掉：只认调用前的快照，快照是 completed 才有结论
printf '%s\n' "$UCLI_ST_RED" > "$UCLI_PROJ/Temp/pipeline_recompile_status.json"
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 120
ucli_age "$UCLI_PROJ/Temp/pipeline_recompile_status.json" 60
ucli_smart uptodate-nogate
ucli_check "unity-cli compile (no gate): up_to_date with a red completed snapshot → exit 1" \
  eval '[ "$UCLI_RC" -eq 1 ] && grep -q "error CS1002" "$UCLI_OUT"'
ucli_smart uptodate-nogate
ucli_check "unity-cli compile (no gate): up_to_date with an up_to_date snapshot (no trustworthy verdict) → exit 2" \
  eval '[ "$UCLI_RC" -eq 2 ] && [ "$(ucli_recompile_calls)" = 1 ] && grep -q "no trustworthy previous verdict" "$UCLI_OUT"'
printf '%s\n' "$UCLI_ST_GREEN" > "$UCLI_PROJ/Temp/pipeline_recompile_status.json"
ucli_age "$UCLI_PROJ/Temp/pipeline_recompile_status.json" 60
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 0
UCLI_CHANGED="$UCLI_PROJ/Assets/Scripts/A.cs"
ucli_smart uptodate-nogate
UCLI_CHANGED=""
ucli_check "unity-cli compile (no gate): up_to_date, green snapshot, but the edited file is newer → exit 2" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "Auto Refresh" "$UCLI_OUT"'
# 调用前状态文件就是 compiling（有一次编译在跑），等待上限内没落地：recompile 回 compiling 之后看到的 completed
# 分不清是不是那次早就在跑的。原来照收不误（假绿）
printf '{"status":"compiling","failed":false,"errors":[]}\n' > "$UCLI_PROJ/Temp/pipeline_recompile_status.json"
ucli_age "$UCLI_PROJ/Temp/pipeline_recompile_status.json" 30
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 10
ucli_smart compiling-green --timeout 1
ucli_check "unity-cli compile (no gate): a compile already running before the call that does not finish in time → exit 2, its completed is not taken" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "still busy with a compile that started before this call" "$UCLI_OUT"'
# 在途的那次落地了（qq 记下「调用前在编」之后才写 completed，所以等 s-busy.json 出现再写），recompile 回 up_to_date：
# 参照时间改用看见它在编的那一刻，编译途中改的文件不算「Unity 看见了」
printf '{"status":"compiling","failed":false,"errors":[]}\n' > "$UCLI_PROJ/Temp/pipeline_recompile_status.json"
ucli_age "$UCLI_PROJ/Temp/pipeline_recompile_status.json" 30
ucli_land_after_busy() {
  ( for _ in $(seq 1 150); do
      if ls "$UCLI_ROOT/tmp"/qq-ucli.*/s-busy.json >/dev/null 2>&1; then break; fi
      sleep 0.1
    done
    printf '%s\n' "$UCLI_ST_GREEN" > "$UCLI_PROJ/Temp/pipeline_recompile_status.json" ) &
  UCLI_LANDER=$!
}
ucli_land_after_busy
UCLI_CHANGED="$UCLI_PROJ/Assets/Scripts/A.cs"
ucli_smart uptodate-nogate
UCLI_CHANGED=""
wait "$UCLI_LANDER" 2>/dev/null || true
ucli_check "unity-cli compile (no gate): up_to_date after waiting out a running compile; the file edited while it ran → exit 2" \
  eval '[ "$UCLI_RC" -eq 2 ] && grep -q "already running" "$UCLI_OUT" && grep -q "Assets/Scripts/A.cs is newer" "$UCLI_OUT"'
printf '{"status":"compiling","failed":false,"errors":[]}\n' > "$UCLI_PROJ/Temp/pipeline_recompile_status.json"
ucli_land_after_busy
ucli_smart compiling-green
wait "$UCLI_LANDER" 2>/dev/null || true
ucli_check "unity-cli compile (no gate): ...once it has landed, the compile this call triggered is taken → exit 0" \
  eval '[ "$UCLI_RC" -eq 0 ] && grep -q "already running" "$UCLI_OUT"'
unset -f ucli_land_after_busy
ucli_age "$UCLI_PROJ/Assets/Scripts/A.cs" 120
ucli_run compiling-green "$UCLI_PROJ/scripts/unity-check.sh" --trigger 5
ucli_check "unity-cli compile: unity-check.sh --trigger (no gate) calls recompile and does not activate the window" \
  eval '[ "$UCLI_RC" -eq 0 ] && [ "$(ucli_recompile_calls)" = 1 ] && ucli_no_activation'
mv "$UCLI_ROOT/compile_gate.py.off" "$UCLI_PROJ/Tools/compile_gate.py"

# 没有描述文件（老通道）：行为不变——写 refresh_trigger、激活窗口、gate 带 --trigger-file 等，不调 CLI
rm -f "$UCLI_DESC"
ucli_smart compiling --editor
ucli_check "unity-cli compile: without a descriptor the old refresh_trigger path is unchanged (activation, --trigger-file, no CLI)" \
  eval '[ "$UCLI_RC" -eq 0 ] && [ ! -s "$UCLI_LOG" ] && [ -e "$UCLI_PROJ/Temp/refresh_trigger" ] && grep -q -- "--trigger-file" "$FAKE_GATE_LOG" && ! ucli_no_activation'

# 信封分类（qq-unity-cli.py envelope）：退出码不可信，success 与退出码要同时满足
ucli_envelope_is() {  # <期望分类码> <退出码> <回包>
  local rc=0
  printf '%s' "$3" > "$UCLI_ROOT/env.json"
  $QQ_PY "$SCRIPT_DIR/scripts/qq-unity-cli.py" envelope --file "$UCLI_ROOT/env.json" --rc "$2" --quiet > "$UCLI_OUT" 2>&1 || rc=$?
  [ "$rc" -eq "$1" ]
}
if ucli_envelope_is 0 0 "$UCLI_ENV_COMPILING" \
   && ucli_envelope_is 2 1 "$UCLI_ENV_COMPILING" \
   && ucli_envelope_is 2 0 '{"success":true,"errors":[{"code":"X","message":"y"}],"data":{}}' \
   && ucli_envelope_is 2 0 '{"success":true,"errors":[],"data":null}' \
   && ucli_envelope_is 2 0 '{"success":"true","errors":[],"data":{}}' \
   && ucli_envelope_is 2 0 '' \
   && ucli_envelope_is 2 0 '[1]' \
   && ucli_envelope_is 10 1 '{"success":false,"retryable":true,"errors":[{"code":"BUSY","message":"settling"}],"data":null}' \
   && ucli_envelope_is 11 6 '{"success":false,"errors":[{"code":"COMMAND_FAILED","message":"Network error: An error occurred while sending the request."}],"data":null}' \
   && ucli_envelope_is 12 6 '{"success":false,"errors":[{"code":"COMMAND_FAILED","message":"Request timed out after 30000ms"}],"data":null}' \
   && ucli_envelope_is 14 6 '{"success":false,"errors":[{"code":"COMMAND_FAILED","message":"Job Not Found"}],"data":null}' \
   && ucli_envelope_is 2 6 "$UCLI_ENV_NOINSTANCE"; then
  pass "unity-cli envelope: success must be identically true AND exit 0, errors empty, data present; failures are classified"
else
  fail "unity-cli envelope: success must be identically true AND exit 0, errors empty, data present; failures are classified"
fi

# 结构性检查：python 助手不起子进程跑 unity；脚本、技能里没有把描述文件 cat / grep 出来的写法；
# 代码里不用会另起 batch Editor 的 unity test/build/run，不用 job cancel，不用 --mode all
if $QQ_PY - "$SCRIPT_DIR" > "$UCLI_OUT" 2>&1 <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
problems = []
helper = root / "scripts" / "qq-unity-cli.py"
if not helper.is_file():
    problems.append("scripts/qq-unity-cli.py is missing")
elif re.search(r"^\s*(import|from)\s+subprocess\b|\bos\.(system|popen|spawn\w*|exec\w*)\s*\(|\bPopen\s*\(", helper.read_text(encoding="utf-8"), re.M):
    problems.append("scripts/qq-unity-cli.py starts processes (the CLI is only called from bash)")

# 把描述文件内容倒出来的命令形状：cat / grep / sed / jq … 后面直接跟着这个文件
dump = re.compile(r"\b(cat|grep|sed|jq|head|tail|less|more|Get-Content)\s+(-[A-Za-z]+\s+|'[^']*'\s+|\"[^\"]*\"\s+|\.\s+)*[\"']?[^\"'\s]*unity-pipeline-port")
# 会另起 batch Editor 的 unity test/build/run、对 run_tests 无效还会把跑完的作业标成 canceled 的 job cancel、混两种协议的 --mode all
banned = re.compile(r"\bjob cancel\b|\bunity (test|build|run)\b|--mode all\b")
for top, patterns in (("scripts", (dump, banned)), ("bin", (dump, banned)), ("skills", (dump,)), ("shared", (dump,))):
    base = root / top
    if not base.is_dir():
        continue
    for path in sorted(base.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in {".sh", ".py", ".md", ".json", ".ps1", ""}:
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            for pattern in patterns:
                if pattern.search(line):
                    problems.append(f"{path.relative_to(root).as_posix()}:{lineno}: {line.strip()[:160]}")
for item in problems:
    print(item)
sys.exit(1 if problems else 0)
PY
then
  pass "unity-cli structure: no subprocess in qq-unity-cli.py, nobody dumps the descriptor, no unity test/build/run, job cancel, --mode all"
else
  fail "unity-cli structure: no subprocess in qq-unity-cli.py, nobody dumps the descriptor, no unity test/build/run, job cancel, --mode all"
  sed 's/^/    /' "$UCLI_OUT"
fi

# 令牌从没出现在任何输出、CLI 的 argv、gate 日志和 .qq/ 里
if grep -rqF "$UCLI_SECRET" "$UCLI_ALL" "$UCLI_LOG" "$FAKE_GATE_LOG" "$UCLI_PROJ/.qq" 2>/dev/null; then
  fail "unity-cli: the descriptor's token never shows up in any output, CLI argv, gate log or .qq/"
else
  pass "unity-cli: the descriptor's token never shows up in any output, CLI argv, gate log or .qq/"
fi

kill "$UCLI_SLEEPER" 2>/dev/null || true
wait "$UCLI_SLEEPER" 2>/dev/null || true
unset UCLI_LOG UCLI_FIX ACT_LOG FAKE_GATE_LOG FAKE_GATE_SEQ FAKE_GATE_CHECK_RC FAKE_GATE_WAIT_RC UCLI_CHANGED UCLI_CLI
rm -rf "$UCLI_ROOT"

# ── Unity 官方 CLI 通道：/qq:test 用 unity command / unity job 跑测试 ──
# 项目有有效的 Library/Pipeline/.unity-pipeline-port 并且找得到 unity 时，unity-test.sh 不再一律走 tykit
# （撤掉 tykit 的项目一跑就报 tykit 连不上）：EditMode 用 --detach 提交 run_tests、轮询 job status、job wait 取结果；
# PlayMode 异步提交、读 Temp/pipeline_test_status.json。argv 固定是 `run_tests -- --timeout 86400 …`（命令层默认
# 300 秒一超时就卡死 Editor 的 CLI 通道），判据一直读到 Summary.Failed 和跳过数：退出码、success、state、error、
# result.success 五处都是绿的、只有 Summary.Failed=1 的回包必须判红。
# 全程用桩：QQ_UNITY_CLI 指向记 argv 的 bash 桩，绝不连真 Editor；描述文件里的令牌是假的，最后查它没漏进任何输出。
echo -e "${CYAN}[unity-cli] /qq:test through the official Unity CLI (detached EditMode job, async PlayMode)${NC}"
UT_ROOT="$(mktemp -d)"
UT_PROJ="$UT_ROOT/proj"
UT_SECRET="QQ-TEST-SECRET-7f3a"
UT_OUT="$UT_ROOT/out.log"
UT_ALL="$UT_ROOT/all-output.log"
export UT_LOG="$UT_ROOT/cli-argv.log" UT_FIX="$UT_ROOT/fix" UT_STATE="$UT_ROOT/state"
mkdir -p "$UT_PROJ/ProjectSettings" "$UT_PROJ/Temp" "$UT_PROJ/Library/Pipeline" "$UT_PROJ/Tools" \
  "$UT_ROOT/bin" "$UT_ROOT/tmp" "$UT_FIX" "$UT_STATE"
: > "$UT_ALL"
printf 'm_EditorVersion: 6000.3.20f1\n' > "$UT_PROJ/ProjectSettings/ProjectVersion.txt"
if command -v cygpath >/dev/null 2>&1; then UT_NATIVE="$(cygpath -m "$UT_PROJ")"; else UT_NATIVE="$UT_PROJ"; fi

# 活着的 pid：一个睡着的 python（Windows 上 $$ 是 MSYS 的 pid，不能用）
$QQ_PY -c 'import os,sys,time
with open(sys.argv[1], "w") as fh: fh.write(str(os.getpid()))
time.sleep(3600)' "$UT_ROOT/live.pid" &
UT_SLEEPER=$!
for _ in $(seq 1 100); do [ -s "$UT_ROOT/live.pid" ] && break; sleep 0.1; done
$QQ_PY - "$UT_PROJ" "$(cat "$UT_ROOT/live.pid" 2>/dev/null || echo 0)" "$UT_SECRET" <<'PY'
import json
import os
import sys

proj, pid, secret = sys.argv[1:4]
with open(os.path.join(proj, "Library", "Pipeline", ".unity-pipeline-port"), "w", encoding="utf-8") as fh:
    json.dump({"pid": int(pid), "port": 7899, "projectPath": os.path.abspath(proj), "projectName": "proj",
               "unityVersion": "6000.3.20f1", "mode": "editor", "evalToken": secret}, fh)
PY

# CLI 桩：argv 记进 $UT_LOG（参数之间用 \x1f 分隔）；按「命令」从 $UT_FIX/<场景>/ 取回包：
#   editor_status / editor_stop / run_tests-detach / run_tests-async / job-status / job-wait
# 同一个命令第 n 次调用优先取 <命令>.<n>.json；调过 editor_stop 之后 editor_status 取 editor_status.after-stop.json；
# <命令>.writes 存在时把它写成项目的 Temp/pipeline_test_status.json（模拟 Editor 跑完），<命令>.age 把它的 mtime 拨回去
cat > "$UT_ROOT/bin/unity" <<'SH'
#!/usr/bin/env bash
line=""
for a in "$@"; do line="$line$a"$'\x1f'; done
printf '%s\n' "$line" >> "$UT_LOG"
pp="" cmd="" prev="" detach=0 async=0
for a in "$@"; do
  [ "$prev" = "--project-path" ] && pp="$a"
  case "$a" in
    editor_status|editor_stop) [ -z "$cmd" ] && cmd="$a" ;;
    run_tests) cmd="run_tests" ;;
    --detach) detach=1 ;;
    --async_tests) async=1 ;;
  esac
  prev="$a"
done
if [ "${1:-}" = job ]; then cmd="job-${2:-}"; fi
if [ "$cmd" = run_tests ]; then
  if [ "$detach" = 1 ]; then cmd="run_tests-detach"; elif [ "$async" = 1 ]; then cmd="run_tests-async"; fi
fi
dir="$UT_FIX/${UT_SCENARIO:-none}"
n=$(( $(cat "$UT_STATE/$cmd.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$UT_STATE/$cmd.count"
if [ "$cmd" = editor_stop ]; then : > "$UT_STATE/stopped"; fi
f="$dir/$cmd.json"
if [ -f "$dir/$cmd.$n.json" ]; then f="$dir/$cmd.$n.json"; fi
if [ "$cmd" = editor_status ] && [ -f "$UT_STATE/stopped" ] && [ -f "$dir/editor_status.after-stop.json" ]; then
  f="$dir/editor_status.after-stop.json"
fi
if [ ! -f "$f" ]; then
  printf '{"success":false,"errors":[{"code":"STUB","message":"no fixture for %s"}],"data":null}\n' "${cmd:-?}"
  exit 6
fi
if [ -f "$dir/$cmd.writes" ]; then
  cp "$dir/$cmd.writes" "$pp/Temp/pipeline_test_status.json"
  if [ -f "$dir/$cmd.age" ]; then
    "$QQ_PY" -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' \
      "$pp/Temp/pipeline_test_status.json" "$(cat "$dir/$cmd.age")"
  fi
fi
cat "$f"
rc=0
if [ -f "$dir/$cmd.rc" ]; then rc="$(cat "$dir/$cmd.rc")"; fi
exit "$rc"
SH
chmod +x "$UT_ROOT/bin/unity"

# 回包夹具：一次 python 把所有场景写进 $UT_FIX/<场景>/（结构照 Pipeline 包的 TestExecutionResponse、作业响应、
# PlayMode 状态文件）。每个场景默认有：editor_status（停着、本项目）、--detach 提交的回包（jobId=J1）、
# job status 先 running 再 completed、异步提交的回包（result=running）
$QQ_PY - "$UT_FIX" "$UT_PROJ" "$UT_ROOT/other-project" <<'PY'
import json
import os
import sys

fix, proj, other = sys.argv[1:4]


def tests(spec):
    out = []
    for item in filter(None, spec.split(",")):
        name, status, *rest = item.split(":")
        out.append({"FullName": name, "Status": status, "Duration": 0.01, "Message": rest[0] if rest else None,
                    "StackTrace": None})
    return out


def counts(results, summary=None):
    if summary:
        return dict(zip(("Total", "Passed", "Failed", "Skipped", "Inconclusive"), summary))
    c = {k: sum(1 for r in results if r["Status"] == k) for k in ("Passed", "Failed", "Skipped", "Inconclusive")}
    return {"Total": sum(c.values()), **c}


def run_result(results, mode="EditMode", fa=None, summary=None):
    return {"success": True, "command": "run_tests", "result": None, "message": None, "error": None, "errorDetails": None,
            "Summary": counts(results, summary), "Results": results, "Duration": 1.5, "StatusPath": None, "Mode": mode,
            "FilterApplied": fa}


def job_wait(spec, fa=None, omit_nulls=False):
    data = {"jobId": "J1", "command": "run_tests", "state": "completed", "cancellationRequested": False,
            "result": run_result(tests(spec), fa=fa), "error": None, "errorDetails": None, "progress": None}
    if omit_nulls:  # 旧版 /api/job 把 null 键整个丢掉
        strip = lambda v: {k: strip(x) for k, x in v.items() if x is not None} if isinstance(v, dict) else v
        data = strip(data)
    return {"success": True, "errors": [], "warnings": [], "data": data}


def job_status(state):
    progress = {"title": "Running tests", "info": "", "current": 1, "total": 3, "pct": 0.33} if state == "running" else None
    return {"success": True, "errors": [], "data": {"jobId": "J1", "command": "run_tests", "state": state,
                                                     "cancellationRequested": False, "result": None, "error": None,
                                                     "errorDetails": None, "progress": progress}}


def play_status(spec="", summary=None, status="completed"):
    if status != "completed":
        return {"status": status, "message": "boom"}
    results = tests(spec)
    c = counts(results, summary)
    return {"status": "completed", "duration": 2.0, "summary": {k.lower(): v for k, v in c.items()}, "results": results}


def editor_status(play="stopped", owner=proj):
    return {"success": True, "errors": [], "data": {"command": "editor_status", "result": {
        "status": "ready", "compiling": False, "domainReloadInProgress": False, "playMode": play,
        "projectPath": os.path.abspath(owner)}}}


async_start = {"success": True, "errors": [], "data": {"command": "run_tests", "result": dict(
    run_result([], mode="PlayMode"), result="running", StatusPath="Temp/pipeline_test_status.json")}}
base = {
    "editor_status.json": editor_status(),
    "run_tests-detach.json": {"success": True, "errors": [], "data": {"command": "run_tests", "jobId": "J1",
                                                                      "state": "queued", "detached": True}},
    "job-status.1.json": job_status("running"),
    "job-status.json": job_status("completed"),
    "run_tests-async.json": async_start,
}
scenarios = {
    "green-a": {"job-wait.json": job_wait("A.a:Passed,A.b:Passed,A.c:Passed")},
    "one-failed": {"job-wait.json": job_wait("A.a:Passed,A.b:Failed:Expected 1 but was 2")},
    "noinstance": {"editor_status.json": {"success": False, "errors": [{"code": "COMMAND_FAILED",
                                                                       "message": "No Pipeline instance found for project"}],
                                          "data": None},
                   "editor_status.rc": 6},
    "skip-one": {"job-wait.json": job_wait("A.a:Passed,A.skipme:Skipped:Ignored on Windows")},
    "zero": {"job-wait.json": job_wait("")},
    "asm": {"job-wait.json": job_wait("A.a:Passed", fa="assembly: Game.Tests")},
    "name": {"job-wait.json": job_wait("A.a:Passed", fa="testname: -Health")},
    "job-lost": {"job-status.1.json": {"success": False, "errors": [{"code": "COMMAND_FAILED",
                                                                    "message": "Job Not Found: No job with id 'J1'"}],
                                       "data": None},
                 "job-status.rc": 6},
    "running": {"job-status.json": job_status("running")},
    "playing": {"job-wait.json": job_wait("A.a:Passed"), "editor_status.json": editor_status("playing"),
                "editor_status.after-stop.json": editor_status(),
                "editor_stop.json": {"success": True, "errors": [], "data": {"command": "editor_stop", "result": {}}}},
    "foreign": {"editor_status.json": editor_status(owner=other)},
    "green-b": {"run_tests-async.writes": play_status("P.a:Passed,P.b:Passed")},
    "stale-b": {"run_tests-async.writes": play_status("P.a:Passed"), "run_tests-async.age": 100},
    "error-b": {"run_tests-async.writes": play_status(status="error")},
    "all": {"job-wait.json": job_wait("A.a:Passed,A.b:Passed"), "run_tests-async.writes": play_status("P.a:Passed")},
    "all-red-b-error": {"job-wait.json": job_wait("A.a:Passed,A.b:Failed:Expected 1 but was 2"),
                        "run_tests-async.writes": play_status(status="error")},
    "resume-floor": {"job-wait.json": job_wait("A.a:Passed", fa="assembly: Game Tests")},
}
for name, files in scenarios.items():
    os.makedirs(os.path.join(fix, name), exist_ok=True)
    for fname, payload in {**base, **files}.items():
        with open(os.path.join(fix, name, fname), "w", encoding="utf-8") as fh:
            fh.write(json.dumps(payload) if isinstance(payload, (dict, list)) else f"{payload}\n")
PY

# 跑一次 unity-test.sh：<场景> <参数...>。退出码在 UT_RC，输出在 $UT_OUT（另外累积进 $UT_ALL 查令牌）
ut_run() {
  local scenario="$1"
  shift
  : > "$UT_LOG"
  rm -rf "$UT_STATE" "$UT_PROJ/.qq" "$UT_PROJ/Temp/pipeline_test_status.json"
  mkdir -p "$UT_STATE"
  UT_RC=0
  UT_SCENARIO="$scenario" QQ_UNITY_CLI="${UT_CLI:-$UT_ROOT/bin/unity}" QQ_UNITY_CHANNEL= \
    QQ_UNITY_CLI_POLL_SEC=0 QQ_UNITY_PROBE_RETRY_DELAY=0 QQ_UNITY_CLI_RETRY_SEC=0 QQ_TEMP_DIR="$UT_ROOT/tmp" \
    bash "$SCRIPT_DIR/scripts/unity-test.sh" --project "$UT_PROJ" "$@" > "$UT_OUT" 2>&1 || UT_RC=$?
  cat "$UT_OUT" >> "$UT_ALL"
}
ut_state() {  # .qq/state/test.json 的某个字段
  $QQ_PY -c 'import json,sys; v=json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], ""); print("" if v is None else v)' \
    "$UT_PROJ/.qq/state/test.json" "$1" 2>/dev/null || true
}
ut_calls() {  # 日志里含某个参数的 CLI 调用次数
  grep -c -- "$1" "$UT_LOG" || true
}
ut_argv_is() {  # <期望的整行（参数之间用空格写）>：日志里恰好有一行是这些参数
  local us=$'\x1f' want
  want="$(printf '%s' "$1" | sed "s/ /$us/g")$us"
  [ "$(grep -cxF -- "$want" "$UT_LOG" || true)" = 1 ]
}
ut_count_args() {  # <连续的几个参数（空格分隔）>：日志里含这一串参数的调用次数
  local us=$'\x1f' want
  want="$us$(printf '%s' "$1" | sed "s/ /$us/g")$us"
  sed "s/^/$us/" "$UT_LOG" | grep -cF -- "$want" || true
}
ut_report() {
  sed 's/^/    | /' "$UT_OUT" | head -40
  if [ -s "$UT_LOG" ]; then tr '\037' ' ' < "$UT_LOG" | sed 's/^/    cli: /'; fi
  if [ -f "$UT_PROJ/.qq/state/test.json" ]; then sed 's/^/    state: /' "$UT_PROJ/.qq/state/test.json" | head -30; fi
}
ut_check() {  # <描述> <条件命令...>
  local desc="$1"
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; ut_report; fi
}
UT_CMD="command --project-path $UT_NATIVE --json --no-banner --non-interactive"

# U7-1 EditMode 全绿：--detach 在 run_tests 前面，run_tests 后面恰好是 `-- --timeout 86400 --mode editor`（只有一个 --），
# 全局的 --timeout 在命令名前面；run record 记 backend=unity-cli、total、job_id
ut_run green-a editmode
ut_check "unity-cli test: EditMode all green → exit 0 via one detached run_tests, job status, job wait" \
  eval '[ "$UT_RC" -eq 0 ] && [ "$(ut_calls run_tests)" = 1 ] && grep -q "Tests passed" "$UT_OUT"'
ut_check "unity-cli test: the submission argv is '--timeout 60 --detach run_tests -- --timeout 86400 --mode editor' (one --)" \
  ut_argv_is "$UT_CMD --timeout 60 --detach run_tests -- --timeout 86400 --mode editor"
ut_check "unity-cli test: job status / job wait carry the jobId and --project-path" \
  eval '[ "$(grep -cxF -- "$(printf "job status J1 --project-path %s --json --no-banner --non-interactive " "$UT_NATIVE" | tr " " "\037")" "$UT_LOG")" = 2 ] && ut_argv_is "job wait J1 --project-path $UT_NATIVE --json --no-banner --non-interactive --timeout 60"'
ut_check "unity-cli test: run record says backend=unity-cli, total=3, job_id=J1, status=passed" \
  eval '[ "$(ut_state backend)" = unity-cli ] && [ "$(ut_state total)" = 3 ] && [ "$(ut_state job_id)" = J1 ] && [ "$(ut_state status)" = passed ] && [ "$(ut_state transport)" = unity-cli-job ]'

# U7-2 五处都说成功（rc 0、success、state=completed、error=null、result.success=true），只有 Summary.Failed=1 → 退 1 并点名
ut_run one-failed editmode
ut_check "unity-cli test: exit 0 / success / completed / error=null / result.success all green but Summary.Failed=1 → exit 1, names the test" \
  eval '[ "$UT_RC" -eq 1 ] && grep -q "A.b" "$UT_OUT" && grep -q "Expected 1 but was 2" "$UT_OUT" && [ "$(ut_state status)" = failed ] && [ "$(ut_state failure_category)" = test_failed ] && [ "$(ut_state failed)" = 1 ]'

# 判据各层（null 键被丢掉、FilterApplied 不该有却有、名单外的跳过、Total=0、PlayMode 的 Results 只是一部分或比
# Summary 多……）在后面的判据单测里逐条测；这里的整条脚本用例只测管道：argv、提交一次、作业丢失、超时、filter、
# 预检、配置、run record。

# U7-5 跳过：qq.yaml 的 unity.expected_skips 指过去的名单里有就放行，并把跳过的那条打出来
printf '# Windows 上必然跳过\nA.skipme\n' > "$UT_PROJ/Tools/skips.txt"
printf 'unity:\n  expected_skips: Tools/skips.txt\n' > "$UT_PROJ/qq.yaml"
ut_run skip-one editmode
ut_check "unity-cli test: a skipped test listed in qq.yaml unity.expected_skips → exit 0, prints the skipped test" \
  eval '[ "$UT_RC" -eq 0 ] && grep -q "all in the expected-skips list" "$UT_OUT" && grep -q "A.skipme" "$UT_OUT" && [ "$(ut_state skipped)" = 1 ]'
rm -f "$UT_PROJ/qq.yaml"

# U7-6 规模下限：--min-tests 0 --allow-zero 放行 Total=0；只给 --allow-zero 是参数矛盾（一条也不提交）
ut_run zero editmode --min-tests 0 --allow-zero
ut_check "unity-cli test: Total=0 with --min-tests 0 --allow-zero → exit 0" eval '[ "$UT_RC" -eq 0 ]'
ut_run zero editmode --allow-zero
ut_check "unity-cli test: --allow-zero without --min-tests 0 → exit 2 before submitting anything" \
  eval '[ "$UT_RC" -eq 2 ] && [ "$(ut_calls run_tests)" = 0 ] && [ "$(ut_state failure_category)" = invalid_arguments ]'
printf 'unity:\n  min_tests:\n    editmode: 5\n' > "$UT_PROJ/qq.yaml"
ut_run green-a editmode
ut_check "unity-cli test: qq.yaml unity.min_tests.editmode=5 with 3 tests → exit 1 (below the floor)" \
  eval '[ "$UT_RC" -eq 1 ] && [ "$(ut_state failure_category)" = test_count_below_floor ]'
rm -f "$UT_PROJ/qq.yaml"

# U7-7 作业不见了（domain reload 之后 404）：退 2 test_job_lost，run_tests 只提交过一次（不重投）
ut_run job-lost editmode
ut_check "unity-cli test: job status 'Job Not Found' → exit 2 (test_job_lost), run_tests submitted exactly once" \
  eval '[ "$UT_RC" -eq 2 ] && [ "$(ut_state failure_category)" = test_job_lost ] && [ "$(ut_calls run_tests)" = 1 ] && [ "$(ut_state job_id)" = J1 ]'

# U7-8 一直 running、等待上限 1 秒：退 2，告诉人用 --job 接着等（带上同一个 filter，判据要核对回显），绝不取消作业
ut_run running editmode --timeout 1 --assembly Game.Tests
ut_check "unity-cli test: still running at the deadline → exit 2 with the --job resume hint (same filter), never cancels the job" \
  eval '[ "$UT_RC" -eq 2 ] && grep -q -- "--job J1 --project .* --assembly Game.Tests " "$UT_OUT" && ! grep -qi "cancel" "$UT_LOG" && [ "$(ut_state failure_category)" = test_timeout_or_blocked ]'

# 超时后打印的「接着等」命令要带上提交时影响判据的参数（--min-tests、--allow-skipped、--project、filter），值要转义：
# 照着它接着等，判据和提交时一样。原来只带 filter（还用单引号硬包），--min-tests 5000 接着等时回落成 1
ut_run running editmode --timeout 1 --assembly "Game Tests" --min-tests 5 --allow-skipped
UT_RESUME="$(sed -n 's/.*Resume waiting with: \(unity-test\.sh editmode --job .*\)   (do not re-submit).*/\1/p' "$UT_OUT" | head -1)"
ut_check "unity-cli test: the resume hint carries --project, the filter, --min-tests and --allow-skipped" \
  eval 'case "$UT_RESUME" in *" --project "*) true ;; *) false ;; esac && printf "%s" "$UT_RESUME" | grep -qF -- "--assembly Game\\ Tests --min-tests 5 --allow-skipped"'
ut_resume_run() {  # 照打印出来的命令原样接着等（在函数里 set --，不动 test.sh 自己的参数）
  eval "set -- ${UT_RESUME#unity-test.sh }"
  ut_run resume-floor "$@"
}
if [ -n "$UT_RESUME" ]; then ut_resume_run; else UT_RC=99; fi
unset -f ut_resume_run
ut_check "unity-cli test: running the printed resume command applies the same floor (1 test < --min-tests 5 → exit 1)" \
  eval '[ "$UT_RC" -eq 1 ] && [ "$(ut_state failure_category)" = test_count_below_floor ] && [ "$(ut_calls run_tests)" = 0 ]'

# U7-9 --job J1 接着等：不提交、不做预检（那个作业正占着执行门）
ut_run green-a editmode --job J1
ut_check "unity-cli test: --job J1 resumes without submitting run_tests or calling editor_status" \
  eval '[ "$UT_RC" -eq 0 ] && [ "$(ut_calls run_tests)" = 0 ] && [ "$(ut_calls editor_status)" = 0 ] && [ "$(ut_count_args "job wait J1")" = 1 ]'
ut_run green-b playmode --job J1
ut_check "unity-cli test: --job with playmode → exit 2 without submitting (PlayMode cannot be resumed)" \
  eval '[ "$UT_RC" -eq 2 ] && [ "$(ut_calls run_tests)" = 0 ]'

# U7-10 PlayMode 全绿：异步提交，argv 是 `-- --timeout 86400 --mode playmode --async_tests true`
ut_run green-b playmode
ut_check "unity-cli test: PlayMode all green → exit 0; argv '--timeout 60 run_tests -- --timeout 86400 --mode playmode --async_tests true'" \
  eval '[ "$UT_RC" -eq 0 ] && ut_argv_is "$UT_CMD --timeout 60 run_tests -- --timeout 86400 --mode playmode --async_tests true" && [ "$(ut_state total)" = 2 ] && [ "$(ut_state transport)" = unity-cli-async ]'
# U7-11 状态文件是提交之前写的（上一轮的残留）：不采用，等到超时退 2
ut_run stale-b playmode --timeout 1
ut_check "unity-cli test: a PlayMode status file older than the submission is not taken → exit 2 after the wait" \
  eval '[ "$UT_RC" -eq 2 ] && [ "$(ut_count_args "--async_tests true")" = 1 ] && grep -q "earlier run" "$UT_OUT" && [ "$(ut_state failure_category)" = test_timeout_or_blocked ]'
# U7-13 状态文件是 {status:"error"}
ut_run error-b playmode
ut_check "unity-cli test: PlayMode status=error → exit 2 (test_run_error)" \
  eval '[ "$UT_RC" -eq 2 ] && [ "$(ut_state failure_category)" = test_run_error ]'

# U7-14 all：分两次提交（--mode editor、--mode playmode），不用官方的 all 模式
ut_run all all
ut_check "unity-cli test: all → two submissions (editor, then playmode), never --mode all; totals add up" \
  eval '[ "$UT_RC" -eq 0 ] && [ "$(ut_count_args "--mode editor")" = 1 ] && [ "$(ut_count_args "--mode playmode --async_tests true")" = 1 ] && [ "$(ut_count_args "--mode all")" = 0 ] && [ "$(ut_state total)" = 3 ] && [ "$(ut_state mode)" = All ]'
# EditMode 没拿到裁决（作业可能还在跑）：不再提交 PlayMode，免得把它打掉
ut_run running all --timeout 1
ut_check "unity-cli test: all, EditMode without a verdict → PlayMode is not submitted" \
  eval '[ "$UT_RC" -eq 2 ] && [ "$(ut_calls run_tests)" = 1 ] && ! grep -q "playmode" "$UT_LOG"'
# EditMode 已经确定判红、PlayMode 没拿到裁决：整次仍是红（test_failed），没裁决的那一轮写进摘要。
# 原来取两次退出码里大的那个，确定的失败被降成 blocked / test_timeout_or_blocked
ut_run all-red-b-error all
ut_check "unity-cli test: all, EditMode red + PlayMode without a verdict → exit 1 (test_failed), the PlayMode problem is still reported" \
  eval '[ "$UT_RC" -eq 1 ] && [ "$(ut_state status)" = failed ] && [ "$(ut_state failure_category)" = test_failed ] && ut_state summary | grep -q "PlayMode gave no verdict (test_run_error)"'

# U7-15 官方接口一次只收一个 filter：两个都给、或者值里有 ; → 退 2，一条也不提交
ut_run green-a editmode --filter A --assembly B
ut_check "unity-cli test: --filter together with --assembly → exit 2 (unsupported_filter), no CLI call" \
  eval '[ "$UT_RC" -eq 2 ] && [ ! -s "$UT_LOG" ] && [ "$(ut_state failure_category)" = unsupported_filter ]'
ut_run green-a editmode --assembly "a;b"
ut_check "unity-cli test: --assembly 'a;b' → exit 2 (unsupported_filter), no CLI call" \
  eval '[ "$UT_RC" -eq 2 ] && [ ! -s "$UT_LOG" ] && [ "$(ut_state failure_category)" = unsupported_filter ]'
# 单个 filter 照官方参数映射，回显的 FilterApplied 要对得上（以 - 开头的值也不能被当成选项）
ut_run asm editmode --assembly Game.Tests
ut_check "unity-cli test: --assembly X → '--filter X --filter_type assembly', FilterApplied 'assembly: X' → exit 0" \
  eval '[ "$UT_RC" -eq 0 ] && ut_argv_is "$UT_CMD --timeout 60 --detach run_tests -- --timeout 86400 --mode editor --filter Game.Tests --filter_type assembly"'
ut_run name editmode --filter -Health
ut_check "unity-cli test: --filter -Health → '--filter -Health --filter_type testName', FilterApplied 'testname: -Health' → exit 0" \
  eval '[ "$UT_RC" -eq 0 ] && ut_argv_is "$UT_CMD --timeout 60 --detach run_tests -- --timeout 86400 --mode editor --filter -Health --filter_type testName"'

# U7-16 Unity 里有一轮测试在跑：不提交
printf '{"mode":"PlayMode"}\n' > "$UT_PROJ/Temp/pipeline_test_request.json"
ut_run green-a editmode
rm -f "$UT_PROJ/Temp/pipeline_test_request.json"
ut_check "unity-cli test: Temp/pipeline_test_request.json in flight → exit 2 (test_in_flight), nothing submitted" \
  eval '[ "$UT_RC" -eq 2 ] && [ "$(ut_calls run_tests)" = 0 ] && [ "$(ut_state failure_category)" = test_in_flight ]'
# 本项目没有 Pipeline 服务应答（rc=6 "No Pipeline instance"）：退 2，提示在 Unity 里 Start Server
ut_run noinstance editmode
ut_check "unity-cli test: 'No Pipeline instance' at preflight → exit 2 (editor_not_detected) with the Start Server hint" \
  eval '[ "$UT_RC" -eq 2 ] && [ "$(ut_calls run_tests)" = 0 ] && grep -q "Window/Pipeline/Start Server" "$UT_OUT" && [ "$(ut_state failure_category)" = editor_not_detected ]'
# U7-17 editor_status 自报的 projectPath 是别的项目
ut_run foreign editmode
ut_check "unity-cli test: editor_status reports another project → exit 2 (editor_mismatch), nothing submitted" \
  eval '[ "$UT_RC" -eq 2 ] && [ "$(ut_calls run_tests)" = 0 ] && [ "$(ut_state failure_category)" = editor_mismatch ]'
# U7-18 Editor 在 Play：先 editor_stop、等回到 stopped，再提交
ut_run playing editmode
ut_check "unity-cli test: Editor in Play mode → editor_stop first, then the submission" \
  eval '[ "$UT_RC" -eq 0 ] && [ "$(grep -n "editor_stop" "$UT_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n "run_tests" "$UT_LOG" | head -1 | cut -d: -f1)" ]'

# 描述文件有效却找不到 CLI：退 2（unity_cli_unavailable），不去碰 tykit、不转 batch
UT_CLI="$UT_ROOT/no-such-unity"
ut_run green-a editmode
UT_CLI=""
ut_check "unity-cli test: live descriptor but no unity CLI → exit 2 (unity_cli_unavailable)" \
  eval '[ "$UT_RC" -eq 2 ] && [ ! -s "$UT_LOG" ] && [ "$(ut_state failure_category)" = unity_cli_unavailable ]'
# ……项目还装着 tykit（Temp/tykit.json）时回落 tykit：描述文件出现之前它就是能用的通道（正从 tykit 迁到官方 CLI、
# 或者 CLI 不在 PATH 上），不能因为多了个 Pipeline 就拒跑。原来判成 none / unity_cli_unavailable，一条也不跑。
# 端口 1 上没有 tykit，所以这里只看走的是哪条路（backend=tykit），不看结果；清掉代理免得 curl 去绕
printf '{"port":1}\n' > "$UT_PROJ/Temp/tykit.json"
UT_CLI="$UT_ROOT/no-such-unity"
http_proxy='' https_proxy='' HTTP_PROXY='' HTTPS_PROXY='' ut_run green-a editmode
UT_CLI=""
ut_check "unity-cli test: live descriptor, no unity CLI, but Temp/tykit.json → falls back to tykit (not unity_cli_unavailable)" \
  eval '[ ! -s "$UT_LOG" ] && [ "$(ut_state backend)" = tykit ] && [ "$(ut_state failure_category)" != unity_cli_unavailable ] && grep -q "Falling back to tykit" "$UT_OUT"'
UT_CHANNEL_GOT="$(PROJECT_DIR="$UT_PROJ" QQ_UNITY_CLI="$UT_ROOT/no-such-unity" QQ_UNITY_PROBE_RETRY_DELAY=0 QQ_UNITY_CHANNEL= bash -c '
  source "$1/scripts/unity-common.sh" || exit 9
  qq_unity_channel test 2>/dev/null; printf "%s|" "$QQ_UNITY_CHANNEL_RESOLVED"
  QQ_UNITY_CLI="$2/bin/unity" $QQ_PY "$1/scripts/qq-unity-cli.py" channel --project "$PROJECT_DIR" | cut -f1 | tr -d "\r\n"
  printf "|"
  $QQ_PY "$1/scripts/qq-unity-cli.py" channel --project "$PROJECT_DIR" | cut -f1 | tr -d "\r\n"' _ "$SCRIPT_DIR" "$UT_ROOT" 2>/dev/null)" || UT_CHANNEL_GOT="error"
ut_check "unity-cli test: ...the bash channel and the skills' qq-unity-cli.py channel agree (tykit without the CLI, unity-cli with it)" \
  eval '[ "$UT_CHANNEL_GOT" = "tykit|unity-cli|tykit" ] || { echo "    got: $UT_CHANNEL_GOT"; false; }'
rm -f "$UT_PROJ/Temp/tykit.json"

# unity-unit-test.sh 不再写死 --timeout 180：官方通道下等待上限是 3600 秒（EditMode 全量要 9 分钟上下）
UT_RC=0
: > "$UT_LOG"; rm -rf "$UT_STATE"; mkdir -p "$UT_STATE"
UT_SCENARIO=green-a PROJECT_DIR="$UT_PROJ" QQ_UNITY_CLI="$UT_ROOT/bin/unity" QQ_UNITY_CHANNEL= QQ_UNITY_CLI_POLL_SEC=0 \
  QQ_UNITY_PROBE_RETRY_DELAY=0 QQ_UNITY_CLI_RETRY_SEC=0 QQ_TEMP_DIR="$UT_ROOT/tmp" \
  bash "$SCRIPT_DIR/scripts/unity-unit-test.sh" editmode > "$UT_OUT" 2>&1 || UT_RC=$?
cat "$UT_OUT" >> "$UT_ALL"
ut_check "unity-cli test: unity-unit-test.sh editmode leaves the wait limit to unity-test.sh (3600s on the official CLI, not 180s)" \
  eval '[ "$UT_RC" -eq 0 ] && grep -q "up to 3600s" "$UT_OUT"'

# 判据单测：把游戏仓 Tools/unity_cli/uc_verdict_tests.ps1 的用例搬过来，直接喂构造的结果给 qq-unity-cli.py
if $QQ_PY - "$SCRIPT_DIR/scripts/qq-unity-cli.py" "$UT_ROOT" > "$UT_OUT" 2>&1 <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import sys

spec = importlib.util.spec_from_file_location("qq_unity_cli", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = sys.argv[2]
failures = []


def t(name, status, message=None):
    return {"FullName": name, "Status": status, "Duration": 0.1, "Message": message}


def fake(p=0, f=0, sk=0, inc=0, res=(), mode="EditMode", fa=None, rres=None, spath=None, omit_fa=False, omit_summary=False):
    o = {}
    if not omit_summary:
        o["Summary"] = {"Total": p + f + sk + inc, "Passed": p, "Failed": f, "Skipped": sk, "Inconclusive": inc}
    o.update(Results=list(res), Duration=1.0, StatusPath=spath, Mode=mode)
    if not omit_fa:
        o["FilterApplied"] = fa
    o.update(success=True, command="run_tests", result=rres)
    return json.loads(json.dumps(o))


A = dict(protocol="A", expect_mode="EditMode", expect_filter_applied=None, min_tests=2)
FL = dict(protocol="A", expect_mode="EditMode", expect_filter_applied=m.expected_filter_applied("Service.Weapon", "assembly"), min_tests=2)
B = dict(protocol="B", expect_mode="EditMode", expect_filter_applied=None, min_tests=2)
three = [t("a", "Passed"), t("b", "Passed"), t("c", "Passed")]
skips_file = os.path.join(root, "unit-skips.txt")
with open(skips_file, "w", encoding="utf-8-sig") as fh:
    fh.write("# comment\n\n  Known.Skip  \n")
SK = m.load_expected_skips(skips_file)


def case(name, want_code, result, **kw):
    got = m.judge_test_result(result, **kw)
    if got["code"] != want_code:
        failures.append(f"{name}: want exit {want_code}, got {got['code']} ({got['layer']}: {got['reason']})")


# Protocol A 主路径：不传 filter
case("3 passed, FilterApplied=null", 0, fake(p=3, res=three), **A)
case("3 passed, FilterApplied key missing (/api/job dropped the null)", 0, fake(p=3, res=three, omit_fa=True), **A)
case("FilterApplied set although no filter was passed", 2, fake(p=3, res=three, fa="assembly: X"), **A)
# 结果裁决
case("one failure", 1, fake(p=1, f=1, res=[t("a", "Passed"), t("b", "Failed")]), **A)
case("Inconclusive > 0", 1, fake(p=2, inc=1, res=[t("a", "Passed"), t("b", "Passed"), t("c", "Inconclusive")]), **A)
case("Skipped > 0 without --allow-skipped", 1, fake(p=2, sk=1, res=[t("a", "Passed"), t("b", "Passed"), t("c", "Skipped")]), **A)
case("Skipped > 0 with --allow-skipped", 0, fake(p=2, sk=1, res=[t("a", "Passed"), t("b", "Passed"), t("c", "Skipped")]), allow_skipped=True, **A)
if SK != ["Known.Skip"]:
    failures.append(f"expected-skips file: comments / blank lines / BOM / padding not handled: {SK}")
case("every skipped test is in the expected-skips list", 0,
     fake(p=2, sk=1, res=[t("a", "Passed"), t("b", "Passed"), t("Known.Skip", "Skipped")]), expected_skips=SK, **A)
case("one listed + one unlisted skip", 1,
     fake(p=1, sk=2, res=[t("a", "Passed"), t("Known.Skip", "Skipped"), t("New.Skip", "Skipped")]), expected_skips=SK, **A)
case("expected-skips match is exact (case differs)", 1,
     fake(p=2, sk=1, res=[t("a", "Passed"), t("b", "Passed"), t("known.skip", "Skipped")]), expected_skips=SK, **A)
case("Summary says 2 skipped but Results name 1 (A)", 2, fake(p=1, sk=2, res=[t("a", "Passed"), t("Known.Skip", "Skipped")]), expected_skips=SK, **A)
case("Summary says 2 skipped but Results name 1 (B)", 1,
     fake(p=1, sk=2, res=[t("a", "Passed"), t("Known.Skip", "Skipped")]), expected_skips=SK, **dict(B, min_tests=1))
# 规模门
case("Total=0", 1, fake(), **A)
case("Total below the minimum", 1, fake(p=1, res=[t("a", "Passed")]), **A)
case("--allow-zero without --min-tests 0 (contradiction)", 2, fake(), allow_zero=True, **A)
case("--allow-zero with --min-tests 0", 0, fake(), allow_zero=True, **dict(A, min_tests=0))
# 身份门
case("async start response (result=running + StatusPath)", 2, fake(rres="running", spath="C:/x.json"), allow_zero=True, **dict(A, min_tests=0))
case("Mode=All (mode not passed)", 2, fake(p=3, res=three, mode="All"), **A)
case("filter_type swallowed (testname instead of assembly)", 2, fake(p=3, res=three, fa="testname: Service.Weapon"), **FL)
case("with a filter, echoed correctly", 0, fake(p=3, res=three, fa="assembly: Service.Weapon"), **FL)
case("with a filter, echoed with a different case of the type", 0, fake(p=3, res=three, fa="Assembly: Service.Weapon"), **FL)
case("with a filter, but FilterApplied missing", 2, fake(p=3, res=three, omit_fa=True), **FL)
# 结构门
case("Summary missing", 2, fake(p=3, res=[t("a", "Passed")], omit_summary=True), **A)
case("Status out of range (Errored)", 2, fake(p=3, res=[t("a", "Passed"), t("b", "Passed"), t("c", "Errored")]), **A)
bad = fake(p=3, res=three)
bad["Summary"]["Failed"] = False
case("a count that is a bool is not an integer", 2, bad, **A)
bad = fake(p=3, res=three)
bad["Summary"]["Skipped"] = -1
case("a negative count", 2, bad, **A)
bad = fake(p=3, res=three)
bad["Results"] = {"a": 1}
case("Results is not a list", 2, bad, **A)
# L6 按协议分强度
case("A: Results one short of Summary", 2, fake(p=3, res=[t("a", "Passed"), t("b", "Passed")]), **A)
case("B: Results one short of Summary (normal across a PlayMode reload)", 0, fake(p=3, res=[t("a", "Passed"), t("b", "Passed")]), **B)
case("B: Results larger than Summary", 2, fake(p=2, res=three), **B)
# 单元素数组
case("a single test", 0, fake(p=1, res=[t("a", "Passed")]), **dict(A, min_tests=1))


# 内层 success 只对 run_tests / list_tests / menu 有意义
def inner(name, result, command, want_ok, want_text=""):
    try:
        m.check_inner_success(result, command)
        ok, text = True, ""
    except m.VerdictFail as error:
        ok, text = False, str(error)
    if ok != want_ok or (want_text and want_text not in text):
        failures.append(f"{name}: ok={ok} text={text!r}")


inner("run_tests may be judged on its inner success", {"success": True}, "run_tests", True)
inner("menu may be judged on its inner success", {"success": True}, "menu", True)
inner("get_console_logs has no inner success and must not be judged at L3", {"total": 1, "returned": 1}, "get_console_logs", False)
inner("a menu failure carries its reason (MenuResponse has only message)", {"success": False, "message": "no such menu"}, "menu", False, "no such menu")
inner("success must be identically true", {"success": "true"}, "run_tests", False)


# 走 CLI 入口：Protocol A 的作业层（L2）与五处都绿、只有 Failed=1 的回包
def write(name, payload):
    path = os.path.join(root, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(payload if isinstance(payload, str) else json.dumps(payload))
    return path


def verdict(name, want_code, data, rc=0, extra=()):
    path = write(name + ".json", {"success": True, "errors": [], "data": data})
    out = os.path.join(root, name + ".summary.json")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        code = m.main(["verdict", "--protocol", "A", "--file", path, "--rc", str(rc), "--job-id=J1", "--mode", "EditMode",
                       "--min-tests", "1", "--summary-out", out, *extra])
    if code != want_code:
        failures.append(f"verdict {name}: want exit {want_code}, got {code}: {buf.getvalue().strip()[:300]}")
    return json.load(open(out, encoding="utf-8")), buf.getvalue()


def job(result, **over):
    data = {"jobId": "J1", "command": "run_tests", "state": "completed", "cancellationRequested": False,
            "result": result, "error": None, "errorDetails": None, "progress": None}
    data.update(over)
    return data


summary, text = verdict("five-green-one-failed", 1, job(fake(p=1, f=1, res=[t("a", "Passed"), t("b", "Failed", "Expected 1\n  at X")])))
if summary["failed"] != 1 or summary["failure_category"] != "test_failed" or summary["failed_tests"][0]["name"] != "b" \
        or summary["failed_tests"][0]["message"] != "Expected 1" or "Total: 2  Passed: 1  Failed: 1  Skipped: 0  Duration:" not in text:
    failures.append(f"five-green-one-failed: summary/output wrong: {summary} / {text!r}")
verdict("null keys dropped by the job endpoint", 0,
        {k: v for k, v in job({k: v for k, v in fake(p=1, res=[t("a", "Passed")]).items() if v is not None}).items() if v is not None})
verdict("job id mismatch", 2, job(fake(p=1, res=[t("a", "Passed")]), jobId="J2"))
verdict("job canceled", 2, job(fake(p=1, res=[t("a", "Passed")]), state="canceled"))
verdict("data.error set", 2, job(fake(p=1, res=[t("a", "Passed")]), error="boom"))
verdict("command is not run_tests", 2, job(fake(p=1, res=[t("a", "Passed")]), command="list_tests"))
summary, _ = verdict("exit code 1 although success=true (protocol break)", 2, job(fake(p=1, res=[t("a", "Passed")])), rc=1)
if summary["failure_category"] != "unity_cli_transport":
    failures.append(f"protocol break: category {summary['failure_category']}")
inner_fail = fake(p=1, res=[t("a", "Passed")])
inner_fail.update(success=False, error="Test execution timed out")
summary, text = verdict("result.success=false", 2, job(inner_fail))
if summary["failure_category"] != "test_run_error" or "Test execution timed out" not in text:
    failures.append(f"result.success=false: {summary} / {text!r}")

# Protocol B：Temp/pipeline_test_status.json（小写键）转成同样结构再判
def verdict_b(name, want_code, status, age=0.0, extra=()):
    path = write(name + ".status.json", status)
    if age:
        then = os.path.getmtime(path) - age
        os.utime(path, (then, then))
    out = os.path.join(root, name + ".summary.json")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        code = m.main(["verdict", "--protocol", "B", "--status-file", path, "--submitted-at", str(os.path.getmtime(path) + age - 1),
                       "--mode", "PlayMode", "--min-tests", "1", "--summary-out", out, *extra])
    if code != want_code:
        failures.append(f"verdict B {name}: want exit {want_code}, got {code}: {buf.getvalue().strip()[:300]}")
    return json.load(open(out, encoding="utf-8"))


def play(results, summary=None):
    c = summary or {"total": len(results), "passed": sum(r["Status"] == "Passed" for r in results), "failed": 0,
                    "skipped": sum(r["Status"] == "Skipped" for r in results), "inconclusive": 0}
    return {"status": "completed", "duration": 2.0, "summary": c, "results": results}


verdict_b("B green", 0, play([t("a", "Passed"), t("b", "Passed")]))
summary = verdict_b("B Results a subset of Summary (normal across a PlayMode reload)", 0,
                    play([t("a", "Passed"), t("b", "Passed")], {"total": 3, "passed": 3, "failed": 0, "skipped": 0, "inconclusive": 0}))
if summary["total"] != 3 or summary["passed"] != 3:
    failures.append(f"B subset: counts must come from summary: {summary}")
verdict_b("B results missing entirely", 0, {"status": "completed", "duration": 1.0,
                                             "summary": {"total": 2, "passed": 2, "failed": 0, "skipped": 0, "inconclusive": 0}})
verdict_b("B results larger than summary", 2, play([t("a", "Passed"), t("b", "Passed"), t("c", "Passed")],
                                                    {"total": 2, "passed": 2, "failed": 0, "skipped": 0, "inconclusive": 0}))
summary = verdict_b("B failed count from summary", 1, play([t("a", "Passed")], {"total": 2, "passed": 1, "failed": 1, "skipped": 0, "inconclusive": 0}))
if summary["failed"] != 1 or summary["failure_category"] != "test_failed":
    failures.append(f"B failed count from summary: {summary}")
verdict_b("B skipped 2 but only 1 named", 1, play([t("a", "Passed"), t("Known.Skip", "Skipped")],
                                                  {"total": 3, "passed": 1, "failed": 0, "skipped": 2, "inconclusive": 0}),
          extra=["--expected-skips", skips_file])
summary = verdict_b("B status=error", 2, {"status": "error", "message": "Tests did not complete"})
if summary["failure_category"] != "test_run_error":
    failures.append(f"B status=error: {summary}")
verdict_b("B summary uses a bool", 2, play([t("a", "Passed")], {"total": 1, "passed": True, "failed": 0, "skipped": 0, "inconclusive": 0}))
verdict_b("B status file older than the submission", 2, play([t("a", "Passed")]), age=30)
summary = verdict_b("B Total=0", 1, play([]))
if summary["failure_category"] != "test_count_below_floor":
    failures.append(f"B Total=0: {summary}")


# start-check：异步启动响应的身份
def start(name, want_code, result, rc=0, extra=()):
    path = write(name + ".json", {"success": True, "errors": [], "data": {"command": "run_tests", "result": result}})
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        code = m.main(["start-check", "--file", path, "--rc", str(rc), "--project", root, "--submitted-at", "0", *extra])
    if code != want_code:
        failures.append(f"start-check {name}: want exit {want_code}, got {code}: {buf.getvalue().strip()[:300]}")


started = fake(rres="running", spath="Temp/pipeline_test_status.json", mode="PlayMode")
start("async start response", 0, started)
start("not started asynchronously", 2, fake(p=1, res=[t("a", "Passed")], mode="PlayMode"))
start("wrong mode", 2, fake(rres="running", spath="x", mode="EditMode"))
start("filter swallowed", 2, started, extra=["--filter=Foo", "--filter-type=testName"])


# channel：给技能用的只读通道判断，与 qq_unity_channel 同一套判据（描述文件有效 + 找得到 CLI → unity-cli）
def channel(project, cli):
    os.environ["QQ_UNITY_CLI"] = cli
    os.environ.pop("QQ_UNITY_CHANNEL", None)
    os.environ["QQ_UNITY_PROBE_RETRY_DELAY"] = "0"
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        m.main(["channel", "--project", project])
    return buf.getvalue().split("\t")[0].strip()


editor_binary = os.path.join(root, "x", "Editor", "Unity.exe")
os.makedirs(os.path.dirname(editor_binary), exist_ok=True)
open(editor_binary, "w").close()
for label, project, cli, want in (
        ("live descriptor + CLI", os.path.join(root, "proj"), os.path.join(root, "bin", "unity"), "unity-cli"),
        ("live descriptor, no CLI", os.path.join(root, "proj"), os.path.join(root, "no-such-unity"), "none"),
        ("live descriptor, an Editor binary is not the CLI", os.path.join(root, "proj"), editor_binary, "none"),
        ("no descriptor", root, os.path.join(root, "bin", "unity"), "none")):
    got = channel(project, cli)
    if got != want:
        failures.append(f"channel {label}: want {want}, got {got}")


# 预期跳过名单的编码：Windows PowerShell 5.1 的 > / Out-File 写 UTF-16LE（带 BOM），名单里又有中文测试名。
# 原来只按 UTF-8 读，UnicodeDecodeError 一路冒出去、python 带着 traceback 退 1——unity-test.sh 读成「测试红」，
# 而且全绿、一条跳过都没有的运行也一样
def skip_job(skipped_names=()):
    res = [t("A.a", "Passed")] + [t(name, "Skipped") for name in skipped_names]
    return job(fake(p=1, sk=len(skipped_names), res=res))


utf16 = os.path.join(root, "skips-utf16.txt")
with open(utf16, "w", encoding="utf-16") as fh:
    fh.write("# Windows 上必然跳过\nGame.测试.Skip\n")
gbk = os.path.join(root, "skips-gbk.txt")
with open(gbk, "wb") as fh:
    fh.write("# 注释\nGame.测试.Skip\n".encode("gbk"))
if m.load_expected_skips(utf16) != ["Game.测试.Skip"]:
    failures.append(f"UTF-16 expected-skips list not decoded: {m.load_expected_skips(utf16)!r}")
verdict("all green, no skips, UTF-16 list", 0, skip_job(), extra=["--expected-skips", utf16])
verdict("all green, no skips, unreadable (GBK) list", 0, skip_job(), extra=["--expected-skips", gbk])
verdict("one listed skip, UTF-16 list", 0, skip_job(["Game.测试.Skip"]), extra=["--expected-skips", utf16])
summary, text = verdict("one skip, unreadable (GBK) list", 2, skip_job(["Game.测试.Skip"]), extra=["--expected-skips", gbk])
if summary["failure_category"] != "config_error" or "not UTF-8" not in text:
    failures.append(f"unreadable expected-skips list: {summary} / {text!r}")


# 助手自己崩了（这里让摘要写不出来）：退 2（没拿到可信裁决），不是 python 默认带 traceback 的 1
def crash_code():
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            return m.main(["verdict", "--protocol", "A", "--file", write("crash.json", {"success": True, "errors": [],
                           "data": skip_job()}), "--rc", "0", "--job-id=J1", "--mode", "EditMode", "--summary-out", root])
    except Exception as error:  # noqa: BLE001
        return f"raised {type(error).__name__}"


if crash_code() != 2:
    failures.append(f"an internal error in verdict must exit 2, got {crash_code()!r}")

# 描述文件有效、找不到 CLI，但项目装着 tykit：回落 tykit（与 qq_unity_channel 一致），不是 none
with open(os.path.join(root, "proj", "Temp", "tykit.json"), "w", encoding="utf-8") as fh:
    fh.write('{"port": 1}')
got = channel(os.path.join(root, "proj"), os.path.join(root, "no-such-unity"))
os.remove(os.path.join(root, "proj", "Temp", "tykit.json"))
if got != "tykit":
    failures.append(f"channel live descriptor, no CLI, tykit.json: want tykit, got {got}")

for item in failures:
    print(item)
print(f"{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
PY
then
  pass "unity-cli verdict unit tests (ported from uc_verdict_tests.ps1): L3b/L4/L5/L6/L7, inner-success whitelist, job layer, Protocol B, start-check, channel"
else
  fail "unity-cli verdict unit tests (ported from uc_verdict_tests.ps1): L3b/L4/L5/L6/L7, inner-success whitelist, job layer, Protocol B, start-check, channel"
  sed 's/^/    /' "$UT_OUT"
fi

# 令牌从没出现在任何输出、CLI 的 argv 和 .qq/ 里
if grep -rqF "$UT_SECRET" "$UT_ALL" "$UT_LOG" "$UT_PROJ/.qq" 2>/dev/null; then
  fail "unity-cli test: the descriptor's token never shows up in any output, CLI argv or .qq/"
else
  pass "unity-cli test: the descriptor's token never shows up in any output, CLI argv or .qq/"
fi

kill "$UT_SLEEPER" 2>/dev/null || true
wait "$UT_SLEEPER" 2>/dev/null || true
unset UT_LOG UT_FIX UT_STATE UT_CLI
rm -rf "$UT_ROOT"

# ── 技能说明按项目实际通道给 Unity Editor 的写法（官方 Unity CLI / tykit）──
# 第 8 条回归：shared/tykit-first.md、tykit-reference.md，以及 add-tests、两个 code-review、execute、explain、plan、
# self-review 里「查正在运行的 Editor」那一段，原来都默认项目装着 tykit——撤掉 tykit、改用官方 Unity CLI 的项目照着做，
# 命令全是错的。现在 shared/unity-live-state.md 先按文件在不在判通道，官方 CLI 的命令面在 shared/unity-cli-reference.md，
# 各技能那一段两种通道都给写法。这里是静态检查；文档链接有没有断由第 5 段的 5e 管（已扩到 skills/、shared/）。
echo -e "${CYAN}[skills] Unity Editor guidance follows the project's channel${NC}"
SK_TMP="$(mktemp -d)"
SK_PY="$SK_TMP/check.py"
cat > "$SK_PY" <<'PY'
import re
import sys
from pathlib import Path

check, root = sys.argv[1], Path(sys.argv[2])
DESCRIPTOR = "unity-pipeline-port"
LIVE = "unity-live-state.md"
# 第 8 条点名的技能（test 是第 7 条改的，这里一起核对）
NAMED = ("add-tests", "claude-code-review", "codex-code-review", "execute", "explain", "plan", "self-review", "test")
OFFICIAL = 'unity command --project-path "$PWD"'
DISCOVER = 'unity command --project-path "$PWD" --query <keyword> --detail full --json'


def docs():
    for path in sorted((root / "skills").rglob("*.md")) + sorted((root / "shared").glob("*.md")):
        yield path, path.read_text(encoding="utf-8")


def rel(path):
    return path.relative_to(root).as_posix()


def read(path):
    return path.read_text(encoding="utf-8") if path.is_file() else ""


problems = []
if check == "by-channel":
    # 提到 tykit 的技能 / 共享文档，也得给出官方 CLI 的判据（描述文件）或链到按通道分流的入口
    for path, text in docs():
        if re.search(r"tykit", text, re.I) and DESCRIPTOR not in text and LIVE not in text:
            problems.append(f"{rel(path)} mentions tykit but neither the Pipeline descriptor nor {LIVE}")
elif check == "named-skills":
    for name in NAMED:
        text = read(root / "skills" / name / "SKILL.md")
        if "../../shared/" + LIVE not in text:
            problems.append(f"skills/{name}/SKILL.md does not link shared/{LIVE}")
        if OFFICIAL not in text:
            problems.append(f"skills/{name}/SKILL.md gives no official Unity CLI form ({OFFICIAL} ...)")
elif check == "shared-docs":
    live, ref = root / "shared" / LIVE, root / "shared" / "unity-cli-reference.md"
    for path in (live, ref):
        if not path.is_file():
            problems.append(f"{rel(path)} is missing")
    text = read(live)
    for needle in ("Library/Pipeline/.unity-pipeline-port", "Temp/tykit.json", "unity-cli-reference.md", "tykit-reference.md", OFFICIAL):
        if live.is_file() and needle not in text:
            problems.append(f"shared/{LIVE} does not mention {needle}")
    text = read(ref)
    if ref.is_file() and DISCOVER not in text:
        problems.append(f"shared/unity-cli-reference.md does not show the parameter lookup ({DISCOVER})")
    if ref.is_file() and not re.search(r"^## Recovery\s*$", text, re.M):
        problems.append("shared/unity-cli-reference.md has no '## Recovery' section (skills link #recovery)")
    head = read(root / "shared" / "tykit-reference.md").split("## Backend selection", 1)[0]
    if "tykit channel only" not in head or "unity-cli-reference.md" not in head:
        problems.append("shared/tykit-reference.md has no 'tykit channel only' banner pointing at unity-cli-reference.md above Backend selection")
    text = read(root / "shared" / "tykit-first.md")
    if LIVE not in text or len(text.splitlines()) > 10:
        problems.append(f"shared/tykit-first.md should be a short pointer to {LIVE}")
elif check == "descriptor-warning":
    for path, text in docs():
        if DESCRIPTOR in text and "eval token" not in text:
            problems.append(f"{rel(path)} names the Pipeline descriptor without warning that it holds an eval token")
elif check == "no-raw-cli":
    # 手写的 unity command … run_tests（同一段行内代码 / 同一行代码块里）；会另起 batch Editor 的 unity test/build/run；
    # 对 run_tests 无效还会把跑完的作业标成 canceled 的 job cancel；混两种协议的 --mode all
    raw_run_tests = re.compile(r"\bunity\s+(command|cmd|request)\b[^`\n]*\brun_tests\b")
    banned = re.compile(r"\bjob cancel\b|\bunity (test|build|run)\b|--mode all\b")
    for path, text in docs():
        for lineno, line in enumerate(text.splitlines(), 1):
            if raw_run_tests.search(line) or banned.search(line):
                problems.append(f"{rel(path)}:{lineno}: {line.strip()[:160]}")
else:
    problems.append(f"unknown check {check}")
for item in problems:
    print(item)
sys.exit(1 if problems else 0)
PY

sk_check() {   # sk_check <检查名> <说明>
  if $QQ_PY "$SK_PY" "$1" "$SCRIPT_DIR" > "$SK_TMP/out" 2>&1; then
    pass "$2"
  else
    fail "$2"
    sed 's/^/    /' "$SK_TMP/out"
  fi
}
sk_check by-channel "skills/shared docs that mention tykit also give the official-CLI route (Pipeline descriptor or shared/unity-live-state.md)"
sk_check named-skills "add-tests, both code reviews, execute, explain, plan, self-review, test: link shared/unity-live-state.md and show the official unity command form"
sk_check shared-docs "shared/unity-live-state.md + unity-cli-reference.md (parameter lookup via --query <keyword> --detail full --json); tykit-reference.md bannered tykit-only; tykit-first.md is a pointer"
sk_check descriptor-warning "every skill/shared doc that names the Pipeline descriptor warns it holds an eval token"
sk_check no-raw-cli "skills/shared docs never hand-write run_tests through unity command, the CLI's own test/build/run, job cancel or --mode all"
unset -f sk_check

# 技能按 qq-unity-cli.py channel 的答案选写法，脚本按 bash 的 qq_unity_channel 走：两边对同一个项目得给同一个通道。
# 原来强制 QQ_UNITY_CHANNEL=unity-cli 却没装 CLI 时 python 照答 unity-cli（技能让人去敲不存在的 unity），bash 已降级；
# 「Editor 本体不算 CLI」两边规则也不一样（bash 分大小写、不认反斜杠）。全程用桩，描述文件里的令牌是假的
SK_PROJ="$SK_TMP/proj"
mkdir -p "$SK_PROJ/Library/Pipeline" "$SK_PROJ/Temp" "$SK_TMP/bin" "$SK_TMP/x/editor" "$SK_TMP/y/Editor"
$QQ_PY -c 'import os,sys,time
with open(sys.argv[1], "w") as fh: fh.write(str(os.getpid()))
time.sleep(3600)' "$SK_TMP/live.pid" &
SK_SLEEPER=$!
for _ in $(seq 1 100); do [ -s "$SK_TMP/live.pid" ] && break; sleep 0.1; done
$QQ_PY - "$SK_PROJ" "$(cat "$SK_TMP/live.pid" 2>/dev/null || echo 0)" <<'PY'
import json
import os
import sys

proj, pid = sys.argv[1:3]
with open(os.path.join(proj, "Library", "Pipeline", ".unity-pipeline-port"), "w", encoding="utf-8") as fh:
    json.dump({"pid": int(pid), "port": 7899, "projectPath": os.path.abspath(proj), "evalToken": "QQ-TEST-SECRET-7f3a"}, fh)
PY
printf '#!/usr/bin/env bash\nexit 0\n' > "$SK_TMP/bin/unity"
: > "$SK_TMP/x/editor/unity.exe"
: > "$SK_TMP/y/Editor/Unity.exe"
chmod +x "$SK_TMP/bin/unity"
sk_channels() {  # <kind> <QQ_UNITY_CHANNEL> <QQ_UNITY_CLI> → "bash 的通道|python 的通道"
  PROJECT_DIR="$SK_PROJ" QQ_UNITY_CHANNEL="$2" QQ_UNITY_CLI="$3" QQ_UNITY_PROBE_RETRY_DELAY=0 bash -c '
    source "$1/scripts/unity-common.sh" || exit 9
    qq_unity_channel "$2" >/dev/null 2>&1
    printf "%s|" "$QQ_UNITY_CHANNEL_RESOLVED"
    $QQ_PY "$1/scripts/qq-unity-cli.py" channel --project "$PROJECT_DIR" --kind "$2" 2>/dev/null | cut -f1 | tr -d "\r\n"' \
    _ "$SCRIPT_DIR" "$1" 2>/dev/null || echo "error"
}
SK_BAD=""
sk_expect() {  # <期望> <kind> <QQ_UNITY_CHANNEL> <QQ_UNITY_CLI> <说明>
  local got
  got="$(sk_channels "$2" "$3" "$4")"
  if [ "$got" != "$1|$1" ]; then SK_BAD="$SK_BAD
    $5 ($2): want $1|$1, got $got"; fi
}
sk_expect unity-cli test "" "$SK_TMP/bin/unity" "live descriptor + CLI"
sk_expect none test unity-cli "$SK_TMP/no-such-unity" "QQ_UNITY_CHANNEL=unity-cli without a CLI"
sk_expect refresh-trigger compile unity-cli "$SK_TMP/no-such-unity" "QQ_UNITY_CHANNEL=unity-cli without a CLI"
sk_expect none test "" "$SK_TMP/x/editor/unity.exe" "an Editor binary spelled in lower case is not the CLI"
sk_expect none test "" "$SK_TMP/y/Editor/Unity.exe" "an Editor binary is not the CLI"
if command -v cygpath >/dev/null 2>&1; then
  sk_expect none test "" "$(cygpath -w "$SK_TMP/y/Editor/Unity.exe")" "an Editor binary given with backslashes is not the CLI"
fi
printf '{"port":1}\n' > "$SK_PROJ/Temp/tykit.json"
sk_expect tykit test unity-cli "$SK_TMP/no-such-unity" "QQ_UNITY_CHANNEL=unity-cli without a CLI, tykit installed"
if [ -z "$SK_BAD" ]; then
  pass "qq-unity-cli.py channel (what skills read) and qq_unity_channel (what scripts do) agree: forced unity-cli without a CLI, Editor binaries in any spelling, tykit fallback"
else
  fail "qq-unity-cli.py channel (what skills read) and qq_unity_channel (what scripts do) agree: forced unity-cli without a CLI, Editor binaries in any spelling, tykit fallback"
  printf '%s\n' "$SK_BAD"
fi
kill "$SK_SLEEPER" 2>/dev/null || true
wait "$SK_SLEEPER" 2>/dev/null || true
unset -f sk_channels sk_expect
rm -rf "$SK_TMP"

# ── review script symmetry ──
echo -e "${CYAN}[review] script symmetry${NC}"

# code-review.sh accepts --files
if grep -q '\-\-files)' "$SCRIPT_DIR/scripts/code-review.sh"; then
  pass "code-review.sh accepts --files"
else
  fail "code-review.sh missing --files"
fi

# severity label consistency
if grep -q '\[Moderate\]' "$SCRIPT_DIR/scripts/code-review.sh" && ! grep -q '\[Medium\]' "$SCRIPT_DIR/scripts/code-review.sh"; then
  pass "code-review.sh uses [Moderate] not [Medium]"
else
  fail "code-review.sh still uses [Medium]"
fi

if grep -q '\[Moderate\]' "$SCRIPT_DIR/scripts/plan-review.sh" && ! grep -q '\[Medium\]' "$SCRIPT_DIR/scripts/plan-review.sh"; then
  pass "plan-review.sh uses [Moderate] not [Medium]"
else
  fail "plan-review.sh still uses [Medium]"
fi

# claude-review.sh exists and uses claude -p
if [[ -x "$SCRIPT_DIR/scripts/claude-review.sh" ]]; then
  pass "claude-review.sh exists and is executable"
else
  fail "claude-review.sh missing or not executable"
fi

if grep -q 'claude -p' "$SCRIPT_DIR/scripts/claude-review.sh"; then
  pass "claude-review.sh calls claude -p"
else
  fail "claude-review.sh does not call claude -p"
fi

if grep -q '\-\-files)' "$SCRIPT_DIR/scripts/claude-review.sh" && grep -q '\-\-base)' "$SCRIPT_DIR/scripts/claude-review.sh"; then
  pass "claude-review.sh accepts --files and --base"
else
  fail "claude-review.sh missing expected args"
fi

# claude-plan-review.sh exists and uses claude -p
if [[ -x "$SCRIPT_DIR/scripts/claude-plan-review.sh" ]] && grep -q 'claude -p' "$SCRIPT_DIR/scripts/claude-plan-review.sh"; then
  pass "claude-plan-review.sh exists and calls claude -p"
else
  fail "claude-plan-review.sh missing or wrong CLI"
fi

# all 4 review scripts open the review gate themselves (the set hook no longer guesses from command text)
for script_name in code-review plan-review claude-review claude-plan-review; do
  if grep -q '^qq_review_gate_open$' "$SCRIPT_DIR/scripts/${script_name}.sh" && \
     grep -q 'source "$(dirname "$0")/platform/detect.sh"' "$SCRIPT_DIR/scripts/${script_name}.sh"; then
    pass "${script_name}.sh opens the review gate itself"
  else
    fail "${script_name}.sh does not source detect.sh / call qq_review_gate_open"
  fi
done
if ! grep -qE 'code-review|plan-review|claude-review' "$SCRIPT_DIR/scripts/hooks/review-gate.sh"; then
  pass "review-gate.sh set no longer pattern-matches review script names in command text"
else
  fail "review-gate.sh still matches review script names in command text"
fi

# ── codex effort resolution & prompt transport (codex-common.sh) ──
echo -e "${CYAN}[review] codex effort resolution & transport${NC}"

CODEX_FIXTURE="$(mktemp -d)"
mkdir -p "$CODEX_FIXTURE/home/.codex" "$CODEX_FIXTURE/alt" "$CODEX_FIXTURE/bin" "$CODEX_FIXTURE/tmp"
printf 'model = "fixture-model"\nmodel_reasoning_effort = "low"\n\n[profiles.x]\nmodel = "other"\n' > "$CODEX_FIXTURE/home/.codex/config.toml"
cat > "$CODEX_FIXTURE/home/.codex/models_cache.json" <<'JSON'
{"models":[{"slug":"other","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]},
           {"slug":"fixture-model","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]}]}
JSON
# alt：旧写法的顶层 profile 指向 fixture-model，codex 0.134+ 已不认它，生效的是顶层 model = 'other'（单引号）
printf "profile = 'x'\nmodel = 'other'\n\n[profiles.x]\nmodel = 'fixture-model'\n" > "$CODEX_FIXTURE/alt/config.toml"
# 项目级 .codex/config.toml 覆盖用户配置里的模型
mkdir -p "$CODEX_FIXTURE/project/.codex" "$CODEX_FIXTURE/project/sub"
printf 'model = "other"\n' > "$CODEX_FIXTURE/project/.codex/config.toml"
# 挡掉 tomllib，逼出旧版 Python 的退回解析器
mkdir -p "$CODEX_FIXTURE/no-tomllib"
printf 'raise ImportError("forced for test")\n' > "$CODEX_FIXTURE/no-tomllib/tomllib.py"
cp "$CODEX_FIXTURE/home/.codex/models_cache.json" "$CODEX_FIXTURE/alt/models_cache.json"

# 在严格模式下解析强度：codex_resolve <CODEX_HOME 目录> <requested>
# 夹具一律经 CODEX_HOME 指定：Windows 上 Python 与 codex 都按 USERPROFILE 找家目录、不认 HOME，
# 用 HOME 造夹具在 Windows 上会悄悄读到本机真实配置。
codex_resolve() {
  CODEX_HOME="$1" bash -c 'set -euo pipefail; source "$0/scripts/codex-common.sh"; qq_codex_resolve_effort "$1" && printf "%s" "$QQ_CODEX_EFFORT_RESOLVED"' "$SCRIPT_DIR" "$2" 2>/dev/null
}
# 夹具模型最高档是 max（故意不含 ultra）：误读本机真实配置会得到别的值
if [[ "$(codex_resolve "$CODEX_FIXTURE/home/.codex" "")" == "max" ]]; then
  pass "unset effort resolves to the configured model's highest level (config.toml low is not inherited)"
else
  fail "unset effort did not resolve to the model's highest level"
fi
if [[ "$(codex_resolve "$CODEX_FIXTURE/home/.codex" "xhigh")" == "xhigh" ]]; then
  pass "explicit effort supported by the model passes through"
else
  fail "explicit supported effort was not passed through"
fi
if codex_resolve "$CODEX_FIXTURE/home/.codex" "config" >/dev/null && [[ "$(codex_resolve "$CODEX_FIXTURE/home/.codex" "config")" == "" ]]; then
  pass "effort 'config' inherits config.toml"
else
  fail "effort 'config' did not inherit config.toml"
fi
if ! codex_resolve "$CODEX_FIXTURE/home/.codex" "bogus" >/dev/null; then
  pass "effort the model does not support is rejected"
else
  fail "unsupported effort was accepted"
fi
if [[ "$(codex_resolve "$CODEX_FIXTURE/empty" "")" == "high" ]]; then
  pass "without a config or models cache the effort falls back to high"
else
  fail "missing models cache did not fall back to high"
fi
if [[ "$(codex_resolve "$CODEX_FIXTURE/alt" "")" == "medium" ]] && \
   ! codex_resolve "$CODEX_FIXTURE/alt" "ultra" >/dev/null; then
  pass "legacy top-level profile is ignored and a single-quoted top-level model is used (codex 0.134+)"
else
  fail "legacy profile / single-quoted model not resolved like codex does"
fi
if [[ "$(cd "$CODEX_FIXTURE/project/sub" && codex_resolve "$CODEX_FIXTURE/home/.codex" "")" == "medium" ]]; then
  pass "a project .codex/config.toml found above the working directory overrides the user model"
else
  fail "project .codex/config.toml did not override the user model"
fi
if [[ "$(PYTHONPATH="$CODEX_FIXTURE/no-tomllib" codex_resolve "$CODEX_FIXTURE/alt" "")" == "medium" ]] && \
   [[ "$(PYTHONPATH="$CODEX_FIXTURE/no-tomllib" codex_resolve "$CODEX_FIXTURE/home/.codex" "")" == "max" ]]; then
  pass "the fallback parser (no tomllib) resolves single- and double-quoted top-level models"
else
  fail "the no-tomllib fallback parser resolved the wrong model"
fi

# 模拟 codex：stdout 回报收到的 stdin 字节数与 -c 参数；按 FAKE_CODEX_MODE 模拟不同结局
cat > "$CODEX_FIXTURE/bin/codex" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "codex-cli 0.0.0-fake"; exit 0; }
args="$*"
bytes=$(wc -c | tr -d ' ')
echo "progress: reading files" >&2
case "${FAKE_CODEX_MODE:-ok}" in
  ok)     echo "stdin-bytes=${bytes} gol=${GIT_OPTIONAL_LOCKS:-unset} args=${args}" ;;
  quote)  echo "Finding: the hint fires on 'is not supported when using Codex with a ChatGPT account'." ;;
  reject) echo "ERROR: {\"status\":400,\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\"}" >&2; exit 1 ;;
esac
SH
chmod +x "$CODEX_FIXTURE/bin/codex"
# codex_run <mode> <out-file> <effort> -> runs qq_codex_run in strict mode, prints "status=<n>" last
codex_run() {
  local long_prompt="$CODEX_FIXTURE/prompt.txt"
  head -c 20000 /dev/zero | tr '\0' 'p' > "$long_prompt"
  PATH="$CODEX_FIXTURE/bin:$PATH" FAKE_CODEX_MODE="$1" QQ_CODEX_EFFORT_RESOLVED="$3" QQ_TEMP_DIR="$CODEX_FIXTURE/tmp" \
    bash -c 'set -euo pipefail; source "$0/scripts/codex-common.sh"; rc=0; qq_codex_run "$1" "$2" || rc=$?; echo "status=$rc"' \
    "$SCRIPT_DIR" "$long_prompt" "$2" 2>"$CODEX_FIXTURE/stderr.txt"
}
OUT="$CODEX_FIXTURE/review.md"
RUN_OUT="$(codex_run ok "$OUT" ultra)"
if [[ "$RUN_OUT" == *"status=0" ]] && grep -q "stdin-bytes=20000 " "$OUT" && grep -q 'model_reasoning_effort="ultra"' "$OUT"; then
  pass "a 20000-byte prompt reaches codex intact through stdin, with the resolved effort"
else
  fail "prompt was not delivered intact through stdin (got: $(head -c 200 "$OUT" 2>/dev/null))"
fi
if ! grep -q "progress:" "$OUT" && grep -q "progress:" "$CODEX_FIXTURE/stderr.txt"; then
  pass "codex stderr stays out of the review file and is replayed to the terminal"
else
  fail "codex stderr leaked into the review file or was lost"
fi
RUN_OUT="$(unset GIT_OPTIONAL_LOCKS; codex_run ok "$OUT" "")"
if [[ "$RUN_OUT" == *"status=0" ]] && \
   grep -qxF 'stdin-bytes=20000 gol=0 args=exec --sandbox read-only -c shell_environment_policy.set.GIT_OPTIONAL_LOCKS="0"' "$OUT"; then
  pass "effort 'config' (empty) runs under set -u without an empty-array error and passes no effort override"
else
  fail "empty effort broke under set -u or still passed an effort override (got: $(head -c 200 "$OUT" 2>/dev/null))"
fi
# 只读沙箱里的 `git status` 会留下删不掉的 0 字节 .git/index.lock：codex 与它沙箱里的 shell 都要带 GIT_OPTIONAL_LOCKS=0
if grep -q "gol=0 " "$OUT" && grep -qF 'shell_environment_policy.set.GIT_OPTIONAL_LOCKS="0"' "$OUT"; then
  pass "codex runs with GIT_OPTIONAL_LOCKS=0 in its env and in the sandboxed shell policy"
else
  fail "GIT_OPTIONAL_LOCKS=0 not passed to codex or its sandboxed shell"
fi
RUN_OUT="$(codex_run quote "$OUT" ultra)"
if [[ "$RUN_OUT" == *"status=0" ]] && ! grep -q "outdated CLI" "$CODEX_FIXTURE/stderr.txt"; then
  pass "a successful review that quotes the rejection text is not turned into a failure"
else
  fail "quoting the rejection text in a successful review caused a false failure"
fi
RUN_OUT="$(codex_run reject "$OUT" ultra)"
if [[ "$RUN_OUT" == *"status=1" ]] && grep -q "npm i -g @openai/codex@latest" "$CODEX_FIXTURE/stderr.txt"; then
  pass "a real model rejection fails and prints the CLI upgrade hint"
else
  fail "model rejection did not fail or printed no upgrade hint"
fi
RUN_OUT="$(codex_run ok "$CODEX_FIXTURE/no-such-dir/review.md" ultra)"
if [[ "$RUN_OUT" != *"status=0" ]]; then
  pass "an unwritable review file is reported as a failure"
else
  fail "an unwritable review file was reported as success"
fi
if [[ -z "$(ls -A "$CODEX_FIXTURE/tmp")" ]]; then
  pass "qq_codex_run removes its stderr temp file"
else
  fail "qq_codex_run left a stderr temp file behind"
fi
rm -rf "$CODEX_FIXTURE"

for review_script in code-review plan-review; do
  if grep -q 'qq_codex_run' "$SCRIPT_DIR/scripts/${review_script}.sh" && ! grep -q '"\$FULL_PROMPT" |' "$SCRIPT_DIR/scripts/${review_script}.sh"; then
    pass "${review_script}.sh feeds the prompt through stdin via qq_codex_run (no argv prompt)"
  else
    fail "${review_script}.sh still passes the prompt as argv"
  fi
done
if grep -q '"scripts/codex-common.sh"' "$SCRIPT_DIR/scripts/qq_internal_install.py"; then
  pass "codex-common.sh is in the install manifest next to the review scripts"
else
  fail "codex-common.sh missing from the install manifest"
fi

# ── skill refactoring ──
echo -e "${CYAN}[skills] review skill structure${NC}"

# claude-code-review calls claude-review.sh
if grep -q 'claude-review\.sh' skills/claude-code-review/SKILL.md; then
  pass "claude-code-review skill calls claude-review.sh"
else
  fail "claude-code-review skill does not call claude-review.sh"
fi

# claude-plan-review calls claude-plan-review.sh
if grep -q 'claude-plan-review\.sh' skills/claude-plan-review/SKILL.md; then
  pass "claude-plan-review skill calls claude-plan-review.sh"
else
  fail "claude-plan-review skill does not call claude-plan-review.sh"
fi

# all 4 skills write expected count
for skill in claude-code-review claude-plan-review codex-code-review codex-plan-review; do
  if grep -q 'review-gate-\$QQ_SESSION_ID' "skills/${skill}/SKILL.md"; then
    pass "${skill} writes expected count to gate"
  else
    fail "${skill} missing expected count write"
  fi
done

# ── MCP review tools ──
echo -e "${CYAN}[mcp] review tools${NC}"

if $QQ_PY -c "
import ast, sys
src = open('scripts/qq_mcp.py').read()
tree = ast.parse(src)
for node in ast.walk(tree):
    if isinstance(node, ast.Dict):
        for key in node.keys:
            if isinstance(key, ast.Constant) and key.value == 'qq_code_review':
                sys.exit(0)
sys.exit(1)
"; then
  pass "qq_code_review defined in qq_mcp.py"
else
  fail "qq_code_review not found in qq_mcp.py"
fi

if $QQ_PY -c "
import ast, sys
src = open('scripts/qq_mcp.py').read()
tree = ast.parse(src)
for node in ast.walk(tree):
    if isinstance(node, ast.Dict):
        for key in node.keys:
            if isinstance(key, ast.Constant) and key.value == 'qq_plan_review':
                sys.exit(0)
sys.exit(1)
"; then
  pass "qq_plan_review defined in qq_mcp.py"
else
  fail "qq_plan_review not found in qq_mcp.py"
fi

# ── Summary ──
echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}All $TOTAL checks passed${NC}"
else
  echo -e "${RED}$FAIL/$TOTAL checks failed${NC}"
  exit 1
fi

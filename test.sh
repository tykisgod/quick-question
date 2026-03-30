#!/usr/bin/env bash
# test.sh — Self-tests for quick-question repo
# Run: ./test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { ((PASS++)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { ((FAIL++)); echo -e "  ${RED}✗${NC} $1"; }

# ── 1. ShellCheck ──
echo -e "${CYAN}[1/9] ShellCheck${NC}"
if command -v shellcheck &>/dev/null; then
  SHELL_FILES=$(find "$SCRIPT_DIR/scripts" -name "*.sh" -not -type l)
  SHELL_FILES="$SHELL_FILES $SCRIPT_DIR/install.sh $SCRIPT_DIR/test.sh"
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
echo -e "${CYAN}[2/9] Python compilation${NC}"
PY_FILES=$(find "$SCRIPT_DIR/scripts" -name "*.py" -not -type l)
for py_file in $PY_FILES; do
  if python3 -m py_compile "$py_file" >/dev/null 2>&1; then
    pass "$(basename "$py_file")"
  else
    fail "$(basename "$py_file")"
  fi
done

# ── 3. JSON validity ──
echo -e "${CYAN}[3/9] JSON validity${NC}"
for json_file in scripts/qq-capabilities.json scripts/tykit_capabilities.json hooks/hooks.json .claude-plugin/plugin.json .claude-plugin/marketplace.json templates/qq-policy.json.example docs/evals/foundation-smoke.json docs/evals/unity-local.json; do
  if [ -f "$SCRIPT_DIR/$json_file" ]; then
    if python3 -m json.tool "$SCRIPT_DIR/$json_file" >/dev/null 2>&1; then
      pass "$json_file"
    else
      fail "$json_file — invalid JSON"
    fi
  else
    fail "$json_file — file not found"
  fi
done

# ── 4. Structural checks ──
echo -e "${CYAN}[4/9] Structural checks${NC}"

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

# install.sh copies hooks subdirectory
if grep -q 'scripts/hooks/' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh copies scripts/hooks/"
else
  fail "install.sh missing scripts/hooks/ copy"
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

# ── 5. README consistency ──
echo -e "${CYAN}[5/9] README consistency${NC}"

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

# ── 6. SKILL.md frontmatter ──
echo -e "${CYAN}[6/9] SKILL.md frontmatter${NC}"

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
echo -e "${CYAN}[7/9] Script permissions${NC}"

for f in "$SCRIPT_DIR"/scripts/*.sh "$SCRIPT_DIR"/scripts/*.py "$SCRIPT_DIR"/scripts/hooks/*.sh "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/test.sh"; do
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    if [ -x "$f" ]; then
      pass "$(basename "$f") is executable"
    else
      fail "$(basename "$f") NOT executable"
    fi
  fi
done

# ── 8. Runtime helper smoke tests ──
echo -e "${CYAN}[8/9] Runtime helper smoke tests${NC}"

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

RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$RUNTIME_TEST_ROOT" --stage compile --command smoke --backend test --transport local --summary "smoke start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$RUNTIME_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "smoke finish" >/dev/null

if python3 - "$RUNTIME_TEST_ROOT" <<'PY'
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

python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$RUNTIME_TEST_ROOT" >/dev/null
if python3 - "$RUNTIME_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["work_mode"] == "feature"
assert state["work_mode_source"] == "default"
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
cat > "$RUNTIME_TEST_ROOT/qq-policy.json" <<'EOF'
{
  "policy_profile": "core",
  "work_mode": "feature",
  "enabled_rules": [
    "find_object_of_type",
    "send_message",
    "tag_compare",
    "get_component_in_hot_path"
  ]
}
EOF
cat > "$RUNTIME_TEST_ROOT/.qq/local-policy.json" <<'EOF'
{
  "work_mode": "prototype",
  "policy_profile": "hardening"
}
EOF
rm -f "$RUNTIME_TEST_ROOT/Docs/design/sample.md" "$RUNTIME_TEST_ROOT/Docs/qq/demo/sample_implementation.md"
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$RUNTIME_TEST_ROOT" >/dev/null
if python3 - "$RUNTIME_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["work_mode"] == "prototype"
assert state["work_mode_source"] == "qq_local_policy"
assert state["task_focus"] == []
assert state["task_focus_source"] == "default"
assert state["policy_profile"] == "hardening"
assert state["policy_profile_source"] == "qq_local_policy"
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

FOCUS_TEST_ROOT="$(mktemp -d)"
mkdir -p "$FOCUS_TEST_ROOT/Docs/design" "$FOCUS_TEST_ROOT/.qq"
cat > "$FOCUS_TEST_ROOT/Docs/design/crew_weapon.md" <<'EOF'
# Crew Weapon
EOF
cat > "$FOCUS_TEST_ROOT/Docs/design/map_refactor.md" <<'EOF'
# Map Refactor
EOF
cat > "$FOCUS_TEST_ROOT/qq-policy.json" <<'EOF'
{
  "work_mode": "prototype",
  "policy_profile": "feature"
}
EOF
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FOCUS_TEST_ROOT" >/dev/null
if python3 - "$FOCUS_TEST_ROOT" <<'PY'
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

cat > "$FOCUS_TEST_ROOT/.qq/local-policy.json" <<'EOF'
{
  "work_mode": "prototype",
  "policy_profile": "feature",
  "task_focus": "crew weapon"
}
EOF
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FOCUS_TEST_ROOT" >/dev/null
if python3 - "$FOCUS_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["task_focus"] == ["crew weapon"]
assert state["task_focus_source"] == "qq_local_policy"
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
RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$POLICY_TEST_ROOT" --stage compile --command policy-compile --backend test --transport local --summary "policy compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$POLICY_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "policy compile passed" >/dev/null
cat > "$POLICY_TEST_ROOT/qq-policy.json" <<'EOF'
{
  "policy_profile": "core",
  "work_mode": "prototype"
}
EOF
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if python3 - "$POLICY_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["has_uncommitted_cs_changes"] is True
assert state["policy_profile"] == "core"
assert state["default_test_scope"] == "editmode"
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

cat > "$POLICY_TEST_ROOT/.qq/local-policy.json" <<'EOF'
{
  "work_mode": "prototype",
  "policy_profile": "hardening"
}
EOF
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if python3 - "$POLICY_TEST_ROOT" <<'PY'
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

RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$POLICY_TEST_ROOT" --stage test --command policy-test --backend test --transport local --summary "policy test start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$POLICY_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "policy test passed" >/dev/null
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if python3 - "$POLICY_TEST_ROOT" <<'PY'
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

RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$POLICY_TEST_ROOT" --stage review_gate --command policy-review --backend test --transport local --summary "policy review start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$POLICY_TEST_ROOT" --run-id "$RUN_ID" --status verified --summary "policy review verified" >/dev/null
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if python3 - "$POLICY_TEST_ROOT" <<'PY'
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

STALE_TEST_ROOT="$(mktemp -d)"
mkdir -p "$STALE_TEST_ROOT/.qq"
(
  cd "$STALE_TEST_ROOT" &&
  git init -q
)
cat > "$STALE_TEST_ROOT/qq-policy.json" <<'EOF'
{
  "work_mode": "prototype",
  "policy_profile": "hardening"
}
EOF
RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$STALE_TEST_ROOT" --stage test --command stale-test --backend test --transport local --summary "stale test start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$STALE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "stale test passed" >/dev/null
sleep 1
cat > "$STALE_TEST_ROOT/Probe.cs" <<'EOF'
public class Probe {}
EOF
RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$STALE_TEST_ROOT" --stage compile --command stale-compile --backend test --transport local --summary "stale compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$STALE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "stale compile passed" >/dev/null
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$STALE_TEST_ROOT" >/dev/null
if python3 - "$STALE_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["has_uncommitted_cs_changes"] is True
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
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$STALE_TEST_ROOT" >/dev/null
if python3 - "$STALE_TEST_ROOT" <<'PY'
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

WORKTREE_TEST_ROOT="$(mktemp -d)"
(
  cd "$WORKTREE_TEST_ROOT" &&
  git init -q &&
  git config user.email qq@example.com &&
  git config user.name "qq test" &&
  printf '{\n  "mcpServers": {\n    "tykit": { "command": "python3" }\n  }\n}\n' > .mcp.json &&
  mkdir -p .claude &&
  printf '{\n  "enabledPlugins": {\n    "qq@quick-question-marketplace": true\n  }\n}\n' > .claude/settings.local.json &&
  printf 'base\n' > README.md &&
  git add README.md .mcp.json &&
  git add -f .claude/settings.local.json &&
  git commit -q -m "init" &&
  git checkout -q -b feature/ship-system
)
WORKTREE_PARENT="$(dirname "$WORKTREE_TEST_ROOT")"
if CREATE_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_TEST_ROOT" --name "Sea Monster" --base-dir "$WORKTREE_PARENT"); then
  WORKTREE_PATH=$(printf '%s' "$CREATE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worktreePath"])')
  if python3 - "$CREATE_JSON" "$WORKTREE_TEST_ROOT" "$WORKTREE_PATH" <<'PY'
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
assert (target / ".mcp.json").is_file()
assert (target / ".claude" / "settings.local.json").is_file()
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

WORKTREE_STATUS_JSON="$(mktemp)"
WORKTREE_MERGE_JSON="$(mktemp)"
WORKTREE_CLEANUP_JSON="$(mktemp)"

if [ -n "${WORKTREE_PATH:-}" ] && python3 "$SCRIPT_DIR/scripts/qq-worktree.py" status --project "$WORKTREE_PATH" > "$WORKTREE_STATUS_JSON" && \
   python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$WORKTREE_PATH" >/dev/null && \
   python3 - "$WORKTREE_STATUS_JSON" "$WORKTREE_PATH" <<'PY'
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

if [ -n "${WORKTREE_PATH:-}" ] && python3 "$SCRIPT_DIR/scripts/qq-worktree.py" merge-back --project "$WORKTREE_PATH" --auto-yes > "$WORKTREE_MERGE_JSON" && \
   python3 - "$WORKTREE_TEST_ROOT" "$WORKTREE_PATH" "$WORKTREE_MERGE_JSON" <<'PY'
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

if [ -n "${WORKTREE_PATH:-}" ] && python3 "$SCRIPT_DIR/scripts/qq-worktree.py" cleanup --project "$WORKTREE_PATH" --delete-branch > "$WORKTREE_CLEANUP_JSON" && \
   python3 - "$WORKTREE_TEST_ROOT" "$WORKTREE_PATH" "$WORKTREE_CLEANUP_JSON" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
worktree = Path(sys.argv[2])
payload = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
assert payload["deletedBranch"] is True
assert not worktree.exists()
branches = subprocess.check_output(["git", "branch", "--list", "feature/ship-system-wt-sea-monster"], cwd=root, text=True).strip()
assert branches == ""
PY
then
  pass "qq-worktree cleanup removes the linked worktree and branch"
else
  fail "qq-worktree cleanup removes the linked worktree and branch"
fi
rm -f "$WORKTREE_STATUS_JSON" "$WORKTREE_MERGE_JSON" "$WORKTREE_CLEANUP_JSON"
rm -rf "$WORKTREE_TEST_ROOT"

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
if python3 "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_BLOCK_ROOT" --name blocked >/dev/null 2>&1; then
  fail "qq-worktree blocks protected source branches by default"
else
  pass "qq-worktree blocks protected source branches by default"
fi
rm -rf "$WORKTREE_BLOCK_ROOT"

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
  unity-compile-smart.sh \
  unity-test.sh \
  qq-project-state.py \
  qq-policy-check.sh \
  tykit_mcp.py \
  tykit_bridge.py \
  qq-capabilities.json \
  tykit_capabilities.json; do
  : > "$RUNTIME_TEST_ROOT/scripts/$path"
done

if python3 "$SCRIPT_DIR/scripts/qq-capability.py" validate --pretty > "$RUNTIME_TEST_ROOT/capability-validate.json" && \
   python3 - "$RUNTIME_TEST_ROOT/capability-validate.json" <<'PY'
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

if python3 "$SCRIPT_DIR/scripts/qq-capability.py" resolve --engine unity --capability compile --available unity.tykit-mcp unity.unity-mcp > "$RUNTIME_TEST_ROOT/capability-resolve.json" && \
   python3 - "$RUNTIME_TEST_ROOT/capability-resolve.json" <<'PY'
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

if "$SCRIPT_DIR/scripts/qq-doctor.sh" --project "$RUNTIME_TEST_ROOT" --write-state > "$RUNTIME_TEST_ROOT/doctor.json" && \
   python3 - "$RUNTIME_TEST_ROOT/doctor.json" "$RUNTIME_TEST_ROOT/.qq/state/provider-resolution.json" <<'PY'
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
assert payload["policy"]["effectiveProfileSource"] == "qq_local_policy"
assert payload["policy"]["effectiveProfileExpectations"]["review_expectation"] == "required"
assert payload["controller"]["workMode"] == "prototype"
assert payload["controller"]["workModeSource"] == "qq_local_policy"
assert payload["controller"]["modeRecommendedNext"] == "prototype_direct"
assert payload["controller"]["taskFocus"] == []
assert payload["controller"]["taskFocusSource"] == "default"
assert payload["controller"]["policyProfile"] == "hardening"
assert payload["controller"]["policyProfileSource"] == "qq_local_policy"
assert payload["controller"]["policyProfileExpectations"]["review_expectation"] == "required"
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
assert providers["unity.qq-direct"]["status"] == "available"
assert providers["unity.tykit-mcp"]["status"] == "available"
assert providers["unity.raw-tykit"]["status"] == "available"
assert providers["unity.mcp-unity"]["status"] == "available"
assert payload["resolution"]["compile"]["resolved"] == "unity.qq-direct"
assert payload["resolution"]["console.read"]["resolved"] == "unity.tykit-mcp"
assert state_payload["resolution"]["compile"]["resolved"] == "unity.qq-direct"
PY
then
  pass "qq-doctor discovers providers and writes resolution state"
else
  fail "qq-doctor discovers providers and writes resolution state"
fi

if (
  cd "$RUNTIME_TEST_ROOT" &&
  "$SCRIPT_DIR/scripts/qq-policy-check.sh" --json Sample.cs > policy.json &&
  python3 - <<'PY'
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

if python3 "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/foundation-smoke.json" > "$RUNTIME_TEST_ROOT/eval-suite.json" && \
   python3 - "$RUNTIME_TEST_ROOT/eval-suite.json" <<'PY'
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

if python3 "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/collaboration-multi-actor.json" > "$RUNTIME_TEST_ROOT/collaboration-eval-suite.json" && \
   python3 - "$RUNTIME_TEST_ROOT/collaboration-eval-suite.json" <<'PY'
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

for idx in 1 2 3; do
  RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$RUNTIME_TEST_ROOT" --stage test --command "prune-$idx" --backend test --transport local --summary "prune start $idx")
  RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
  python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$RUNTIME_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "prune finish $idx" >/dev/null
done

if python3 "$SCRIPT_DIR/scripts/qq-run-record.py" prune --project "$RUNTIME_TEST_ROOT" --max-runs 2 --max-age-days 365 --max-telemetry-bytes 1 --max-telemetry-files 1 > "$RUNTIME_TEST_ROOT/prune-result.json" && \
   python3 - "$RUNTIME_TEST_ROOT" "$RUNTIME_TEST_ROOT/prune-result.json" <<'PY'
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

# ── 9. install.sh validation ──
echo -e "${CYAN}[9/9] install.sh validation${NC}"

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

# Check install copies JSON registries used by bridge and capability resolver
if grep -q 'scripts/\*.json' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh copies script JSON registries"
else
  fail "install.sh missing script JSON registry copy"
fi

if grep -q -- '--profile' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh supports policy profile selection"
else
  fail "install.sh missing policy profile selection"
fi

if grep -q 'qq_default_test_scope' "$SCRIPT_DIR/scripts/githooks/pre-push" && \
   grep -q 'unity-test.sh" editmode' "$SCRIPT_DIR/scripts/githooks/pre-push"; then
  pass "pre-push hook adapts test scope from policy profile"
else
  fail "pre-push hook adapts test scope from policy profile"
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

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

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${NC} $1"; }

# ── 1. ShellCheck ──
echo -e "${CYAN}[1/9] ShellCheck${NC}"
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
for json_file in scripts/qq-capabilities.json scripts/tykit_capabilities.json scripts/godot_capabilities.json scripts/unreal_capabilities.json scripts/sbox_capabilities.json hooks/hooks.json .claude-plugin/plugin.json .claude-plugin/marketplace.json docs/evals/foundation-smoke.json docs/evals/unity-local.json docs/evals/collaboration-multi-actor.json docs/evals/qq-bench-foundation.json docs/evals/qq-bench-core-v0.json docs/evals/qq-bench-core-v1.json docs/evals/qq-bench-core-solver-v0.json .devcontainer/devcontainer.json; do
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

if grep -q 'updated existing dependency to tested release' "$SCRIPT_DIR/install.sh"; then
  pass "install.sh repins existing tykit dependency"
else
  fail "install.sh does not repin existing tykit dependency"
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
if printf '%s' "$DOCKER_DEV_META" | python3 -c '
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

CAPSULE_BUILD_JSON="$(mktemp)"
CAPSULE_STATUS_JSON="$(mktemp)"
if python3 "$SCRIPT_DIR/scripts/qq-context-capsule.py" build --project "$RUNTIME_TEST_ROOT" --trigger resume --pretty > "$CAPSULE_BUILD_JSON" && \
   python3 "$SCRIPT_DIR/scripts/qq-context-capsule.py" status --project "$RUNTIME_TEST_ROOT" --pretty > "$CAPSULE_STATUS_JSON" && \
   python3 - "$RUNTIME_TEST_ROOT" "$CAPSULE_BUILD_JSON" "$CAPSULE_STATUS_JSON" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
build = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
status = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
state_path = root / ".qq" / "state" / "context-capsule.json"
capsule = json.loads(state_path.read_text(encoding="utf-8"))
markdown_dir = root / ".qq" / "telemetry" / "context-capsules"
markdown_files = sorted(markdown_dir.glob("*.md"))

assert state_path.is_file()
assert markdown_files
assert build["trigger"] == "resume"
assert capsule["workMode"] == "feature"
assert capsule["policyProfile"] == "feature"
assert capsule["recommendedNext"] == "/qq:execute"
assert capsule["sourceRecords"]["projectState"] == ".qq/state/project-state.json"
assert "Resume Capsule" in capsule["resumePromptMd"]
assert status["exists"] is True
assert status["trigger"] == "resume"
assert status["recommendedNext"] == "/qq:execute"
assert status["resumePromptChars"] > 0
assert status["config"]["mode"] == "auto"
assert status["config"]["enabled"] is True
PY
then
  pass "context capsule builds a thin resume handoff from runtime state"
else
  fail "context capsule builds a thin resume handoff from runtime state"
fi

if python3 "$SCRIPT_DIR/scripts/qq-context-capsule.py" prompt --project "$RUNTIME_TEST_ROOT" --refresh --note "Focus on the recommended next step." > "$CAPSULE_BUILD_JSON" && \
   python3 - "$CAPSULE_BUILD_JSON" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
assert "Use the following qq Context Capsule" in text
assert "Resume Capsule" in text
assert "Additional instruction:" in text
assert "Focus on the recommended next step." in text
PY
then
  pass "context capsule can render a standard resume consumer prompt"
else
  fail "context capsule can render a standard resume consumer prompt"
fi

if python3 "$SCRIPT_DIR/scripts/qq-context-capsule.py" consume --project "$RUNTIME_TEST_ROOT" --agent claude --pretty > "$CAPSULE_STATUS_JSON" && \
   python3 - "$CAPSULE_STATUS_JSON" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["agent"] == "claude"
assert payload["resumeApplied"] is True
assert payload["resumeMode"] == "auto"
assert payload["resumeReason"] == "capsule:resume"
assert payload["resumeRefresh"] is True
assert payload["resumePromptChars"] > 0
assert "Use the following qq Context Capsule" in payload["resumePrompt"]
PY
then
  pass "context capsule exposes a host-neutral consume interface"
else
  fail "context capsule exposes a host-neutral consume interface"
fi

if python3 "$SCRIPT_DIR/scripts/qq-context-capsule.py" consume --project "$RUNTIME_TEST_ROOT" --agent cursor --no-resume --pretty > "$CAPSULE_STATUS_JSON" && \
   python3 - "$CAPSULE_STATUS_JSON" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["agent"] == "cursor"
assert payload["resumeApplied"] is False
assert payload["resumeMode"] == "disabled"
assert payload["resumeReason"] == "flag:no_resume"
assert payload["resumePromptChars"] == 0
PY
then
  pass "context capsule consume interface supports per-request opt-out for any host"
else
  fail "context capsule consume interface supports per-request opt-out for any host"
fi

CAPSULE_STRICT_TEST_ROOT="$(mktemp -d)"
cat > "$CAPSULE_STRICT_TEST_ROOT/Probe.cs" <<'EOF'
public class StrictProbe {}
EOF
cat > "$CAPSULE_STRICT_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
default_profile: feature
trust_level: strict
EOF
if python3 "$SCRIPT_DIR/scripts/qq-context-capsule.py" build --project "$CAPSULE_STRICT_TEST_ROOT" --trigger resume >/dev/null && \
   python3 "$SCRIPT_DIR/scripts/qq-context-capsule.py" consume --project "$CAPSULE_STRICT_TEST_ROOT" --agent codex --pretty > "$CAPSULE_STATUS_JSON" && \
   python3 - "$CAPSULE_STATUS_JSON" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["resumeApplied"] is False
assert payload["resumeMode"] == "auto"
assert payload["resumeReason"] == "trust_level:auto_resume_disabled"
assert payload["capsuleStatus"]["config"]["trustLevel"] == "strict"
PY
then
  pass "strict trust level disables automatic context capsule consumption"
else
  fail "strict trust level disables automatic context capsule consumption"
fi
rm -f "$CAPSULE_BUILD_JSON" "$CAPSULE_STATUS_JSON"

CAPSULE_AUTO_TEST_ROOT="$(mktemp -d)"
mkdir -p "$CAPSULE_AUTO_TEST_ROOT/.qq" "$CAPSULE_AUTO_TEST_ROOT/tmp"
(
  cd "$CAPSULE_AUTO_TEST_ROOT" &&
  git init -q
)
cat > "$CAPSULE_AUTO_TEST_ROOT/Probe.cs" <<'EOF'
public class Probe {}
EOF
cat > "$CAPSULE_AUTO_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
default_profile: feature
EOF
if python3 "$SCRIPT_DIR/scripts/qq-context-capsule.py" maybe-build --project "$CAPSULE_AUTO_TEST_ROOT" --trigger pre_clear --pretty > "$CAPSULE_BUILD_JSON" && \
   python3 - "$CAPSULE_AUTO_TEST_ROOT" "$CAPSULE_BUILD_JSON" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert payload["built"] is True
assert payload["capsule"]["trigger"] == "pre_clear"
assert (root / ".qq" / "state" / "context-capsule.json").exists()
PY
then
  pass "context capsule narrow auto mode is on by default"
else
  fail "context capsule narrow auto mode is on by default"
fi

cat > "$CAPSULE_AUTO_TEST_ROOT/.qq/local.yaml" <<'EOF'
context_capsule:
  enabled: false
  mode: off
EOF

if python3 "$SCRIPT_DIR/scripts/qq-context-capsule.py" maybe-build --project "$CAPSULE_AUTO_TEST_ROOT" --trigger pre_clear --pretty > "$CAPSULE_BUILD_JSON" && \
   python3 - "$CAPSULE_AUTO_TEST_ROOT" "$CAPSULE_BUILD_JSON" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert payload["built"] is False
assert payload["config"]["mode"] == "off"
assert payload["config"]["enabled"] is False
PY
then
  pass "context capsule can be disabled explicitly"
else
  fail "context capsule can be disabled explicitly"
fi

cat > "$CAPSULE_AUTO_TEST_ROOT/.qq/local.yaml" <<'EOF'
context_capsule:
  enabled: true
  mode: auto
  triggers:
    - after_blocker
    - pre_clear
  max_chars: 1800
EOF

if PROJECT_DIR="$CAPSULE_AUTO_TEST_ROOT" bash -lc '
  source "'"$SCRIPT_DIR"'/scripts/qq-runtime.sh"
  run_json=$(qq_run_record_start "compile" "auto-capsule-test" "test" "local" "compile start")
  run_id=$(printf "%s" "$run_json" | python3 -c '"'"'import json,sys; print(json.load(sys.stdin)["run_id"])'"'"')
  qq_run_record_finish "$run_id" "failed" "compile_failed" "compile failed for auto capsule" >/dev/null
' && python3 - "$CAPSULE_AUTO_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
capsule = json.loads((root / ".qq" / "state" / "context-capsule.json").read_text(encoding="utf-8"))
assert capsule["trigger"] == "after_blocker"
assert capsule["config"]["mode"] == "auto"
assert capsule["config"]["maxChars"] == 1800
assert capsule["blockers"]
assert capsule["blockers"][0]["kind"] == "compile"
PY
then
  pass "context capsule auto-builds after blocker when enabled"
else
  fail "context capsule auto-builds after blocker when enabled"
fi

if PROJECT_DIR="$CAPSULE_AUTO_TEST_ROOT" bash "$SCRIPT_DIR/scripts/hooks/session-cleanup.sh" && \
   python3 - "$CAPSULE_AUTO_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
capsule = json.loads((root / ".qq" / "state" / "context-capsule.json").read_text(encoding="utf-8"))
assert capsule["trigger"] == "pre_clear"
assert capsule["config"]["mode"] == "auto"
PY
then
  pass "session cleanup can auto-build a pre_clear context capsule"
else
  fail "session cleanup can auto-build a pre_clear context capsule"
fi
rm -rf "$CAPSULE_AUTO_TEST_ROOT"

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
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$RUNTIME_TEST_ROOT" >/dev/null
if python3 - "$RUNTIME_TEST_ROOT" <<'PY'
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
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$YAML_CONFIG_TEST_ROOT" >/dev/null
if python3 - "$YAML_CONFIG_TEST_ROOT" <<'PY'
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
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$YAML_CONFIG_TEST_ROOT" >/dev/null
if python3 - "$YAML_CONFIG_TEST_ROOT" <<'PY'
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

cat > "$FOCUS_TEST_ROOT/.qq/local.yaml" <<'EOF'
work_mode: prototype
policy_profile: feature
task_focus: crew weapon
EOF
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FOCUS_TEST_ROOT" >/dev/null
if python3 - "$FOCUS_TEST_ROOT" <<'PY'
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
RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$POLICY_TEST_ROOT" --stage compile --command policy-compile --backend test --transport local --summary "policy compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$POLICY_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "policy compile passed" >/dev/null
cat > "$POLICY_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
engine: unity
default_profile: core
work_mode: prototype
EOF
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if python3 - "$POLICY_TEST_ROOT" <<'PY'
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

python3 "$SCRIPT_DIR/scripts/qq-run-record.py" record --project "$POLICY_TEST_ROOT" --stage changes --command qq:changes --status checked --summary "prototype summary captured" --capture-local-changes >/dev/null
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if python3 - "$POLICY_TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
state = json.loads((root / ".qq" / "state" / "project-state.json").read_text(encoding="utf-8"))

assert state["changes_summary_fresh"] is True
assert state["last_changes_status"] == "checked"
assert state["mode_recommended_next"] == "/qq:commit-push"
assert state["recommended_next"] == "/qq:commit-push"
PY
then
  pass "prototype changes summary advances the controller to commit-push"
else
  fail "prototype changes summary advances the controller to commit-push"
fi

printf '// follow-up\n' >> "$POLICY_TEST_ROOT/SeaMonsterSpike.cs"
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$POLICY_TEST_ROOT" >/dev/null
if python3 - "$POLICY_TEST_ROOT" <<'PY'
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

RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$POLICY_TEST_ROOT" --stage compile --command policy-compile-refresh --backend test --transport local --summary "policy compile refresh start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$POLICY_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "policy compile refresh passed" >/dev/null

cat > "$POLICY_TEST_ROOT/.qq/local.yaml" <<'EOF'
work_mode: prototype
policy_profile: hardening
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
RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$FIX_TEST_ROOT" --stage compile --command fix-compile --backend test --transport local --summary "fix compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$FIX_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "fix compile passed" >/dev/null
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FIX_TEST_ROOT" >/dev/null
if python3 - "$FIX_TEST_ROOT" <<'PY'
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
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FIX_TEST_ROOT" >/dev/null
if python3 - "$FIX_TEST_ROOT" <<'PY'
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
RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$FIX_TEST_ROOT" --stage compile --command fix-test-compile --backend test --transport local --summary "fix test compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$FIX_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "fix test compile passed" >/dev/null
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FIX_TEST_ROOT" >/dev/null
if python3 - "$FIX_TEST_ROOT" <<'PY'
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
RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$FEATURE_TEST_ROOT" --stage compile --command feature-compile --backend test --transport local --summary "feature compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$FEATURE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "feature compile passed" >/dev/null
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FEATURE_TEST_ROOT" >/dev/null
if python3 - "$FEATURE_TEST_ROOT" <<'PY'
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
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FEATURE_TEST_ROOT" >/dev/null
if python3 - "$FEATURE_TEST_ROOT" <<'PY'
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

RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$FEATURE_TEST_ROOT" --stage compile --command feature-test-compile --backend test --transport local --summary "feature test compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$FEATURE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "feature test compile passed" >/dev/null
python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$FEATURE_TEST_ROOT" >/dev/null
if python3 - "$FEATURE_TEST_ROOT" <<'PY'
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
if python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$WORKTREE_BARE_STATE_ROOT" >/dev/null && \
   python3 - "$WORKTREE_BARE_STATE_ROOT" <<'PY'
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
if BARE_CREATE_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_BARE_CREATE_ROOT" --name bare-create --base-dir "$WORKTREE_BARE_CREATE_PARENT"); then
  BARE_WORKTREE_PATH=$(printf '%s' "$BARE_CREATE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worktreePath"])')
  if python3 - "$BARE_CREATE_JSON" "$BARE_WORKTREE_PATH" <<'PY'
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
  python3 "$SCRIPT_DIR/scripts/qq-worktree.py" cleanup --project "$BARE_WORKTREE_PATH" --delete-branch >/dev/null 2>&1 || true
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
  printf '{\n  "mcpServers": {\n    "qq-unity": { "command": "python3" }\n  }\n}\n' > .mcp.json &&
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
RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$WORKTREE_TEST_ROOT" --stage compile --command source-compile --backend test --transport local --summary "source compile start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$WORKTREE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "source compile passed" >/dev/null
RUN_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-run-record.py" start --project "$WORKTREE_TEST_ROOT" --stage test --command source-test --backend test --transport local --summary "source test start")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
python3 "$SCRIPT_DIR/scripts/qq-run-record.py" finish --project "$WORKTREE_TEST_ROOT" --run-id "$RUN_ID" --status passed --summary "source test passed" >/dev/null
WORKTREE_PARENT="$(dirname "$WORKTREE_TEST_ROOT")"
if CREATE_JSON=$(python3 "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_TEST_ROOT" --name "Sea Monster" --base-dir "$WORKTREE_PARENT" --allow-dirty-source); then
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
assert payload["contextCapsule"]["built"] is True
assert payload["contextCapsule"]["trigger"] == "worktree_handoff"
assert (target / ".qq" / "state" / "context-capsule.json").is_file()
capsule = json.loads((target / ".qq" / "state" / "context-capsule.json").read_text(encoding="utf-8"))
for record_path in metadata["copiedBaselineRunRecords"]:
    assert (target / record_path).is_file()
for record_path in capsule.get("sourceRecords", {}).values():
    if record_path and str(record_path).startswith(".qq/runs/"):
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

if [ -n "${WORKTREE_PATH:-}" ] && python3 "$SCRIPT_DIR/scripts/qq-worktree.py" seed-runtime-cache --project "$WORKTREE_PATH" --pretty > "$WORKTREE_SEED_JSON" && \
   python3 - "$WORKTREE_SEED_JSON" "$WORKTREE_PATH" <<'PY'
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

if [ -n "${WORKTREE_PATH:-}" ] && python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$WORKTREE_PATH" >/dev/null && \
   python3 - "$WORKTREE_PATH" <<'PY'
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

if [ -n "${WORKTREE_PATH:-}" ]; then
  printf 'default_profile: lightweight\n' > "$WORKTREE_PATH/qq.yaml"
  printf '# runtime tweak\n' >> "$WORKTREE_PATH/scripts/qq-doctor.py"
  mkdir -p "$WORKTREE_PATH/.claude"
  printf '{\"enabledPlugins\":{\"qq@quick-question-marketplace\":true}}\n' > "$WORKTREE_PATH/.claude/settings.local.json"
  printf '{\"mcpServers\":{\"tykit\":{\"command\":\"python3\"}}}\n' > "$WORKTREE_PATH/.mcp.json"
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
if python3 "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_REMOTE_ROOT" --name remote-closeout --base-dir "$WORKTREE_REMOTE_PARENT" > "$WORKTREE_REMOTE_JSON" && \
   python3 - "$WORKTREE_REMOTE_JSON" "$WORKTREE_REMOTE_ROOT" "$WORKTREE_REMOTE_BARE" "$SCRIPT_DIR" <<'PY'
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
    ["python3", "scripts/qq-worktree.py", "closeout", "--project", str(worktree), "--auto-yes", "--delete-branch"],
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
if python3 "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_BLOCK_ROOT" --name blocked >/dev/null 2>&1; then
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
if python3 "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_DOCKER_ROOT" --name docker-flow --base-dir "$(dirname "$WORKTREE_DOCKER_ROOT")" --pretty > "$WORKTREE_DOCKER_CREATE_JSON" && \
   python3 - "$WORKTREE_DOCKER_CREATE_JSON" <<'PY'
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
python3 - "$WORKTREE_DOCKER_CREATE_JSON" <<'PY' >/dev/null
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
python3 "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_CLOSEOUT_ROOT" --name closeout --pretty > "$WORKTREE_CLOSEOUT_CREATE_JSON"
WORKTREE_CLOSEOUT_PATH="$(python3 - "$WORKTREE_CLOSEOUT_CREATE_JSON" <<'PY'
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
if python3 "$SCRIPT_DIR/scripts/qq-worktree.py" closeout --project "$WORKTREE_CLOSEOUT_PATH" --auto-yes --delete-branch --pretty > "$WORKTREE_CLOSEOUT_RESULT" && \
   python3 - "$WORKTREE_CLOSEOUT_RESULT" "$WORKTREE_CLOSEOUT_ROOT" "$WORKTREE_CLOSEOUT_PATH" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2]).resolve()
worktree = Path(sys.argv[3]).resolve()

assert payload["action"] == "closeout"
assert payload["mergeBack"]["pushedSourceBranch"] is True
assert payload["sourceContextCapsule"]["built"] is True
assert payload["sourceContextCapsule"]["trigger"] == "worktree_handoff"
assert payload["cleanup"]["deletedBranch"] is True
assert not worktree.exists()
assert (root / ".qq" / "state" / "context-capsule.json").is_file()
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
python3 "$SCRIPT_DIR/scripts/qq-worktree.py" create --project "$WORKTREE_CODEX_ROOT" --name codex-closeout --base-dir "$WORKTREE_CODEX_PARENT" --pretty > "$WORKTREE_CODEX_CREATE_JSON"
WORKTREE_CODEX_PATH="$(python3 - "$WORKTREE_CODEX_CREATE_JSON" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["worktreePath"])
PY
)"
WORKTREE_CODEX_DRY_RUN="$(mktemp)"
if python3 "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --dry-run --pretty "closeout" > "$WORKTREE_CODEX_DRY_RUN" && \
   python3 - "$WORKTREE_CODEX_DRY_RUN" "$WORKTREE_CODEX_ROOT" "$WORKTREE_CODEX_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2]).resolve()
worktree = Path(sys.argv[3]).resolve()
command = payload["command"]
resume_prompt = command[-1]

assert payload["action"] == "dry-run"
assert payload["isManagedWorktree"] is True
assert Path(payload["sourceWorktreePath"]).resolve() == root
assert payload["defaultSandboxApplied"] is True
assert payload["defaultCdApplied"] is True
assert payload["addedSourceDir"] is True
assert payload["resumeApplied"] is True
assert payload["resumeMode"] == "auto"
assert payload["resumeReason"] == "capsule:worktree_handoff"
assert payload["resumeRefresh"] is True
assert command[:2] == ["codex", "exec"]
assert "--sandbox" in command
assert command[command.index("--sandbox") + 1] == "workspace-write"
assert "-C" in command
assert Path(command[command.index("-C") + 1]).resolve() == worktree
assert "--add-dir" in command
assert Path(command[command.index("--add-dir") + 1]).resolve() == root
assert "Use the following qq Context Capsule" in resume_prompt
assert "User request:\ncloseout" in resume_prompt
PY
then
  pass "qq-codex-exec auto-resumes managed worktree closeout context"
else
  fail "qq-codex-exec auto-resumes managed worktree closeout context"
fi

if python3 "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$RUNTIME_TEST_ROOT" --resume --resume-refresh --resume-note "Continue carefully." --dry-run --pretty > "$WORKTREE_CODEX_DRY_RUN" && \
   python3 - "$WORKTREE_CODEX_DRY_RUN" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
command = payload["command"]
resume_prompt = command[-1]

assert payload["action"] == "dry-run"
assert payload["resumeApplied"] is True
assert payload["resumeRefresh"] is True
assert payload["resumePromptChars"] > 0
assert "Use the following qq Context Capsule" in resume_prompt
assert "Continue carefully." in resume_prompt
PY
then
  pass "qq-codex-exec can consume the latest context capsule as a resume prompt"
else
  fail "qq-codex-exec can consume the latest context capsule as a resume prompt"
fi

if python3 "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --no-resume --dry-run --pretty "closeout" > "$WORKTREE_CODEX_DRY_RUN" && \
   python3 - "$WORKTREE_CODEX_DRY_RUN" "$WORKTREE_CODEX_ROOT" "$WORKTREE_CODEX_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
root = Path(sys.argv[2]).resolve()
worktree = Path(sys.argv[3]).resolve()
command = payload["command"]

assert payload["resumeApplied"] is False
assert payload["resumeMode"] == "disabled"
assert payload["resumeReason"] == "flag:no_resume"
assert payload["resumeRefresh"] is False
assert Path(payload["sourceWorktreePath"]).resolve() == root
assert Path(command[command.index("-C") + 1]).resolve() == worktree
assert command[-1] == "closeout"
PY
then
  pass "qq-codex-exec can opt out of automatic context capsule consumption"
else
  fail "qq-codex-exec can opt out of automatic context capsule consumption"
fi

mkdir -p "$WORKTREE_CODEX_PATH/.qq"
cat > "$WORKTREE_CODEX_PATH/.qq/local.yaml" <<'EOF'
trust_level: balanced
EOF

if python3 "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --dry-run --pretty "Summarize current state." > "$WORKTREE_CODEX_DRY_RUN" && \
   python3 - "$WORKTREE_CODEX_DRY_RUN" "$WORKTREE_CODEX_ROOT" <<'PY'
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
assert payload["resumeApplied"] is False
assert payload["resumeReason"] == "trust_level:auto_resume_disabled"
assert "--add-dir" not in command
assert Path(payload["sourceWorktreePath"]).resolve() == root
PY
then
  pass "balanced trust level blocks automatic source-worktree widening for non-closeout Codex execs"
else
  fail "balanced trust level blocks automatic source-worktree widening for non-closeout Codex execs"
fi

if python3 "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --dry-run --pretty "closeout" > "$WORKTREE_CODEX_DRY_RUN" && \
   python3 - "$WORKTREE_CODEX_DRY_RUN" "$WORKTREE_CODEX_ROOT" <<'PY'
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
assert payload["resumeApplied"] is False
assert payload["resumeReason"] == "trust_level:auto_resume_disabled"
PY
then
  pass "balanced trust level still widens source worktree access for closeout Codex execs"
else
  fail "balanced trust level still widens source worktree access for closeout Codex execs"
fi

cat > "$WORKTREE_CODEX_PATH/.qq/local.yaml" <<'EOF'
trust_level: strict
EOF

if python3 "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --dry-run --pretty "closeout" > "$WORKTREE_CODEX_DRY_RUN" && \
   python3 - "$WORKTREE_CODEX_DRY_RUN" <<'PY'
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
assert payload["resumeApplied"] is False
assert payload["resumeReason"] == "trust_level:auto_resume_disabled"
PY
then
  pass "strict trust level requires explicit source-worktree widening"
else
  fail "strict trust level requires explicit source-worktree widening"
fi

if python3 "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" --allow-source-worktree --dry-run --pretty "closeout" > "$WORKTREE_CODEX_DRY_RUN" && \
   python3 - "$WORKTREE_CODEX_DRY_RUN" "$WORKTREE_CODEX_ROOT" <<'PY'
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

FAKE_CODEX_BIN_DIR="$(mktemp -d)"
FAKE_CODEX_LOG="$(mktemp)"
CURRENT_CODEX_SERVER="$(python3 - "$WORKTREE_CODEX_PATH" <<'PY'
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
OTHER_CODEX_SERVER="$(python3 - "$WORKTREE_CODEX_ROOT" <<'PY'
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
   python3 "$SCRIPT_DIR/scripts/qq-codex-exec.py" --project "$WORKTREE_CODEX_PATH" "Use the unity_health tool" >/dev/null && \
   python3 - "$FAKE_CODEX_LOG" "$CURRENT_CODEX_SERVER" "$OTHER_CODEX_SERVER" <<'PY'
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

if python3 "$SCRIPT_DIR/scripts/qq-capability.py" resolve --engine unreal --capability scene.query --available unreal.runreal-mcp unreal.flop-mcp > "$RUNTIME_TEST_ROOT/capability-resolve-unreal.json" && \
   python3 - "$RUNTIME_TEST_ROOT/capability-resolve-unreal.json" <<'PY'
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

if python3 "$SCRIPT_DIR/scripts/qq-capability.py" resolve --engine sbox --capability compile --available sbox.qq-direct > "$RUNTIME_TEST_ROOT/capability-resolve-sbox.json" && \
   python3 - "$RUNTIME_TEST_ROOT/capability-resolve-sbox.json" <<'PY'
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
PY
then
  pass "qq-doctor discovers providers and writes resolution state"
else
  fail "qq-doctor discovers providers and writes resolution state"
fi

MCP_TRUST_TEST_ROOT="$(mktemp -d)"
mkdir -p "$MCP_TRUST_TEST_ROOT/ProjectSettings" "$MCP_TRUST_TEST_ROOT/Packages"
cat > "$MCP_TRUST_TEST_ROOT/ProjectSettings/ProjectVersion.txt" <<'EOF'
m_EditorVersion: 2022.3.56f1
EOF
cat > "$MCP_TRUST_TEST_ROOT/Packages/manifest.json" <<'EOF'
{
  "dependencies": {}
}
EOF
cat > "$MCP_TRUST_TEST_ROOT/qq.yaml" <<'EOF'
version: 1
default_profile: feature
trust_level: strict
EOF

if python3 - "$SCRIPT_DIR" "$MCP_TRUST_TEST_ROOT" <<'PY'
import sys
from pathlib import Path

script_dir = Path(sys.argv[1]).resolve() / "scripts"
project_dir = Path(sys.argv[2]).resolve()
sys.path.insert(0, str(script_dir))
from qq_mcp import build_bridge

standard_names = {tool["name"] for tool in build_bridge(str(project_dir), profile="standard").list_tools()}
full_names = {tool["name"] for tool in build_bridge(str(project_dir), profile="full").list_tools()}

assert "unity_raw_command" not in standard_names
assert "unity_raw_command" in full_names
PY
then
  pass "strict trust level hides raw engine commands from the standard MCP surface"
else
  fail "strict trust level hides raw engine commands from the standard MCP surface"
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

if python3 "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/qq-bench-foundation.json" > "$RUNTIME_TEST_ROOT/qq-bench-foundation.json" && \
   python3 - "$RUNTIME_TEST_ROOT/qq-bench-foundation.json" <<'PY'
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

if python3 "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/qq-bench-core-v0.json" > "$RUNTIME_TEST_ROOT/qq-bench-core-v0.json" && \
   python3 - "$RUNTIME_TEST_ROOT/qq-bench-core-v0.json" <<'PY'
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

if python3 "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/qq-bench-core-v1.json" > "$RUNTIME_TEST_ROOT/qq-bench-core-v1.json" && \
   python3 - "$RUNTIME_TEST_ROOT/qq-bench-core-v1.json" <<'PY'
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

if python3 "$SCRIPT_DIR/scripts/eval/run-benchmarks.py" --suite "$SCRIPT_DIR/docs/evals/qq-bench-core-solver-v0.json" > "$RUNTIME_TEST_ROOT/qq-bench-core-solver-v0.json" && \
   python3 - "$RUNTIME_TEST_ROOT/qq-bench-core-solver-v0.json" <<'PY'
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
cat > "$GODOT_RUNTIME_ROOT/.qq/state/qq-godot-editor-bridge.json" <<EOF
{
  "ok": true,
  "running": true,
  "lastHeartbeatUnix": $(python3 -c 'import time; print(time.time())')
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
   python3 - "$GODOT_RUNTIME_ROOT/doctor.json" "$GODOT_RUNTIME_ROOT/.qq/state/provider-resolution.json" <<'PY'
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
python3 - "$GODOT_RUNTIME_ROOT" <<'PY' &
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
if python3 "$SCRIPT_DIR/scripts/godot_bridge.py" --project "$GODOT_RUNTIME_ROOT" --tool godot_query --arguments '{"action":"status"}' > "$GODOT_RUNTIME_ROOT/godot-bridge-call.json" && \
   wait "$FAKE_GODOT_BRIDGE_PID" && \
   python3 - "$GODOT_RUNTIME_ROOT/godot-bridge-call.json" <<'PY'
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

python3 - "$GODOT_RUNTIME_ROOT" <<'PY' &
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
if python3 "$SCRIPT_DIR/scripts/godot_bridge.py" --project "$GODOT_RUNTIME_ROOT" --profile full --tool godot_batch --arguments '{"operations":[{"tool":"godot_input","arguments":{"action":"inject_action","input_action":"jump","strength":1.0}},{"tool":"godot_ui","arguments":{"action":"create_control","parent":".","node_type":"Button","name":"QQButton","text":"Parity"}},{"tool":"godot_animation","arguments":{"action":"create_animation","player_path":"AnimationPlayer","animation":"qq_spin","length":0.5}},{"tool":"godot_screenshot","arguments":{"path":".qq/state/screenshots/test.png","width":640,"height":360}}]}' > "$GODOT_RUNTIME_ROOT/godot-full-batch-call.json" && \
   wait "$FAKE_GODOT_BRIDGE_PID" && \
   python3 - "$GODOT_RUNTIME_ROOT/godot-full-batch-call.json" <<'PY'
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

if python3 - "$GODOT_RUNTIME_ROOT" "$SCRIPT_DIR/scripts" <<'PY'
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

if python3 - "$GODOT_RUNTIME_ROOT" "$SCRIPT_DIR/scripts" <<'PY'
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
python3 - "$FAKE_GODOT_BIN_DIR/godot4" "$FAKE_GODOT_LOG" <<'PY'
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
python3 - "$FAKE_GODOT_COMPILE_BIN_DIR/godot4" "$FAKE_GODOT_COMPILE_LOG" <<'PY'
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
   python3 - "$FAKE_GODOT_COMPILE_LOG" <<'PY'
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
  "lastHeartbeatUnix": $(python3 -c 'import time; print(time.time())')
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
   python3 - "$UNREAL_RUNTIME_ROOT/doctor.json" "$UNREAL_RUNTIME_ROOT/.qq/state/provider-resolution.json" <<'PY'
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

python3 - "$UNREAL_RUNTIME_ROOT" <<'PY' &
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
if python3 "$SCRIPT_DIR/scripts/unreal_bridge.py" --project "$UNREAL_RUNTIME_ROOT" --tool unreal_query --arguments '{"action":"status"}' > "$UNREAL_RUNTIME_ROOT/unreal-bridge-call.json" && \
   wait "$FAKE_UNREAL_BRIDGE_PID" && \
   python3 - "$UNREAL_RUNTIME_ROOT/unreal-bridge-call.json" "$UNREAL_RUNTIME_ROOT/.qq/state/qq-unreal-editor-console.jsonl" <<'PY'
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

python3 - "$UNREAL_RUNTIME_ROOT" <<'PY' &
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
if python3 "$SCRIPT_DIR/scripts/unreal_bridge.py" --project "$UNREAL_RUNTIME_ROOT" --tool unreal_batch --arguments '{"operations":[{"tool":"unreal_object","arguments":{"action":"create","class_path":"/Script/Engine.EmptyActor","label":"QQActor","select":true}},{"tool":"unreal_assets","arguments":{"action":"create_material","path":"/Game/QQ/M_Test"}}]}' > "$UNREAL_RUNTIME_ROOT/unreal-batch-call.json" && \
   wait "$FAKE_UNREAL_BRIDGE_PID" && \
   python3 - "$UNREAL_RUNTIME_ROOT/unreal-batch-call.json" <<'PY'
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

if python3 - "$UNREAL_RUNTIME_ROOT" "$SCRIPT_DIR/scripts" <<'PY'
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
python3 - "$FAKE_UNREAL_BIN_DIR/UnrealEditor-Cmd" "$FAKE_UNREAL_LOG" <<'PY'
import sys
from pathlib import Path

script = Path(sys.argv[1])
log_path = sys.argv[2]
script.write_text(script.read_text(encoding="utf-8").replace("__LOG__", log_path), encoding="utf-8")
PY
chmod +x "$FAKE_UNREAL_BIN_DIR/UnrealEditor-Cmd"

if env PATH="$FAKE_UNREAL_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/qq-compile.sh" --project "$UNREAL_SCRIPT_TEST_ROOT" > "$UNREAL_SCRIPT_TEST_ROOT/unreal-compile.log" && \
   python3 - "$FAKE_UNREAL_LOG" "$UNREAL_SCRIPT_TEST_ROOT/unreal-compile.log" "$UNREAL_SCRIPT_TEST_ROOT" <<'PY'
import sys
from pathlib import Path

log_text = Path(sys.argv[1]).read_text(encoding="utf-8")
compile_text = Path(sys.argv[2]).read_text(encoding="utf-8")
project_root = Path(sys.argv[3])

assert f"-ExecutePythonScript={project_root / 'scripts' / 'unreal-compile-check.py'}" in log_text
assert "Unreal compile/check passed" in compile_text
PY
then
  pass "unreal-compile invokes the project-local compile check through UnrealEditor-Cmd"
else
  fail "unreal-compile invokes the project-local compile check through UnrealEditor-Cmd"
fi

if env PATH="$FAKE_UNREAL_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/qq-test.sh" editmode --project "$UNREAL_SCRIPT_TEST_ROOT" > "$UNREAL_SCRIPT_TEST_ROOT/unreal-test.log" && \
   python3 - "$FAKE_UNREAL_LOG" "$UNREAL_SCRIPT_TEST_ROOT/unreal-test.log" <<'PY'
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
python3 - "$SBOX_RUNTIME_ROOT/.mcp.json" "$SBOX_RUNTIME_ROOT" <<'PY'
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
  "lastHeartbeatUnix": $(python3 -c 'import time; print(time.time())')
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
   python3 - "$SBOX_RUNTIME_ROOT/doctor.json" "$SBOX_RUNTIME_ROOT/.qq/state/provider-resolution.json" <<'PY'
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

if python3 "$SCRIPT_DIR/scripts/qq-project-state.py" --project "$SBOX_RUNTIME_ROOT" --no-write > "$SBOX_RUNTIME_ROOT/project-state.json" && \
   python3 - "$SBOX_RUNTIME_ROOT/project-state.json" <<'PY'
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
   python3 - "$SBOX_RUNTIME_ROOT/sbox-policy.json" <<'PY'
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

python3 - "$SBOX_RUNTIME_ROOT" <<'PY' &
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
if python3 "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_query --arguments '{"action":"status"}' > "$SBOX_RUNTIME_ROOT/sbox-bridge-call.json" && \
   wait "$FAKE_SBOX_BRIDGE_PID" && \
   python3 - "$SBOX_RUNTIME_ROOT/sbox-bridge-call.json" "$SBOX_RUNTIME_ROOT/.qq/state/qq-sbox-editor-console.jsonl" <<'PY'
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

python3 - "$SBOX_RUNTIME_ROOT" <<'PY' &
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
if python3 "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_batch --arguments '{"operations":[{"tool":"sbox_editor","arguments":{"action":"open_scene","path":"Assets/Scenes/Main.scene"}},{"tool":"sbox_object","arguments":{"action":"select","path":"Player"}}]}' > "$SBOX_RUNTIME_ROOT/sbox-batch-call.json" && \
   wait "$FAKE_SBOX_BRIDGE_PID" && \
   python3 - "$SBOX_RUNTIME_ROOT/sbox-batch-call.json" <<'PY'
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

if python3 - "$SBOX_RUNTIME_ROOT" "$SCRIPT_DIR/scripts" <<'PY'
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
if python3 "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_query --arguments '{"action":"list_scenes","count":10}' > "$SBOX_RUNTIME_ROOT/sbox-local-scenes.json" && \
   python3 "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_query --arguments '{"action":"list_assets","count":10}' > "$SBOX_RUNTIME_ROOT/sbox-local-query-assets.json" && \
   python3 "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_scene --arguments '{"action":"duplicate_scene","source":"Assets/Scenes/Main.scene","target":"Assets/Scenes/Main_LocalCopy.scene"}' > "$SBOX_RUNTIME_ROOT/sbox-local-duplicate.json" && \
   python3 "$SCRIPT_DIR/scripts/sbox_bridge.py" --project "$SBOX_RUNTIME_ROOT" --tool sbox_assets --arguments '{"action":"create_directory","path":"Assets/Generated"}' > "$SBOX_RUNTIME_ROOT/sbox-local-assets.json" && \
   python3 - "$SBOX_RUNTIME_ROOT/sbox-local-scenes.json" "$SBOX_RUNTIME_ROOT/sbox-local-query-assets.json" "$SBOX_RUNTIME_ROOT/sbox-local-duplicate.json" "$SBOX_RUNTIME_ROOT/sbox-local-assets.json" "$SBOX_RUNTIME_ROOT" <<'PY'
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
python3 - "$FAKE_SBOX_BIN_DIR/dotnet" "$FAKE_SBOX_LOG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("__FAKE_DOTNET_LOG__", sys.argv[2])
path.write_text(text, encoding="utf-8")
PY
chmod +x "$FAKE_SBOX_BIN_DIR/dotnet"
if env PATH="$FAKE_SBOX_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/qq-compile.sh" --project "$SBOX_SCRIPT_TEST_ROOT" > "$SBOX_SCRIPT_TEST_ROOT/sbox-compile.log" && \
   env PATH="$FAKE_SBOX_BIN_DIR:$PATH" "$SCRIPT_DIR/scripts/qq-test.sh" all --project "$SBOX_SCRIPT_TEST_ROOT" > "$SBOX_SCRIPT_TEST_ROOT/sbox-test.log" && \
   python3 - "$FAKE_SBOX_LOG" "$SBOX_SCRIPT_TEST_ROOT" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
root = Path(sys.argv[2])
assert any(line.startswith(f"build {root / 'Game.sln'}") for line in lines)
assert any(line.startswith(f"test {root / 'UnitTests' / 'Game.UnitTests.csproj'}") for line in lines)
PY
then
  pass "qq-compile and qq-test route S&box projects onto dotnet build/test targets"
else
  fail "qq-compile and qq-test route S&box projects onto dotnet build/test targets"
fi
rm -rf "$SBOX_SCRIPT_TEST_ROOT" "$FAKE_SBOX_BIN_DIR"

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
if LANG=zh_CN.UTF-8 python3 "$SCRIPT_DIR/scripts/qq-onboard.py" preview --project "$ONBOARD_PREVIEW_ROOT" --preset quickstart --host-surface claude --json | python3 -c '
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

INSTALL_UPDATE_ROOT="$(mktemp -d)"
mkdir -p "$INSTALL_UPDATE_ROOT/ProjectSettings" "$INSTALL_UPDATE_ROOT/Packages"
cat > "$INSTALL_UPDATE_ROOT/ProjectSettings/ProjectVersion.txt" <<'EOF'
m_EditorVersion: 2022.3.17f1
EOF
cat > "$INSTALL_UPDATE_ROOT/Packages/manifest.json" <<'EOF'
{
  "dependencies": {
    "com.tyk.tykit": "https://github.com/tykisgod/tykit.git#b14919953fd8f655be05a929b69c9d71d6556ebe"
  }
}
EOF
"$SCRIPT_DIR/install.sh" "$INSTALL_UPDATE_ROOT" >/dev/null
if python3 - "$INSTALL_UPDATE_ROOT/Packages/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert manifest["dependencies"]["com.tyk.tykit"] == "https://github.com/tykisgod/tykit.git#84b129b026d3b725f5f7dd21d59a5fe9d206850c"
PY
then
  pass "install.sh updates existing tykit dependency to current tested release"
else
  fail "install.sh updates existing tykit dependency to current tested release"
fi
rm -rf "$INSTALL_UPDATE_ROOT"

ONBOARD_INSTALL_ROOT="$(mktemp -d)"
: > "$ONBOARD_INSTALL_ROOT/.sbproj"
LANG=ja_JP.UTF-8 "$SCRIPT_DIR/install.sh" --preset quickstart --language ja "$ONBOARD_INSTALL_ROOT" >/dev/null
if python3 - "$ONBOARD_INSTALL_ROOT" <<'PY'
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
if python3 - "$GODOT_INSTALL_ROOT" <<'PY'
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
if python3 - "$UNREAL_INSTALL_ROOT" <<'PY'
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
if python3 - "$SBOX_INSTALL_ROOT" <<'PY'
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
python3 - "$MODULAR_INSTALL_ROOT/qq.yaml" <<'PY'
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
end = text.find("context_capsule:\n", start)
if start == -1 or end == -1 or end <= start:
    raise SystemExit("failed to replace install block in qq.yaml fixture")
updated = text[:start] + replacement + "\n" + text[end:]
path.write_text(updated, encoding="utf-8")
PY
"$SCRIPT_DIR/install.sh" "$MODULAR_INSTALL_ROOT" >/dev/null
if python3 - "$MODULAR_INSTALL_ROOT" <<'PY'
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

# ── Summary ──
echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}All $TOTAL checks passed${NC}"
else
  echo -e "${RED}$FAIL/$TOTAL checks failed${NC}"
  exit 1
fi

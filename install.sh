#!/usr/bin/env bash
# install.sh — Install quick-question into a Unity project
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WITH_PRE_PUSH=0
POLICY_PROFILE="feature"
TARGET=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-pre-push)
      WITH_PRE_PUSH=1
      shift
      ;;
    --profile)
      if [ "$#" -lt 2 ]; then
        echo "Error: --profile requires one of: lightweight, core, feature, hardening"
        exit 1
      fi
      POLICY_PROFILE="$2"
      shift 2
      ;;
    --profile=*)
      POLICY_PROFILE="${1#--profile=}"
      shift
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

case "$POLICY_PROFILE" in
  lightweight|core|feature|hardening) ;;
  *)
    echo "Error: unsupported profile '$POLICY_PROFILE' (expected: lightweight, core, feature, hardening)"
    exit 1
    ;;
esac

# ── Platform check ──
case "$(uname -s)" in
  Darwin*)              QQ_PLATFORM="macos" ;;
  MINGW*|MSYS*|CYGWIN*) QQ_PLATFORM="windows" ;;
  *)
    echo "Error: unsupported platform ($(uname -s)). quick-question supports macOS and Windows."
    exit 1
    ;;
esac

# ── Dependency check ──
MISSING=""
command -v curl  &>/dev/null || MISSING="$MISSING curl"
command -v python3 &>/dev/null || MISSING="$MISSING python3"
command -v jq   &>/dev/null || MISSING="$MISSING jq"
if [ -n "$MISSING" ]; then
  echo "Error: missing required tools:$MISSING"
  if [[ "$QQ_PLATFORM" == "macos" ]]; then
    echo "Install with: brew install$MISSING"
  else
    echo "Install with: winget install$MISSING"
    echo "Or ensure Git for Windows is installed (provides bash, curl)"
  fi
  exit 1
fi

# ── Find Unity project ──
if [ -z "$TARGET" ]; then
  TARGET=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

if [ ! -f "$TARGET/ProjectSettings/ProjectVersion.txt" ]; then
  echo "Error: $TARGET is not a Unity project (ProjectSettings/ProjectVersion.txt not found)"
  echo "Usage: ./install.sh /path/to/unity-project"
  exit 1
fi

echo "Installing quick-question to: $TARGET"
echo ""

# ── Scripts (needed by hooks, must be in project) ──
mkdir -p "$TARGET/scripts" "$TARGET/scripts/hooks"
cp "$SCRIPT_DIR"/scripts/*.sh "$TARGET/scripts/"
cp "$SCRIPT_DIR"/scripts/*.py "$TARGET/scripts/"
cp "$SCRIPT_DIR"/scripts/*.json "$TARGET/scripts/"
cp "$SCRIPT_DIR"/scripts/hooks/*.sh "$TARGET/scripts/hooks/"
mkdir -p "$TARGET/scripts/platform"
cp "$SCRIPT_DIR"/scripts/platform/*.sh "$TARGET/scripts/platform/"
cp "$SCRIPT_DIR"/scripts/hooks/hook-dispatch.cmd "$TARGET/scripts/hooks/" 2>/dev/null || true
chmod +x "$TARGET/scripts/"*.sh "$TARGET/scripts/"*.py "$TARGET/scripts/hooks/"*.sh "$TARGET/scripts/platform/"*.sh
SCRIPT_COUNT=$(find "$TARGET/scripts" -maxdepth 2 -type f | wc -l | tr -d ' ')
echo "  Scripts: $SCRIPT_COUNT files → scripts/ (including hooks/, platform/, MCP bridge, python helpers, JSON registries)"
echo "  Skills + Hooks: provided by the qq plugin (see Next steps below)"

# ── Pre-push hook (optional) ──
if [ "$WITH_PRE_PUSH" -eq 1 ]; then
  mkdir -p "$TARGET/.githooks"
  cp "$SCRIPT_DIR/scripts/githooks/pre-push" "$TARGET/.githooks/pre-push"
  chmod +x "$TARGET/.githooks/pre-push"
  git -C "$TARGET" config core.hooksPath .githooks
  echo "  Pre-push: installed (runs tests before every push, skip with --no-verify)"
else
  echo "  Pre-push: skipped (add --with-pre-push to enable)"
fi

# ── Templates ──
if [ ! -f "$TARGET/CLAUDE.md" ]; then
  cp "$SCRIPT_DIR/templates/CLAUDE.md.example" "$TARGET/CLAUDE.md"
  echo "  CLAUDE.md: created from template"
else
  echo "  CLAUDE.md: already exists — check templates/CLAUDE.md.example for Unity-specific rules you may want to add"
fi

if [ ! -f "$TARGET/AGENTS.md" ]; then
  cp "$SCRIPT_DIR/templates/AGENTS.md.example" "$TARGET/AGENTS.md"
  echo "  AGENTS.md: created from template"
else
  echo "  AGENTS.md: already exists — check templates/AGENTS.md.example for review rules you may want to add"
fi

# ── Claude local permission baseline ──
CLAUDE_LOCAL_SETTINGS="$TARGET/.claude/settings.local.json"
mkdir -p "$TARGET/.claude"
python3 - "$CLAUDE_LOCAL_SETTINGS" << 'PYEOF'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
data = {}
if settings_path.exists():
    try:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        data = {}

if not isinstance(data, dict):
    data = {}

permissions = data.setdefault("permissions", {})
allow = permissions.setdefault("allow", [])
if not isinstance(allow, list):
    allow = []
    permissions["allow"] = allow

baseline = [
    "Bash(python3 ./scripts/qq-config.py:*)",
    "Bash(python3 scripts/qq-config.py:*)",
    "Bash(python3 ./scripts/qq-context-capsule.py:*)",
    "Bash(python3 scripts/qq-context-capsule.py:*)",
    "Bash(python3 ./scripts/qq-project-state.py:*)",
    "Bash(python3 scripts/qq-project-state.py:*)",
    "Bash(python3 ./scripts/qq-worktree.py:*)",
    "Bash(python3 scripts/qq-worktree.py:*)",
    "Bash(python3 ./scripts/qq-codex-mcp.py:*)",
    "Bash(python3 scripts/qq-codex-mcp.py:*)",
    "Bash(python3 ./scripts/qq-codex-exec.py:*)",
    "Bash(python3 scripts/qq-codex-exec.py:*)",
    "Bash(python3 ./scripts/qq-doctor.py:*)",
    "Bash(python3 scripts/qq-doctor.py:*)",
    "Bash(./scripts/qq-doctor.sh:*)",
    "Bash(scripts/qq-doctor.sh:*)",
    "Bash(./scripts/unity-compile-smart.sh:*)",
    "Bash(scripts/unity-compile-smart.sh:*)",
    "Bash(./scripts/unity-test.sh:*)",
    "Bash(scripts/unity-test.sh:*)",
]

existing = {str(item) for item in allow}
for item in baseline:
    if item not in existing:
        allow.append(item)

settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYEOF
echo "  Claude permissions: added baseline allow rules for qq state/doctor/compile/test commands"

# ── Built-in MCP bridge ──
MCP_CONFIG="$TARGET/.mcp.json"
python3 - "$MCP_CONFIG" << 'PYEOF'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
data = {}
if config_path.exists():
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        data = {}

if not isinstance(data, dict):
    data = {}

servers = data.setdefault("mcpServers", {})
servers["tykit"] = {
    "command": "python3",
    "args": [
        str((config_path.parent / "scripts" / "tykit_mcp.py").resolve()),
        "--project",
        str(config_path.parent.resolve())
    ],
    "cwd": str(config_path.parent.resolve())
}

config_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYEOF
echo "  MCP: .mcp.json now points tykit to the built-in project-local bridge"

if [ ! -f "$TARGET/qq.yaml" ]; then
  python3 - "$SCRIPT_DIR/templates/qq.yaml.example" "$TARGET/qq.yaml" "$POLICY_PROFILE" << 'PYEOF'
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
default_profile = sys.argv[3]

lines = template_path.read_text(encoding="utf-8").splitlines()
patched = []
for line in lines:
    if line.startswith("default_profile:"):
        patched.append(f"default_profile: {default_profile}")
    else:
        patched.append(line)
target_path.write_text("\n".join(patched) + "\n", encoding="utf-8")
PYEOF
  echo "  qq.yaml: created from template (default_profile=$POLICY_PROFILE)"
else
  echo "  qq.yaml: already exists"
fi
echo "  local overrides: use .qq/local.yaml for per-worktree task mode"

# ── tykit UPM package ──
MANIFEST="$TARGET/Packages/manifest.json"
TYKIT_REF="https://github.com/tykisgod/tykit.git#84b129b026d3b725f5f7dd21d59a5fe9d206850c"
if [ -f "$MANIFEST" ]; then
  TYKIT_ACTION=$(python3 - "$MANIFEST" "$TYKIT_REF" << 'PYEOF'
import json, sys
manifest_path, tykit_ref = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    m = json.load(f)
deps = m.setdefault('dependencies', {})
current = deps.get('com.tyk.tykit')
if current == tykit_ref:
    print("current")
    raise SystemExit(0)
deps['com.tyk.tykit'] = tykit_ref
with open(manifest_path, 'w') as f:
    json.dump(m, f, indent=2)
    f.write('\n')
print("added" if current is None else "updated")
PYEOF
)
  case "$TYKIT_ACTION" in
    current)
      echo "  tykit: already pinned to tested release"
      ;;
    added)
      echo "  tykit: added to manifest.json"
      ;;
    updated)
      echo "  tykit: updated existing dependency to tested release"
      ;;
    *)
      echo "  tykit: manifest updated"
      ;;
  esac
else
  echo "  tykit: Packages/manifest.json not found — please add com.tyk.tykit manually"
fi

echo ""
echo "Installation complete!"
echo ""
echo "Skills (provided by the qq plugin — 22 total):"
echo "  /qq:go                  — Entry point: detect stage, suggest next step"
echo "  /qq:design              — Write game design document"
echo "  /qq:plan                — Generate technical implementation plan"
echo "  /qq:execute             — Smart implementation from plan"
echo "  /qq:test                — Run unit + integration tests"
echo "  /qq:best-practice       — Quick 18-rule Unity check"
echo "  /qq:codex-code-review   — Cross-model code review"
echo "  ... and 15 more (see /skills in Claude Code)"
echo ""
echo "Optional Codex MCP setup:"
echo "  python3 ./scripts/qq-codex-mcp.py install --pretty"
echo "  python3 ./scripts/qq-codex-mcp.py status --pretty"
echo "  python3 ./scripts/qq-codex-exec.py --dry-run --pretty 'Summarize current qq state'"
echo ""
echo "Prerequisites:"
echo "  - Claude Code CLI (claude)"
echo "  - Codex CLI (optional, for cross-model review): npm install -g @openai/codex"
echo ""
echo "Next steps:"
echo "  1. In Claude Code, register the marketplace and install the plugin:"
echo "       /plugin marketplace add tykisgod/quick-question"
echo "       /plugin install qq@quick-question-marketplace"
echo "  2. Open Unity — tykit will auto-start"
echo "  3. The project-local built-in MCP bridge is now wired in .mcp.json"
echo "  4. Shared default_profile is set to $POLICY_PROFILE in qq.yaml"
echo "  5. Optional: set .qq/local.yaml if this worktree needs prototype/fix/hardening mode"
echo "  6. Run ./scripts/qq-doctor.sh to verify direct path + MCP routing"
echo "  7. Edit a .cs file — auto-compilation hook will verify"
echo "  8. Type /qq:test in Claude Code to run tests"

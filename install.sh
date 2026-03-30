#!/usr/bin/env bash
# install.sh — Install quick-question into a Unity project
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WITH_PRE_PUSH=0
TARGET=""

for arg in "$@"; do
  case "$arg" in
    --with-pre-push) WITH_PRE_PUSH=1 ;;
    *) TARGET="$arg" ;;
  esac
done

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
        "scripts/tykit_mcp.py",
        "--project",
        "."
    ]
}

config_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYEOF
echo "  MCP: .mcp.json now points tykit to the built-in project-local bridge"

if [ ! -f "$TARGET/qq-policy.json" ]; then
  cp "$SCRIPT_DIR/templates/qq-policy.json.example" "$TARGET/qq-policy.json"
  echo "  qq-policy.json: created from template"
else
  echo "  qq-policy.json: already exists"
fi

# ── tykit UPM package ──
MANIFEST="$TARGET/Packages/manifest.json"
if [ -f "$MANIFEST" ]; then
  if grep -q "com.tyk.tykit" "$MANIFEST"; then
    echo "  tykit: already in manifest.json"
  else
    # Add tykit as git dependency (hash pinned to tested release)
    TYKIT_REF="https://github.com/tykisgod/tykit.git#84b129b026d3b725f5f7dd21d59a5fe9d206850c"
    python3 - "$MANIFEST" "$TYKIT_REF" << 'PYEOF'
import json, sys
manifest_path, tykit_ref = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    m = json.load(f)
m['dependencies']['com.tyk.tykit'] = tykit_ref
with open(manifest_path, 'w') as f:
    json.dump(m, f, indent=2)
    f.write('\n')
PYEOF
    echo "  tykit: added to manifest.json"
  fi
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
echo "  4. Run ./scripts/qq-doctor.sh to verify direct path + MCP routing"
echo "  5. Edit a .cs file — auto-compilation hook will verify"
echo "  6. Type /qq:test in Claude Code to run tests"

#!/usr/bin/env bash
# install.sh — Install quick-question into a Unity project
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"

# ── Platform check ──
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: quick-question v1 only supports macOS. Windows/Linux support planned for v2."
  exit 1
fi

# ── Dependency check ──
MISSING=""
command -v curl  &>/dev/null || MISSING="$MISSING curl"
command -v python3 &>/dev/null || MISSING="$MISSING python3"
command -v jq   &>/dev/null || MISSING="$MISSING jq"
if [ -n "$MISSING" ]; then
  echo "Error: missing required tools:$MISSING"
  echo "Install with: brew install$MISSING"
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
mkdir -p "$TARGET/scripts"
cp "$SCRIPT_DIR"/scripts/*.sh "$TARGET/scripts/"
chmod +x "$TARGET/scripts/"*.sh
echo "  Scripts: $(ls "$SCRIPT_DIR"/scripts/*.sh | wc -l | tr -d ' ') files → scripts/"
echo "  Skills + Hooks: provided by the qq plugin (install via /plugin install qq@quick-question-marketplace)"

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

# ── tykit UPM package ──
MANIFEST="$TARGET/Packages/manifest.json"
if [ -f "$MANIFEST" ]; then
  if grep -q "com.tyk.tykit" "$MANIFEST"; then
    echo "  tykit: already in manifest.json"
  else
    # Add tykit as git dependency (hash pinned to tested release)
    TYKIT_REF="https://github.com/tykisgod/tykit.git#b14919953fd8f655be05a929b69c9d71d6556ebe"
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
echo "Skills added:"
echo "  /qq-ut                  — Run unit + integration tests"
echo "  /qq-st                  — Full test pipeline"
echo "  /qq-cp                  — Commit and push"
echo "  /qq-codex-plan-review   — Cross-model design review"
echo "  /qq-codex-code-review   — Cross-model code review"
echo "  /qq-arch-review         — Architecture diff review"
echo "  /qq-code-review         — Project-specific code review"
echo "  ... and more (see .claude/commands/)"
echo ""
echo "Prerequisites:"
echo "  - Claude Code CLI (claude)"
echo "  - Codex CLI (optional, for cross-model review): npm install -g @openai/codex"
echo ""
echo "Next steps:"
echo "  1. Open Unity — EvalServer will auto-start"
echo "  2. Edit a .cs file — auto-compilation hook will verify"
echo "  3. Type /qq-ut in Claude Code to run tests"

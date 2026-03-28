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
mkdir -p "$TARGET/scripts" "$TARGET/scripts/hooks"
cp "$SCRIPT_DIR"/scripts/*.sh "$TARGET/scripts/"
cp "$SCRIPT_DIR"/scripts/hooks/*.sh "$TARGET/scripts/hooks/"
chmod +x "$TARGET/scripts/"*.sh "$TARGET/scripts/hooks/"*.sh
SCRIPT_COUNT=$(ls "$SCRIPT_DIR"/scripts/*.sh "$SCRIPT_DIR"/scripts/hooks/*.sh | wc -l | tr -d ' ')
echo "  Scripts: $SCRIPT_COUNT files → scripts/ (including hooks/)"
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
echo "Skills (provided by the qq plugin):"
echo "  /qq:test                — Run unit + integration tests"
echo "  /qq:st                  — Full test pipeline"
echo "  /qq:commit-push         — Commit and push"
echo "  /qq:codex-code-review   — Cross-model code review"
echo "  /qq:codex-plan-review   — Cross-model design review"
echo "  /qq:brief               — Architecture diff + PR checklist"
echo "  /qq:code-review         — Project-specific code review"
echo "  ... and 10 more (see /skills in Claude Code)"
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
echo "  3. Edit a .cs file — auto-compilation hook will verify"
echo "  4. Type /qq:test in Claude Code to run tests"

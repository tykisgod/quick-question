#!/usr/bin/env bash
# hook-dispatch.sh — Unified hook entry point
# Usage: bash scripts/hooks/hook-dispatch.sh <hook-name>
# Finds and runs the named hook script in the same directory

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_NAME="$1"
shift

if [ -z "$HOOK_NAME" ]; then
  echo "Usage: hook-dispatch.sh <hook-name>" >&2
  exit 1
fi

HOOK_SCRIPT="$HOOK_DIR/${HOOK_NAME}.sh"
if [ ! -f "$HOOK_SCRIPT" ]; then
  echo "Hook script not found: $HOOK_SCRIPT" >&2
  exit 1
fi

exec bash "$HOOK_SCRIPT" "$@"

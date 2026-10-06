#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
source "$SCRIPT_DIR/platform/detect.sh"
exec $QQ_PY "$SCRIPT_DIR/qq-execute-checkpoint.py" "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
    if [[ "${ARGS[$i]}" == "--project" && $((i + 1)) -lt ${#ARGS[@]} ]]; then
        PROJECT_DIR="$(cd "${ARGS[$((i + 1))]}" && pwd)"
        break
    fi
done

ENGINE="$(python3 "$SCRIPT_DIR/qq_engine.py" detect --project "$PROJECT_DIR" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("engine",""))' 2>/dev/null || true)"

case "$ENGINE" in
    unity)
        exec "$SCRIPT_DIR/unity-compile-smart.sh" "$@"
        ;;
    godot)
        exec "$SCRIPT_DIR/godot-compile.sh" "$@"
        ;;
    *)
        echo "Error: no supported engine detected for project: $PROJECT_DIR" >&2
        exit 1
        ;;
esac

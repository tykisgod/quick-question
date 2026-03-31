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

if [[ "$ENGINE" == "godot" && ${#ARGS[@]} -gt 0 ]]; then
    case "${ARGS[0]}" in
        editmode|playmode)
            ARGS=("all" "${ARGS[@]:1}")
            ;;
    esac
fi

case "$ENGINE" in
    unity)
        exec "$SCRIPT_DIR/unity-test.sh" "${ARGS[@]}"
        ;;
    godot)
        exec "$SCRIPT_DIR/godot-test.sh" "${ARGS[@]}"
        ;;
    *)
        echo "Error: no supported engine detected for project: $PROJECT_DIR" >&2
        exit 1
        ;;
esac

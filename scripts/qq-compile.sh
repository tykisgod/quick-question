#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# detect.sh 定 QQ_PY / QQ_TEMP_DIR，也提供 qq_session_id（编译转绿时清本会话的编译门要用）
source "$SCRIPT_DIR/platform/detect.sh"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
    if [[ "${ARGS[$i]}" == "--project" && $((i + 1)) -lt ${#ARGS[@]} ]]; then
        PROJECT_DIR="$(cd "${ARGS[$((i + 1))]}" && pwd)"
        break
    fi
done

ENGINE="$($QQ_PY "$SCRIPT_DIR/qq_engine.py" detect --project "$PROJECT_DIR" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin).get("engine",""))' 2>/dev/null || true)"

case "$ENGINE" in
    unity)  ENGINE_COMPILE="$SCRIPT_DIR/unity-compile-smart.sh" ;;
    godot)  ENGINE_COMPILE="$SCRIPT_DIR/godot-compile.sh" ;;
    unreal) ENGINE_COMPILE="$SCRIPT_DIR/unreal-compile.sh" ;;
    sbox)   ENGINE_COMPILE="$SCRIPT_DIR/sbox-compile.sh" ;;
    *)
        echo "Error: no supported engine detected for project: $PROJECT_DIR" >&2
        exit 1
        ;;
esac

COMPILE_EXIT=0
"$ENGINE_COMPILE" "$@" || COMPILE_EXIT=$?

# 编译转绿：清掉本会话在本项目的编译门（auto-compile.sh 在定性失败时立的）。错误在别处修好之后，
# agent 手动跑一次本脚本就能解门，不必为了触发自动编译去改一个报错文件。
# --help 也退 0，但什么都没编，不算转绿。
SHOWED_HELP=0
for arg in "$@"; do
    case "$arg" in --help|-h) SHOWED_HELP=1 ;; esac
done
if [[ "$COMPILE_EXIT" -eq 0 && "$SHOWED_HELP" -eq 0 ]] && qq_session_id \
   && compgen -G "$QQ_TEMP_DIR/compile-gate-$QQ_SESSION_ID-*" >/dev/null; then
    "$QQ_PY" "$SCRIPT_DIR/qq_compile_gate.py" clear --project "$PROJECT_DIR" --gate-prefix "$QQ_TEMP_DIR/compile-gate-$QQ_SESSION_ID" || true
fi
exit "$COMPILE_EXIT"

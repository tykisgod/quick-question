#!/bin/bash
# Unity 智能编译入口
# 用法:
#   ./scripts/unity-compile-smart.sh
#   ./scripts/unity-compile-smart.sh --timeout 20
#   ./scripts/unity-compile-smart.sh --project /path/to/project
#   ./scripts/unity-compile-smart.sh --editor   # 强制走 Editor 触发
#   ./scripts/unity-compile-smart.sh --batch    # 强制走 batch mode
#
# 自动策略:
# 1) 若检测到该项目被 Unity Editor 打开 -> 使用 unity-check.sh --trigger
# 2) 否则 -> 使用 unity-compile.sh (batch mode)
# 3) Editor 触发超时时，先读取一次当前状态；若仍未知再尝试 batch mode

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMEOUT=15
FORCE_MODE="auto" # auto/editor/batch

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --project <path>   Unity project path (default: current repo)"
    echo "  --timeout <sec>    Editor trigger wait timeout (default: 15)"
    echo "  --editor           Force use unity-check.sh --trigger"
    echo "  --batch            Force use unity-compile.sh"
    echo "  --help, -h         Show help"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project)
            PROJECT_DIR="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --editor)
            FORCE_MODE="editor"
            shift
            ;;
        --batch)
            FORCE_MODE="batch"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

if [ ! -f "$PROJECT_DIR/ProjectSettings/ProjectVersion.txt" ]; then
    echo -e "${RED}Error: $PROJECT_DIR is not a valid Unity project${NC}"
    exit 1
fi

CHECK_SCRIPT="$PROJECT_DIR/scripts/unity-check.sh"
COMPILE_SCRIPT="$PROJECT_DIR/scripts/unity-compile.sh"

if [ ! -x "$CHECK_SCRIPT" ]; then
    echo -e "${RED}Error: missing script $CHECK_SCRIPT${NC}"
    exit 1
fi

if [ ! -x "$COMPILE_SCRIPT" ]; then
    echo -e "${RED}Error: missing script $COMPILE_SCRIPT${NC}"
    exit 1
fi

# 公共函数（is_editor_open_for_project, find_unity_eval 等）
source "$(dirname "$0")/unity-common.sh"
source "$(dirname "$0")/qq-runtime.sh"

QQ_COMPILE_BACKEND="auto"
QQ_COMPILE_TRANSPORT="script"

run_tykit_mode() {
    # 检查 tykit 是否可达
    [ -f "$PROJECT_DIR/Temp/tykit.json" ] || return 2

    local eval_script
    eval_script=$(find_unity_eval)
    if [ -z "$eval_script" ]; then
        return 2
    fi

    QQ_COMPILE_BACKEND="tykit"
    QQ_COMPILE_TRANSPORT="tykit-eval"
    echo -e "${CYAN}[smart] Using tykit mode${NC}"
    UNITY_PROJECT_DIR="$PROJECT_DIR" bash "$eval_script" --compile "$TIMEOUT"
}

run_editor_mode() {
    # 优先尝试 tykit（不抢焦点、最快路径）
    local rc
    run_tykit_mode
    rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    elif [ "$rc" -eq 1 ]; then
        return 1
    fi

    # tykit 不可用或状态未知，回退到 unity-check（窗口激活触发）
    QQ_COMPILE_BACKEND="unity-editor"
    QQ_COMPILE_TRANSPORT="unity-check"
    echo -e "${CYAN}[smart] Falling back to unity-check --trigger ${TIMEOUT}${NC}"
    if "$CHECK_SCRIPT" --trigger "$TIMEOUT"; then
        return 0
    fi

    rc=$?
    if [ "$rc" -ne 2 ]; then
        return "$rc"
    fi

    echo -e "${YELLOW}[smart] Editor trigger timed out, checking current state...${NC}"
    if "$CHECK_SCRIPT"; then
        return 0
    fi

    rc=$?
    if [ "$rc" -eq 1 ]; then
        return 1
    fi

    echo -e "${YELLOW}[smart] State still unknown, trying batch mode...${NC}"
    QQ_COMPILE_BACKEND="unity-batch"
    QQ_COMPILE_TRANSPORT="unity-cli"
    "$COMPILE_SCRIPT" "$PROJECT_DIR"
}

run_batch_mode() {
    QQ_COMPILE_BACKEND="unity-batch"
    QQ_COMPILE_TRANSPORT="unity-cli"
    echo -e "${CYAN}[smart] Using batch mode: unity-compile${NC}"
    "$COMPILE_SCRIPT" "$PROJECT_DIR"
}

RUN_JSON=$(qq_run_record_start "compile" "unity-compile-smart" "$QQ_COMPILE_BACKEND" "$QQ_COMPILE_TRANSPORT" "smart compile started")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
EXIT_CODE=0

case "$FORCE_MODE" in
    editor)
        run_editor_mode || EXIT_CODE=$?
        ;;
    batch)
        run_batch_mode || EXIT_CODE=$?
        ;;
    auto)
        if is_editor_open_for_project; then
            echo -e "${CYAN}[smart] Unity Editor detected for this project${NC}"
            run_editor_mode || EXIT_CODE=$?
        else
            echo -e "${CYAN}[smart] Unity Editor not detected for this project${NC}"
            run_batch_mode || EXIT_CODE=$?
        fi
        ;;
esac

case "$EXIT_CODE" in
    0)
        qq_run_record_finish "$RUN_ID" "passed" "" "Compilation successful" \
            "{\"backend\":\"$QQ_COMPILE_BACKEND\",\"transport\":\"$QQ_COMPILE_TRANSPORT\",\"force_mode\":\"$FORCE_MODE\"}" >/dev/null
        ;;
    1)
        qq_run_record_finish "$RUN_ID" "failed" "compile_failed" "Compilation failed" \
            "{\"backend\":\"$QQ_COMPILE_BACKEND\",\"transport\":\"$QQ_COMPILE_TRANSPORT\",\"force_mode\":\"$FORCE_MODE\"}" >/dev/null
        ;;
    2)
        qq_run_record_finish "$RUN_ID" "blocked" "compile_blocked_or_timeout" "Compilation blocked or timed out" \
            "{\"backend\":\"$QQ_COMPILE_BACKEND\",\"transport\":\"$QQ_COMPILE_TRANSPORT\",\"force_mode\":\"$FORCE_MODE\"}" >/dev/null
        ;;
    *)
        qq_run_record_finish "$RUN_ID" "failed" "compile_unknown" "Compilation failed unexpectedly" \
            "{\"backend\":\"$QQ_COMPILE_BACKEND\",\"transport\":\"$QQ_COMPILE_TRANSPORT\",\"force_mode\":\"$FORCE_MODE\",\"exit_code\":$EXIT_CODE}" >/dev/null
        ;;
esac

exit "$EXIT_CODE"

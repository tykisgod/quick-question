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
# 2) 否则 -> 硬失败退 2，不自动改走 batch mode（见 refuse_batch_fallback）
# 3) Editor 触发/裁决超时时同样硬失败退 2，由人决定下一步
#
# batch mode 只在显式 --batch 时才跑：它会另起一个 Unity 进程去抢项目锁，
# 而「探测不到 Editor」不等于「Editor 没开」，自动降级等于拿一次抢锁事故赌探测准确。

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
    echo "  --batch            Force use unity-compile.sh (仅在确认本机无 Editor 打开本项目时用)"
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
# compile_gate 可插拔判据（项目提供 Tools/compile_gate.py 时启用，见 unity-check.sh 注释）
GATE="$PROJECT_DIR/Tools/compile_gate.py"
TRIGGER_FILE="$PROJECT_DIR/Temp/refresh_trigger"

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

# 项目提供 compile_gate 时：触发动作保留(tykit 优先/否则文件触发+激活窗口)，裁决统一交给 compile_gate。
run_editor_mode_gate() {
    local base rc

    # 抓 baseline；若正在编译则退一格以捕获本次而非下一次
    base=$("$QQ_PY" "$GATE" --project "$PROJECT_DIR" seq)
    "$QQ_PY" "$GATE" --project "$PROJECT_DIR" check >/dev/null 2>&1
    if [ $? -eq 2 ]; then
        base=$((base - 1))
    fi

    # 触发：优先 tykit（不抢焦点），不可达则窗口激活 + refresh_trigger 文件
    run_tykit_mode
    rc=$?
    if [ "$rc" -eq 2 ]; then
        QQ_COMPILE_BACKEND="unity-editor"
        QQ_COMPILE_TRANSPORT="unity-check"
        echo -e "${CYAN}[smart] tykit unavailable, triggering via refresh_trigger + window activate${NC}"
        mkdir -p "$(dirname "$TRIGGER_FILE")"
        touch "$TRIGGER_FILE"
        qq_activate_unity_window
    fi

    # 唯一判据：等到 seq>base 的终态
    echo -e "${CYAN}[smart] Judging via compile_gate (seq>${base})${NC}"
    "$QQ_PY" "$GATE" --project "$PROJECT_DIR" wait \
        --since "$base" --timeout "$TIMEOUT" --trigger-file "$TRIGGER_FILE" --grace 8
    rc=$?

    if [ "$rc" -eq 2 ] && ! is_editor_open_for_project; then
        refuse_batch_fallback "compile_gate 等到超时仍无新裁决(seq 未越过 base=${base})，且未探测到 Editor 打开本项目"
        return $?
    fi
    return "$rc"
}

run_editor_mode() {
    # 项目自带 compile_gate 判据 → 走 gate 裁决路径
    if [ -f "$GATE" ]; then
        run_editor_mode_gate
        return $?
    fi

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
    # 必须用 `|| rc=$?` 就地接退出码：写成 `if cmd; then ...; fi` 再 `rc=$?`，取到的是
    # if 复合命令自己的退出码（条件为假且无 else 时恒为 0），unity-check 判出的编译失败
    # 会被读成 0 一路返回成功。下面那条拒绝分支也因此永远走不到。
    rc=0
    "$CHECK_SCRIPT" --trigger "$TIMEOUT" || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    if [ "$rc" -ne 2 ]; then
        return "$rc"
    fi

    echo -e "${YELLOW}[smart] Editor trigger timed out, checking current state...${NC}"
    rc=0
    "$CHECK_SCRIPT" || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    if [ "$rc" -eq 1 ]; then
        return 1
    fi

    refuse_batch_fallback "unity-check 触发超时后复读状态仍为未知(既没判成功也没判失败)"
    return $?
}

# 探测不到 Editor / 拿不到裁决时，宁可退非 0 也不自动改走 batch。
# batch mode 会另起一个 Unity 进程去抢 Temp/UnityLockfile：若此刻真有 Editor 开着
# （探测失败 != Editor 没开），轻则卡在等锁上、重则两个进程同时写 Library 把导入缓存搞坏。
# 这种代价不对称的猜测必须交回给人，脚本只负责把拒绝理由说清楚。
refuse_batch_fallback() {
    echo -e "${RED}[smart] 拒绝自动降级到 batch mode: $1${NC}" >&2
    echo -e "${RED}[smart] 后果: batch mode 会另起 Unity 进程抢 ${PROJECT_DIR}/Temp/UnityLockfile，若已有 Editor 打开本项目，会卡等锁或损坏 Library 导入缓存${NC}" >&2
    echo -e "${RED}[smart] 处理: 让 Editor 打开本项目并能响应触发后重跑；确认本机确实没有 Editor 打开本项目时，才显式加 --batch${NC}" >&2
    return 2
}

# 只有显式 --batch 才会走到这里（auto/editor 路径一律不再自动降级）
run_batch_mode() {
    QQ_COMPILE_BACKEND="unity-batch"
    QQ_COMPILE_TRANSPORT="unity-cli"
    echo -e "${CYAN}[smart] Using batch mode: unity-compile${NC}"
    "$COMPILE_SCRIPT" "$PROJECT_DIR"
}

RUN_JSON=$(qq_run_record_start "compile" "unity-compile-smart" "$QQ_COMPILE_BACKEND" "$QQ_COMPILE_TRANSPORT" "smart compile started")
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')
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
            refuse_batch_fallback "auto 模式下未探测到 Editor 打开本项目" || EXIT_CODE=$?
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

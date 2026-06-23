#!/bin/bash
# Unity 编译状态检查脚本（自动化版）
# 用法:
#   ./scripts/unity-check.sh              # 检查当前状态
#   ./scripts/unity-check.sh --wait       # 等待下一次编译完成
#   ./scripts/unity-check.sh --trigger    # 触发编译并等待结果

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATUS_FILE="$PROJECT_DIR/Temp/compile_status.json"
TRIGGER_FILE="$PROJECT_DIR/Temp/refresh_trigger"
BATCH_COMPILE_SCRIPT="$PROJECT_DIR/scripts/unity-compile.sh"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

source "$(dirname "$0")/platform/detect.sh"

# 读取状态文件
read_status() {
    if [ ! -f "$STATUS_FILE" ]; then
        echo ""
        return
    fi
    cat "$STATUS_FILE"
}

# 获取状态字段
get_field() {
    local json="$1"
    local field="$2"
    echo "$json" | grep "\"$field\"" | sed 's/.*: *"\([^"]*\)".*/\1/' | head -1
}

# 获取数组字段
get_errors() {
    local json="$1"
    echo "$json" | grep -A100 '"errors"' | grep -E '^\s+"' | sed 's/.*"\(.*\)".*/\1/' | head -10
}

# 公共函数（is_editor_open_for_project 等）
source "$(dirname "$0")/unity-common.sh"

# Editor 不可用时，回退 batch 编译
run_batch_fallback() {
    if [ ! -x "$BATCH_COMPILE_SCRIPT" ]; then
        echo -e "${RED}❌ Missing batch compile script: $BATCH_COMPILE_SCRIPT${NC}"
        return 2
    fi

    echo -e "${CYAN}Unity Editor not detected for this project, falling back to batch compilation...${NC}"
    "$BATCH_COMPILE_SCRIPT" "$PROJECT_DIR"
}

# ---------------------------------------------------------------------------
# compile_gate 可插拔判据（仅当项目提供 Tools/compile_gate.py 时启用）
# 项目若自带 Tools/compile_gate.py（配套一个写 Temp/compile_gate.json 的 CompileWatcher），
# 则编译"过没过"的裁决改走它的 seq 门退出码（0/1/2），消解 timestamp 缓存假错 / reload 期 timeout。
# 项目未提供时 USE_GATE=0，下方一切沿用原 timestamp 逻辑，行为零变化。
# ---------------------------------------------------------------------------
GATE="$PROJECT_DIR/Tools/compile_gate.py"
USE_GATE=0
[ -f "$GATE" ] && USE_GATE=1

gate() { "$QQ_PY" "$GATE" --project "$PROJECT_DIR" "$@"; }

gate_check_status() {
    gate check
}

gate_wait_compile() {
    local timeout=${1:-60}
    local base
    base=$(gate seq)
    gate check >/dev/null 2>&1
    if [ $? -eq 2 ]; then
        base=$((base - 1))
    fi
    echo -e "${CYAN}Waiting for Unity compilation (compile_gate, seq>${base})...${NC}"
    gate wait --since "$base" --timeout "$timeout"
}

gate_trigger_and_wait() {
    local timeout=${1:-60}

    if ! is_editor_open_for_project; then
        run_batch_fallback
        return $?
    fi

    local base
    base=$(gate seq)
    gate check >/dev/null 2>&1
    if [ $? -eq 2 ]; then
        base=$((base - 1))
    fi

    echo -e "${CYAN}Triggering Unity refresh (compile_gate judge)...${NC}"
    mkdir -p "$(dirname "$TRIGGER_FILE")"
    touch "$TRIGGER_FILE"
    qq_activate_unity_window

    gate wait --since "$base" --timeout "$timeout" --trigger-file "$TRIGGER_FILE" --grace 8
    local rc=$?
    if [ "$rc" -eq 2 ] && ! is_editor_open_for_project; then
        run_batch_fallback
        return $?
    fi
    return "$rc"
}

# 检查当前编译状态
check_status() {
    local json=$(read_status)

    if [ -z "$json" ]; then
        echo -e "${YELLOW}⚠️ No status file found (Unity may not be running or first use)${NC}"
        echo "Ensure Unity Editor has the project open and has completed the first compilation"
        return 2
    fi

    local state=$(get_field "$json" "state")
    local timestamp=$(get_field "$json" "timestamp")
    local duration=$(echo "$json" | grep '"duration"' | sed 's/.*: *\([0-9.]*\).*/\1/')

    case "$state" in
        "success")
            echo -e "${GREEN}✅ Compilation successful${NC} (${duration}s @ $timestamp)"
            return 0
            ;;
        "failed")
            echo -e "${RED}❌ Compilation failed${NC} @ $timestamp"
            local errors=$(get_errors "$json")
            if [ -n "$errors" ]; then
                echo -e "${RED}Errors:${NC}"
                echo "$errors" | while read line; do
                    echo "  $line"
                done
            fi
            return 1
            ;;
        "compiling")
            echo -e "${YELLOW}⏳ Compiling...${NC}"
            return 2
            ;;
        *)
            echo -e "${YELLOW}⚠️ Unknown state: $state${NC}"
            return 2
            ;;
    esac
}

# 等待编译完成（带超时）
wait_compile() {
    local timeout=${1:-60}
    local start_time=$(date +%s)
    local last_timestamp=""

    echo -e "${CYAN}Waiting for Unity compilation...${NC}"

    # 获取当前时间戳（用于判断是否有新编译）
    local json=$(read_status)
    if [ -n "$json" ]; then
        last_timestamp=$(get_field "$json" "timestamp")
    fi

    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))

        if [ $elapsed -ge $timeout ]; then
            echo -e "\n${YELLOW}⚠️ Timeout waiting (${timeout}s)${NC}"
            check_status
            return 2
        fi

        local json=$(read_status)
        local state=$(get_field "$json" "state")
        local timestamp=$(get_field "$json" "timestamp")

        # 检查是否有新的编译结果
        if [ "$state" = "success" ] || [ "$state" = "failed" ]; then
            if [ "$timestamp" != "$last_timestamp" ] || [ -z "$last_timestamp" ]; then
                echo ""
                check_status
                return $?
            fi
        fi

        # 显示进度
        printf "\rWaiting... %ds " $elapsed
        sleep 0.5
    done
}

# 触发 Unity 刷新并等待编译完成
trigger_and_wait() {
    local timeout=${1:-60}

    if ! is_editor_open_for_project; then
        run_batch_fallback
        return $?
    fi

    # 记录当前时间戳
    local json=$(read_status)
    local last_timestamp=$(get_field "$json" "timestamp")
    local saw_compiling=0
    local trigger_consumed=0
    local consumed_elapsed=0
    local no_compile_grace=8

    # 超时很小时，缩短无编译判定窗口，避免窗口超过总超时
    if [ $timeout -le $no_compile_grace ]; then
        no_compile_grace=$((timeout - 1))
        if [ $no_compile_grace -lt 1 ]; then
            no_compile_grace=1
        fi
    fi

    # 短暂激活 Unity 窗口触发 Auto Refresh，然后切回原窗口
    echo -e "${CYAN}Triggering Unity refresh...${NC}"
    qq_activate_unity_window

    # 同时创建触发文件作为备用方案
    mkdir -p "$(dirname "$TRIGGER_FILE")"
    touch "$TRIGGER_FILE"

    # 等待编译完成
    local start_time=$(date +%s)

    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))

        if [ $elapsed -ge $timeout ]; then
            echo -e "\n${YELLOW}⚠️ Timeout waiting (${timeout}s)${NC}"
            echo "Unity may not be responding in the background; ensure the Unity Editor window is visible"

            # 超时时若判定当前并非本项目 Editor 在处理，尝试回退 batch 编译
            if ! is_editor_open_for_project; then
                run_batch_fallback
                return $?
            fi

            check_status
            return 2
        fi

        local json=$(read_status)
        local state=$(get_field "$json" "state")
        local timestamp=$(get_field "$json" "timestamp")

        # 触发文件被 Unity 删除，说明刷新请求已被消费
        if [ $trigger_consumed -eq 0 ] && [ ! -f "$TRIGGER_FILE" ]; then
            trigger_consumed=1
            consumed_elapsed=$elapsed
        fi

        # 检查是否有新的编译结果
        if [ "$state" = "success" ] || [ "$state" = "failed" ]; then
            if [ "$timestamp" != "$last_timestamp" ]; then
                echo ""
                check_status
                return $?
            fi
        fi

        # 检查是否正在编译
        if [ "$state" = "compiling" ]; then
            saw_compiling=1
            printf "\rCompiling... %ds " $elapsed
            sleep 0.5
            continue
        fi

        # 无代码变化时，Refresh 可能不会触发编译：触发文件被消费即可判定完成
        if [ $trigger_consumed -eq 1 ] && [ $saw_compiling -eq 0 ]; then
            if [ "$state" = "success" ] || [ "$state" = "failed" ]; then
                if [ $((elapsed - consumed_elapsed)) -ge $no_compile_grace ]; then
                    echo ""
                    echo -e "${CYAN}Refresh processed (no code changes, recompilation not needed)${NC}"
                    check_status
                    return $?
                fi
            fi
            printf "\rWaiting for possible compilation start... %ds " $elapsed
        else
            printf "\rWaiting for Unity response... %ds " $elapsed
        fi

        sleep 0.5
    done
}

# 主逻辑（项目提供 Tools/compile_gate.py 时走 gate 判据，否则原 timestamp 逻辑）
case "$1" in
    --trigger|-t)
        if [ $USE_GATE -eq 1 ]; then gate_trigger_and_wait ${2:-60}; else trigger_and_wait ${2:-60}; fi
        ;;
    --wait|-w)
        if [ $USE_GATE -eq 1 ]; then gate_wait_compile ${2:-60}; else wait_compile ${2:-60}; fi
        ;;
    --help|-h)
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  (no args)       Check current compilation state"
        echo "  --trigger, -t   Trigger compilation and wait for result (for agents)"
        echo "  --wait, -w      Wait for the next compilation to complete"
        echo "  --trigger 120   Trigger compilation with 120s timeout"
        echo ""
        echo "Judge:"
        if [ $USE_GATE -eq 1 ]; then
            echo "  compile_gate: $GATE  (seq 门, reads Temp/compile_gate.json)"
        else
            echo "  timestamp:    $STATUS_FILE  (set Tools/compile_gate.py to use the seq-gate judge)"
        fi
        echo "  Trigger file: $TRIGGER_FILE"
        echo ""
        echo "Prerequisites:"
        echo "  1. Prefers Unity Editor + CompileWatcher with the project open"
        echo "  2. Falls back automatically to unity-compile.sh (batch mode) if Editor is not open"
        ;;
    *)
        if [ $USE_GATE -eq 1 ]; then gate_check_status; else check_status; fi
        ;;
esac

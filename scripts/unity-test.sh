#!/bin/bash
# Unity 测试运行脚本
# 用法:
#   ./scripts/unity-test.sh                        # 运行所有 EditMode 测试
#   ./scripts/unity-test.sh editmode               # 运行 EditMode 测试
#   ./scripts/unity-test.sh playmode               # 运行 PlayMode 测试
#   ./scripts/unity-test.sh all                    # EditMode + PlayMode
#   ./scripts/unity-test.sh editmode --filter "Engine"  # 按名称过滤
#   ./scripts/unity-test.sh editmode --assembly "ProductionSystem.Tests;Ship.Tests"
#
# 优先通过 Editor（TestWatcher）运行，Editor 未打开时回退到 batch mode。

set -euo pipefail

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 项目路径
DEFAULT_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$DEFAULT_PROJECT_DIR}"
STATUS_FILE=""
TRIGGER_FILE=""

# 公共函数（is_editor_open_for_project, find_unity 等）
source "$(dirname "$0")/unity-common.sh"
source "$(dirname "$0")/qq-runtime.sh"

# 兼容别名
is_editor_open() { is_editor_open_for_project; }

QQ_LAST_TOTAL=0
QQ_LAST_PASSED=0
QQ_LAST_FAILED=0
QQ_LAST_SKIPPED=0
QQ_LAST_DURATION=0
QQ_TEST_BACKEND="unknown"
QQ_TEST_TRANSPORT="script"
SKIP_WORKTREE_LIBRARY_SEED=0

reset_last_test_summary() {
    QQ_LAST_TOTAL=0
    QQ_LAST_PASSED=0
    QQ_LAST_FAILED=0
    QQ_LAST_SKIPPED=0
    QQ_LAST_DURATION=0
}

set_last_test_summary() {
    QQ_LAST_TOTAL="${1:-0}"
    QQ_LAST_PASSED="${2:-0}"
    QQ_LAST_FAILED="${3:-0}"
    QQ_LAST_SKIPPED="${4:-0}"
    QQ_LAST_DURATION="${5:-0}"
}

# ===== Editor 模式 =====

get_json_field() {
    local json="$1"
    local field="$2"
    echo "$json" | sed -n "s/.*\"$field\" *: *\"\([^\"]*\)\".*/\1/p" | head -1
}

get_json_int() {
    local json="$1"
    local field="$2"
    echo "$json" | sed -n "s/.*\"$field\" *: *\([0-9]*\).*/\1/p" | head -1
}

get_json_float() {
    local json="$1"
    local field="$2"
    echo "$json" | sed -n "s/.*\"$field\" *: *\([0-9.]*\).*/\1/p" | head -1
}

# 通过 tykit HTTP 触发测试并等待结果
trigger_editor_tests() {
    local platform="$1"
    local filter="${2:-}"
    local assembly="${3:-}"
    local timeout="${4:-120}"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Running ${platform} tests (Editor mode)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ -n "$filter" ]; then
        echo -e "${CYAN}Filter:${NC}   $filter"
    fi
    if [ -n "$assembly" ]; then
        echo -e "${CYAN}Assembly:${NC} $assembly"
    fi
    echo ""

    local port
    port=$(get_tykit_port)
    if [ -z "$port" ]; then
        echo -e "${RED}tykit unreachable${NC}"
        return 2
    fi

    ensure_editor_edit_mode "$port" || return $?

    local mode_lower
    mode_lower=$(echo "$platform" | tr '[:upper:]' '[:lower:]')

    # 构建 run-tests 参数
    local args_json="{\"mode\":\"${mode_lower}\""
    [ -n "$filter" ] && args_json="${args_json},\"filter\":\"${filter}\""
    [ -n "$assembly" ] && args_json="${args_json},\"assemblyNames\":\"${assembly}\""
    args_json="${args_json}}"

    # 触发测试（重试前先检查是否已有 running 状态）
    local run_id=""
    for attempt in 1 2 3; do
        # 检查是否已有 running 测试
        local check
        check=$(curl -s --connect-timeout 5 --max-time 10 -X POST "http://localhost:$port/" \
            -d '{"command":"get-test-result"}' -H 'Content-Type: application/json' 2>/dev/null) || true
        local check_state
        check_state=$(echo "$check" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('state',''))" 2>/dev/null) || true
        if [ "$check_state" = "running" ]; then
            run_id=$(echo "$check" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('runId',''))" 2>/dev/null) || true
            break
        fi

        local response
        response=$(curl -s --connect-timeout 5 --max-time 15 -X POST "http://localhost:$port/" \
            -d "{\"command\":\"run-tests\",\"args\":$args_json}" -H 'Content-Type: application/json' 2>/dev/null) || { sleep 2; continue; }
        run_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['runId'])" 2>/dev/null) || { sleep 2; continue; }
        break
    done

    if [ -z "$run_id" ]; then
        echo -e "${RED}Failed to start tests (tykit not responding)${NC}"
        return 2
    fi

    # 轮询 get-test-result（只在 passed/failed 终态退出）
    local start_time=$(date +%s)
    while true; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))

        if [ $elapsed -ge $timeout ]; then
            echo -e "\n${YELLOW}⚠️ Timeout waiting (${timeout}s)${NC}"
            return 2
        fi

        local result
        result=$(curl -s --connect-timeout 5 --max-time 10 -X POST "http://localhost:$port/" \
            -d "{\"command\":\"get-test-result\",\"args\":{\"runId\":\"$run_id\"}}" \
            -H 'Content-Type: application/json' 2>/dev/null) || { printf "\r${CYAN}Running tests...${NC} %ds " $elapsed; sleep 1; continue; }

        local state total passed failed skipped duration
        state=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('state',''))" 2>/dev/null) || { sleep 1; continue; }

        case "$state" in
            passed|failed)
                total=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['total'])" 2>/dev/null)
                passed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['passed'])" 2>/dev/null)
                failed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['failed'])" 2>/dev/null)
                skipped=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['skipped'])" 2>/dev/null)
                duration=$(echo "$result" | python3 -c "import sys,json; print(f'{json.load(sys.stdin)[\"data\"][\"duration\"]:.6f}')" 2>/dev/null)

                echo ""
                if [ "$state" = "passed" ]; then
                    echo -e "${GREEN}✅ Tests passed${NC}"
                else
                    echo -e "${RED}❌ Tests failed${NC}"
                    # 输出失败详情
                    echo "$result" | python3 -c "
import sys,json
data = json.load(sys.stdin)['data']
for f in data.get('failures', []):
    print(f'  {f}')
" 2>/dev/null || true
                fi
                echo -e "${BOLD}Total:${NC} ${total:-0}  ${GREEN}Passed:${NC} ${passed:-0}  ${RED}Failed:${NC} ${failed:-0}  ${YELLOW}Skipped:${NC} ${skipped:-0}  Duration: ${duration:-0}s"
                set_last_test_summary "${total:-0}" "${passed:-0}" "${failed:-0}" "${skipped:-0}" "${duration:-0}"

                [ "$state" = "failed" ] && return 1
                return 0
                ;;
            running|waiting)
                printf "\r${CYAN}Running tests...${NC} %ds " $elapsed
                sleep 1
                ;;
            *)
                printf "\r${CYAN}Running tests...${NC} %ds " $elapsed
                sleep 1
                ;;
        esac
    done
}

ensure_editor_edit_mode() {
    local port="$1"
    local timeout="${2:-30}"

    local status
    status=$(curl -s --connect-timeout 5 --max-time 10 -X POST "http://localhost:$port/" \
        -d '{"command":"status"}' -H 'Content-Type: application/json' 2>/dev/null) || return 0

    local state
    state=$(echo "$status" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", {})
print("busy" if data.get("isPlaying") or data.get("isPaused") else "ready")
' 2>/dev/null) || return 0

    if [ "$state" = "ready" ]; then
        return 0
    fi

    echo -e "${YELLOW}Editor is in Play Mode; stopping before running tests...${NC}"
    curl -s --connect-timeout 5 --max-time 10 -X POST "http://localhost:$port/" \
        -d '{"command":"stop"}' -H 'Content-Type: application/json' >/dev/null 2>&1 || true

    local start_time
    start_time=$(date +%s)
    while true; do
        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))
        if [ $elapsed -ge $timeout ]; then
            echo -e "${RED}Unity did not return to Edit Mode within ${timeout}s${NC}"
            return 2
        fi

        status=$(curl -s --connect-timeout 5 --max-time 10 -X POST "http://localhost:$port/" \
            -d '{"command":"status"}' -H 'Content-Type: application/json' 2>/dev/null) || { sleep 1; continue; }
        state=$(echo "$status" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", {})
print("busy" if data.get("isPlaying") or data.get("isPaused") else "ready")
' 2>/dev/null) || { sleep 1; continue; }
        if [ "$state" = "ready" ]; then
            return 0
        fi
        sleep 1
    done
}

# 显示 test_status.json 的内容
display_status() {
    local json="$1"
    local state=$(get_json_field "$json" "state")
    local total=$(get_json_int "$json" "total")
    local passed=$(get_json_int "$json" "passed")
    local failed=$(get_json_int "$json" "failed")
    local skipped=$(get_json_int "$json" "skipped")
    local duration=$(get_json_float "$json" "duration")
    local message=$(get_json_field "$json" "message")

    total=${total:-0}
    passed=${passed:-0}
    failed=${failed:-0}
    skipped=${skipped:-0}
    duration=${duration:-0}

    if [ "$state" = "error" ]; then
        echo -e "${RED}❌ Test error: ${message}${NC}"
        return
    fi

    if [ "$failed" -gt 0 ]; then
        echo -e "${RED}❌ Tests failed${NC}"
    else
        echo -e "${GREEN}✅ Tests passed${NC}"
    fi

    echo -e "${BOLD}Total:${NC} ${total}  ${GREEN}Passed:${NC} ${passed}  ${RED}Failed:${NC} ${failed}  ${YELLOW}Skipped:${NC} ${skipped}  Duration: ${duration}s"

    # 显示失败详情
    if [ "$failed" -gt 0 ]; then
        echo ""
        echo -e "${RED}Failed tests:${NC}"
        # 从 JSON 的 failures 数组提取
        echo "$json" | sed -n '/failures/,/\]/p' | grep '"' | sed 's/.*"\(.*\)".*/\1/' | while IFS= read -r line; do
            # 解码常见转义
            line=$(echo "$line" | sed 's/\\n/\n/g')
            echo -e "  ${RED}✗${NC} $line"
        done
    fi
}

# ===== Batch 模式（回退） =====

run_batch_tests() {
    local platform="$1"
    local filter="${2:-}"
    local assembly="${3:-}"

    local UNITY_BIN=$(find_unity)
    if [ -z "$UNITY_BIN" ]; then
        echo -e "${RED}Error: Unity installation not found${NC}"
        return 1
    fi

    local results_file="$QQ_TEMP_DIR/unity-test-${platform}-$(date +%s).xml"
    local log_file="$QQ_TEMP_DIR/unity-test-${platform}-$(date +%s).log"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Running ${platform} tests (Batch mode)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local cmd=(
        "$UNITY_BIN" -batchmode -nographics
        -projectPath "$PROJECT_DIR"
        -runTests -testPlatform "$platform"
        -testResults "$results_file" -logFile "$log_file"
    )

    [ -n "$filter" ] && cmd+=(-testFilter "$filter") && echo -e "${CYAN}Filter:${NC}   $filter"
    [ -n "$assembly" ] && cmd+=(-assemblyNames "$assembly") && echo -e "${CYAN}Assembly:${NC} $assembly"
    echo ""

    "${cmd[@]}" 2>&1 || true

    # 检查锁定
    if grep -q "Multiple Unity instances\|another Unity instance" "$log_file" 2>/dev/null; then
        echo -e "${RED}❌ Unity project is locked${NC}"
        return 2
    fi

    # 检查编译错误
    local errors=$(grep -E "error CS[0-9]+" "$log_file" 2>/dev/null | sort -u || true)
    if [ -n "$errors" ]; then
        echo -e "${RED}❌ Compilation failed${NC}"
        echo "$errors" | head -10 | while IFS= read -r line; do echo -e "  ${RED}$line${NC}"; done
        return 1
    fi

    # 解析 XML 结果
    if [ ! -f "$results_file" ]; then
        echo -e "${RED}❌ No test results${NC}"
        echo "Log: $log_file"
        return 1
    fi

    # 用 sed 解析（macOS 兼容）
    local total=$(sed -n 's/.*total="\([0-9]*\)".*/\1/p' "$results_file" | head -1)
    local passed=$(sed -n 's/.*passed="\([0-9]*\)".*/\1/p' "$results_file" | head -1)
    local failed=$(sed -n 's/.*failed="\([0-9]*\)".*/\1/p' "$results_file" | head -1)
    local skipped=$(sed -n 's/.*skipped="\([0-9]*\)".*/\1/p' "$results_file" | head -1)
    local duration=$(sed -n 's/.*duration="\([0-9.]*\)".*/\1/p' "$results_file" | head -1)

    total=${total:-0}; passed=${passed:-0}; failed=${failed:-0}; skipped=${skipped:-0}; duration=${duration:-0}

    if [ "$failed" -gt 0 ]; then
        echo -e "${RED}❌ Tests failed${NC}"
    else
        echo -e "${GREEN}✅ Tests passed${NC}"
    fi
    echo -e "${BOLD}Total:${NC} ${total}  ${GREEN}Passed:${NC} ${passed}  ${RED}Failed:${NC} ${failed}  ${YELLOW}Skipped:${NC} ${skipped}  Duration: ${duration}s"
    set_last_test_summary "$total" "$passed" "$failed" "$skipped" "$duration"

    [ $failed -eq 0 ] && rm -f "$log_file"
    [ $failed -gt 0 ] && return 1
    return 0
}

ensure_managed_worktree_runtime_cache_seed() {
    [ "${QQ_SKIP_WORKTREE_LIBRARY_SEED:-0}" = "1" ] && return 0
    [ "$SKIP_WORKTREE_LIBRARY_SEED" -eq 1 ] && return 0
    [ "$(qq_is_managed_worktree)" = "true" ] || return 0
    [ -d "$PROJECT_DIR/Library/PackageCache" ] && return 0

    local helper
    helper="$(dirname "$0")/qq-worktree.py"
    [ -f "$helper" ] || return 0

    echo -e "${CYAN}Managed worktree has no Unity runtime cache; seeding from source worktree...${NC}"
    local payload
    if ! payload=$(python3 "$helper" seed-runtime-cache --project "$PROJECT_DIR" 2>&1); then
        echo -e "${YELLOW}⚠️ Runtime cache seed failed; falling back to cold batch mode${NC}"
        echo "$payload"
        return 0
    fi

    local summary
    summary=$(QQ_WORKTREE_SEED_PAYLOAD="$payload" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ.get("QQ_WORKTREE_SEED_PAYLOAD", ""))
except Exception:
    print("Runtime cache seed status unknown")
    raise SystemExit(0)

seed = payload.get("runtimeCacheSeed", {})
action = seed.get("action", "")
strategy = seed.get("strategy", "")

if action == "seeded" and strategy:
    print(f"Runtime cache seeded ({strategy})")
elif action == "seeded":
    print("Runtime cache seeded")
elif action == "already_present":
    print("Runtime cache already present")
elif action == "source_missing":
    print("Source runtime cache missing; continuing without seed")
elif action:
    print(f"Runtime cache seed status: {action}")
else:
    print("Runtime cache seed status unknown")
PY
)
    echo -e "${CYAN}${summary}${NC}"
}

# ===== 显示帮助 =====

show_help() {
    echo "Usage: $0 [platform] [options]"
    echo ""
    echo "Platforms:"
    echo "  editmode    Run EditMode tests (default)"
    echo "  playmode    Run PlayMode tests"
    echo "  all         EditMode + PlayMode"
    echo ""
    echo "Options:"
    echo "  --filter NAME     Filter by test name (semicolon-separated)"
    echo "  --assembly NAME   Filter by assembly (semicolon-separated)"
    echo "  --timeout SEC     Timeout in seconds (default: 120)"
    echo "  --batch           Force batch mode (requires Editor to be closed)"
    echo "  --project PATH    Override project root (default: script parent)"
    echo "  --skip-worktree-library-seed  Skip automatic runtime-cache seeding in qq-managed worktrees"
    echo "  --help, -h        Show help"
    echo ""
    echo "Examples:"
    echo "  $0                                              # EditMode tests"
    echo "  $0 playmode                                     # PlayMode tests"
    echo "  $0 editmode --filter \"Engine\"                   # Filter by name"
    echo "  $0 editmode --assembly \"ProductionSystem.Tests\""
    echo "  $0 all --batch                                  # Force batch mode"
    echo ""
    echo "Run modes:"
    echo "  Editor open   → triggered via TestWatcher (fast, no Unity restart)"
    echo "  Editor closed → falls back to batch mode automatically (slower, starts Unity)"
}

# ===== 主逻辑 =====

PLATFORM="EditMode"
FILTER=""
ASSEMBLY=""
TIMEOUT=120
FORCE_BATCH=0

while [ $# -gt 0 ]; do
    case "$1" in
        editmode|EditMode) PLATFORM="EditMode"; shift ;;
        playmode|PlayMode) PLATFORM="PlayMode"; shift ;;
        all|All)           PLATFORM="All"; shift ;;
        --filter|-f)       FILTER="$2"; shift 2 ;;
        --assembly|-a)     ASSEMBLY="$2"; shift 2 ;;
        --timeout|-t)      TIMEOUT="$2"; shift 2 ;;
        --batch)           FORCE_BATCH=1; shift ;;
        --project)         PROJECT_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        --skip-worktree-library-seed) SKIP_WORKTREE_LIBRARY_SEED=1; shift ;;
        --help|-h)         show_help; exit 0 ;;
        *)                 echo -e "${RED}Unknown argument: $1${NC}"; show_help; exit 1 ;;
    esac
done

STATUS_FILE="$PROJECT_DIR/Temp/test_status.json"
TRIGGER_FILE="$PROJECT_DIR/Temp/test_trigger"

# 验证项目
if [ ! -f "$PROJECT_DIR/ProjectSettings/ProjectVersion.txt" ]; then
    echo -e "${RED}Error: not a valid Unity project${NC}"
    exit 1
fi

# 选择运行模式
EXIT_CODE=0
TOTAL_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
DURATION_TOTAL=0

RUN_JSON=$(qq_run_record_start "test" "unity-test" "pending" "script" "test run started")
RUN_ID=$(printf '%s' "$RUN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')

accumulate_last_summary() {
    TOTAL_COUNT=$((TOTAL_COUNT + QQ_LAST_TOTAL))
    PASSED_COUNT=$((PASSED_COUNT + QQ_LAST_PASSED))
    FAILED_COUNT=$((FAILED_COUNT + QQ_LAST_FAILED))
    SKIPPED_COUNT=$((SKIPPED_COUNT + QQ_LAST_SKIPPED))
    DURATION_TOTAL=$(python3 - <<PY
total = float("${DURATION_TOTAL}")
last = float("${QQ_LAST_DURATION}")
print(f"{total + last:.6f}")
PY
)
}

if [ $FORCE_BATCH -eq 0 ] && is_editor_open; then
    QQ_TEST_BACKEND="tykit"
    QQ_TEST_TRANSPORT="tykit-http"
    echo -e "${CYAN}Unity Editor detected, triggering tests via tykit${NC}"
    echo ""
    if [ "$PLATFORM" = "All" ]; then
        reset_last_test_summary
        trigger_editor_tests "EditMode" "$FILTER" "$ASSEMBLY" "$TIMEOUT" || EXIT_CODE=$?
        accumulate_last_summary
        echo ""
        reset_last_test_summary
        trigger_editor_tests "PlayMode" "$FILTER" "$ASSEMBLY" "$TIMEOUT" || {
            rc=$?; [ $rc -gt $EXIT_CODE ] && EXIT_CODE=$rc
        }
        accumulate_last_summary
    else
        reset_last_test_summary
        trigger_editor_tests "$PLATFORM" "$FILTER" "$ASSEMBLY" "$TIMEOUT" || EXIT_CODE=$?
        accumulate_last_summary
    fi
else
    QQ_TEST_BACKEND="unity-batch"
    QQ_TEST_TRANSPORT="unity-cli"
    if [ $FORCE_BATCH -eq 0 ]; then
        echo -e "${CYAN}Unity Editor not detected, using batch mode${NC}"
    else
        echo -e "${CYAN}Forcing batch mode${NC}"
    fi
    echo ""
    ensure_managed_worktree_runtime_cache_seed

    if [ "$PLATFORM" = "All" ]; then
        reset_last_test_summary
        run_batch_tests "EditMode" "$FILTER" "$ASSEMBLY" || EXIT_CODE=$?
        accumulate_last_summary
        echo ""
        reset_last_test_summary
        run_batch_tests "PlayMode" "$FILTER" "$ASSEMBLY" || {
            rc=$?; [ $rc -gt $EXIT_CODE ] && EXIT_CODE=$rc
        }
        accumulate_last_summary
    else
        reset_last_test_summary
        run_batch_tests "$PLATFORM" "$FILTER" "$ASSEMBLY" || EXIT_CODE=$?
        accumulate_last_summary
    fi
fi

if [ "$EXIT_CODE" -eq 0 ]; then
    TEST_STATUS="passed"
    FAILURE_CATEGORY=""
    TEST_SUMMARY="Tests passed"
elif [ "$EXIT_CODE" -eq 1 ]; then
    TEST_STATUS="failed"
    FAILURE_CATEGORY="test_failed"
    TEST_SUMMARY="Tests failed"
else
    TEST_STATUS="blocked"
    FAILURE_CATEGORY="test_timeout_or_blocked"
    TEST_SUMMARY="Tests blocked or timed out"
fi

qq_run_record_finish "$RUN_ID" "$TEST_STATUS" "$FAILURE_CATEGORY" "$TEST_SUMMARY" \
    "{\"backend\":\"$QQ_TEST_BACKEND\",\"transport\":\"$QQ_TEST_TRANSPORT\",\"mode\":\"$PLATFORM\",\"total\":$TOTAL_COUNT,\"passed\":$PASSED_COUNT,\"failed\":$FAILED_COUNT,\"skipped\":$SKIPPED_COUNT,\"duration_sec\":$DURATION_TOTAL}" >/dev/null

exit $EXIT_CODE

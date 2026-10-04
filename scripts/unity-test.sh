#!/bin/bash
# Unity 测试运行脚本
# 用法:
#   ./scripts/unity-test.sh                        # 运行所有 EditMode 测试
#   ./scripts/unity-test.sh editmode               # 运行 EditMode 测试
#   ./scripts/unity-test.sh playmode               # 运行 PlayMode 测试
#   ./scripts/unity-test.sh all                    # EditMode + PlayMode
#   ./scripts/unity-test.sh editmode --filter "Engine"  # 按名称过滤
#   ./scripts/unity-test.sh editmode --assembly "ProductionSystem.Tests;Ship.Tests"   # tykit 通道才认 ;
#   ./scripts/unity-test.sh editmode --job <jobId>  # 官方 CLI：接着等上次没等完的 EditMode 作业（不重新提交）
#
# 通过已打开的 Editor 运行，通道按项目实际情况选（unity-common.sh 的 qq_unity_channel test）：
#   - 官方 Unity CLI（Library/Pipeline/.unity-pipeline-port 有效、找得到 unity）：EditMode 用 --detach 提交
#     run_tests、轮询 job status、最后 job wait 取结果；PlayMode 异步提交、读 Temp/pipeline_test_status.json。
#     结果交给 qq-unity-cli.py verdict 分层裁决，一直读到 Summary.Failed 和跳过数——退出码和任何 success 字段
#     都不算数（实测过一次 1 过 1 败的运行，五个「成功」字段全是绿的）。
#   - tykit（Temp/tykit.json，Editor 开着）：HTTP run-tests / get-test-result。描述文件有效、却找不到 unity 时
#     也回落到这里（正从 tykit 迁到官方 CLI 的项目）；连 tykit 都没有才退 2（unity_cli_unavailable）。
# 探测不到 Editor 时**硬失败**，不再自动转 batch mode——见文末主逻辑处的说明：静默转 batchmode 会去抢项目锁，
# 是事故而不是降级。真要跑 batch 必须显式 --batch，由调用方自己保证 Editor 已关闭。

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

# Python：沿用 platform/detect.sh（经 unity-common.sh 加载）选好的 QQ_PY。这里原来无条件改回 python3：
# Windows 上那是应用商店的别名，每起一次要 0.7 秒，喂 stdin 脚本（accumulate_last_summary）还会卡住；
# 官方 CLI 的跑法每轮都要调几次 python 判回包，这个代价会被放大。

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
        check_state=$(echo "$check" | $QQ_PY -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('state',''))" 2>/dev/null) || true
        if [ "$check_state" = "running" ]; then
            run_id=$(echo "$check" | $QQ_PY -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('runId',''))" 2>/dev/null) || true
            break
        fi

        local response
        response=$(curl -s --connect-timeout 5 --max-time 15 -X POST "http://localhost:$port/" \
            -d "{\"command\":\"run-tests\",\"args\":$args_json}" -H 'Content-Type: application/json' 2>/dev/null) || { sleep 2; continue; }
        run_id=$(echo "$response" | $QQ_PY -c "import sys,json; print(json.load(sys.stdin)['data']['runId'])" 2>/dev/null) || { sleep 2; continue; }
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
        state=$(echo "$result" | $QQ_PY -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('state',''))" 2>/dev/null) || { sleep 1; continue; }

        case "$state" in
            passed|failed)
                total=$(echo "$result" | $QQ_PY -c "import sys,json; print(json.load(sys.stdin)['data']['total'])" 2>/dev/null)
                passed=$(echo "$result" | $QQ_PY -c "import sys,json; print(json.load(sys.stdin)['data']['passed'])" 2>/dev/null)
                failed=$(echo "$result" | $QQ_PY -c "import sys,json; print(json.load(sys.stdin)['data']['failed'])" 2>/dev/null)
                skipped=$(echo "$result" | $QQ_PY -c "import sys,json; print(json.load(sys.stdin)['data']['skipped'])" 2>/dev/null)
                duration=$(echo "$result" | $QQ_PY -c "import sys,json; print(f'{json.load(sys.stdin)[\"data\"][\"duration\"]:.6f}')" 2>/dev/null)

                echo ""
                if [ "$state" = "passed" ]; then
                    echo -e "${GREEN}✅ Tests passed${NC}"
                else
                    echo -e "${RED}❌ Tests failed${NC}"
                    # 输出失败详情
                    echo "$result" | $QQ_PY -c "
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
    state=$(echo "$status" | $QQ_PY -c '
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
        state=$(echo "$status" | $QQ_PY -c '
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

# ===== 官方 Unity CLI 模式（unity command / unity job） =====
#
# 两个实际踩过的坑，决定了这里的写法：
#   1. run_tests 的命令层超时默认 300 秒，一超时 Editor 的整条 CLI 通道就卡死（之后所有命令都进不去）。
#      EditMode 全量能跑将近 9 分钟，所以 argv 固定写成 `run_tests -- --timeout 86400 …`：命令层参数一律放在
#      唯一的一个 -- 后面（不加 -- 时与全局选项同名的 --timeout 会被客户端吞掉，写两个 -- 会报参数错）。
#   2. 退出码和任何 success 字段都不能判绿，判据交给 qq-unity-cli.py verdict，一直读到 Summary.Failed 和跳过数。
# 另外几条：
#   - EditMode 必须 --detach：同步跑时客户端 30 秒就放弃连接，Editor 却接着跑完、一直占着执行门，结果没人收。
#   - 等不到结果时绝不取消作业：取消对 run_tests 不起作用，还会把已经跑完的作业标成 canceled、被判红。
#     只打印 jobId，让人用 --job 接着等。
#   - jobId 撑不过 domain reload：提交前先等在途编译结束；作业不见了（404）就判红，不立即重投（重投 = 白跑一遍）。
#   - 不用官方的 all 模式：它把 EditMode 同步结果和 PlayMode 异步结果混在一起，两种编码用同一个解析器会假绿；
#     All 是分两次提交、各自判。
#   - CLI 只在 bash 里调，回包写进文件交给 python 判，bash 不碰 JSON；--project-path 每次都传。

UCLI_TMP=""
UCLI_CATEGORY=""   # 没走到任何一个模式就失败时（参数不支持等）的 failure_category
UCLI_FILTER=""
UCLI_FILTER_TYPE=""
UCLI_NATIVE=""
UCLI_MODE_TIMEOUT=0

ucli_cleanup() {
    if [ -n "$UCLI_TMP" ]; then rm -rf "$UCLI_TMP"; fi
}

# 没走到判据就失败的模式也记一份同样格式的摘要（failure_category、jobId），run record 里才看得到。返回 <退出码>。
ucli_note() {  # <模式> <退出码> <failure_category> <层> [<jobId>]
    "$QQ_PY" "$QQ_UNITY_CLI_PY" note --out "$UCLI_TMP/run-$1.json" --mode "$1" --exit "$2" \
        --category "$3" --layer "$4" --job-id="${5:-}" >/dev/null 2>&1 || true
    return "$2"
}

# 接着等同一个 EditMode 作业的命令。提交时影响判据的参数都要原样带上，不然接着等时用的是另一套标准：
# filter（判据核对回显的 FilterApplied）、--min-tests / --allow-zero / --allow-skipped，以及 --project。
# 值用 printf %q 转义，给人原样复制进 shell（filter 里有空格、引号也不会坏）
ucli_resume_cmd() {  # <jobId>
    local cmd
    cmd="unity-test.sh editmode --job $(printf '%q' "$1")"
    if [ -n "$PROJECT_ARG" ]; then cmd="$cmd --project $(printf '%q' "$PROJECT_ARG")"; fi
    if [ "$UCLI_FILTER_TYPE" = assembly ]; then
        cmd="$cmd --assembly $(printf '%q' "$UCLI_FILTER")"
    elif [ -n "$UCLI_FILTER" ]; then
        cmd="$cmd --filter $(printf '%q' "$UCLI_FILTER")"
    fi
    if [ -n "$MIN_TESTS" ]; then cmd="$cmd --min-tests $MIN_TESTS"; fi
    if [ -n "$ALLOW_ZERO" ]; then cmd="$cmd --allow-zero"; fi
    if [ -n "$ALLOW_SKIPPED" ]; then cmd="$cmd --allow-skipped"; fi
    printf '%s\n' "$cmd"
}

# 一次 CLI 调用失败后，按回包归一个 failure_category（stdout）
ucli_failure_category() {  # <回包文件> <CLI 退出码>
    "$QQ_PY" "$QQ_UNITY_CLI_PY" failure-category --file "$1" --rc "$2" 2>/dev/null || echo unity_cli_transport
}

# 官方接口一次只收一个 filter（子串匹配）加一个 filter_type
ucli_resolve_filter() {
    UCLI_FILTER=""
    UCLI_FILTER_TYPE=""
    local reason=""
    if [ -n "$FILTER" ] && [ -n "$ASSEMBLY" ]; then
        reason="both --filter and --assembly were given"
    elif [ -n "$FILTER" ]; then
        case "$FILTER" in *';'*) reason="--filter has several ';'-separated values" ;; esac
        UCLI_FILTER="$FILTER"
        UCLI_FILTER_TYPE="testName"
    elif [ -n "$ASSEMBLY" ]; then
        case "$ASSEMBLY" in *';'*) reason="--assembly has several ';'-separated values" ;; esac
        UCLI_FILTER="$ASSEMBLY"
        UCLI_FILTER_TYPE="assembly"
    fi
    [ -z "$reason" ] && return 0
    echo -e "${RED}❌ Unsupported filter for the official Unity CLI: ${reason}.${NC}"
    echo "   The CLI takes one filter value per run (a substring match), with one filter type."
    echo "   qq does not loop over several values: substring matches overlap, so a looped run counts some tests"
    echo "   twice (one project got 3837 results for 1932 real tests). Pass a single --filter or a single --assembly."
    UCLI_FILTER=""
    UCLI_FILTER_TYPE=""
    return 1
}

# 提交前的预检：没有在途测试、Editor 是本项目的、没在编译 / reload、不在 Play（在 Play 就先停，和 tykit 路径一致）
ucli_preflight() {  # <模式>
    local mode="$1" es="$UCLI_TMP/es.json" cls info st comp reload play owner now
    local poll="${QQ_UNITY_CLI_POLL_SEC:-2}" settle_deadline stop_deadline="" said_settle=0
    if "$QQ_PY" "$QQ_UNITY_CLI_PY" test-in-flight --project "$PROJECT_DIR" >/dev/null 2>&1; then
        echo -e "${RED}❌ A test run is already in flight in Unity (Temp/pipeline_test_request.json): not submitting another one.${NC}"
        echo "   A new run_tests would cancel the run in flight. Wait for it to finish, then re-run."
        echo "   If no run is actually in progress (e.g. Unity restarted mid-run), delete that file and re-run."
        ucli_note "$mode" 2 test_in_flight preflight
        return 2
    fi
    settle_deadline=$(( $(date +%s) + ${QQ_UNITY_CLI_SETTLE_SEC:-120} ))
    while :; do
        cls=0
        qq_ucli_cmd_retry 0 "$es" "$es.err" 20 editor_status || cls=$?
        if [ "$cls" -ne 0 ]; then
            local category
            category="$(ucli_failure_category "$es" "$QQ_UCLI_RC")"
            case "$category" in
                editor_not_detected)
                    echo -e "${RED}❌ No Pipeline server answers for this project.${NC} Start it in Unity: Window/Pipeline/Start Server" ;;
                editor_busy)
                    echo -e "${RED}❌ The Editor's CLI channel is busy or blocked (see above); not submitting tests.${NC}" ;;
                *)
                    echo -e "${RED}❌ editor_status failed (see above); not submitting tests.${NC}" ;;
            esac
            ucli_note "$mode" 2 "$category" preflight
            return 2
        fi
        info="$("$QQ_PY" "$QQ_UNITY_CLI_PY" editor-status --file "$es" --project "$PROJECT_DIR")" || {
            ucli_note "$mode" 2 unity_cli_transport preflight
            return 2
        }
        IFS=$'\t' read -r st comp reload play owner <<EOF
$info
EOF
        if [ "$owner" = foreign ]; then
            echo -e "${RED}❌ The Editor answering on this project's Pipeline port reports a different project path.${NC}"
            echo "   Not running tests against another project's Editor. Restart Unity on this project."
            ucli_note "$mode" 2 editor_mismatch preflight
            return 2
        fi
        now="$(date +%s)"
        if [ "$comp" = true ] || [ "$reload" = true ]; then
            # jobId 撑不过 domain reload：编译 / reload 结束之前不提交
            if [ "$now" -ge "$settle_deadline" ]; then
                echo -e "${RED}❌ Unity is still compiling or reloading after ${QQ_UNITY_CLI_SETTLE_SEC:-120}s; not submitting tests.${NC}"
                ucli_note "$mode" 2 editor_busy preflight
                return 2
            fi
            if [ "$said_settle" -eq 0 ]; then
                echo -e "${CYAN}Unity is compiling / reloading (status=${st}); waiting before submitting — a test job does not survive a domain reload${NC}"
                said_settle=1
            fi
            sleep "$poll"
            continue
        fi
        if [ "$play" != stopped ] && [ "$play" != "-" ]; then
            if [ -z "$stop_deadline" ]; then
                echo -e "${YELLOW}Editor is in Play mode (playMode=${play}); stopping it before running tests...${NC}"
                qq_ucli_cmd_retry 0 "$UCLI_TMP/stop.json" "$UCLI_TMP/stop.err" 20 editor_stop || true
                stop_deadline=$(( now + ${QQ_UNITY_CLI_STOP_SEC:-30} ))
            elif [ "$now" -ge "$stop_deadline" ]; then
                echo -e "${RED}❌ Unity did not return to Edit mode within ${QQ_UNITY_CLI_STOP_SEC:-30}s${NC}"
                ucli_note "$mode" 2 editor_busy preflight
                return 2
            fi
            sleep "$poll"
            continue
        fi
        return 0
    done
}

# EditMode（Protocol A）：--detach 提交 → 轮询 job status → job wait 取结果 → verdict
ucli_editmode() {  # <最少条数> <预期跳过名单>
    local min="$1" skips="$2" sub="$UCLI_TMP/sub-edit.json" cls=0 job="" rc=0
    if [ -n "$RESUME_JOB" ]; then
        job="$RESUME_JOB"
        echo -e "${CYAN}Resuming EditMode job ${job} (not re-submitting)${NC}"
    else
        # submit-once：信封含糊（network）也绝不重投
        qq_ucli_cmd_retry 1 "$sub" "$sub.err" 60 --detach run_tests -- --timeout 86400 --mode editor \
            ${UCLI_FILTER:+--filter "$UCLI_FILTER" --filter_type "$UCLI_FILTER_TYPE"} || cls=$?
        if [ "$cls" -ne 0 ]; then
            if [ "$cls" -eq 11 ]; then
                echo -e "${RED}❌ The EditMode submission's reply was lost; it may or may not have reached Unity.${NC}"
                echo "   Not re-submitting automatically. Check that Unity is idle (no tests running) before re-running."
            else
                echo -e "${RED}❌ Could not submit the EditMode run (see above).${NC}"
            fi
            ucli_note EditMode 2 "$(ucli_failure_category "$sub" "$QQ_UCLI_RC")" submit
            return 2
        fi
        job="$("$QQ_PY" "$QQ_UNITY_CLI_PY" job-id --file "$sub")" || {
            ucli_note EditMode 2 unity_cli_transport submit
            return 2
        }
        echo -e "${CYAN}[unity-cli] EditMode jobId=${job}${NC} — if this wait is interrupted or times out, resume with:"
        echo "    $(ucli_resume_cmd "$job")     (do not re-submit: that runs the whole suite again)"
    fi

    ucli_wait_job "$job" || return $?

    # 作业已到终态，job wait 会立刻返回完整结果；网络抖动（domain reload）时它可以安全重试
    local attempt=0 jw="$UCLI_TMP/jw.json" jcls
    while :; do
        rc=0
        qq_ucli "$jw" "$jw.err" job wait "$job" --project-path "$UCLI_NATIVE" --json --no-banner --non-interactive --timeout 60 || rc=$?
        jcls=0
        "$QQ_PY" "$QQ_UNITY_CLI_PY" envelope --file "$jw" --rc "$rc" --quiet || jcls=$?
        case "$jcls" in 10|11) ;; *) break ;; esac
        attempt=$((attempt + 1))
        [ "$attempt" -le 3 ] || break
        sleep "${QQ_UNITY_CLI_RETRY_SEC:-5}"
    done
    "$QQ_PY" "$QQ_UNITY_CLI_PY" verdict --protocol A --file "$jw" --rc "$rc" --job-id="$job" --mode EditMode \
        --filter="$UCLI_FILTER" --filter-type="$UCLI_FILTER_TYPE" --min-tests "$min" \
        ${ALLOW_ZERO:+--allow-zero} ${ALLOW_SKIPPED:+--allow-skipped} --expected-skips="$skips" \
        --summary-out "$UCLI_TMP/run-EditMode.json"
}

# 轮询 job status 直到作业离开 queued / running。超时、作业不见了、通道一直进不去都退 2，并给出接着等的写法。
ucli_wait_job() {  # <jobId>
    local job="$1" js="$UCLI_TMP/js.json" rc cls line state="" detail="" last="" fails=0
    local poll="${QQ_UNITY_CLI_POLL_SEC:-10}" start now deadline next_note
    start="$(date +%s)"
    deadline=$(( start + UCLI_MODE_TIMEOUT ))
    next_note=$(( start + 60 ))
    while :; do
        rc=0
        qq_ucli "$js" "$js.err" job status "$job" --project-path "$UCLI_NATIVE" --json --no-banner --non-interactive || rc=$?
        cls=0
        line="$("$QQ_PY" "$QQ_UNITY_CLI_PY" job-poll --file "$js" --rc "$rc" --job-id="$job")" || cls=$?
        case "$cls" in
            0)
                fails=0
                state="${line%%$'\t'*}"
                detail="${line#*$'\t'}"
                ;;
            14)
                echo -e "${RED}❌ EditMode job ${job} is gone (Job Not Found).${NC}"
                echo "   Jobs live in memory and do not survive a domain reload: something compiled or reloaded in Unity"
                echo "   during the run. Wait until Unity is idle, then re-run. Do not re-submit right away."
                ucli_note EditMode 2 test_job_lost wait "$job"
                return 2
                ;;
            13)
                echo -e "${RED}❌ Unity is blocked by a modal dialog (see above).${NC} Answer it in the Unity window, then resume:"
                echo "    $(ucli_resume_cmd "$job")"
                ucli_note EditMode 2 editor_busy wait "$job"
                return 2
                ;;
            *)
                fails=$((fails + 1))
                if [ "$fails" -gt 3 ]; then
                    echo -e "${RED}❌ job status failed ${fails} times in a row; giving up waiting.${NC} The tests may still be running in Unity."
                    echo "   Resume later with: $(ucli_resume_cmd "$job")"
                    ucli_note EditMode 2 unity_cli_transport wait "$job"
                    return 2
                fi
                ;;
        esac
        now="$(date +%s)"
        case "$state" in
            queued|running|"") ;;
            *) break ;;
        esac
        if [ "$now" -ge "$deadline" ]; then
            echo -e "${YELLOW}⚠️ Timeout waiting (${UCLI_MODE_TIMEOUT}s): EditMode job ${job} is still ${state:-unknown} in Unity.${NC}"
            echo "   Resume waiting with: $(ucli_resume_cmd "$job")   (do not re-submit)"
            echo "   If it never progresses, look for a modal dialog in the Unity window; exiting Play mode or restarting the"
            echo "   Editor frees a wedged CLI channel."
            ucli_note EditMode 2 test_timeout_or_blocked wait "$job"
            return 2
        fi
        if [ "$state:$detail" != "$last" ] || [ "$now" -ge "$next_note" ]; then
            echo "[unity-cli] EditMode job ${job}: ${state:-?} ($((now - start))s)${detail:+ $detail}"
            last="$state:$detail"
            next_note=$(( now + 60 ))
        fi
        sleep "$poll"
    done
    echo "[unity-cli] EditMode job ${job}: ${state}"
    return 0
}

# PlayMode（Protocol B）：异步提交 → 确认开跑 → 读 Temp/pipeline_test_status.json（不用 test_status 命令轮询：它要取执行门）
ucli_playmode() {  # <最少条数> <预期跳过名单>
    local min="$1" skips="$2" sub="$UCLI_TMP/sub-play.json" t0 out="$UCLI_TMP/run-PlayMode.json"
    rm -f "$PROJECT_DIR/Temp/pipeline_test_status.json"
    t0="$(date +%s)"
    qq_ucli_cmd_retry 1 "$sub" "$sub.err" 60 run_tests -- --timeout 86400 --mode playmode --async_tests true \
        ${UCLI_FILTER:+--filter "$UCLI_FILTER" --filter_type "$UCLI_FILTER_TYPE"} || true
    "$QQ_PY" "$QQ_UNITY_CLI_PY" start-check --file "$sub" --rc "${QQ_UCLI_RC:-0}" --project "$PROJECT_DIR" \
        --submitted-at "$t0" --filter="$UCLI_FILTER" --filter-type="$UCLI_FILTER_TYPE" --summary-out "$out" || return $?
    echo "[unity-cli] PlayMode run started; waiting for Temp/pipeline_test_status.json (up to ${UCLI_MODE_TIMEOUT}s)."
    echo "    PlayMode cannot be resumed: if this wait is cut short, let the run finish in Unity before re-running."
    "$QQ_PY" "$QQ_UNITY_CLI_PY" wait-playmode --project "$PROJECT_DIR" --submitted-at "$t0" \
        --timeout "$UCLI_MODE_TIMEOUT" --poll "${QQ_UNITY_CLI_POLL_SEC:-5}" --summary-out "$out" || return $?
    "$QQ_PY" "$QQ_UNITY_CLI_PY" verdict --protocol B --status-file "$PROJECT_DIR/Temp/pipeline_test_status.json" \
        --submitted-at "$t0" --mode PlayMode --filter="$UCLI_FILTER" --filter-type="$UCLI_FILTER_TYPE" \
        --min-tests "$min" ${ALLOW_ZERO:+--allow-zero} ${ALLOW_SKIPPED:+--allow-skipped} --expected-skips="$skips" \
        --summary-out "$out"
}

ucli_run_mode() {  # <EditMode|PlayMode>
    local mode="$1" line min skips
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Running ${mode} tests (official Unity CLI)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ -n "$UCLI_FILTER" ]; then
        echo -e "${CYAN}Filter:${NC}   ${UCLI_FILTER_TYPE}: ${UCLI_FILTER}"
    fi
    UCLI_MODE_TIMEOUT="$(mode_timeout "$mode")"
    echo -e "${CYAN}Wait:${NC}     up to ${UCLI_MODE_TIMEOUT}s for the result"

    # 规模下限与预期跳过名单（qq.yaml 写坏了要在提交之前报出来）
    line="$("$QQ_PY" "$QQ_UNITY_CLI_PY" test-config --project "$PROJECT_DIR" --mode "$mode" \
        ${UCLI_FILTER:+--filtered})" || {
        ucli_note "$mode" 2 config_error config
        return 2
    }
    min="${line%%$'\t'*}"
    skips="${line#*$'\t'}"
    [ -n "$MIN_TESTS" ] && min="$MIN_TESTS"
    echo ""

    # 接着等一个已经在跑的作业时不做预检：那个作业正占着执行门，editor_status 只会排队到超时
    if [ -z "$RESUME_JOB" ]; then
        ucli_preflight "$mode" || return $?
    fi
    if [ "$mode" = EditMode ]; then
        ucli_editmode "$min" "$skips"
    else
        ucli_playmode "$min" "$skips"
    fi
}

run_unity_cli_tests() {
    QQ_TEST_BACKEND="unity-cli"
    QQ_TEST_TRANSPORT="unity-cli"
    echo -e "${CYAN}Unity Editor reachable through the official Unity CLI (Library/Pipeline descriptor); running tests via unity command / unity job${NC}"
    echo ""
    UCLI_TMP="$(mktemp -d "${QQ_TEMP_DIR:-/tmp}/qq-ucli-test.XXXXXX" 2>/dev/null || mktemp -d)" || {
        echo -e "${RED}❌ Could not create a temporary directory${NC}"
        UCLI_CATEGORY=unity_cli_transport
        return 2
    }
    trap ucli_cleanup EXIT
    UCLI_NATIVE="$(qq_unity_native_path "$PROJECT_DIR")"

    # 参数检查：不合法就一条也不提交
    if ! ucli_resolve_filter; then
        UCLI_CATEGORY=unsupported_filter
        return 2
    fi
    if [ -n "$ALLOW_ZERO" ] && [ "${MIN_TESTS:-}" != 0 ]; then
        echo -e "${RED}❌ --allow-zero must be combined with --min-tests 0${NC}"
        UCLI_CATEGORY=invalid_arguments
        return 2
    fi
    if [ -n "$RESUME_JOB" ] && [ "$PLATFORM" != EditMode ]; then
        echo -e "${RED}❌ --job resumes an EditMode job only (PlayMode results cannot be tied to a run)${NC}"
        UCLI_CATEGORY=invalid_arguments
        return 2
    fi

    local rc=0
    if [ "$PLATFORM" = "All" ]; then
        ucli_run_mode EditMode || rc=$?
        echo ""
        if [ "$rc" -eq 2 ]; then
            # EditMode 没拿到裁决时它可能还在 Unity 里跑：再提交一轮 run_tests 会把它打掉
            echo -e "${YELLOW}EditMode gave no verdict; not starting PlayMode (a new run_tests would cancel a run that may still be in flight).${NC}"
        else
            local prc=0
            ucli_run_mode PlayMode || prc=$?
            # 一轮确定判红（1）整次就是红：另一轮没拿到裁决（2）不能把已经确定的失败降成「没有裁决」
            if [ "$rc" -eq 1 ] || [ "$prc" -eq 1 ]; then
                rc=1
            elif [ "$prc" -gt "$rc" ]; then
                rc=$prc
            fi
        fi
    else
        ucli_run_mode "$PLATFORM" || rc=$?
    fi
    return "$rc"
}

# 按通道和模式定的等待上限（--timeout 优先）：tykit 沿用 unity-unit-test.sh 原来传的 180 / 300；
# 官方 CLI 下 --timeout 指 qq 等结果的时长（命令层超时另有 86400），EditMode 全量就要 9 分钟上下，默认 3600
mode_timeout() {  # <EditMode|PlayMode>
    if [ -n "$TIMEOUT" ]; then
        echo "$TIMEOUT"
    elif [ "$QQ_TEST_BACKEND" = unity-cli ]; then
        echo 3600
    elif [ "$1" = PlayMode ]; then
        echo 300
    else
        echo 180
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

    # Windows Unity.exe needs Windows-style paths
    local proj_path="$PROJECT_DIR"
    local res_path="$results_file"
    local log_path="$log_file"
    if [[ "$QQ_PLATFORM" == "windows" ]]; then
        proj_path=$(cygpath -w "$PROJECT_DIR")
        res_path=$(cygpath -w "$results_file")
        log_path=$(cygpath -w "$log_file")
    fi

    local cmd=(
        "$UNITY_BIN" -batchmode -nographics
        -projectPath "$proj_path"
        -runTests -testPlatform "$platform"
        -testResults "$res_path" -logFile "$log_path"
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
    if ! payload=$($QQ_PY "$helper" seed-runtime-cache --project "$PROJECT_DIR" 2>&1); then
        # 只是没有热缓存，不是模式回退（本函数只在显式 --batch 的路径上被调用）
        echo -e "${YELLOW}⚠️ Runtime cache seed failed; continuing with a cold Library (first compile will be slow)${NC}"
        echo "$payload"
        return 0
    fi

    local summary
    summary=$(QQ_WORKTREE_SEED_PAYLOAD="$payload" $QQ_PY - <<'PY'
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
    echo "  --filter NAME     Filter by test name (tykit: semicolon-separated; official CLI: one value)"
    echo "  --assembly NAME   Filter by assembly (tykit: semicolon-separated; official CLI: one value,"
    echo "                    and not together with --filter)"
    echo "  --timeout SEC     How long to wait for results (default: official CLI 3600; tykit"
    echo "                    EditMode 180 / PlayMode 300)"
    echo "  --job ID          Official CLI, EditMode only: resume waiting for a job submitted earlier"
    echo "                    (its id is printed at submission, with the exact command to resume:"
    echo "                    it carries the same --filter / --assembly / --min-tests / ...). Never re-submits."
    echo "  --min-tests N     Official CLI: fail when fewer than N tests ran (default: qq.yaml"
    echo "                    unity.min_tests.<editmode|playmode> for unfiltered runs, else 1)"
    echo "  --allow-zero      Official CLI: accept a run with 0 tests (needs --min-tests 0)"
    echo "  --allow-skipped   Official CLI: accept any skipped test (one-off debugging only; normally"
    echo "                    skips must be listed in the expected-skips file)"
    echo "  --batch           Run via -batchmode. ONLY when the Editor is closed: batchmode grabs"
    echo "                    the project lock and will break an Editor that is still open."
    echo "  --project PATH    Override project root (default: script parent)"
    echo "  --skip-worktree-library-seed  Skip automatic runtime-cache seeding in qq-managed worktrees"
    echo "  --help, -h        Show help"
    echo ""
    echo "Examples:"
    echo "  $0                                              # EditMode tests"
    echo "  $0 playmode                                     # PlayMode tests"
    echo "  $0 editmode --filter \"Engine\"                   # Filter by name"
    echo "  $0 editmode --assembly \"ProductionSystem.Tests\""
    echo "  $0 editmode --job <jobId>                       # Resume an official-CLI EditMode job"
    echo "  $0 all --batch                                  # Force batch mode"
    echo ""
    echo "Run modes (picked per project):"
    echo "  Official Unity CLI  → live Library/Pipeline/.unity-pipeline-port + the unity CLI:"
    echo "                        EditMode via a detached run_tests job, PlayMode asynchronously;"
    echo "                        the verdict reads Summary.Failed and the skip count, never exit codes"
    echo "  tykit               → Temp/tykit.json and an open Editor: tykit HTTP run-tests"
    echo "  Editor NOT detected → hard failure (exit 2). No automatic batchmode fallback:"
    echo "                        batchmode would grab the lock of an Editor that may well be"
    echo "                        open but simply undetectable. Pass --batch to opt in yourself."
    echo ""
    echo "Exit codes: 0 passed, 1 tests failed (or fewer than the minimum ran), 2 no trustworthy verdict"
    echo "(no Editor, busy / blocked, timed out, unsupported filter, ...). The reason is failure_category"
    echo "in .qq/state/test.json."
}

# ===== 主逻辑 =====

PLATFORM="EditMode"
FILTER=""
ASSEMBLY=""
TIMEOUT=""   # 空 = 按通道和模式定（见 mode_timeout）
FORCE_BATCH=0
EDITOR_UNDETECTED=0
RESUME_JOB=""
PROJECT_ARG=""   # 显式给过 --project 时记下（接着等的提示要带上）
MIN_TESTS=""
ALLOW_ZERO=""
ALLOW_SKIPPED=""

while [ $# -gt 0 ]; do
    case "$1" in
        editmode|EditMode) PLATFORM="EditMode"; shift ;;
        playmode|PlayMode) PLATFORM="PlayMode"; shift ;;
        all|All)           PLATFORM="All"; shift ;;
        --filter|-f)       FILTER="$2"; shift 2 ;;
        --assembly|-a)     ASSEMBLY="$2"; shift 2 ;;
        --timeout|-t)      TIMEOUT="$2"; shift 2 ;;
        --job)             RESUME_JOB="$2"; shift 2 ;;
        --min-tests)       MIN_TESTS="$2"; shift 2 ;;
        --allow-zero)      ALLOW_ZERO=1; shift ;;
        --allow-skipped)   ALLOW_SKIPPED=1; shift ;;
        --batch)           FORCE_BATCH=1; shift ;;
        --project)         PROJECT_DIR="$(cd "$2" && pwd)"; PROJECT_ARG="$PROJECT_DIR"; shift 2 ;;
        --skip-worktree-library-seed) SKIP_WORKTREE_LIBRARY_SEED=1; shift ;;
        --help|-h)         show_help; exit 0 ;;
        *)                 echo -e "${RED}Unknown argument: $1${NC}"; show_help; exit 1 ;;
    esac
done

case "$TIMEOUT" in
    "") ;;
    *[!0-9]*|0) echo -e "${RED}--timeout needs a positive number of seconds: $TIMEOUT${NC}"; exit 1 ;;
esac
case "$MIN_TESTS" in
    "") ;;
    *[!0-9]*) echo -e "${RED}--min-tests needs a non-negative integer: $MIN_TESTS${NC}"; exit 1 ;;
esac
case "$RESUME_JOB" in
    *[[:space:]]*) echo -e "${RED}--job: a job id has no whitespace: $RESUME_JOB${NC}"; exit 1 ;;
esac

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
RUN_ID=$(printf '%s' "$RUN_JSON" | $QQ_PY -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')

accumulate_last_summary() {
    TOTAL_COUNT=$((TOTAL_COUNT + QQ_LAST_TOTAL))
    PASSED_COUNT=$((PASSED_COUNT + QQ_LAST_PASSED))
    FAILED_COUNT=$((FAILED_COUNT + QQ_LAST_FAILED))
    SKIPPED_COUNT=$((SKIPPED_COUNT + QQ_LAST_SKIPPED))
    DURATION_TOTAL=$($QQ_PY - <<PY
total = float("${DURATION_TOTAL}")
last = float("${QQ_LAST_DURATION}")
print(f"{total + last:.6f}")
PY
)
}

# 探测不到 Editor（或探测到了却没有能驱动测试的通道）时硬失败。
# 探测不到 Editor ≠ Editor 没开。探测手段本身会失效（tykit 已从项目移除、Temp/tykit.json 过期、
# 进程枚举拿不到权限），此时 Editor 往往正开着。以前这里静默转 -batchmode，等于默认去抢项目锁：
# 轻则测试直接失败，重则把人正在用的 Editor 搞坏，而调用方看到的只是一句「using batch mode」。
# 所以这里硬失败退非 0，把「要不要拿 batchmode 去撞锁」这个决定交还给调用方（显式 --batch）。
editor_not_detected() {
    QQ_TEST_BACKEND="none"
    QQ_TEST_TRANSPORT="none"
    EDITOR_UNDETECTED=1
    EXIT_CODE=2
    if [ "${QQ_UNITY_CHANNEL_REASON:-}" = unity_cli_unavailable ]; then
        echo -e "${RED}❌ This project's Unity Editor runs the Pipeline server (official Unity CLI), but the unity CLI was not found.${NC}"
        echo "   Install the Unity CLI, or set QQ_UNITY_CLI to its path, then re-run."
        echo -e "${RED}   Refusing to fall back to -batchmode: the Editor is open and holds the project lock.${NC}"
        return 0
    fi
    echo -e "${RED}❌ Unity Editor not detected, or the detection mechanism is unavailable.${NC}"
    echo -e "${RED}   Refusing to fall back to -batchmode: it grabs the project lock, and an Editor${NC}"
    echo -e "${RED}   that is open but undetectable would be broken by it.${NC}"
    echo ""
    echo -e "${BOLD}Project:${NC} $PROJECT_DIR"
    echo -e "${BOLD}Next:${NC}"
    echo "  - open the Unity Editor on this project, then re-run (recommended); with the official Unity CLI,"
    echo "    make sure its Pipeline server runs (Unity menu Window/Pipeline/Start Server); or"
    echo "  - make sure no Editor holds the lock, then re-run with --batch to opt into batchmode."
}

# 官方 CLI 通道才有的参数，别的通道上不能当作生效了
other_channel_args_check() {  # <通道说明>
    if [ -n "$RESUME_JOB" ]; then
        echo -e "${RED}❌ --job resumes an official Unity CLI job; this run goes through $1.${NC}"
        EXIT_CODE=2
        RUN_CATEGORY=invalid_arguments
        return 1
    fi
    if [ -n "$MIN_TESTS$ALLOW_ZERO$ALLOW_SKIPPED" ]; then
        echo -e "${YELLOW}--min-tests / --allow-zero / --allow-skipped only apply to the official Unity CLI channel; ignored for $1${NC}"
    fi
    return 0
}

RUN_CATEGORY=""
RUN_NOTE=""
if [ $FORCE_BATCH -eq 0 ]; then
    qq_unity_channel test
    case "$QQ_UNITY_CHANNEL_RESOLVED" in
        unity-cli)
            run_unity_cli_tests || EXIT_CODE=$?
            ;;
        tykit)
            QQ_TEST_BACKEND="tykit"
            QQ_TEST_TRANSPORT="tykit-http"
            if other_channel_args_check "tykit"; then
                echo -e "${CYAN}Unity Editor detected, triggering tests via tykit${NC}"
                echo ""
                if [ "$PLATFORM" = "All" ]; then
                    reset_last_test_summary
                    trigger_editor_tests "EditMode" "$FILTER" "$ASSEMBLY" "$(mode_timeout EditMode)" || EXIT_CODE=$?
                    accumulate_last_summary
                    echo ""
                    reset_last_test_summary
                    trigger_editor_tests "PlayMode" "$FILTER" "$ASSEMBLY" "$(mode_timeout PlayMode)" || {
                        rc=$?; [ $rc -gt $EXIT_CODE ] && EXIT_CODE=$rc
                    }
                    accumulate_last_summary
                else
                    reset_last_test_summary
                    trigger_editor_tests "$PLATFORM" "$FILTER" "$ASSEMBLY" "$(mode_timeout "$PLATFORM")" || EXIT_CODE=$?
                    accumulate_last_summary
                fi
            fi
            ;;
        *)
            editor_not_detected
            ;;
    esac
else
    QQ_TEST_BACKEND="unity-batch"
    QQ_TEST_TRANSPORT="unity-cli"
    if other_channel_args_check "batch mode"; then
        echo -e "${CYAN}Forcing batch mode (--batch)${NC}"
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
fi

EXTRA_JSON=""
if [ "$QQ_TEST_BACKEND" = unity-cli ] && [ -n "$UCLI_TMP" ]; then
    # 官方 CLI：各模式的摘要（python 写的）合成附加字段；失败名单截到 20 条，测试名不经 bash 拼 JSON
    case "$PLATFORM" in
        EditMode) QQ_TEST_TRANSPORT="unity-cli-job" ;;
        PlayMode) QQ_TEST_TRANSPORT="unity-cli-async" ;;
        *) QQ_TEST_TRANSPORT="unity-cli" ;;
    esac
    MERGED="$("$QQ_PY" "$QQ_UNITY_CLI_PY" merge-summaries --mode "$PLATFORM" --backend unity-cli \
        --transport "$QQ_TEST_TRANSPORT" --category="$UCLI_CATEGORY" --extra-out "$UCLI_TMP/extra.json" \
        "$UCLI_TMP/run-EditMode.json" "$UCLI_TMP/run-PlayMode.json" 2>/dev/null)" || MERGED=""
    if [ -n "$MERGED" ] && [ -s "$UCLI_TMP/extra.json" ]; then
        IFS=$'\t' read -r RUN_CATEGORY TOTAL_COUNT PASSED_COUNT FAILED_COUNT SKIPPED_COUNT DURATION_TOTAL RUN_NOTE <<EOF
$MERGED
EOF
        [ "$RUN_CATEGORY" = "-" ] && RUN_CATEGORY=""
        [ "$RUN_NOTE" = "-" ] && RUN_NOTE=""
        EXTRA_JSON="$(cat "$UCLI_TMP/extra.json")"
    else
        RUN_CATEGORY="${UCLI_CATEGORY:-unity_cli_transport}"
    fi
fi

if [ "$EXIT_CODE" -eq 0 ]; then
    TEST_STATUS="passed"
    FAILURE_CATEGORY=""
    TEST_SUMMARY="Tests passed"
elif [ "$EXIT_CODE" -eq 1 ]; then
    TEST_STATUS="failed"
    FAILURE_CATEGORY="${RUN_CATEGORY:-test_failed}"
    if [ "$FAILURE_CATEGORY" = test_count_below_floor ]; then
        TEST_SUMMARY="Fewer tests ran than the minimum"
    else
        TEST_SUMMARY="Tests failed"
    fi
    # all：判红的那一轮定了整次的结论，另一轮没拿到裁决也要说出来
    if [ -n "$RUN_NOTE" ]; then TEST_SUMMARY="$TEST_SUMMARY; $RUN_NOTE"; fi
elif [ "$EDITOR_UNDETECTED" -eq 1 ]; then
    # 与超时/阻塞分开记，让调用方（qq:test 等上层）能从 run record 直接看出「一个测试都没跑」
    TEST_STATUS="blocked"
    if [ "${QQ_UNITY_CHANNEL_REASON:-}" = unity_cli_unavailable ]; then
        FAILURE_CATEGORY="unity_cli_unavailable"
        TEST_SUMMARY="Unity CLI not found for a Pipeline-enabled Editor; no tests ran"
    else
        FAILURE_CATEGORY="editor_not_detected"
        TEST_SUMMARY="Editor not detected; refused to fall back to batchmode"
    fi
else
    TEST_STATUS="blocked"
    FAILURE_CATEGORY="${RUN_CATEGORY:-test_timeout_or_blocked}"
    case "$FAILURE_CATEGORY" in
        test_job_lost) TEST_SUMMARY="Test job lost (domain reload during the run); no verdict" ;;
        test_in_flight) TEST_SUMMARY="Another test run is in flight in Unity; nothing submitted" ;;
        editor_busy) TEST_SUMMARY="Editor busy or blocked; no verdict" ;;
        editor_mismatch) TEST_SUMMARY="The Editor answering belongs to another project; nothing submitted" ;;
        editor_not_detected) TEST_SUMMARY="No Pipeline server answers for this project; no tests ran" ;;
        unsupported_filter|invalid_arguments) TEST_SUMMARY="Invalid test arguments; nothing submitted" ;;
        config_error) TEST_SUMMARY="Unusable test settings (qq.yaml or the expected-skips list); no verdict" ;;
        test_run_error) TEST_SUMMARY="The test run reported an error; no verdict" ;;
        test_verdict_untrusted) TEST_SUMMARY="Test result could not be trusted; no verdict" ;;
        *) TEST_SUMMARY="Tests blocked or timed out" ;;
    esac
fi

if [ -z "$EXTRA_JSON" ]; then
    EXTRA_JSON="{\"backend\":\"$QQ_TEST_BACKEND\",\"transport\":\"$QQ_TEST_TRANSPORT\",\"mode\":\"$PLATFORM\",\"total\":$TOTAL_COUNT,\"passed\":$PASSED_COUNT,\"failed\":$FAILED_COUNT,\"skipped\":$SKIPPED_COUNT,\"duration_sec\":$DURATION_TOTAL}"
fi
qq_run_record_finish "$RUN_ID" "$TEST_STATUS" "$FAILURE_CATEGORY" "$TEST_SUMMARY" "$EXTRA_JSON" >/dev/null

exit $EXIT_CODE

#!/usr/bin/env bash
# unity-unit-test.sh — 运行 EditMode + PlayMode 单元/集成测试
#
# 用法:
#   ./scripts/unity-unit-test.sh              # 跑 EditMode + PlayMode
#   ./scripts/unity-unit-test.sh editmode     # 只跑 EditMode
#   ./scripts/unity-unit-test.sh playmode     # 只跑 PlayMode
#
# 退出码:
#   0 = 全部通过
#   1 = 有测试失败（unity-test.sh 的 2「没拿到可信裁决」也压成 1；原因看 .qq/state/test.json 的 failure_category）
#
# 不传 --timeout：等待上限由 unity-test.sh 按通道定（tykit EditMode 180 / PlayMode 300 秒；
# 官方 Unity CLI 3600 秒——EditMode 全量就要 9 分钟上下，原来写死的 180 秒在那边一定超时）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/unity-test.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

MODE="${1:-all}"

if [ ! -x "$TEST_SCRIPT" ]; then
    echo -e "${RED}Test script not found: $TEST_SCRIPT${NC}"
    exit 1
fi

FAILED=0

run_editmode() {
    local label="${1:-[1/2]}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${label} EditMode unit tests${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if "$TEST_SCRIPT" editmode; then
        echo -e "${GREEN}✅ EditMode passed${NC}"
    else
        echo -e "${RED}❌ EditMode failed${NC}"
        FAILED=1
    fi
}

run_playmode() {
    local label="${1:-[2/2]}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${label} PlayMode integration tests${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if "$TEST_SCRIPT" playmode; then
        echo -e "${GREEN}✅ PlayMode passed${NC}"
    else
        echo -e "${RED}❌ PlayMode failed${NC}"
        FAILED=1
    fi
}

case "$MODE" in
    editmode) run_editmode "[1/1]" ;;
    playmode) run_playmode "[1/1]" ;;
    all)
        run_editmode "[1/2]"
        if [ "$FAILED" -eq 1 ]; then
            echo -e "${RED}EditMode failed, skipping PlayMode${NC}"
            exit 1
        fi
        run_playmode "[2/2]"
        ;;
    *)
        echo "Usage: $0 [editmode|playmode|all]"
        exit 1
        ;;
esac

if [ "$FAILED" -eq 1 ]; then
    echo -e "${RED}❌ Not all tests passed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ All tests passed${NC}"
exit 0

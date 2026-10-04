#!/usr/bin/env bash
# Stop hook: clean up session temp files
_qq_self="${BASH_SOURCE[0]//\\//}"; [[ "$_qq_self" == */* ]] || _qq_self="./$_qq_self"
_qq_dir="${_qq_self%/*}"; [[ "$_qq_dir" == /* || "$_qq_dir" == [A-Za-z]:/* ]] || _qq_dir="$PWD/$_qq_dir"   # 纯 bash 取目录，不 fork；Claude Code 在 Windows 上用 C:/… 调钩子，盘符路径也是绝对路径
source "$_qq_dir/../platform/detect.sh"

# 快路径：本会话没开过 review gate 就没有东西可清。原来每次收尾都起 python 记一笔「已清理」再 prune，
# 机器一忙就超过本钩子 2 秒的上限被砍（2026-10-04 实测两天 1253 次几乎全部超时），每次收尾白等。
# run 记录在写入时自己会按写入次数 prune，不靠这里。
GATE_FILE="$QQ_TEMP_DIR/review-gate-$PPID"
[[ -f "$GATE_FILE" ]] || exit 0

source "$_qq_dir/../qq-runtime.sh"

rm -f "$GATE_FILE"
qq_run_record_state_only "review_gate" "session-cleanup" "cleared" "Session cleanup removed review gate" >/dev/null
qq_runtime_prune

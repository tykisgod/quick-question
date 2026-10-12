#!/usr/bin/env bash
# SessionEnd hook: clean up this session's temp files
_qq_self="${BASH_SOURCE[0]//\\//}"; [[ "$_qq_self" == */* ]] || _qq_self="./$_qq_self"
_qq_dir="${_qq_self%/*}"; [[ "$_qq_dir" == /* || "$_qq_dir" == [A-Za-z]:/* ]] || _qq_dir="$PWD/$_qq_dir"   # 纯 bash 取目录，不 fork；Claude Code 在 Windows 上用 C:/… 调钩子，盘符路径也是绝对路径
source "$_qq_dir/../platform/detect.sh"

# 会话结束（SessionEnd）时清掉本会话的审查门。原来挂在 Stop 上：Stop 在每轮回答结束时都触发，和 review-gate.sh stop
# 并行跑，先把门删了，门活不过一轮（issue #6 第 1 条）；还每次把 count 写下的 verified 盖成 cleared，/qq:go 又推荐审查。
# 所以这里只删文件、不写 state：state 记的是本会话的审查走到了哪一步，别的会话本来就不认（qq-project-state.py 只认本会话的记录）。
# 会话被强杀时 SessionEnd 不触发，门留在临时目录里，靠立门 2 小时后过期兜底（review-gate.sh 的 check 和 stop 都认过期）。
# 快路径：本会话没开过 review gate 就没有东西可清，不起 python 去 prune。
# run 记录在写入时自己会按写入次数 prune，不靠这里。
# 只清本会话的 gate（按会话 id 命名）：清别的会话的 gate 等于替它放行。拿不到会话 id 就什么都不清。
# 会话 id 先取环境变量 CLAUDE_CODE_SESSION_ID（钩子进程里也有），没有时才读 stdin 的 session_id。
qq_session_id || { qq_hook_read_stdin; qq_session_id; } || exit 0
GATE_FILE="$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
[[ -f "$GATE_FILE" ]] || exit 0

rm -f "$GATE_FILE" "$GATE_FILE.announce"

source "$_qq_dir/../qq-runtime.sh"
qq_runtime_prune

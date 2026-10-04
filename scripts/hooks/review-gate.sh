#!/usr/bin/env bash
# review-gate.sh — Unified review gate manager
# Usage:
#   review-gate.sh check   — PreToolUse: block edits if gate active and not all verified
#   review-gate.sh set     — PostToolUse(Bash): activate gate after review script runs
#   review-gate.sh count   — PostToolUse(Agent): increment verified count
#   review-gate.sh stop    — Stop: block session end if verification incomplete
#   review-gate.sh clear   — Remove gate file unconditionally

set -euo pipefail

_qq_self="${BASH_SOURCE[0]//\\//}"; [[ "$_qq_self" == */* ]] || _qq_self="./$_qq_self"
_qq_dir="${_qq_self%/*}"; [[ "$_qq_dir" == /* || "$_qq_dir" == [A-Za-z]:/* ]] || _qq_dir="$PWD/$_qq_dir"   # 纯 bash 取目录，不 fork；Claude Code 在 Windows 上用 C:/… 调钩子，盘符路径也是绝对路径
SCRIPT_DIR="$_qq_dir"
source "$SCRIPT_DIR/../platform/detect.sh"

GATE_FILE="$QQ_TEMP_DIR/review-gate-$PPID"
ACTION="${1:-check}"

# 快路径：本脚本挂在每一条 Bash、每次 Agent / Edit / Write 和每次收尾上，绝大多数调用什么都不用做。
# 先只用 bash 内建判「这次显然无事」就退出，后面那串读配置、解析 JSON 的 python / git 进程一个都不起。
# 不这样做的代价是实测出来的（2026-10-04）：机器一忙这串进程要 5 秒以上，被 Claude Code 按超时砍掉，
# 两天里 33537 条 Bash 有 8226 条白等了 5 秒以上。判定结果与下面的慢路径一致：
#   set   —— 慢路径只认命令里含 scripts/*review.sh 的调用，原始输入里连 "review.sh" 都没有就不可能命中；
#   其余  —— 慢路径第一件事就是「gate 文件不存在就放行」，这里提前做同一件事。
case "$ACTION" in
  set)
    if [[ -t 0 ]]; then
      _QQ_HOOK_INPUT_CACHE=""
    else
      IFS= read -r -d '' _QQ_HOOK_INPUT_CACHE || true   # 内建读完 stdin，并作为 qq_hook_input 的缓存沿用
    fi
    [[ "$_QQ_HOOK_INPUT_CACHE" == *review.sh* ]] || exit 0
    ;;
  check|count|stop)
    [[ -f "$GATE_FILE" ]] || exit 0
    ;;
esac

source "$SCRIPT_DIR/../qq-runtime.sh"

if [ "$(qq_hook_enabled review_gate)" != "true" ]; then
  exit 0
fi

case "$ACTION" in
  check)
    # PreToolUse (Edit|Write): gate 激活期间阻止修改代码/文档，直到 subagent 验证完成
    [[ -f "$GATE_FILE" ]] || exit 0

    file_path="$(qq_hook_input tool_input.file_path)"

    # 只拦截相关文件类型
    case "$file_path" in
      *.cs) ;;
      */Docs/*.md) ;;
      *) exit 0 ;;
    esac

    IFS=: read -r ts count expected < "$GATE_FILE"

    # 超过 2 小时自动过期
    now=$(date +%s)
    age=$(( now - ${ts:-0} ))
    if [[ $age -gt 7200 ]]; then
      rm -f "$GATE_FILE"
      exit 0
    fi

    # expected=0 表示还没派 subagent，completed < expected 表示还没跑完 → 阻止
    if [[ ${expected:-0} -eq 0 || ${count:-0} -lt ${expected:-0} ]]; then
      qq_run_record_state_only "review_gate" "review-gate-check" "blocked" "Edit blocked until review findings are verified" >/dev/null
      echo "BLOCKED: Review gate active, verification incomplete (${count:-0}/${expected:-0} subagents returned). Code/doc edits are blocked until all verification subagents complete." >&2
      exit 1
    fi
    ;;

  set)
    # PostToolUse (Bash): 检测 review 脚本执行完毕后激活 gate
    cmd="$(qq_hook_input tool_input.command)"

    if echo "$cmd" | grep -qE '\./scripts/(code-review|plan-review|claude-review|claude-plan-review)\.sh'; then
      echo "$(date +%s):0:0" > "$GATE_FILE"
      qq_run_record_state_only "review_gate" "review-gate-set" "locked" "Review gate activated after code review" >/dev/null
      cat <<'HOOK'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"⛔ [REVIEW-GATE 已激活] 流程强制要求：你必须对每个 [Critical] 和 [Moderate] 发现开 subagent 并行验证（subagent_type: general-purpose, model: opus）。在所有验证 subagent 完成前，Edit 工具对 .cs 和 Docs/*.md 文件会被阻止。这是机械约束，不是建议。"}}
HOOK
    fi
    ;;

  count)
    # PostToolUse (Agent): gate 激活期间记录 subagent 完成数
    [[ -f "$GATE_FILE" ]] || exit 0

    IFS=: read -r ts count expected < "$GATE_FILE"
    new_count=$(( ${count:-0} + 1 ))
    echo "${ts}:${new_count}:${expected}" > "$GATE_FILE"

    if [[ ${expected:-0} -gt 0 && $new_count -eq ${expected:-0} ]]; then
      qq_run_record_state_only "review_gate" "review-gate-count" "verified" "All verification subagents completed" >/dev/null
      cat <<HOOK
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[REVIEW-GATE] 所有验证 subagent 已完成（${new_count}/${expected}），Edit gate 放行。"}}
HOOK
    fi
    ;;

  stop)
    # Stop hook: 验证未全部完成时阻止会话退出
    [[ -f "$GATE_FILE" ]] || exit 0

    IFS=: read -r _ts count expected < "$GATE_FILE"

    # 验证已全部完成或还没开始派（expected=0）→ 允许退出
    if [[ ${expected:-0} -eq 0 || ${count:-0} -ge ${expected:-0} ]]; then
      exit 0
    fi

    echo "{\"decision\":\"block\",\"reason\":\"BLOCKED: Review verification incomplete (${count:-0}/${expected:-0} subagents returned). You MUST wait for remaining verification subagents to finish before the session can end.\"}"
    exit 0
    ;;

  clear)
    rm -f "$GATE_FILE"
    ;;

  *)
    echo "Usage: review-gate.sh {check|set|count|stop|clear}" >&2
    exit 1
    ;;
esac

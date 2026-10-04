#!/usr/bin/env bash
# review-gate.sh — Unified review gate manager
# Usage:
#   review-gate.sh check   — PreToolUse: block edits if gate active and not all verified
#   review-gate.sh set     — PostToolUse(Bash): announce a gate the review script just opened
#   review-gate.sh count   — PostToolUse(Agent): increment verified count
#   review-gate.sh stop    — Stop: block session end if verification incomplete
#   review-gate.sh clear   — Remove gate file unconditionally

set -euo pipefail

_qq_self="${BASH_SOURCE[0]//\\//}"; [[ "$_qq_self" == */* ]] || _qq_self="./$_qq_self"
_qq_dir="${_qq_self%/*}"; [[ "$_qq_dir" == /* || "$_qq_dir" == [A-Za-z]:/* ]] || _qq_dir="$PWD/$_qq_dir"   # 纯 bash 取目录，不 fork；Claude Code 在 Windows 上用 C:/… 调钩子，盘符路径也是绝对路径
SCRIPT_DIR="$_qq_dir"
source "$SCRIPT_DIR/../platform/detect.sh"

ACTION="${1:-check}"

# gate 文件按会话 id 命名（见 detect.sh 的 qq_session_id）。拿不到会话 id 就什么都不做：
# 宁可这一回没有门，也不退回全机共用的文件。
qq_hook_read_stdin   # 内建读完 stdin，会话 id 和后面的字段都从这份缓存里取
qq_session_id || exit 0
GATE_FILE="$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"

# 快路径：本脚本挂在每一条 Bash、每次 Agent / Edit / Write 和每次收尾上，绝大多数调用什么都不用做。
# 先只用 bash 内建判「这次显然无事」就退出，后面那串读配置、解析 JSON 的 python / git 进程一个都不起。
# 不这样做的代价是实测出来的（2026-10-04）：机器一忙这串进程要 5 秒以上，被 Claude Code 按超时砍掉，
# 两天里 33537 条 Bash 有 8226 条白等了 5 秒以上。判定结果与下面的慢路径一致：
#   set   —— 只有审查脚本刚立了门（留下 .announce 标记）时才有事做；
#   其余  —— 慢路径第一件事就是「gate 文件不存在就放行」，这里提前做同一件事。
case "$ACTION" in
  set)
    [[ -f "$GATE_FILE.announce" ]] || exit 0
    rm -f "$GATE_FILE.announce"   # 只说一次：先消费标记（钩子可能对同一输入触发两次，也可能被配置关掉）
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
      # 必须 exit 2：PreToolUse 钩子退 1 只算「非阻断错误」，Claude Code 显示一下照样执行编辑（2026-10-04 实测），
      # 这道门原来退 1，从来没真拦住过
      exit 2
    fi
    ;;

  set)
    # PostToolUse (Bash): 门由审查脚本在审查真跑完时自己立（platform/detect.sh 的 qq_review_gate_open），
    # 这里不再从命令文本里猜——命令里只要出现脚本名（heredoc、grep、测试字符串）就会误立门。
    # 只负责把「门已立」告诉模型：快路径见到 .announce 标记就消费掉它，这里说一次。
    [[ -f "$GATE_FILE" ]] || exit 0
    qq_run_record_state_only "review_gate" "review-gate-set" "locked" "Review gate activated after code review" >/dev/null
    cat <<'HOOK'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"⛔ [REVIEW-GATE 已激活] 流程强制要求：你必须对每个 [Critical] 和 [Moderate] 发现开 subagent 并行验证（subagent_type: general-purpose, model: opus）。在所有验证 subagent 完成前，Edit 工具对 .cs 和 Docs/*.md 文件会被阻止。这是机械约束，不是建议。"}}
HOOK
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
    rm -f "$GATE_FILE" "$GATE_FILE.announce"
    ;;

  *)
    echo "Usage: review-gate.sh {check|set|count|stop|clear}" >&2
    exit 1
    ;;
esac

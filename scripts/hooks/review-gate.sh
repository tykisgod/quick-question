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
# 快路径先用环境变量里的 CLAUDE_CODE_SESSION_ID（钩子进程里也有，与 stdin 的 session_id 同值），先不读 stdin：
# 内建 read 读管道是逐字节的，Write 大文件时整份 content 都在 stdin 里，读一遍要一两秒，而绝大多数调用根本没有门。
# 环境里没有时才读 stdin 取 session_id。
qq_session_id || { qq_hook_read_stdin; qq_session_id; } || exit 0
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
    ;;
  check|count|stop)
    [[ -f "$GATE_FILE" ]] || exit 0
    ;;
esac

# 真有门才读 stdin，并以 stdin 的 session_id 为准重新定位门文件（与环境变量不一致时听 stdin 的）
qq_hook_read_stdin
qq_session_id || exit 0
GATE_FILE="$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"

# 门只管主 agent。子 agent 的工具调用带 agent_id，会话 id 却和主会话相同：要是也拦子 agent，
# 并行子 agent 里任何一个跑完审查，都会把其余子 agent 和主 agent 一起锁住；验证子 agent 本来就只读。
# 所以 check 不拦子 agent 的编辑，count 只数主 agent 派出的 Agent，宣告留给主 agent 的下一条 Bash。
# 匹配的是键 "agent_id":，字符串里的同名文本在 JSON 里是 \"agent_id\"，不会误中；主 agent 的 Agent 回包里是 agentId。
IS_SUBAGENT=0
if [[ "$_QQ_HOOK_INPUT_CACHE" =~ \"agent_id\"[[:space:]]*: ]]; then
  IS_SUBAGENT=1
fi
case "$ACTION" in
  set)
    [[ $IS_SUBAGENT -eq 0 && -f "$GATE_FILE.announce" ]] || exit 0
    rm -f "$GATE_FILE.announce"   # 只说一次：先消费标记（钩子可能对同一输入触发两次，也可能被配置关掉）
    ;;
  check|count)
    [[ $IS_SUBAGENT -eq 0 && -f "$GATE_FILE" ]] || exit 0
    ;;
  stop)
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
    file_path="${file_path//\\//}"   # Windows 上 file_path 是 E:\…\Docs\x.md，反斜杠先换成正斜杠，否则 */Docs/*.md 永远匹配不上

    # 只拦截相关文件类型（Windows 文件名不分大小写，Foo.CS 也算）
    shopt -s nocasematch
    case "$file_path" in
      *.cs) ;;
      */Docs/*.md) ;;
      *) exit 0 ;;
    esac
    shopt -u nocasematch

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
    # 只宣告还没开始验证的门（0:0）。审查在后台跑时，标记要等跑完之后的下一条 Bash 才消费，
    # 那时验证可能已经派出去、expected 也写好了，再说「必须开 subagent 验证」就是过时的，会招来重复的一轮验证。
    IFS=: read -r _ts count expected < "$GATE_FILE"
    [[ "${count:-0}" == "0" && "${expected:-0}" == "0" ]] || exit 0
    qq_run_record_state_only "review_gate" "review-gate-set" "locked" "Review gate activated after code review" >/dev/null
    cat <<'HOOK'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"⛔ [REVIEW-GATE 已激活] 流程强制要求：本轮每条 [Critical]、[Moderate] 发现，以及每条标为 Missing / Wrong / Unrequested 的 [Spec] 条目，都必须交给 subagent 核实（subagent_type: general-purpose, model: opus），不能自己看一眼了事。默认把本轮这些条目一起交给一个 subagent 核，逐条给结论；条目多到一个 agent 核不过来才分成几组并行。派完把派出的个数 N 写进门文件。在所有验证 subagent 完成前，Edit 工具对 .cs 和 Docs/*.md 文件会被阻止。这是机械约束，不是建议。"}}
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

#!/usr/bin/env bash
# detect.sh — Platform detection and routing
# Sources the correct platform helper (macos.sh / windows.sh)
# Exports: QQ_PLATFORM, QQ_TEMP_DIR

# 这个文件会被每一个钩子 source，而钩子挂在每条 Bash、每次 Edit/Write、每次收尾上。
# 机器一忙，起一个子进程就要几百毫秒，所以这里能用 bash 内建的就别起进程：
# 平台用 $OSTYPE 判（内建变量），只有它为空时才退回 uname。
case "${OSTYPE:-}" in
  darwin*)              QQ_PLATFORM="macos"   ;;
  msys*|cygwin*|win*)   QQ_PLATFORM="windows" ;;
  linux*)               QQ_PLATFORM="linux"   ;;
  *)
    case "$(uname -s)" in
      Darwin*)              QQ_PLATFORM="macos"   ;;
      MINGW*|MSYS*|CYGWIN*) QQ_PLATFORM="windows" ;;
      Linux*)               QQ_PLATFORM="linux"   ;;
      *)                    QQ_PLATFORM="unknown"  ;;
    esac
    ;;
esac

if [[ -z "${QQ_TEMP_DIR:-}" ]]; then
  if [[ "$QQ_PLATFORM" == "windows" ]]; then
    QQ_TEMP_DIR="${TEMP:-/tmp}"
  else
    QQ_TEMP_DIR="/tmp"
  fi
fi

# Python command: python3 on macOS/Linux, python on Windows (Git Bash).
# The Windows Store python3 alias passes `--version` yet hangs when a script is fed on stdin,
# so --version alone is not enough: skip any python3 that resolves into WindowsApps.
# 上层 qq 脚本已经探测过就直接沿用（export 下来的）；Windows 上 `python` 能解析到就直接用它，
# 不再起一个 python3 进程去探测——那一下在 Store 别名上要半秒。
if [[ -z "${QQ_PY:-}" ]]; then
  if [[ "$QQ_PLATFORM" == "windows" ]] && command -v python >/dev/null 2>&1; then
    QQ_PY="python"
  else
    QQ_PY="python"
    if python3 --version >/dev/null 2>&1; then
      case "$(command -v python3)" in
        */WindowsApps/*) ;;   # Windows Store alias: answers --version but hangs on stdin-fed scripts
        *) QQ_PY="python3" ;;
      esac
    fi
  fi
fi

export QQ_PLATFORM QQ_TEMP_DIR QQ_PY

# ── 会话 id：$QQ_TEMP_DIR 下的门文件 / 标记文件都按它命名 ──
# 不能用 $PPID：Windows Git Bash 下钩子和 Bash 工具里的 $PPID 恒为 1，按它命名等于全机所有会话共用一份门文件
# （一个会话立审查门，所有会话都改不了代码；任何一个会话收尾又把它删掉）。
# 钩子从 stdin JSON 的 session_id 取；技能里的 Bash 从 CLAUDE_CODE_SESSION_ID 取，两者是同一个值。
# 子 agent 的工具调用带的也是主会话的 session_id（2026-10-04 实测），所以子 agent 与主会话共用同一扇门。

# 用内建 read 读完钩子的 stdin，存进 _QQ_HOOK_INPUT_CACHE（qq-runtime.sh 的 qq_hook_input 沿用这份缓存）。
# 必须在父 shell 里调：$(qq_hook_input …) 跑在子 shell 里，那里读到的缓存带不回来。
qq_hook_read_stdin() {
  [[ -n "${_QQ_HOOK_INPUT_CACHE+x}" ]] && return 0
  if [[ -t 0 ]]; then
    _QQ_HOOK_INPUT_CACHE=""
  else
    IFS= read -r -d '' _QQ_HOOK_INPUT_CACHE || true
  fi
}

# 把会话 id 放进 QQ_SESSION_ID；拿不到返回 1。调用方拿不到就不建门、不查门——宁可没有门，也不退回共用文件。
# 只用 bash 内建，不起进程（钩子挂在每条 Bash、每次 Edit/Write 上）。
# 从原始 JSON 里取 "session_id"：字符串里的同名文本在 JSON 里是 \"session_id\"，不会误中；只收文件名安全的字符。
qq_session_id() {
  QQ_SESSION_ID=""
  if [[ "${_QQ_HOOK_INPUT_CACHE:-}" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-][A-Za-z0-9._-]*)\" ]]; then
    QQ_SESSION_ID="${BASH_REMATCH[1]}"
  elif [[ "${CLAUDE_CODE_SESSION_ID:-}" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]; then
    QQ_SESSION_ID="$CLAUDE_CODE_SESSION_ID"
  fi
  [[ -n "$QQ_SESSION_ID" ]]
}

# 审查门由四个审查脚本（code-review / plan-review / claude-review / claude-plan-review）在审查真跑完时
# 自己立，不再由 PostToolUse(Bash) 钩子从命令文本里猜：命令里只要出现脚本名（heredoc、grep、测试字符串）
# 就会误立门，而技能实际调用的 ${CLAUDE_PLUGIN_ROOT}/bin/xxx-review.sh 反倒匹配不上。
# 跑完才立、不在启动时立：审查失败或没有可审的改动就不该锁编辑，后台跑的审查也不该在跑的途中挡住无关编辑。
# 立门时顺手留一个 .announce 标记，review-gate.sh set 见到它就把「门已立、先验证」告诉模型，只说一次。
# 拿不到会话 id（不在 Claude Code 里跑，例如 MCP 宿主）就不立门。总是返回 0，调用方在 set -e 下直接调。
# review_gate 钩子关着（hooks.disable 关的，或 workflow: prototype-loop 连带关的）也不立门：关着时没有钩子拦编辑、
# 数验证数，立了门只会打出一句「每条发现都派子 agent 验证」误导模型，门文件还会被 qq-project-state 读成 locked。
# 配置读不出来按关处理，和钩子一致。
# 可选参数 $1 是技能实际跑的流程（技能参数里的 --workflow，审查脚本原样转过来；可能和配置不同）。门要两头都开着才立：
# 钩子按配置开关，门立了得有钩子守；技能跑的是 prototype-loop 时，hooks.enable 没点名 review_gate 也不立
# （不然主 agent 自己核实、不派验证子 agent，应派数 0 的门一直锁着改文件）。
qq_review_gate_open() {
  qq_session_id || return 0
  source "$_QQ_PLATFORM_DIR/../qq-runtime.sh"
  [[ "$(qq_hook_enabled review_gate)" == "true" ]] || return 0
  [[ -z "${1:-}" || "$(qq_hook_enabled review_gate --workflow "$1")" == "true" ]] || return 0
  local gate="$QQ_TEMP_DIR/review-gate-$QQ_SESSION_ID"
  printf '%s:0:0\n' "$(date +%s)" > "$gate" || return 0
  : > "$gate.announce" || true
  echo ">>> Review gate active for this session: verify each [Critical]/[Moderate] finding and each Missing/Wrong/Unrequested [Spec] item with a subagent before editing .cs / Docs/*.md" >&2
  return 0
}

# QQ_PLATFORM_IMPL 记的是「下面这些函数到底是真实现还是桩」。
# 下游（unity-common.sh 的 is_editor_open_for_project）必须区分「探测过、确实没开」和
# 「根本没人探测过」——桩恒返回 1，照单全收就是把「没实现」读成「没开」。
# 这个事实只有这里知道，所以由这里记下来：让下游自己再拼一遍路径去判断，那份拼接会随
# 调用时的 cwd 失真（相对路径 source 时实测会把有实现误判成没实现），也会在这里的路由
# 规则改动时悄悄和事实脱节。
_QQ_PLATFORM_DIR="${BASH_SOURCE[0]//\\//}"; [[ "$_QQ_PLATFORM_DIR" == */* ]] || _QQ_PLATFORM_DIR="./$_QQ_PLATFORM_DIR"
_QQ_PLATFORM_DIR="${_QQ_PLATFORM_DIR%/*}"   # 纯 bash 取目录，不 fork；下面用的是拼好的绝对路径，不怕调用方 cwd
# Windows 上 Claude Code 用 C:/… 调钩子：盘符路径也是绝对路径，别再拼 $PWD
[[ "$_QQ_PLATFORM_DIR" == /* || "$_QQ_PLATFORM_DIR" == [A-Za-z]:/* ]] || _QQ_PLATFORM_DIR="$PWD/$_QQ_PLATFORM_DIR"
if [[ -f "$_QQ_PLATFORM_DIR/${QQ_PLATFORM}.sh" ]]; then
  QQ_PLATFORM_IMPL=1
  source "$_QQ_PLATFORM_DIR/${QQ_PLATFORM}.sh"
else
  QQ_PLATFORM_IMPL=0
  # Graceful degradation: define stubs that warn and fail
  for _fn in qq_find_unity_binary qq_is_unity_running qq_is_file_locked \
             qq_get_file_mtime qq_activate_unity_window qq_get_editor_log_path; do
    eval "$_fn() { echo \"[qq] WARNING: $_fn not implemented for $QQ_PLATFORM\" >&2; return 1; }"
  done
fi
export QQ_PLATFORM_IMPL

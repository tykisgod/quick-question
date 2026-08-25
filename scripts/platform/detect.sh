#!/usr/bin/env bash
# detect.sh — Platform detection and routing
# Sources the correct platform helper (macos.sh / windows.sh)
# Exports: QQ_PLATFORM, QQ_TEMP_DIR

case "$(uname -s)" in
  Darwin*)              QQ_PLATFORM="macos"   ;;
  MINGW*|MSYS*|CYGWIN*) QQ_PLATFORM="windows" ;;
  Linux*)               QQ_PLATFORM="linux"   ;;
  *)                    QQ_PLATFORM="unknown"  ;;
esac

if [[ -z "${QQ_TEMP_DIR:-}" ]]; then
  if [[ "$QQ_PLATFORM" == "windows" ]]; then
    QQ_TEMP_DIR="${TEMP:-/tmp}"
  else
    QQ_TEMP_DIR="/tmp"
  fi
fi

# Python command: python3 on macOS/Linux, python on Windows (Git Bash)
# Note: Windows Store has a python3 alias that exists but doesn't work,
# so we verify with --version, not just command -v.
if python3 --version >/dev/null 2>&1; then
  QQ_PY="python3"
else
  QQ_PY="python"
fi

export QQ_PLATFORM QQ_TEMP_DIR QQ_PY

# QQ_PLATFORM_IMPL 记的是「下面这些函数到底是真实现还是桩」。
# 下游（unity-common.sh 的 is_editor_open_for_project）必须区分「探测过、确实没开」和
# 「根本没人探测过」——桩恒返回 1，照单全收就是把「没实现」读成「没开」。
# 这个事实只有这里知道，所以由这里记下来：让下游自己再拼一遍路径去判断，那份拼接会随
# 调用时的 cwd 失真（相对路径 source 时实测会把有实现误判成没实现），也会在这里的路由
# 规则改动时悄悄和事实脱节。
_QQ_PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

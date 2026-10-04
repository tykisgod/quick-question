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

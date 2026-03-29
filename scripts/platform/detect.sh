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

if [[ "$QQ_PLATFORM" == "windows" ]]; then
  QQ_TEMP_DIR="${TEMP:-/tmp}"
else
  QQ_TEMP_DIR="/tmp"
fi

export QQ_PLATFORM QQ_TEMP_DIR

_QQ_PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_QQ_PLATFORM_DIR/${QQ_PLATFORM}.sh" ]]; then
  source "$_QQ_PLATFORM_DIR/${QQ_PLATFORM}.sh"
else
  # Graceful degradation: define stubs that warn and fail
  for _fn in qq_find_unity_binary qq_is_unity_running qq_is_file_locked \
             qq_get_file_mtime qq_activate_unity_window qq_get_editor_log_path; do
    eval "$_fn() { echo \"[qq] WARNING: $_fn not implemented for $QQ_PLATFORM\" >&2; return 1; }"
  done
fi

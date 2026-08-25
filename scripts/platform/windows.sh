#!/usr/bin/env bash
# windows.sh — Windows platform helpers (runs in Git Bash)

qq_find_unity_binary() {
    local project_dir="${1:-$PROJECT_DIR}"

    # 1. Environment variable
    if [ -n "${UNITY_PATH:-}" ] && [ -f "$UNITY_PATH" ]; then
        echo "$UNITY_PATH"; return
    fi

    # 2. Unity Hub editors-v2.json (most reliable on Windows)
    local editors_json="$APPDATA/UnityHub/editors-v2.json"
    if [ -f "$editors_json" ]; then
        local win_path
        win_path=$(python -c "
import json
data = json.load(open(r'$(cygpath -w "$editors_json")'))['data']
for e in data:
    if 'location' in e:
        print(e['location'][0]); break
" 2>/dev/null)
        if [ -n "$win_path" ]; then
            local unix_path
            unix_path=$(cygpath -u "$win_path" 2>/dev/null || echo "$win_path")
            if [ -f "$unix_path" ]; then
                echo "$unix_path"; return
            fi
        fi
    fi

    # 3. Unity Hub (standard path)
    local hub_base="/c/Program Files/Unity/Hub/Editor"
    if [ -d "$hub_base" ]; then
        local project_version=""
        local version_file="$project_dir/ProjectSettings/ProjectVersion.txt"
        if [ -f "$version_file" ]; then
            project_version=$(grep "m_EditorVersion:" "$version_file" | sed 's/.*: //')
        fi
        if [ -n "$project_version" ] && [ -f "$hub_base/$project_version/Editor/Unity.exe" ]; then
            echo "$hub_base/$project_version/Editor/Unity.exe"; return
        fi
        local latest
        latest=$(ls -1 "$hub_base" 2>/dev/null | sort -V | tail -1)
        if [ -n "$latest" ] && [ -f "$hub_base/$latest/Editor/Unity.exe" ]; then
            echo "$hub_base/$latest/Editor/Unity.exe"; return
        fi
    fi

    # 4. Check PATH
    if command -v Unity.exe >/dev/null 2>&1; then
        command -v Unity.exe; return
    fi

    echo ""
}

# 传感器不可用时，喊清楚原因并退 2。
#
# 2 这个值不是本文件自造的：scripts/unity-common.sh 的 is_editor_open_for_project 把平台层的
# ≥2 定义为「判不出」并原样上传，调用方据此拒绝跑 batch。所以这里必须 return 而不是 exit ——
# exit 会跳过调用方的收尾（写 run record、置 backend 字段），也会让那一层专为本文件写的分支变成死代码。
#
# 反过来说，1 和 2 的区别全靠那一层认。谁要是把这里的 2 压回 1、或让调用方拿 `if ! ...` 一律读成
# 「没在跑」，静默降级立刻原样复活：一个坏掉的读数会被当成「可以去抢锁了」的批准。
qq_refuse_unity_probe() {
    local project_dir="$1"
    local reason="$2"
    {
        echo "[qq] ❌ 无法判断 Unity Editor 是否为本项目打开：探测手段本身不可用"
        echo "[qq]    原因: $reason"
        echo "[qq]    项目: $project_dir"
        echo "[qq]    本项目的 Temp/UnityLockfile 还在，Editor 很可能正开着，只是查不出来。"
        echo "[qq]    此时若报「没在跑」，调用方会用 -batchmode 另起一个 Unity 抢同一个项目的"
        echo "[qq]    Library 锁：轻则拿到的编译/测试判据不可信，重则写坏正开着的 Editor 的 Library。"
        echo "[qq]    要不要冒这个险交给人来定夺：确认没有 Editor 持有本项目后，按调用方紧接着"
        echo "[qq]    给出的显式 batch 入口重跑（unity-test.sh / unity-compile-smart.sh 是 --batch，"
        echo "[qq]    unity-check.sh 没有这个开关、它会另给兜底做法）。"
    } >&2
    return 2
}

# 返回码契约：
#   0 = 确认本项目的 Editor 正开着
#   1 = 确认没开。只有在「不依赖坏掉的传感器就能下结论」时才给这个答案
#   2 = 传感器不可用，本函数拒绝作答（见 qq_refuse_unity_probe）
qq_is_unity_running() {
    local project_dir="${1:-$PROJECT_DIR}"
    local lock_file="$project_dir/Temp/UnityLockfile"

    # 本项目的锁文件不在 = 没有 Editor 持有这个项目。
    # 这个结论不依赖任何进程枚举工具，所以是可以放心作答的那种「没在跑」。
    [ -f "$lock_file" ] || return 1

    # 从这里往下每一步都要枚举进程。少一件工具，「没在跑」就不再是本函数有资格给出的答案。
    if ! command -v tasklist.exe >/dev/null 2>&1; then
        qq_refuse_unity_probe "$project_dir" "tasklist.exe 不在 PATH 上（Git Bash / hook 环境下常见）"
        return $?
    fi

    if ! tasklist.exe //FI "IMAGENAME eq Unity.exe" 2>/dev/null | grep -qi "Unity.exe"; then
        return 1
    fi

    local have_wmic=0
    command -v wmic.exe >/dev/null 2>&1 && have_wmic=1

    # 归属判定：在跑的这个 Unity，命令行里是不是本项目。
    if [ "$have_wmic" -eq 1 ] &&
       wmic.exe process where "name='Unity.exe'" get CommandLine 2>/dev/null | grep -qF "$project_dir"; then
        return 0
    fi

    # 弱信号：本项目 Temp 下的 compile_status 还新鲜，说明这个 Unity 一直在给本项目写状态。
    local status_file="$project_dir/Temp/compile_status.json"
    if [ -f "$status_file" ]; then
        local now mtime age
        now="$(date +%s)"
        mtime="$(qq_get_file_mtime "$status_file")"
        age=$((now - mtime))
        if [ "$age" -le 300 ]; then
            return 0
        fi
    fi

    # wmic 在、也确实查过命令行，只是没匹配上本项目 —— 这是一次有依据的否定。
    # 边界：wmic 在、但这次调用自身失败（WMI 服务坏 / 权限不够）时，stderr 同样被吞，这里仍会
    # 读成「没匹配上」。没把它一并升成拒答，是因为要分辨就得看 wmic 的退出码，而 wmic 正常无
    # 匹配时的退出码本身就不可靠 —— 押错会让每台还带 wmic 的机器长期假拒答，代价大过这个窄
    # 缺口（须同时满足 wmic 在、wmic 坏、弱信号还过期）。
    if [ "$have_wmic" -eq 1 ]; then
        return 1
    fi

    # wmic 不在。Windows 11 24H2 起微软已把它从系统里移除，本机 `where wmic` 就是空的，
    # 而原来的写法把它的 stderr 吞进 /dev/null，让「命令不存在」和「命令查过了、没匹配上」
    # 长得一模一样。此刻已知的事实是「本项目锁文件在 + 有 Unity 在跑」，最可能的世界恰恰是
    # 「它就是本项目的」，所以这里绝不能顺着往下报「没在跑」。
    qq_refuse_unity_probe "$project_dir" \
        "wmic.exe 不可用（Windows 11 24H2+ 已移除），无法判定在跑的 Unity 属于哪个项目"
    return $?
}

qq_is_file_locked() {
    local file="$1"
    powershell.exe -NoProfile -Command "
        try { \$s = [IO.File]::Open('$file','Open','ReadWrite','None'); \$s.Close(); exit 1 }
        catch { exit 0 }
    " 2>/dev/null
    return $?
}

qq_get_file_mtime() {
    # Git Bash ships GNU stat
    stat -c %Y "$1" 2>/dev/null || echo 0
}

qq_activate_unity_window() {
    powershell.exe -NoProfile -Command "
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WinFocus {
    [DllImport(\"user32.dll\")] public static extern IntPtr GetForegroundWindow();
    [DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport(\"user32.dll\")] public static extern IntPtr FindWindow(string cls, string title);
}
'@
        \$prev = [WinFocus]::GetForegroundWindow()
        \$unity = Get-Process Unity -ErrorAction SilentlyContinue | Select-Object -First 1
        if (\$unity) {
            [WinFocus]::SetForegroundWindow(\$unity.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 500
            [WinFocus]::SetForegroundWindow(\$prev) | Out-Null
        }
    " 2>/dev/null || true
}

qq_get_editor_log_path() {
    echo "$LOCALAPPDATA/Unity/Editor/Editor.log"
}

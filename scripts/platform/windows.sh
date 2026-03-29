#!/usr/bin/env bash
# windows.sh — Windows platform helpers (runs in Git Bash)

qq_find_unity_binary() {
    local project_dir="${1:-$PROJECT_DIR}"

    # 1. Environment variable
    if [ -n "${UNITY_PATH:-}" ] && [ -f "$UNITY_PATH" ]; then
        echo "$UNITY_PATH"; return
    fi

    # 2. Unity Hub (standard path)
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

    # 3. Check PATH
    if command -v Unity.exe >/dev/null 2>&1; then
        command -v Unity.exe; return
    fi

    echo ""
}

qq_is_unity_running() {
    local project_dir="${1:-$PROJECT_DIR}"
    local lock_file="$project_dir/Temp/UnityLockfile"

    # 1) Lock file exists + Unity.exe is running
    if [ -f "$lock_file" ]; then
        if tasklist.exe //FI "IMAGENAME eq Unity.exe" 2>/dev/null | grep -qi "Unity.exe"; then
            # Check if this Unity is for our project
            if wmic.exe process where "name='Unity.exe'" get CommandLine 2>/dev/null | grep -qF "$project_dir"; then
                return 0
            fi
            # Fallback: lock file exists + some Unity is running
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
        fi
    fi
    return 1
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

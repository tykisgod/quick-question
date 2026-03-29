#!/usr/bin/env bash
# macos.sh — macOS platform helpers

qq_find_unity_binary() {
    local project_dir="${1:-$PROJECT_DIR}"

    # 1. Environment variable
    if [ -n "${UNITY_PATH:-}" ] && [ -f "$UNITY_PATH" ]; then
        echo "$UNITY_PATH"; return
    fi

    # 2. Direct installation
    local direct="/Applications/Unity/Unity.app/Contents/MacOS/Unity"
    if [ -f "$direct" ]; then
        echo "$direct"; return
    fi

    # 3. Unity Hub (by version)
    local hub_base="/Applications/Unity/Hub/Editor"
    if [ -d "$hub_base" ]; then
        local project_version=""
        local version_file="$project_dir/ProjectSettings/ProjectVersion.txt"
        if [ -f "$version_file" ]; then
            project_version=$(grep "m_EditorVersion:" "$version_file" | sed 's/.*: //')
        fi
        if [ -n "$project_version" ] && [ -f "$hub_base/$project_version/Unity.app/Contents/MacOS/Unity" ]; then
            echo "$hub_base/$project_version/Unity.app/Contents/MacOS/Unity"; return
        fi
        local latest
        latest=$(ls -1 "$hub_base" 2>/dev/null | sort -V | tail -1)
        if [ -n "$latest" ] && [ -f "$hub_base/$latest/Unity.app/Contents/MacOS/Unity" ]; then
            echo "$hub_base/$latest/Unity.app/Contents/MacOS/Unity"; return
        fi
    fi
    echo ""
}

qq_is_unity_running() {
    local project_dir="${1:-$PROJECT_DIR}"
    local lock_file="$project_dir/Temp/UnityLockfile"

    # 1) Lock file held by a process
    if [ -f "$lock_file" ] && command -v lsof >/dev/null 2>&1; then
        if lsof "$lock_file" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 2) Process args contain projectPath
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -af "/Unity.app/Contents/MacOS/Unity" | grep -F -- "-projectPath $project_dir" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 3) Weak signal: lock file + recent compile_status + Unity process exists
    local status_file="$project_dir/Temp/compile_status.json"
    if [ -f "$lock_file" ] && [ -f "$status_file" ] && command -v pgrep >/dev/null 2>&1; then
        if pgrep -af "/Unity.app/Contents/MacOS/Unity" >/dev/null 2>&1; then
            local now mtime age
            now="$(date +%s)"
            mtime="$(qq_get_file_mtime "$status_file")"
            age=$((now - mtime))
            if [ "$age" -le 300 ]; then
                return 0
            fi
        fi
    fi
    return 1
}

qq_is_file_locked() {
    local file="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof "$file" >/dev/null 2>&1
        return $?
    fi
    return 1
}

qq_get_file_mtime() {
    stat -f %m "$1" 2>/dev/null || echo 0
}

qq_activate_unity_window() {
    osascript -e '
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
        end tell
        tell application "Unity" to activate
        delay 0.5
        tell application frontApp to activate
    ' 2>/dev/null || true
}

qq_get_editor_log_path() {
    echo "$HOME/Library/Logs/Unity/Editor.log"
}

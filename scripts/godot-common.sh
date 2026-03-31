#!/usr/bin/env bash
# godot-common.sh — Godot runtime helpers shared by qq shell scripts

qq_find_godot_binary() {
    local candidates=()
    if [[ -n "${GODOT_BIN:-}" ]]; then
        candidates+=("${GODOT_BIN}")
    fi
    candidates+=(
        godot4
        godot
        /Applications/Godot.app/Contents/MacOS/Godot
        /Applications/Godot_mono.app/Contents/MacOS/Godot
    )

    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

qq_is_godot_project() {
    local project_dir="$1"
    [[ -f "$project_dir/project.godot" ]]
}

qq_detect_godot_test_backend() {
    local project_dir="$1"

    if [[ -f "$project_dir/addons/gut/gut_cmdln.gd" ]]; then
        printf 'gut\n'
        return 0
    fi

    local gdunit_runner=""
    gdunit_runner="$(find "$project_dir/addons" -type f \( -name 'runtest.sh' -o -name 'runtest' \) 2>/dev/null | grep -i 'gdunit' | head -1 || true)"
    if [[ -n "$gdunit_runner" ]]; then
        printf 'gdunit4\n'
        return 0
    fi

    local gdunit_tool=""
    gdunit_tool="$(find "$project_dir/addons" -type f -name 'GdUnitCmdTool.gd' 2>/dev/null | head -1 || true)"
    if [[ -n "$gdunit_tool" ]]; then
        printf 'gdunit4\n'
        return 0
    fi

    printf 'none\n'
    return 0
}

qq_find_gdunit_runner() {
    local project_dir="$1"
    find "$project_dir/addons" -type f \( -name 'runtest.sh' -o -name 'runtest' \) 2>/dev/null | grep -i 'gdunit' | head -1 || true
}

qq_find_gdunit_tool() {
    local project_dir="$1"
    find "$project_dir/addons" -type f -name 'GdUnitCmdTool.gd' 2>/dev/null | head -1 || true
}

qq_import_godot_project() {
    local project_dir="$1"
    local godot_bin="$2"
    local quit_after_msec="${3:-2000}"

    "$godot_bin" --headless --editor --path "$project_dir" --import --quit-after "$quit_after_msec"
}

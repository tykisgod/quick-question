#!/usr/bin/env bash
# install.sh — Install quick-question into a supported engine project
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WITH_PRE_PUSH=0
POLICY_PROFILE="feature"
MODULES=""
WITHOUT_MODULES=""
SYNC_INSTALL=0
RUN_WIZARD=0
INSTALL_PRESET=""
INSTALL_LANGUAGE=""
TARGET=""
ENGINE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-pre-push)
      WITH_PRE_PUSH=1
      shift
      ;;
    --profile)
      if [ "$#" -lt 2 ]; then
        echo "Error: --profile requires one of: lightweight, core, feature, hardening"
        exit 1
      fi
      POLICY_PROFILE="$2"
      shift 2
      ;;
    --profile=*)
      POLICY_PROFILE="${1#--profile=}"
      shift
      ;;
    --modules)
      if [ "$#" -lt 2 ]; then
        echo "Error: --modules requires a comma-separated module list"
        exit 1
      fi
      MODULES="$2"
      shift 2
      ;;
    --modules=*)
      MODULES="${1#--modules=}"
      shift
      ;;
    --without)
      if [ "$#" -lt 2 ]; then
        echo "Error: --without requires a comma-separated module list"
        exit 1
      fi
      WITHOUT_MODULES="$2"
      shift 2
      ;;
    --without=*)
      WITHOUT_MODULES="${1#--without=}"
      shift
      ;;
    --sync)
      SYNC_INSTALL=1
      shift
      ;;
    --wizard)
      RUN_WIZARD=1
      shift
      ;;
    --preset)
      if [ "$#" -lt 2 ]; then
        echo "Error: --preset requires one of: quickstart, daily, stabilize"
        exit 1
      fi
      INSTALL_PRESET="$2"
      shift 2
      ;;
    --preset=*)
      INSTALL_PRESET="${1#--preset=}"
      shift
      ;;
    --language)
      if [ "$#" -lt 2 ]; then
        echo "Error: --language requires one of: en, zh-CN, ja, ko"
        exit 1
      fi
      INSTALL_LANGUAGE="$2"
      shift 2
      ;;
    --language=*)
      INSTALL_LANGUAGE="${1#--language=}"
      shift
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

if [ "$RUN_WIZARD" -eq 1 ] && [ -n "$INSTALL_PRESET" ]; then
  echo "Error: use either --wizard or --preset, not both"
  exit 1
fi

case "$INSTALL_PRESET" in
  ""|quickstart|daily|stabilize) ;;
  *)
    echo "Error: unsupported preset '$INSTALL_PRESET' (expected: quickstart, daily, stabilize)"
    exit 1
    ;;
esac

case "$INSTALL_LANGUAGE" in
  ""|en|zh-CN|ja|ko) ;;
  *)
    echo "Error: unsupported language '$INSTALL_LANGUAGE' (expected: en, zh-CN, ja, ko)"
    exit 1
    ;;
esac

case "$POLICY_PROFILE" in
  lightweight|core|feature|hardening) ;;
  *)
    echo "Error: unsupported profile '$POLICY_PROFILE' (expected: lightweight, core, feature, hardening)"
    exit 1
    ;;
esac

# ── Platform check ──
case "$(uname -s)" in
  Darwin*)              QQ_PLATFORM="macos" ;;
  MINGW*|MSYS*|CYGWIN*) QQ_PLATFORM="windows" ;;
  *)
    echo "Error: unsupported platform ($(uname -s)). quick-question supports macOS and Windows."
    exit 1
    ;;
esac

# ── Dependency check ──
MISSING=""
command -v curl  &>/dev/null || MISSING="$MISSING curl"
command -v python3 &>/dev/null || MISSING="$MISSING python3"
command -v jq   &>/dev/null || MISSING="$MISSING jq"
if [ -n "$MISSING" ]; then
  echo "Error: missing required tools:$MISSING"
  if [[ "$QQ_PLATFORM" == "macos" ]]; then
    echo "Install with: brew install$MISSING"
  else
    echo "Install with: winget install$MISSING"
    echo "Or ensure Git for Windows is installed (provides bash, curl)"
  fi
  exit 1
fi

# ── Find supported project ──
if [ -z "$TARGET" ]; then
  TARGET=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

ENGINE="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" detect --project "$TARGET" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("engine",""))' 2>/dev/null || true)"
if [ -z "$ENGINE" ]; then
  echo "Error: $TARGET is not a supported engine project"
  echo "Usage: ./install.sh /path/to/<supported-engine-project>"
  exit 1
fi

echo "Installing quick-question to: $TARGET"
echo "  Engine: $ENGINE"
echo ""

# ── Shared config (needed before module resolution) ──
if [ "$RUN_WIZARD" -eq 1 ] || [ -n "$INSTALL_PRESET" ]; then
  ONBOARD_ARGS=(
    apply
    --project "$TARGET"
    --engine "$ENGINE"
    --template "$SCRIPT_DIR/templates/qq.yaml.example"
  )
  if [ "$RUN_WIZARD" -eq 1 ]; then
    ONBOARD_ARGS+=(--interactive)
  fi
  if [ -n "$INSTALL_PRESET" ]; then
    ONBOARD_ARGS+=(--preset "$INSTALL_PRESET")
  fi
  if [ -n "$INSTALL_LANGUAGE" ]; then
    ONBOARD_ARGS+=(--language "$INSTALL_LANGUAGE")
  fi
  python3 "$SCRIPT_DIR/scripts/qq-onboard.py" "${ONBOARD_ARGS[@]}"
elif [ ! -f "$TARGET/qq.yaml" ]; then
  python3 - "$SCRIPT_DIR/templates/qq.yaml.example" "$TARGET/qq.yaml" "$POLICY_PROFILE" << 'PYEOF'
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
default_profile = sys.argv[3]

lines = template_path.read_text(encoding="utf-8").splitlines()
patched = []
for line in lines:
    if line.startswith("default_profile:"):
        patched.append(f"default_profile: {default_profile}")
    else:
        patched.append(line)
target_path.write_text("\n".join(patched) + "\n", encoding="utf-8")
PYEOF
  echo "  qq.yaml: created from template (default_profile=$POLICY_PROFILE)"
else
  echo "  qq.yaml: already exists"
fi
echo "  local overrides: use .qq/local.yaml for per-worktree task mode"

INSTALL_PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/qq-install-plan.XXXXXX.json")"
INSTALL_PLAN_ARGS=(
  resolve
  --repo-root "$SCRIPT_DIR"
  --project "$TARGET"
)
if [ "$WITH_PRE_PUSH" -eq 1 ]; then
  INSTALL_PLAN_ARGS+=(--with-pre-push)
fi
if [ "$SYNC_INSTALL" -eq 1 ]; then
  INSTALL_PLAN_ARGS+=(--sync)
fi
if [ -n "$MODULES" ]; then
  INSTALL_PLAN_ARGS+=(--modules "$MODULES")
fi
if [ -n "$WITHOUT_MODULES" ]; then
  INSTALL_PLAN_ARGS+=(--without "$WITHOUT_MODULES")
fi
python3 "$SCRIPT_DIR/scripts/qq_internal_install.py" "${INSTALL_PLAN_ARGS[@]}" > "$INSTALL_PLAN_FILE"

mkdir -p "$TARGET"
python3 - "$SCRIPT_DIR" "$TARGET" "$INSTALL_PLAN_FILE" << 'PYEOF'
import json
import os
import shutil
import stat
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
target_root = Path(sys.argv[2]).resolve()
plan = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))

for entry in plan.get("entries") or []:
    source = (repo_root / str(entry["source"])).resolve()
    destination = (target_root / str(entry["target"])).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    if destination.suffix in {".sh", ".py"} or destination.name in {"pre-push"}:
        destination.chmod(destination.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
PYEOF

SELECTED_MODULES="$(python3 - "$INSTALL_PLAN_FILE" << 'PYEOF'
import json, sys
payload = json.load(open(sys.argv[1]))
print(",".join(payload.get("selectedModules") or []))
PYEOF
)"
SCRIPT_COUNT="$(python3 - "$INSTALL_PLAN_FILE" << 'PYEOF'
import json, sys
payload = json.load(open(sys.argv[1]))
count = 0
for entry in payload.get("entries") or []:
    target = str(entry.get("target") or "")
    if target.startswith("scripts/"):
        count += 1
print(count)
PYEOF
)"
PLAN_SYNC_ENABLED="$(python3 - "$INSTALL_PLAN_FILE" << 'PYEOF'
import json, sys
payload = json.load(open(sys.argv[1]))
print("1" if payload.get("sync") else "0")
PYEOF
)"
echo "  Modules: $SELECTED_MODULES"
echo "  Scripts: $SCRIPT_COUNT managed files selected by install modules"
echo "  Skills + Hooks: behavior still comes from qq.yaml packs and the qq plugin"

has_install_module() {
  python3 - "$INSTALL_PLAN_FILE" "$1" <<'PYEOF'
import json, sys
payload = json.load(open(sys.argv[1]))
print("true" if sys.argv[2] in (payload.get("selectedModules") or []) else "false")
PYEOF
}

HAS_PROJECT_DOCS="$(has_install_module project-docs)"
HAS_HOST_CLAUDE="$(has_install_module host-claude)"
HAS_HOST_CODEX="$(has_install_module host-codex)"
HAS_HOST_MCP="$(has_install_module host-mcp)"
HAS_GIT_PRE_PUSH="$(has_install_module git-pre-push)"
HAS_ENGINE_GODOT="$(has_install_module engine-godot)"
HAS_ENGINE_UNREAL="$(has_install_module engine-unreal)"
HAS_ENGINE_SBOX="$(has_install_module engine-sbox)"

SPECIAL_MANAGED_FILE_LIST="$(mktemp "${TMPDIR:-/tmp}/qq-install-managed.XXXXXX.txt")"
python3 - "$INSTALL_PLAN_FILE" "$SPECIAL_MANAGED_FILE_LIST" <<'PYEOF'
import json, sys

payload = json.load(open(sys.argv[1]))
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    for target in payload.get("managedTargets") or []:
        handle.write(str(target) + "\n")
PYEOF

# ── Pre-push hook (optional/module-gated) ──
if [ "$HAS_GIT_PRE_PUSH" = "true" ]; then
  git -C "$TARGET" config core.hooksPath .githooks
  echo "  Pre-push: installed (runs tests before every push, skip with --no-verify)"
else
  echo "  Pre-push: skipped"
fi

# ── Templates ──
if [ "$HAS_PROJECT_DOCS" = "true" ]; then
  if [ ! -f "$TARGET/CLAUDE.md" ]; then
    cp "$SCRIPT_DIR/templates/CLAUDE.md.example" "$TARGET/CLAUDE.md"
    echo "  CLAUDE.md: created from template"
  else
    echo "  CLAUDE.md: already exists — check templates/CLAUDE.md.example for engine-specific rules you may want to add"
  fi

  if [ ! -f "$TARGET/AGENTS.md" ]; then
    cp "$SCRIPT_DIR/templates/AGENTS.md.example" "$TARGET/AGENTS.md"
    echo "  AGENTS.md: created from template"
  else
    echo "  AGENTS.md: already exists — check templates/AGENTS.md.example for review rules you may want to add"
  fi
else
  echo "  Project docs: skipped (project-docs module not selected)"
fi

# ── Claude local permission baseline ──
if [ "$HAS_HOST_CLAUDE" = "true" ]; then
CLAUDE_LOCAL_SETTINGS="$TARGET/.claude/settings.local.json"
mkdir -p "$TARGET/.claude"
python3 - "$CLAUDE_LOCAL_SETTINGS" "$HAS_HOST_CODEX" << 'PYEOF'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
has_codex = sys.argv[2] == "true"
data = {}
if settings_path.exists():
    try:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        data = {}

if not isinstance(data, dict):
    data = {}

permissions = data.setdefault("permissions", {})
allow = permissions.setdefault("allow", [])
if not isinstance(allow, list):
    allow = []
    permissions["allow"] = allow

baseline = [
    "Bash(python3 ./scripts/qq-config.py:*)",
    "Bash(python3 scripts/qq-config.py:*)",
    "Bash(python3 ./scripts/qq-context-capsule.py:*)",
    "Bash(python3 scripts/qq-context-capsule.py:*)",
    "Bash(python3 ./scripts/qq-project-state.py:*)",
    "Bash(python3 scripts/qq-project-state.py:*)",
    "Bash(python3 ./scripts/qq-worktree.py:*)",
    "Bash(python3 scripts/qq-worktree.py:*)",
    "Bash(python3 ./scripts/qq-doctor.py:*)",
    "Bash(python3 scripts/qq-doctor.py:*)",
    "Bash(python3 ./scripts/qq-preflight.py:*)",
    "Bash(python3 scripts/qq-preflight.py:*)",
    "Bash(./scripts/qq-doctor.sh:*)",
    "Bash(scripts/qq-doctor.sh:*)",
    "Bash(./scripts/qq-compile.sh:*)",
    "Bash(scripts/qq-compile.sh:*)",
    "Bash(./scripts/qq-test.sh:*)",
    "Bash(scripts/qq-test.sh:*)",
    "Bash(./scripts/unity-compile-smart.sh:*)",
    "Bash(scripts/unity-compile-smart.sh:*)",
    "Bash(./scripts/unity-test.sh:*)",
    "Bash(scripts/unity-test.sh:*)",
    "Bash(./scripts/godot-compile.sh:*)",
    "Bash(scripts/godot-compile.sh:*)",
    "Bash(./scripts/godot-test.sh:*)",
    "Bash(scripts/godot-test.sh:*)",
    "Bash(./scripts/unreal-compile.sh:*)",
    "Bash(scripts/unreal-compile.sh:*)",
    "Bash(./scripts/unreal-test.sh:*)",
    "Bash(scripts/unreal-test.sh:*)",
    "Bash(./scripts/sbox-compile.sh:*)",
    "Bash(scripts/sbox-compile.sh:*)",
    "Bash(./scripts/sbox-test.sh:*)",
    "Bash(scripts/sbox-test.sh:*)",
]

if has_codex:
    baseline.extend(
        [
            "Bash(python3 ./scripts/qq-codex-mcp.py:*)",
            "Bash(python3 scripts/qq-codex-mcp.py:*)",
            "Bash(python3 ./scripts/qq-codex-exec.py:*)",
            "Bash(python3 scripts/qq-codex-exec.py:*)",
        ]
    )

existing = {str(item) for item in allow}
for item in baseline:
    if item not in existing:
        allow.append(item)

settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYEOF
echo "  Claude permissions: added baseline allow rules for qq state/doctor/compile/test commands"
else
  echo "  Claude permissions: skipped (host-claude module not selected)"
fi

# ── Built-in MCP bridge ──
if [ "$HAS_HOST_MCP" = "true" ]; then
MCP_CONFIG="$TARGET/.mcp.json"
BRIDGE_SCRIPT="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field bridgeScript --project "$TARGET" --engine "$ENGINE")"
BRIDGE_SERVER_NAME="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field bridgeServerName --project "$TARGET" --engine "$ENGINE")"
python3 - "$MCP_CONFIG" "$BRIDGE_SCRIPT" "$BRIDGE_SERVER_NAME" << 'PYEOF'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
bridge_name = sys.argv[2]
server_name = sys.argv[3]
data = {}
if config_path.exists():
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        data = {}

if not isinstance(data, dict):
    data = {}

servers = data.setdefault("mcpServers", {})
servers[server_name] = {
    "command": "python3",
    "args": [
        str((config_path.parent / "scripts" / bridge_name).resolve()),
        "--project",
        str(config_path.parent.resolve())
    ],
    "cwd": str(config_path.parent.resolve())
}

config_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYEOF
echo "  MCP: .mcp.json now points $ENGINE to the built-in project-local bridge"
else
  echo "  MCP: skipped (host-mcp module not selected)"
fi

# ── Engine-side bridge assets ──
if [[ "$ENGINE" == "godot" && "$HAS_ENGINE_GODOT" == "true" ]]; then
  ADDON_SOURCE_DIR="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field engineSupportSourceDir --project "$TARGET" --engine "$ENGINE")"
  ADDON_TARGET_DIR="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field engineSupportTargetDir --project "$TARGET" --engine "$ENGINE")"
  ADDON_PLUGIN_PATH="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field editorPluginConfigPath --project "$TARGET" --engine "$ENGINE")"
  if [[ -n "$ADDON_SOURCE_DIR" && -d "$SCRIPT_DIR/$ADDON_SOURCE_DIR" && -n "$ADDON_TARGET_DIR" ]]; then
    mkdir -p "$TARGET/$(dirname "$ADDON_TARGET_DIR")"
    rm -rf "$TARGET/$ADDON_TARGET_DIR"
    cp -R "$SCRIPT_DIR/$ADDON_SOURCE_DIR" "$TARGET/$ADDON_TARGET_DIR"
    python3 - "$TARGET/project.godot" "$ADDON_PLUGIN_PATH" << 'PYEOF'
import re
import sys
from pathlib import Path

project_path = Path(sys.argv[1])
plugin_path = sys.argv[2]
lines = project_path.read_text(encoding="utf-8").splitlines()
out: list[str] = []
in_section = False
section_found = False
enabled_written = False

def build_enabled_line(existing: str = "") -> str:
    plugins = re.findall(r'"([^"]+)"', existing)
    if plugin_path not in plugins:
        plugins.append(plugin_path)
    joined = ", ".join(f'"{item}"' for item in plugins)
    return f"enabled=PackedStringArray({joined})"

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_section and not enabled_written:
            out.append(build_enabled_line())
            enabled_written = True
        in_section = stripped == "[editor_plugins]"
        section_found = section_found or in_section
        out.append(line)
        continue
    if in_section and stripped.startswith("enabled="):
        out.append(build_enabled_line(line))
        enabled_written = True
        continue
    out.append(line)

if section_found and not enabled_written:
    out.append(build_enabled_line())
elif not section_found:
    if out and out[-1] != "":
        out.append("")
    out.append("[editor_plugins]")
    out.append(build_enabled_line())

project_path.write_text("\n".join(out) + "\n", encoding="utf-8")
PYEOF
    echo "  Godot addon: installed $ADDON_TARGET_DIR and enabled $ADDON_PLUGIN_PATH"
    find "$TARGET/$ADDON_TARGET_DIR" -type f | sed "s#^$TARGET/##" >> "$SPECIAL_MANAGED_FILE_LIST"
  else
    echo "  Godot addon: source assets not found — install incomplete"
  fi
elif [[ "$ENGINE" == "unreal" && "$HAS_ENGINE_UNREAL" == "true" ]]; then
  REQUIRED_PLUGINS_JSON="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field requiredProjectPlugins --project "$TARGET" --engine "$ENGINE")"
  SUPPORT_SOURCE_DIR="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field engineSupportSourceDir --project "$TARGET" --engine "$ENGINE")"
  SUPPORT_TARGET_DIR="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field engineSupportTargetDir --project "$TARGET" --engine "$ENGINE")"
  STARTUP_COMMAND="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field editorBridgeStartupCommand --project "$TARGET" --engine "$ENGINE")"
  UPROJECT_FILE="$(python3 - "$TARGET" "$REQUIRED_PLUGINS_JSON" << 'PYEOF'
import json
import sys
from pathlib import Path

project_root = Path(sys.argv[1])
required = [str(item) for item in json.loads(sys.argv[2]) if str(item)]
project_files = sorted(project_root.glob("*.uproject"))
if not project_files:
    raise SystemExit("No .uproject file found in target project")

project_path = project_files[0]
data = json.loads(project_path.read_text(encoding="utf-8"))
plugins = data.get("Plugins")
if not isinstance(plugins, list):
    plugins = []
    data["Plugins"] = plugins

existing: dict[str, dict] = {}
ordered: list[dict] = []
for item in plugins:
    if isinstance(item, dict):
        name = str(item.get("Name") or "").strip()
        if name:
            existing[name] = item
            ordered.append(item)
            continue
    ordered.append(item)

for name in required:
    plugin = existing.get(name)
    if plugin is None:
        plugin = {"Name": name, "Enabled": True}
        ordered.append(plugin)
        existing[name] = plugin
    else:
        plugin["Enabled"] = True

data["Plugins"] = ordered
project_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(project_path.name)
PYEOF
)"
  REQUIRED_PLUGINS_LABEL="$(python3 - "$REQUIRED_PLUGINS_JSON" << 'PYEOF'
import json
import sys

plugins = [str(item) for item in json.loads(sys.argv[1]) if str(item)]
print(", ".join(plugins))
PYEOF
)"
  echo "  Unreal project plugins: enabled $REQUIRED_PLUGINS_LABEL in $UPROJECT_FILE"
  if [[ -n "$SUPPORT_SOURCE_DIR" && -d "$SCRIPT_DIR/$SUPPORT_SOURCE_DIR" && -n "$SUPPORT_TARGET_DIR" ]]; then
    mkdir -p "$TARGET/$SUPPORT_TARGET_DIR"
    cp -R "$SCRIPT_DIR/$SUPPORT_SOURCE_DIR"/. "$TARGET/$SUPPORT_TARGET_DIR/"
    echo "  Unreal editor bridge: installed support scripts into $SUPPORT_TARGET_DIR"
    find "$TARGET/$SUPPORT_TARGET_DIR" -type f | sed "s#^$TARGET/##" >> "$SPECIAL_MANAGED_FILE_LIST"
  else
    echo "  Unreal editor bridge: support assets not found — install incomplete"
  fi
  mkdir -p "$TARGET/Config"
  python3 - "$TARGET/Config/DefaultEngine.ini" "$STARTUP_COMMAND" << 'PYEOF'
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
startup_command = sys.argv[2].strip()
section_name = "[/Script/PythonScriptPlugin.PythonScriptPluginSettings]"
startup_line = f"+StartupScripts={startup_command}"

lines = config_path.read_text(encoding="utf-8").splitlines() if config_path.exists() else []
out: list[str] = []
in_section = False
section_found = False
startup_written = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_section and not startup_written:
            out.append(startup_line)
            startup_written = True
        in_section = stripped == section_name
        section_found = section_found or in_section
        out.append(line)
        continue
    if in_section and stripped.startswith("+StartupScripts=") and startup_command in stripped:
        if not startup_written:
            out.append(startup_line)
            startup_written = True
        continue
    out.append(line)

if section_found and not startup_written:
    out.append(startup_line)
elif not section_found:
    if out and out[-1] != "":
        out.append("")
    out.append(section_name)
    out.append(startup_line)

config_path.write_text("\n".join(out) + "\n", encoding="utf-8")
PYEOF
  echo "  Unreal editor bridge: configured Python startup hook in Config/DefaultEngine.ini"
elif [[ "$ENGINE" == "sbox" && "$HAS_ENGINE_SBOX" == "true" ]]; then
  SUPPORT_SOURCE_DIR="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field engineSupportSourceDir --project "$TARGET" --engine "$ENGINE")"
  SUPPORT_TARGET_DIR="$(python3 "$SCRIPT_DIR/scripts/qq_engine.py" field engineSupportTargetDir --project "$TARGET" --engine "$ENGINE")"
  if [[ -n "$SUPPORT_SOURCE_DIR" && -d "$SCRIPT_DIR/$SUPPORT_SOURCE_DIR" && -n "$SUPPORT_TARGET_DIR" ]]; then
    mkdir -p "$TARGET/$SUPPORT_TARGET_DIR"
    cp -R "$SCRIPT_DIR/$SUPPORT_SOURCE_DIR"/. "$TARGET/$SUPPORT_TARGET_DIR/"
    echo "  S&box editor bridge: installed support scripts into $SUPPORT_TARGET_DIR"
    find "$TARGET/$SUPPORT_TARGET_DIR" -type f | sed "s#^$TARGET/##" >> "$SPECIAL_MANAGED_FILE_LIST"
  else
    echo "  S&box editor bridge: support assets not found — install incomplete"
  fi
fi

# ── Engine-side dependency wiring ──
MANIFEST="$TARGET/Packages/manifest.json"
TYKIT_REF="https://github.com/tykisgod/tykit.git#84b129b026d3b725f5f7dd21d59a5fe9d206850c"
if [[ "$ENGINE" == "unity" && -f "$MANIFEST" ]]; then
  TYKIT_ACTION=$(python3 - "$MANIFEST" "$TYKIT_REF" << 'PYEOF'
import json, sys
manifest_path, tykit_ref = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    m = json.load(f)
deps = m.setdefault('dependencies', {})
current = deps.get('com.tyk.tykit')
if current == tykit_ref:
    print("current")
    raise SystemExit(0)
deps['com.tyk.tykit'] = tykit_ref
with open(manifest_path, 'w') as f:
    json.dump(m, f, indent=2)
    f.write('\n')
print("added" if current is None else "updated")
PYEOF
)
  case "$TYKIT_ACTION" in
    current)
      echo "  tykit: already pinned to tested release"
      ;;
    added)
      echo "  tykit: added to manifest.json"
      ;;
    updated)
      echo "  tykit: updated existing dependency to tested release"
      ;;
    *)
      echo "  tykit: manifest updated"
      ;;
  esac
elif [[ "$ENGINE" == "unity" ]]; then
  echo "  tykit: Packages/manifest.json not found — please add com.tyk.tykit manually"
else
  echo "  engine dependency: no built-in package pinning required for $ENGINE"
fi

# ── Install state + sync ──
INSTALL_STATE_PATH="$TARGET/.qq/install-state.json"
python3 - "$TARGET" "$INSTALL_STATE_PATH" "$INSTALL_PLAN_FILE" "$SPECIAL_MANAGED_FILE_LIST" "$PLAN_SYNC_ENABLED" > /dev/null << 'PYEOF'
import json
import os
import shutil
import sys
from pathlib import Path

project_dir = Path(sys.argv[1]).resolve()
state_path = Path(sys.argv[2]).resolve()
plan = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
managed_list_path = Path(sys.argv[4]).resolve()
sync_enabled = sys.argv[5] == "1"

managed_files = []
if managed_list_path.is_file():
    managed_files = [line.strip() for line in managed_list_path.read_text(encoding="utf-8").splitlines() if line.strip()]
managed_files = sorted(dict.fromkeys(managed_files))

previous = {}
if state_path.is_file():
    try:
        previous = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        previous = {}
if not isinstance(previous, dict):
    previous = {}

old_files = {str(item) for item in previous.get("managedFiles") or [] if str(item)}
new_files = set(managed_files)
removed: list[str] = []

if sync_enabled:
    stale = sorted(old_files - new_files)
    for rel in stale:
        path = (project_dir / rel).resolve()
        try:
            path.relative_to(project_dir)
        except ValueError:
            continue
        if path.is_file() or path.is_symlink():
            path.unlink()
            removed.append(rel)
        parent = path.parent
        while parent != project_dir and parent.exists():
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent

state_path.parent.mkdir(parents=True, exist_ok=True)
payload = {
    "engine": str(plan.get("engine") or ""),
    "profile": str(plan.get("profile") or ""),
    "selectedModules": list(plan.get("selectedModules") or []),
    "defaultModules": list(plan.get("defaultModules") or []),
    "requiredModules": list(plan.get("requiredModules") or []),
    "hosts": list(plan.get("hosts") or []),
    "managedFiles": managed_files,
    "syncEnabled": sync_enabled,
    "removedFiles": removed,
}
state_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"removedFiles": removed}))
PYEOF

if [ "$HAS_GIT_PRE_PUSH" = "false" ] && [ "$PLAN_SYNC_ENABLED" -eq 1 ]; then
  CURRENT_HOOKS_PATH="$(git -C "$TARGET" config --get core.hooksPath 2>/dev/null || true)"
  if [ "$CURRENT_HOOKS_PATH" = ".githooks" ]; then
    git -C "$TARGET" config --unset core.hooksPath || true
    echo "  Pre-push: removed .githooks core.hooksPath during sync"
  fi
fi

echo ""
echo "Installation complete!"
echo ""
echo "Skills (provided by the qq plugin — 23 total):"
echo "  /qq:go                  — Entry point: detect stage, suggest next step"
echo "  /qq:design              — Write game design document"
echo "  /qq:plan                — Generate technical implementation plan"
echo "  /qq:execute             — Smart implementation from plan"
echo "  /qq:add-tests           — Author targeted test coverage"
echo "  /qq:test                — Run unit + integration tests"
echo "  /qq:best-practice       — Quick 18-rule Unity check"
echo "  /qq:codex-code-review   — Cross-model code review"
echo "  ... and 15 more (see /skills in Claude Code)"
echo ""
echo "Prerequisites:"
if [ "$HAS_HOST_CLAUDE" = "true" ]; then
  echo "  - Claude Code CLI (claude)"
fi
if [ "$HAS_HOST_CODEX" = "true" ]; then
  echo "  - Codex CLI (optional, for cross-model review): npm install -g @openai/codex"
fi
echo ""
echo "Next steps:"
if [ "$HAS_HOST_CLAUDE" = "true" ]; then
  echo "  1. In Claude Code, register the marketplace and install the plugin:"
  echo "       /plugin marketplace add tykisgod/quick-question"
  echo "       /plugin install qq@quick-question-marketplace"
else
  echo "  1. Install the qq host/plugin you plan to use."
fi
if [[ "$ENGINE" == "unity" ]]; then
  echo "  2. Open Unity — tykit will auto-start"
elif [[ "$ENGINE" == "godot" ]]; then
  echo "  2. Open Godot — the built-in qq editor bridge addon is already installed and enabled"
  echo "     Also ensure your preferred test backend (GUT or GdUnit4) is installed under addons/"
elif [[ "$ENGINE" == "sbox" ]]; then
  echo "  2. Open s&box once so project targets are generated and the built-in qq editor bridge can start"
  echo "     qq now wires direct dotnet build/test plus a typed project-local MCP bridge for S&box"
else
  echo "  2. Open Unreal Editor — project plugins were enabled for qq rich automation"
  echo "     If the project was already open, restart Unreal so PythonScriptPlugin and EditorScriptingUtilities reload"
fi
if [ "$HAS_HOST_MCP" = "true" ]; then
  echo "  3. The project-local built-in MCP bridge is now wired in .mcp.json"
else
  echo "  3. Built-in MCP wiring was skipped by install modules"
fi
echo "  4. Shared default_profile is set to $POLICY_PROFILE in qq.yaml"
echo "  5. Optional: set .qq/local.yaml if this worktree needs prototype/fix/hardening mode"
echo "  6. Run ./scripts/qq-doctor.sh to verify direct path + installed modules"
echo "  7. Edit an engine runtime file — auto-compilation hook will verify if installed"
echo "  8. Type /qq:add-tests to author coverage, or /qq:test to run it"
if [ "$HAS_HOST_CODEX" = "true" ]; then
  echo ""
  echo "Optional Codex MCP setup:"
  echo "  python3 ./scripts/qq-codex-mcp.py install --pretty"
  echo "  python3 ./scripts/qq-codex-mcp.py status --pretty"
  echo "  python3 ./scripts/qq-codex-exec.py --dry-run --pretty 'Summarize current qq state'"
fi

rm -f "$INSTALL_PLAN_FILE" "$SPECIAL_MANAGED_FILE_LIST"

#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from qq_engine import (
    bridge_host_state_file,
    bridge_script,
    bridge_server_name,
    engine_metadata,
    host_validation_reason,
    recommended_compile_action,
    resolve_project_engine,
)
from qq_internal_config import ConfigError, read_optional_structured, resolve_project_config
from qq_internal_git import apply_safe_git_hooks_fix, check_git_hooks
from qq_internal_install import load_install_state, resolve_install_plan, install_state_path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_REGISTRY_PATH = SCRIPT_DIR / "qq-capabilities.json"


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_optional_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        return load_json(path)
    except (OSError, json.JSONDecodeError):
        return {}


def is_unity_project(project_dir: Path) -> bool:
    return (project_dir / "ProjectSettings" / "ProjectVersion.txt").is_file()


def has_repo_dev_docker(project_dir: Path) -> bool:
    return (project_dir / "scripts" / "docker-dev.sh").is_file() and (project_dir / ".devcontainer" / "devcontainer.json").is_file()


def shell_join(parts: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def build_host_recommended_action(project_dir: Path) -> str:
    if (project_dir / "scripts" / "qq-compile.sh").is_file():
        return "./scripts/qq-compile.sh"
    if (project_dir / "scripts" / "unity-compile-smart.sh").is_file():
        return "./scripts/unity-compile-smart.sh"
    if (project_dir / "scripts" / "qq-project-state.py").is_file():
        return "python3 ./scripts/qq-project-state.py --pretty"
    return ""


def build_recommended_execution(project_dir: Path, engine: str) -> dict[str, str]:
    if engine:
        return {
            "mode": "host",
            "reason": host_validation_reason(engine),
            "recommendedAction": recommended_compile_action(engine) or build_host_recommended_action(project_dir),
        }
    if has_repo_dev_docker(project_dir):
        return {
            "mode": "docker",
            "reason": "Repository-side qq development is standardized through scripts/docker-dev.sh in this repository.",
            "recommendedAction": "./scripts/docker-dev.sh shell",
        }
    return {
        "mode": "host",
        "reason": "No repo-dev Docker helper was detected in this repository; continue on the host machine.",
        "recommendedAction": build_host_recommended_action(project_dir),
    }


def build_parallel_agent_safety(project_dir: Path, controller: dict[str, Any], recommended_execution: dict[str, str]) -> dict[str, str]:
    if bool(controller.get("isManagedWorktree")):
        return {
            "status": "ok",
            "summary": "Current directory is a dedicated managed worktree and is safe to hand to exactly one agent.",
            "recommendedAction": recommended_execution.get("recommendedAction") or "continue in this worktree",
        }

    helper = SCRIPT_DIR / "qq-worktree.py"
    recommended_action = ""
    if helper.is_file():
        recommended_action = shell_join(
            [
                "python3",
                str(helper),
                "create",
                "--project",
                str(project_dir),
                "--name",
                "<task>",
                "--pretty",
            ]
        )

    return {
        "status": "warn",
        "summary": "Current directory is the primary worktree. For unrelated parallel work, create a dedicated linked worktree first.",
        "recommendedAction": recommended_action,
    }


def find_tykit_info(project_dir: Path) -> Path | None:
    for candidate in (project_dir / "Temp" / "tykit.json", project_dir / "Temp" / "eval_server.json"):
        if candidate.is_file():
            return candidate
    return None


def has_tykit_package(project_dir: Path) -> bool:
    manifest = project_dir / "Packages" / "manifest.json"
    if manifest.is_file():
        try:
            data = load_json(manifest)
        except json.JSONDecodeError:
            return False
        deps = data.get("dependencies") or {}
        if "com.tyk.tykit" in deps:
            return True
    embedded = project_dir / "Packages" / "com.tyk.tykit"
    if embedded.is_dir():
        return True
    return any("com.tyk.tykit" in path.as_posix() for path in (project_dir / "Library" / "PackageCache").glob("**/*")) if (project_dir / "Library" / "PackageCache").is_dir() else False


def find_unity_eval(project_dir: Path) -> Path | None:
    embedded = project_dir / "Packages" / "com.tyk.tykit" / "Scripts~" / "unity-eval.sh"
    if embedded.is_file():
        return embedded
    package_cache = project_dir / "Library" / "PackageCache"
    if package_cache.is_dir():
        for candidate in sorted(package_cache.glob("**/unity-eval.sh")):
            if "com.tyk.tykit" in candidate.as_posix():
                return candidate
    return None


def gather_host_config_text(project_dir: Path) -> str:
    texts: list[str] = []
    for relative in (".mcp.json", ".cursor/mcp.json", ".cursor/mcp.jsonc"):
        path = project_dir / relative
        if path.is_file():
            try:
                texts.append(path.read_text(encoding="utf-8", errors="ignore"))
            except OSError:
                continue
    return "\n".join(texts)


def gather_config_tree_text(root: Path) -> tuple[str, list[str]]:
    texts: list[str] = []
    scanned: list[str] = []
    if not root.is_dir():
        return "", scanned
    for path in sorted(root.rglob("*.ini")):
        if not path.is_file():
            continue
        try:
            texts.append(path.read_text(encoding="utf-8", errors="ignore"))
            scanned.append(str(path))
        except OSError:
            continue
    return "\n".join(texts), scanned


def gather_unreal_config_text(project_dir: Path) -> tuple[str, list[str]]:
    roots = [project_dir / "Config", project_dir / "Saved" / "Config"]
    combined: list[str] = []
    scanned: list[str] = []
    for root in roots:
        text, paths = gather_config_tree_text(root)
        if text:
            combined.append(text)
        scanned.extend(paths)
    return "\n".join(combined), scanned


def unreal_remote_execution_state(project_dir: Path) -> dict[str, Any]:
    text, scanned = gather_unreal_config_text(project_dir)
    lowered = text.lower()
    enabled = "enableremoteexecution=true" in lowered or "enable_remote_execution=true" in lowered
    return {
        "enabled": enabled,
        "scanned": scanned,
    }


def unreal_editor_bridge_state(project_dir: Path) -> dict[str, Any]:
    metadata = engine_metadata("unreal")
    path = project_dir / str(metadata.get("editorBridgeStateFile") or ".qq/state/qq-unreal-editor-bridge.json")
    payload = load_optional_json(path)
    heartbeat = float(payload.get("lastHeartbeatUnix") or 0.0) if payload else 0.0
    age_sec = (time.time() - heartbeat) if heartbeat > 0 else None
    running = bool(payload.get("running")) and age_sec is not None and age_sec <= 5.0
    return {
        "path": str(path),
        "present": bool(payload),
        "running": running,
        "lastHeartbeatUnix": heartbeat,
        "lastHeartbeatAgeSec": age_sec,
        "state": payload,
    }


def unreal_python_startup_state(project_dir: Path) -> dict[str, Any]:
    metadata = engine_metadata("unreal")
    startup_command = str(metadata.get("editorBridgeStartupCommand") or "").strip()
    support_dir = str(metadata.get("engineSupportTargetDir") or "Content/Python").strip()
    bootstrap_path = project_dir / support_dir / "qq_unreal_bridge.py"
    config_text, scanned = gather_unreal_config_text(project_dir)
    return {
        "startupCommand": startup_command,
        "startupConfigured": bool(startup_command) and startup_command in config_text,
        "bootstrapPath": str(bootstrap_path),
        "bootstrapInstalled": bootstrap_path.is_file(),
        "configScanned": scanned,
    }


def unreal_plugin_state(project_dir: Path, plugin_name: str, enabled_plugins: dict[str, bool] | None = None) -> dict[str, Any]:
    plugins = enabled_plugins or enabled_unreal_plugins(project_dir)
    exact_dir = project_dir / "Plugins" / plugin_name
    plugin_files = sorted(project_dir.glob(f"Plugins/**/{plugin_name}.uplugin"))
    return {
        "name": plugin_name,
        "enabled": bool(plugins.get(plugin_name)),
        "localDirectory": str(exact_dir) if exact_dir.is_dir() else "",
        "localDescriptor": str(plugin_files[0]) if plugin_files else "",
    }


def host_config_matches(host_config: str, patterns: list[str]) -> bool:
    haystack = host_config.lower()
    return any(pattern.lower() in haystack for pattern in patterns if pattern)


def bridge_mcp_host_state(project_dir: Path, engine: str) -> dict[str, Any]:
    filename = bridge_host_state_file(engine)
    if not filename:
        return {
            "path": "",
            "verified": False,
            "verifiedAt": "",
            "clientInfo": {},
            "protocolVersion": "",
        }
    path = project_dir / ".qq" / "state" / filename
    payload = load_optional_json(path)
    if not payload:
        return {
            "path": str(path),
            "verified": False,
            "verifiedAt": "",
            "clientInfo": {},
            "protocolVersion": "",
        }
    return {
        "path": str(path),
        "verified": True,
        "verifiedAt": str(payload.get("lastInitializeAt") or ""),
        "clientInfo": payload.get("clientInfo") or {},
        "protocolVersion": str(payload.get("protocolVersion") or ""),
    }


def enabled_godot_plugins(project_dir: Path) -> list[str]:
    project_file = project_dir / "project.godot"
    if not project_file.is_file():
        return []
    lines = project_file.read_text(encoding="utf-8").splitlines()
    in_section = False
    plugins: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_section = stripped == "[editor_plugins]"
            continue
        if not in_section or not stripped.startswith("enabled="):
            continue
        plugins.extend(part for index, part in enumerate(stripped.split('"')) if index % 2 == 1)
    return plugins


def find_unreal_project_file(project_dir: Path) -> Path | None:
    for path in sorted(project_dir.glob("*.uproject")):
        if path.is_file():
            return path
    return None


def enabled_unreal_plugins(project_dir: Path) -> dict[str, bool]:
    project_file = find_unreal_project_file(project_dir)
    if project_file is None:
        return {}
    try:
        payload = load_json(project_file)
    except (OSError, json.JSONDecodeError):
        return {}
    plugins = payload.get("Plugins") or []
    if not isinstance(plugins, list):
        return {}
    enabled: dict[str, bool] = {}
    for item in plugins:
        if not isinstance(item, dict):
            continue
        name = str(item.get("Name") or "").strip()
        if not name:
            continue
        enabled[name] = bool(item.get("Enabled"))
    return enabled


def find_sbox_project_file(project_dir: Path) -> Path | None:
    hidden = project_dir / ".sbproj"
    if hidden.is_file():
        return hidden
    for path in sorted(project_dir.glob("*.sbproj")):
        if path.is_file():
            return path
    return None


def list_sbox_solution_files(project_dir: Path) -> list[Path]:
    return [path for path in sorted(project_dir.glob("*.sln")) if path.is_file()]


def list_sbox_csproj_files(project_dir: Path) -> list[Path]:
    files: list[Path] = []
    for path in sorted(project_dir.rglob("*.csproj")):
        if not path.is_file():
            continue
        lowered_parts = {part.lower() for part in path.parts}
        if "bin" in lowered_parts or "obj" in lowered_parts:
            continue
        files.append(path)
    return files


def is_sbox_test_project(path: Path) -> bool:
    lowered_parts = [part.lower() for part in path.parts]
    lowered_name = path.name.lower()
    return "unittests" in lowered_parts or "unittests" in lowered_name or lowered_name.endswith(".tests.csproj") or lowered_name.endswith(".test.csproj")


def find_sbox_editor_cmd() -> str:
    candidates = [
        str(item).strip()
        for item in (
            os.environ.get("SBOX_EDITOR_CMD"),
            os.environ.get("SBOX_CMD"),
            "sbox",
            "/Applications/sbox.app/Contents/MacOS/sbox",
            "/Applications/s&box.app/Contents/MacOS/sbox",
        )
        if str(item or "").strip()
    ]
    for candidate in candidates:
        if Path(candidate).expanduser().is_file():
            return str(Path(candidate).expanduser())
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
    return ""


def find_sbox_server_cmd() -> str:
    candidates = [
        str(item).strip()
        for item in (
            os.environ.get("SBOX_SERVER_CMD"),
            "sbox-server",
            "sbox-server.exe",
        )
        if str(item or "").strip()
    ]
    for candidate in candidates:
        if Path(candidate).expanduser().is_file():
            return str(Path(candidate).expanduser())
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
    return ""


def sbox_editor_bridge_state(project_dir: Path) -> dict[str, Any]:
    metadata = engine_metadata("sbox")
    path = project_dir / str(metadata.get("editorBridgeStateFile") or ".qq/state/qq-sbox-editor-bridge.json")
    payload = load_optional_json(path)
    heartbeat = float(payload.get("lastHeartbeatUnix") or 0.0) if payload else 0.0
    age_sec = (time.time() - heartbeat) if heartbeat > 0 else None
    running = bool(payload.get("running")) and age_sec is not None and age_sec <= 5.0
    return {
        "path": str(path),
        "present": bool(payload),
        "running": running,
        "lastHeartbeatUnix": heartbeat,
        "lastHeartbeatAgeSec": age_sec,
        "state": payload,
    }


def godot_editor_bridge_state(project_dir: Path) -> dict[str, Any]:
    metadata = engine_metadata("godot")
    path = project_dir / str(metadata.get("editorBridgeStateFile") or ".qq/state/qq-godot-editor-bridge.json")
    payload = load_optional_json(path)
    heartbeat = float(payload.get("lastHeartbeatUnix") or 0.0) if payload else 0.0
    age_sec = (time.time() - heartbeat) if heartbeat > 0 else None
    running = bool(payload.get("running")) and age_sec is not None and age_sec <= 5.0
    return {
        "path": str(path),
        "present": bool(payload),
        "running": running,
        "lastHeartbeatUnix": heartbeat,
        "lastHeartbeatAgeSec": age_sec,
        "state": payload,
    }


def codex_mcp_host_state(project_dir: Path) -> dict[str, Any]:
    helper = SCRIPT_DIR / "qq-codex-mcp.py"
    if not helper.is_file():
        return {
            "scriptPath": str(helper),
            "available": False,
            "error": "qq-codex-mcp.py not found",
        }
    result = subprocess.run(
        [sys.executable, str(helper), "status", "--project", str(project_dir)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode not in {0, 1}:
        return {
            "scriptPath": str(helper),
            "available": False,
            "error": result.stderr.strip() or result.stdout.strip() or "qq-codex-mcp.py failed",
        }
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {
            "scriptPath": str(helper),
            "available": False,
            "error": "qq-codex-mcp.py returned invalid JSON",
        }
    if not isinstance(payload, dict):
        return {
            "scriptPath": str(helper),
            "available": False,
            "error": "qq-codex-mcp.py returned a non-object payload",
        }
    payload["scriptPath"] = str(helper)
    payload["available"] = True
    return payload


def inspect_project_local_bridge_config(project_dir: Path, engine: str) -> dict[str, Any]:
    mcp_path = project_dir / ".mcp.json"
    expected_server_name = bridge_server_name(engine)
    expected_bridge_name = bridge_script(engine)
    details: dict[str, Any] = {
        "path": str(mcp_path),
        "configState": "missing",
        "configured": False,
        "serverName": "",
        "command": "",
        "args": [],
        "cwd": "",
        "projectLocalBridge": False,
        "projectArgMatches": False,
        "cwdMatches": False,
    }
    if not mcp_path.is_file():
        return details

    try:
        payload = load_json(mcp_path)
    except (OSError, json.JSONDecodeError):
        details["configState"] = "invalid"
        return details
    if not isinstance(payload, dict):
        details["configState"] = "invalid"
        return details

    raw_servers = payload.get("mcpServers")
    if not isinstance(raw_servers, dict):
        details["configState"] = "invalid"
        return details

    if not expected_bridge_name:
        details["configState"] = "unsupported"
        return details

    expected_bridge = (project_dir / "scripts" / expected_bridge_name).resolve()
    expected_project = project_dir.resolve()
    for name, raw in raw_servers.items():
        if not isinstance(raw, dict):
            continue
        command = str(raw.get("command") or "")
        raw_args = raw.get("args") or []
        args = [str(item) for item in raw_args] if isinstance(raw_args, list) else []
        cwd = str(raw.get("cwd") or "")
        lowered = " ".join([str(name), command, *args]).lower()
        if str(name) != expected_server_name and expected_bridge_name not in lowered:
            continue
        details["serverName"] = str(name)
        details["command"] = command
        details["args"] = args
        details["cwd"] = cwd

        bridge_arg = ""
        for value in args:
            if expected_bridge_name not in value.replace("\\", "/"):
                continue
            bridge_arg = value
            break
        if bridge_arg:
            try:
                details["projectLocalBridge"] = Path(bridge_arg).expanduser().resolve() == expected_bridge
            except OSError:
                details["projectLocalBridge"] = False

        for index, value in enumerate(args):
            if value != "--project" or index + 1 >= len(args):
                continue
            project_arg = args[index + 1]
            try:
                details["projectArgMatches"] = Path(project_arg).expanduser().resolve() == expected_project
            except OSError:
                details["projectArgMatches"] = False
            break

        if cwd:
            try:
                details["cwdMatches"] = Path(cwd).expanduser().resolve() == expected_project
            except OSError:
                details["cwdMatches"] = False

        details["configured"] = bool(details["projectLocalBridge"] and details["projectArgMatches"])
        details["configState"] = "configured" if details["configured"] else "misconfigured"
        return details

    details["configState"] = "missing_server"
    return details


def build_controller_state(project_dir: Path) -> dict[str, Any]:
    project_state_script = SCRIPT_DIR / "qq-project-state.py"
    if not project_state_script.is_file():
        return {}

    result = subprocess.run(
        [sys.executable, str(project_state_script), "--project", str(project_dir), "--no-write"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return {
            "error": result.stderr.strip() or result.stdout.strip() or "qq-project-state.py failed",
        }
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {
            "error": "qq-project-state.py returned invalid JSON",
        }
    if not isinstance(payload, dict):
        return {
            "error": "qq-project-state.py returned a non-object payload",
        }
    return {
        "engine": payload.get("engine") or "",
        "configFormat": payload.get("config_format") or "",
        "profile": payload.get("profile") or "",
        "profileSource": payload.get("profile_source") or "",
        "profileDescription": payload.get("profile_description") or "",
        "packs": payload.get("packs") or [],
        "packDetails": payload.get("pack_details") or {},
        "enabledSkills": payload.get("enabled_skills") or [],
        "enabledHooks": payload.get("enabled_hooks") or [],
        "enabledRules": payload.get("enabled_rules") or [],
        "workMode": payload.get("work_mode") or "",
        "workModeSource": payload.get("work_mode_source") or "",
        "modeProfile": payload.get("mode_profile") or {},
        "modeRecommendedNext": payload.get("mode_recommended_next") or "",
        "taskFocus": payload.get("task_focus") or [],
        "taskFocusSource": payload.get("task_focus_source") or "",
        "policyProfile": payload.get("policy_profile") or "",
        "policyProfileSource": payload.get("policy_profile_source") or "",
        "policyProfileExpectations": payload.get("policy_profile_expectations") or {},
        "trustLevel": payload.get("trust_level") or "",
        "trustLevelSource": payload.get("trust_level_source") or "",
        "trustLevelExpectations": payload.get("trust_level_expectations") or {},
        "defaultTestScope": payload.get("default_test_scope") or "",
        "recommendedNext": payload.get("recommended_next") or "",
        "compileStatusFresh": bool(payload.get("compile_status_fresh", True)),
        "compileStatus": payload.get("last_compile_status") or "",
        "compileStatusRaw": payload.get("last_compile_status_raw") or "",
        "testStatusFresh": bool(payload.get("test_status_fresh", True)),
        "testStatus": payload.get("last_test_status") or "",
        "testStatusRaw": payload.get("last_test_status_raw") or "",
        "reviewGateStatus": payload.get("review_gate_status") or "",
        "docDriftStatus": payload.get("doc_drift_status") or "",
        "hasDesignDoc": bool(payload.get("has_design_doc")),
        "hasImplementationPlan": bool(payload.get("has_implementation_plan")),
        "repositoryDesignDocCount": int(payload.get("repository_design_doc_count") or 0),
        "repositoryImplementationPlanCount": int(payload.get("repository_implementation_plan_count") or 0),
        "hasUncommittedRuntimeChanges": bool(payload.get("has_uncommitted_runtime_changes")),
        "isManagedWorktree": bool(payload.get("is_managed_worktree")),
        "worktreeRole": payload.get("worktree_role") or "",
        "worktreeName": payload.get("worktree_name") or "",
        "worktreeBranch": payload.get("worktree_branch") or "",
        "worktreeSourceBranch": payload.get("worktree_source_branch") or "",
        "worktreeSourceWorktreePath": payload.get("worktree_source_worktree_path") or "",
        "worktreeSourceBranchMerged": bool(payload.get("worktree_source_branch_merged")),
        "worktreeSourceBranchUpstream": payload.get("worktree_source_branch_upstream") or "",
        "worktreeSourceBranchPublishState": payload.get("worktree_source_branch_publish_state") or "",
        "worktreeSourceBranchPublished": bool(payload.get("worktree_source_branch_published")),
        "worktreeRuntimeCacheDir": payload.get("worktree_runtime_cache_dir") or "",
        "worktreeSourceRuntimeCacheExists": bool(payload.get("worktree_source_runtime_cache_exists")),
        "worktreeLocalRuntimeCacheExists": bool(payload.get("worktree_local_runtime_cache_exists")),
        "worktreeLocalRuntimeCacheSupportExists": bool(payload.get("worktree_local_runtime_cache_support_exists")),
        "worktreeCanSeedRuntimeCache": bool(payload.get("worktree_can_seed_runtime_cache")),
        "worktreeRuntimeCacheSeedState": payload.get("worktree_runtime_cache_seed_state") or "",
        "worktreeRuntimeCacheSeedStrategy": payload.get("worktree_runtime_cache_seed_strategy") or "",
        "worktreeCanMergeBack": bool(payload.get("worktree_can_merge_back")),
        "worktreeCanPushSource": bool(payload.get("worktree_can_push_source")),
        "worktreeCanCleanup": bool(payload.get("worktree_can_cleanup")),
    }


def build_installation_state(project_dir: Path) -> dict[str, Any]:
    state = load_install_state(project_dir)
    expected = resolve_install_plan(project_dir, project_dir)
    installed_modules = list(state.get("selectedModules") or [])
    expected_modules = list(expected.get("selectedModules") or [])
    managed_files = list(state.get("managedFiles") or [])
    missing_files = [rel for rel in managed_files if not (project_dir / rel).exists()]

    return {
        "statePath": str(install_state_path(project_dir)),
        "exists": bool(state),
        "engine": str(state.get("engine") or ""),
        "profile": str(state.get("profile") or ""),
        "selectedModules": installed_modules,
        "expectedModules": expected_modules,
        "missingModules": [module for module in expected_modules if module not in installed_modules],
        "extraModules": [module for module in installed_modules if module not in expected_modules],
        "managedFileCount": len(managed_files),
        "missingManagedFiles": missing_files,
        "syncEnabled": bool(state.get("syncEnabled")),
        "hosts": list(state.get("hosts") or []),
    }


def detect_provider(project_dir: Path, provider_id: str, definition: dict[str, Any], engine: str) -> dict[str, Any]:
    scripts_dir = project_dir / "scripts"
    host_config = gather_host_config_text(project_dir)

    if provider_id == "sbox.qq-direct":
        required = []
        for entries in (definition.get("toolMappings") or {}).values():
            for entry in entries or []:
                if isinstance(entry, str) and entry.startswith("scripts/"):
                    required.append(project_dir / entry)
        required.extend(
            [
                project_dir / "scripts" / "sbox-compile.sh",
                project_dir / "scripts" / "sbox-test.sh",
            ]
        )
        missing = sorted({path.relative_to(project_dir).as_posix() for path in required if not path.is_file()})
        project_file = find_sbox_project_file(project_dir)
        solution_files = [path.relative_to(project_dir).as_posix() for path in list_sbox_solution_files(project_dir)]
        csproj_files = [path.relative_to(project_dir).as_posix() for path in list_sbox_csproj_files(project_dir)]
        test_projects = [item for item in csproj_files if is_sbox_test_project(Path(item))]
        dotnet_path = shutil.which("dotnet") or ""
        editor_cmd = find_sbox_editor_cmd()
        server_cmd = find_sbox_server_cmd()
        reasons: list[str] = []
        if not missing:
            reasons.append("project-local qq fast path scripts for S&box are installed")
        else:
            reasons.append("missing S&box fast-path scripts")
        if project_file is not None:
            reasons.append(f"S&box project marker found: {project_file.name}")
        else:
            reasons.append("no .sbproj file found in the project root")
        if dotnet_path:
            reasons.append("dotnet SDK is available")
        else:
            reasons.append("dotnet SDK is not available")
        if solution_files or csproj_files:
            reasons.append("dotnet build targets were detected for this S&box project")
        else:
            reasons.append("no .sln or .csproj build targets were detected yet")
        if (project_dir / "UnitTests").is_dir():
            reasons.append("UnitTests directory is present")
        else:
            reasons.append("UnitTests directory is not present")
        if editor_cmd:
            reasons.append("local s&box editor command detected")
        if server_cmd:
            reasons.append("local s&box dedicated server command detected")
        available = not missing and project_file is not None and bool(dotnet_path)
        return {
            "id": provider_id,
            "status": "available" if available else "unavailable",
            "reasons": reasons,
            "evidence": {
                "missing": missing,
                "projectFile": project_file.relative_to(project_dir).as_posix() if project_file else "",
                "dotnetPath": dotnet_path,
                "solutionFiles": solution_files,
                "csprojFiles": csproj_files,
                "testProjects": test_projects,
                "unitTestsPresent": (project_dir / "UnitTests").is_dir(),
                "editorCommand": editor_cmd,
                "serverCommand": server_cmd,
            },
        }

    if provider_id == "sbox.qq-mcp":
        sbox_meta = engine_metadata("sbox")
        support_dir = str(sbox_meta.get("engineSupportTargetDir") or "Editor/QQ").strip()
        support_files = [
            project_dir / support_dir / "QQSboxEditorBridge.cs",
        ]
        required = [
            scripts_dir / "qq_mcp.py",
            scripts_dir / "sbox_bridge.py",
            scripts_dir / "sbox_capabilities.json",
            scripts_dir / "qq-capabilities.json",
            scripts_dir / "qq_engine.py",
            scripts_dir / "qq-compile.sh",
            scripts_dir / "qq-test.sh",
        ]
        missing = [path.relative_to(project_dir).as_posix() for path in required if not path.is_file()]
        support_missing = [path.relative_to(project_dir).as_posix() for path in support_files if not path.is_file()]
        project_file = find_sbox_project_file(project_dir)
        config = inspect_project_local_bridge_config(project_dir, "sbox")
        host_state = bridge_mcp_host_state(project_dir, "sbox")
        bridge_state = sbox_editor_bridge_state(project_dir)
        editor_cmd = find_sbox_editor_cmd()
        reasons: list[str] = []
        if not missing:
            reasons.append("built-in qq MCP bridge installed")
        else:
            reasons.append("missing bridge scripts")
        if project_file is not None:
            reasons.append(f"project-local S&box marker found: {project_file.name}")
        else:
            reasons.append("no .sbproj file found in the project root")
        if not support_missing:
            reasons.append("qq S&box editor bridge support is installed in Editor/QQ")
        else:
            reasons.append("qq S&box editor bridge support files are missing")
        if config["configState"] == "configured":
            reasons.append("project-local .mcp.json points at the built-in bridge")
        elif config["configState"] == "missing":
            reasons.append("project-local .mcp.json not found")
        elif config["configState"] == "missing_server":
            reasons.append("project-local .mcp.json does not expose the S&box bridge")
        elif config["configState"] == "misconfigured":
            reasons.append("project-local .mcp.json exists but does not point at this project's bridge")
        else:
            reasons.append("project-local .mcp.json could not be parsed")
        if host_state["verified"]:
            reasons.append("a host session has connected to the built-in bridge")
        else:
            reasons.append("no successful host connection has been recorded yet")
        if bridge_state["running"]:
            reasons.append("S&box editor bridge heartbeat is active")
        elif bridge_state["present"]:
            reasons.append("S&box editor bridge state exists but heartbeat is stale")
        else:
            reasons.append("S&box editor bridge state has not been written yet")
        reasons.append("typed S&box editor/query/object/tools fall back to local scene/asset file operations when the live bridge is inactive")
        if editor_cmd:
            reasons.append("local s&box editor command detected")
        return {
            "id": provider_id,
            "status": "available" if not missing and not support_missing and project_file is not None else "unavailable",
            "reasons": reasons,
            "evidence": {
                "missing": missing,
                "supportMissing": support_missing,
                "projectFile": project_file.relative_to(project_dir).as_posix() if project_file else "",
                "editorCommand": editor_cmd,
                "localFileOpsAvailable": True,
                "typedTools": [
                    "sbox_console",
                    "sbox_editor",
                    "sbox_query",
                    "sbox_object",
                    "sbox_scene",
                    "sbox_assets",
                ],
                "liveBridgeRequiredFor": [
                    "sbox_console",
                    "sbox_editor",
                    "sbox_object",
                    "sbox_query.hierarchy",
                    "sbox_query.find",
                    "sbox_query.inspect",
                    "sbox_query.get_selection",
                ],
                "localFallbackTools": [
                    "sbox_query.status",
                    "sbox_query.list_scenes",
                    "sbox_query.list_assets",
                    "sbox_scene",
                    "sbox_assets",
                ],
                "hostConfig": config,
                "hostConnection": host_state,
                "bridgeState": bridge_state,
            },
        }

    if provider_id.endswith(".qq-direct"):
        required = []
        for entries in (definition.get("toolMappings") or {}).values():
            for entry in entries or []:
                if isinstance(entry, str) and entry.startswith("scripts/"):
                    required.append(project_dir / entry)
        missing = [path.relative_to(project_dir).as_posix() for path in required if not path.is_file()]
        return {
            "id": provider_id,
            "status": "available" if not missing else "unavailable",
            "reasons": ["project-local qq fast path scripts installed"] if not missing else ["missing required fast-path scripts"],
            "evidence": {
                "missing": missing,
            },
        }

    if provider_id == "unity.tykit-mcp":
        required = [
            scripts_dir / "qq_mcp.py",
            scripts_dir / "tykit_bridge.py",
            scripts_dir / "qq-capabilities.json",
            scripts_dir / "tykit_capabilities.json",
        ]
        missing = [path.relative_to(project_dir).as_posix() for path in required if not path.is_file()]
        config = inspect_project_local_bridge_config(project_dir, "unity")
        host_state = bridge_mcp_host_state(project_dir, "unity")
        reasons: list[str] = []
        if not missing:
            reasons.append("built-in qq MCP bridge for Unity is installed")
        else:
            reasons.append("missing bridge scripts or registries")
        if config["configState"] == "configured":
            reasons.append("project-local .mcp.json points at the built-in bridge")
        elif config["configState"] == "missing":
            reasons.append("project-local .mcp.json not found")
        elif config["configState"] == "missing_server":
            reasons.append("project-local .mcp.json does not expose the Unity bridge")
        elif config["configState"] == "misconfigured":
            reasons.append("project-local .mcp.json exists but does not point at this project's bridge")
        else:
            reasons.append("project-local .mcp.json could not be parsed")
        if host_state["verified"]:
            reasons.append("a host session has connected to the built-in bridge")
        else:
            reasons.append("no successful host connection has been recorded yet")
        return {
            "id": provider_id,
            "status": "available" if not missing else "unavailable",
            "reasons": reasons,
            "evidence": {
                "missing": missing,
                "hostConfig": config,
                "hostConnection": host_state,
            },
        }

    if provider_id == "godot.qq-mcp":
        godot_meta = engine_metadata("godot")
        plugin_path = str(godot_meta.get("editorPluginConfigPath") or "res://addons/qq_editor_bridge/plugin.cfg")
        addon_files = [
            project_dir / "addons" / "qq_editor_bridge" / "plugin.cfg",
            project_dir / "addons" / "qq_editor_bridge" / "plugin.gd",
        ]
        required = [
            scripts_dir / "qq_mcp.py",
            scripts_dir / "godot_bridge.py",
            scripts_dir / "godot_capabilities.json",
            scripts_dir / "qq-capabilities.json",
            scripts_dir / "qq_engine.py",
            scripts_dir / "qq-compile.sh",
            scripts_dir / "qq-test.sh",
        ]
        missing = [path.relative_to(project_dir).as_posix() for path in required if not path.is_file()]
        addon_missing = [path.relative_to(project_dir).as_posix() for path in addon_files if not path.is_file()]
        enabled_plugins = enabled_godot_plugins(project_dir)
        plugin_enabled = plugin_path in enabled_plugins
        config = inspect_project_local_bridge_config(project_dir, "godot")
        host_state = bridge_mcp_host_state(project_dir, "godot")
        bridge_state = godot_editor_bridge_state(project_dir)
        reasons: list[str] = []
        if not missing:
            reasons.append("built-in qq MCP bridge installed")
        else:
            reasons.append("missing bridge scripts")
        if not addon_missing:
            reasons.append("qq_editor_bridge addon installed")
        else:
            reasons.append("qq_editor_bridge addon files missing")
        if plugin_enabled:
            reasons.append("project.godot enables the qq editor bridge addon")
        else:
            reasons.append("project.godot does not enable the qq editor bridge addon")
        if config["configState"] == "configured":
            reasons.append("project-local .mcp.json points at the built-in bridge")
        elif config["configState"] == "missing":
            reasons.append("project-local .mcp.json not found")
        elif config["configState"] == "missing_server":
            reasons.append("project-local .mcp.json does not expose the Godot bridge")
        elif config["configState"] == "misconfigured":
            reasons.append("project-local .mcp.json exists but does not point at this project's bridge")
        else:
            reasons.append("project-local .mcp.json could not be parsed")
        if host_state["verified"]:
            reasons.append("a host session has connected to the built-in bridge")
        else:
            reasons.append("no successful host connection has been recorded yet")
        if bridge_state["running"]:
            reasons.append("Godot editor bridge heartbeat is active")
        elif bridge_state["present"]:
            reasons.append("Godot editor bridge state exists but heartbeat is stale")
        else:
            reasons.append("Godot editor bridge state has not been written yet")
        return {
            "id": provider_id,
            "status": "available" if not missing and not addon_missing and plugin_enabled else "unavailable",
            "reasons": reasons,
            "evidence": {
                "missing": missing,
                "addonMissing": addon_missing,
                "enabledPlugins": enabled_plugins,
                "pluginEnabled": plugin_enabled,
                "hostConfig": config,
                "hostConnection": host_state,
                "bridgeState": bridge_state,
            },
        }

    if provider_id == "unreal.qq-mcp":
        unreal_meta = engine_metadata("unreal")
        required = [
            scripts_dir / "qq_mcp.py",
            scripts_dir / "unreal_bridge.py",
            scripts_dir / "unreal_editor_command.py",
            scripts_dir / "unreal_capabilities.json",
            scripts_dir / "qq-capabilities.json",
            scripts_dir / "qq_engine.py",
            scripts_dir / "qq-compile.sh",
            scripts_dir / "qq-test.sh",
        ]
        missing = [path.relative_to(project_dir).as_posix() for path in required if not path.is_file()]
        project_file = find_unreal_project_file(project_dir)
        enabled_plugins = enabled_unreal_plugins(project_dir)
        required_plugins = [str(item) for item in unreal_meta.get("requiredProjectPlugins") or [] if str(item)]
        missing_plugins = [name for name in required_plugins if not enabled_plugins.get(name)]
        startup_state = unreal_python_startup_state(project_dir)
        bridge_state = unreal_editor_bridge_state(project_dir)
        config = inspect_project_local_bridge_config(project_dir, "unreal")
        host_state = bridge_mcp_host_state(project_dir, "unreal")
        reasons: list[str] = []
        if not missing:
            reasons.append("built-in qq MCP bridge installed")
        else:
            reasons.append("missing bridge scripts")
        if project_file is not None:
            reasons.append(f"project-local Unreal descriptor found: {project_file.name}")
        else:
            reasons.append("no .uproject file found in the project root")
        if not missing_plugins:
            reasons.append("required Unreal project plugins are enabled")
        else:
            reasons.append("required Unreal project plugins are not fully enabled")
        if startup_state["bootstrapInstalled"]:
            reasons.append("qq Unreal editor bridge bootstrap is installed in Content/Python")
        else:
            reasons.append("qq Unreal editor bridge bootstrap is missing from Content/Python")
        if startup_state["startupConfigured"]:
            reasons.append("Unreal Python startup hook is configured for the qq editor bridge")
        else:
            reasons.append("Unreal Python startup hook is not configured for the qq editor bridge")
        if config["configState"] == "configured":
            reasons.append("project-local .mcp.json points at the built-in bridge")
        elif config["configState"] == "missing":
            reasons.append("project-local .mcp.json not found")
        elif config["configState"] == "missing_server":
            reasons.append("project-local .mcp.json does not expose the Unreal bridge")
        elif config["configState"] == "misconfigured":
            reasons.append("project-local .mcp.json exists but does not point at this project's bridge")
        else:
            reasons.append("project-local .mcp.json could not be parsed")
        if host_state["verified"]:
            reasons.append("a host session has connected to the built-in bridge")
        else:
            reasons.append("no successful host connection has been recorded yet")
        if bridge_state["running"]:
            reasons.append("Unreal editor bridge heartbeat is active")
        elif bridge_state["present"]:
            reasons.append("Unreal editor bridge state exists but heartbeat is stale")
        else:
            reasons.append("Unreal editor bridge state has not been written yet")
        return {
            "id": provider_id,
            "status": "available" if not missing and project_file is not None and not missing_plugins and startup_state["bootstrapInstalled"] and startup_state["startupConfigured"] else "unavailable",
            "reasons": reasons,
            "evidence": {
                "missing": missing,
                "projectFile": str(project_file) if project_file else "",
                "requiredPlugins": required_plugins,
                "enabledPlugins": enabled_plugins,
                "missingPlugins": missing_plugins,
                "startup": startup_state,
                "hostConfig": config,
                "hostConnection": host_state,
                "bridgeState": bridge_state,
            },
        }

    if provider_id == "unreal.unreal-engine-mcp":
        enabled_plugins = enabled_unreal_plugins(project_dir)
        plugin_state = unreal_plugin_state(project_dir, "McpAutomationBridge", enabled_plugins)
        config_detected = host_config_matches(
            host_config,
            [
                "unreal-engine-mcp-server",
                "\"unreal-engine\"",
                "mcpautomationbridge",
                "mcp_automation_port",
            ],
        )
        available = config_detected and (plugin_state["enabled"] or bool(plugin_state["localDirectory"]) or bool(plugin_state["localDescriptor"]))
        reasons: list[str] = []
        if config_detected:
            reasons.append("host MCP config references unreal-engine-mcp")
        else:
            reasons.append("host MCP config does not reference unreal-engine-mcp")
        if plugin_state["enabled"]:
            reasons.append("McpAutomationBridge is enabled in the Unreal project descriptor")
        elif plugin_state["localDirectory"] or plugin_state["localDescriptor"]:
            reasons.append("McpAutomationBridge plugin files exist locally but are not enabled in the project descriptor")
        else:
            reasons.append("McpAutomationBridge plugin was not found in the project")
        return {
            "id": provider_id,
            "status": "available" if available else ("unavailable" if config_detected else "unknown"),
            "reasons": reasons,
            "evidence": {
                "hostConfigDetected": config_detected,
                "plugin": plugin_state,
                "configScanned": [".mcp.json", ".cursor/mcp.json", ".cursor/mcp.jsonc"],
            },
        }

    if provider_id == "unreal.runreal-mcp":
        enabled_plugins = enabled_unreal_plugins(project_dir)
        remote_state = unreal_remote_execution_state(project_dir)
        config_detected = host_config_matches(
            host_config,
            [
                "@runreal/unreal-mcp",
                "runreal/unreal-mcp",
                "\"unreal\"",
                "editor_run_python",
            ],
        )
        python_enabled = bool(enabled_plugins.get("PythonScriptPlugin"))
        available = config_detected and python_enabled and remote_state["enabled"]
        reasons = []
        if config_detected:
            reasons.append("host MCP config references runreal/unreal-mcp")
        else:
            reasons.append("host MCP config does not reference runreal/unreal-mcp")
        if python_enabled:
            reasons.append("PythonScriptPlugin is enabled")
        else:
            reasons.append("PythonScriptPlugin is not enabled")
        if remote_state["enabled"]:
            reasons.append("Unreal Python Remote Execution is enabled in config")
        else:
            reasons.append("Unreal Python Remote Execution was not detected in config")
        return {
            "id": provider_id,
            "status": "available" if available else ("unavailable" if config_detected else "unknown"),
            "reasons": reasons,
            "evidence": {
                "hostConfigDetected": config_detected,
                "pythonPluginEnabled": python_enabled,
                "remoteExecution": remote_state,
                "configScanned": [".mcp.json", ".cursor/mcp.json", ".cursor/mcp.jsonc"],
            },
        }

    if provider_id == "unreal.flop-mcp":
        enabled_plugins = enabled_unreal_plugins(project_dir)
        plugin_state = unreal_plugin_state(project_dir, "UnrealMCP", enabled_plugins)
        config_detected = host_config_matches(
            host_config,
            [
                "agent.flopperam.com/mcp",
                "\"flopperam-unreal\"",
                "flopperam.com/mcp",
                "flopperamunrealmcp",
            ],
        )
        available = config_detected and (plugin_state["enabled"] or bool(plugin_state["localDirectory"]) or bool(plugin_state["localDescriptor"]))
        reasons = []
        if config_detected:
            reasons.append("host MCP config references the Flopperam Unreal MCP endpoint")
        else:
            reasons.append("host MCP config does not reference the Flopperam Unreal MCP endpoint")
        if plugin_state["enabled"]:
            reasons.append("UnrealMCP is enabled in the Unreal project descriptor")
        elif plugin_state["localDirectory"] or plugin_state["localDescriptor"]:
            reasons.append("UnrealMCP plugin files exist locally but are not enabled in the project descriptor")
        else:
            reasons.append("UnrealMCP plugin was not found in the project")
        return {
            "id": provider_id,
            "status": "available" if available else ("unavailable" if config_detected else "unknown"),
            "reasons": reasons,
            "evidence": {
                "hostConfigDetected": config_detected,
                "plugin": plugin_state,
                "configScanned": [".mcp.json", ".cursor/mcp.json", ".cursor/mcp.jsonc"],
            },
        }

    if provider_id == "unity.raw-tykit":
        info_file = find_tykit_info(project_dir)
        eval_script = find_unity_eval(project_dir)
        package_installed = has_tykit_package(project_dir)
        available = bool(info_file or eval_script or package_installed)
        reasons: list[str] = []
        if info_file:
            reasons.append("tykit metadata file found")
        if eval_script:
            reasons.append("unity-eval.sh available")
        if package_installed:
            reasons.append("com.tyk.tykit installed")
        if not reasons:
            reasons.append("tykit package or metadata not detected")
        return {
            "id": provider_id,
            "status": "available" if available else "unavailable",
            "reasons": reasons,
            "evidence": {
                "infoFile": str(info_file) if info_file else "",
                "evalScript": str(eval_script) if eval_script else "",
                "packageInstalled": package_installed,
            },
        }

    if provider_id == "unity.mcp-unity":
        detected = "mcp-unity" in host_config or "recompile_scripts" in host_config or "run_tests" in host_config
        return {
            "id": provider_id,
            "status": "available" if detected else "unknown",
            "reasons": ["host MCP config references mcp-unity"] if detected else ["host MCP config not detected in project-local files"],
            "evidence": {
                "configScanned": [".mcp.json", ".cursor/mcp.json", ".cursor/mcp.jsonc"],
            },
        }

    if provider_id == "unity.unity-mcp":
        detected = "unity-mcp" in host_config.lower() or "Unity-MCP" in host_config or "tests-run" in host_config
        return {
            "id": provider_id,
            "status": "available" if detected else "unknown",
            "reasons": ["host MCP config references Unity-MCP"] if detected else ["host MCP config not detected in project-local files"],
            "evidence": {
                "configScanned": [".mcp.json", ".cursor/mcp.json", ".cursor/mcp.jsonc"],
            },
        }

    return {
        "id": provider_id,
        "status": "unknown",
        "reasons": ["no detector implemented"],
        "evidence": {},
    }


def resolve_capabilities(registry: dict[str, Any], engine: str, provider_status: dict[str, dict[str, Any]]) -> dict[str, Any]:
    preferred = ((registry.get("resolution") or {}).get("preferredProviders") or {}).get(engine) or {}
    resolved: dict[str, Any] = {}
    for capability, ordered in preferred.items():
        available = [provider_id for provider_id in ordered if provider_status.get(provider_id, {}).get("status") == "available"]
        resolved[capability] = {
            "preferredProviders": ordered,
            "availableProviders": available,
            "resolved": available[0] if available else "",
        }
    return resolved


def write_state(project_dir: Path, payload: dict[str, Any]) -> Path:
    state_dir = project_dir / ".qq" / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    output = state_dir / "provider-resolution.json"
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return output


def build_payload(project_dir: Path, engine: str, registry: dict[str, Any]) -> dict[str, Any]:
    controller = build_controller_state(project_dir)
    config = resolve_project_config(project_dir)
    codex_host = codex_mcp_host_state(project_dir)
    recommended_execution = build_recommended_execution(project_dir, engine)
    parallel_agent_safety = build_parallel_agent_safety(project_dir, controller, recommended_execution)
    sbox_project_file = find_sbox_project_file(project_dir) if engine == "sbox" else None
    sbox_csproj_files = list_sbox_csproj_files(project_dir) if engine == "sbox" else []
    provider_items = []
    provider_status: dict[str, dict[str, Any]] = {}
    for provider_id, definition in sorted((registry.get("providers") or {}).items()):
        if definition.get("engineAdapter") != engine:
            continue
        detection = detect_provider(project_dir, provider_id, definition, engine)
        entry = {
            "id": provider_id,
            "engineAdapter": definition.get("engineAdapter"),
            "transportAdapter": definition.get("transportAdapter"),
            "hostAdapters": definition.get("hostAdapters") or [],
            "official": bool(definition.get("official")),
            "capabilities": definition.get("capabilities") or [],
            **detection,
        }
        provider_items.append(entry)
        provider_status[provider_id] = entry

    return {
        "projectDir": str(project_dir),
        "engine": engine,
        "engineProjectDetected": bool(engine),
        "unityProjectDetected": is_unity_project(project_dir) if engine == "unity" else None,
        "sboxProjectDetected": sbox_project_file is not None if engine == "sbox" else None,
        "sboxProjectFile": sbox_project_file.relative_to(project_dir).as_posix() if sbox_project_file else "",
        "sboxUnitTestsPresent": (project_dir / "UnitTests").is_dir() if engine == "sbox" else None,
        "sboxLibraryCount": len([path for path in (project_dir / "Libraries").iterdir() if path.is_dir()]) if engine == "sbox" and (project_dir / "Libraries").is_dir() else (0 if engine == "sbox" else None),
        "sboxEditorProjectPresent": (project_dir / "Editor").is_dir() if engine == "sbox" else None,
        "sboxServerCodePresent": bool(list(project_dir.glob("**/*.Server.cs"))) if engine == "sbox" else None,
        "sboxCsprojCount": len(sbox_csproj_files) if engine == "sbox" else None,
        "policy": {
            "configFormat": config.get("config_format") or "",
            "sharedPath": config.get("shared_config_path") or "",
            "sharedExists": bool(config.get("shared_config_exists")),
            "shared": read_optional_structured(Path(str(config.get("shared_config_path") or "."))) if config.get("shared_config_exists") else {},
            "localPath": config.get("local_config_path") or "",
            "localExists": bool(config.get("local_config_exists")),
            "local": read_optional_structured(Path(str(config.get("local_config_path") or "."))) if config.get("local_config_exists") else {},
            "profile": config.get("profile") or "",
            "profileSource": config.get("profile_source") or "",
            "profileDescription": config.get("profile_description") or "",
            "packs": config.get("packs") or [],
            "enabledSkills": config.get("enabled_skills") or [],
            "enabledHooks": config.get("enabled_hooks") or [],
            "enabledRules": config.get("enabled_rules") or [],
            "effectiveProfile": controller.get("policyProfile") or "",
            "effectiveProfileSource": controller.get("policyProfileSource") or "",
            "effectiveProfileExpectations": controller.get("policyProfileExpectations") or {},
            "trustLevel": config.get("trust_level") or "",
            "trustLevelSource": config.get("trust_level_source") or "",
            "trustLevelExpectations": config.get("trust_level_expectations") or {},
            "installPreferences": config.get("install_preferences") or {},
        },
        "controller": controller,
        "recommendedExecution": recommended_execution,
        "parallelAgentSafety": parallel_agent_safety,
        "gitHooks": check_git_hooks(project_dir),
        "installation": build_installation_state(project_dir),
        "hosts": {
            "codex": codex_host,
        },
        "providers": provider_items,
        "resolution": resolve_capabilities(registry, engine, provider_status),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="qq provider discovery and capability resolution doctor")
    parser.add_argument("--project", default=".", help="Project root to inspect")
    parser.add_argument("--engine", default=None, help="Engine adapter id to inspect")
    parser.add_argument("--registry", default=str(DEFAULT_REGISTRY_PATH), help="Path to qq capability registry JSON")
    parser.add_argument("--write-state", action="store_true", help="Write provider-resolution.json into .qq/state/")
    parser.add_argument(
        "--fix-git-hooks",
        action="store_true",
        help="Apply the safe core.hooksPath auto-fix before reporting (only acts when local config is broken).",
    )
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    return parser


def main() -> int:
    try:
        return _run(build_parser().parse_args())
    except ConfigError as exc:
        print(f"qq-doctor: error: {exc}", file=sys.stderr)
        return 2


def _run(args: argparse.Namespace) -> int:
    project_dir = Path(args.project).resolve()
    registry = load_json(Path(args.registry).resolve())
    config = resolve_project_config(project_dir)
    engine = args.engine or str(config.get("engine") or "") or resolve_project_engine(project_dir) or registry.get("defaultEngine") or "unity"

    git_hooks_fix = apply_safe_git_hooks_fix(project_dir) if args.fix_git_hooks else None

    payload = build_payload(project_dir, engine, registry)
    if git_hooks_fix is not None:
        payload["gitHooksFix"] = git_hooks_fix
    if args.write_state:
        payload["statePath"] = str(write_state(project_dir, payload))

    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

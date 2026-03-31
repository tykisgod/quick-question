#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
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
from qq_internal_config import read_optional_structured, resolve_project_config


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
        ["python3", str(helper), "status", "--project", str(project_dir)],
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
        ["python3", str(project_state_script), "--project", str(project_dir), "--no-write"],
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


def build_context_capsule_state(project_dir: Path) -> dict[str, Any]:
    path = project_dir / ".qq" / "state" / "context-capsule.json"
    config: dict[str, Any] = {}
    helper = SCRIPT_DIR / "qq-context-capsule.py"
    if helper.is_file():
        result = subprocess.run(
            ["python3", str(helper), "config", "--project", str(project_dir)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            try:
                payload_config = json.loads(result.stdout)
            except json.JSONDecodeError:
                payload_config = {}
            if isinstance(payload_config, dict):
                config = payload_config
    payload = load_optional_json(path)
    if not payload:
        return {
            "path": str(path),
            "exists": False,
            "generatedAt": "",
            "trigger": "",
            "recommendedNext": "",
            "blockerCount": 0,
            "resumePromptChars": 0,
            "config": config,
        }

    blockers = payload.get("blockers") or []
    prompt = str(payload.get("resumePromptMd") or "")
    return {
        "path": str(path),
        "exists": True,
        "generatedAt": str(payload.get("generatedAt") or ""),
        "trigger": str(payload.get("trigger") or ""),
        "recommendedNext": str(payload.get("recommendedNext") or ""),
        "blockerCount": len(blockers) if isinstance(blockers, list) else 0,
        "resumePromptChars": len(prompt),
        "workMode": str(payload.get("workMode") or ""),
        "policyProfile": str(payload.get("policyProfile") or ""),
        "config": config,
    }


def detect_provider(project_dir: Path, provider_id: str, definition: dict[str, Any], engine: str) -> dict[str, Any]:
    scripts_dir = project_dir / "scripts"
    host_config = gather_host_config_text(project_dir)

    if provider_id.endswith(".qq-direct"):
        required = []
        for entries in (definition.get("toolMappings") or {}).values():
            for entry in entries or []:
                if isinstance(entry, str) and entry.startswith("scripts/"):
                    required.append(project_dir / entry)
        missing = [str(path.relative_to(project_dir)) for path in required if not path.is_file()]
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
        missing = [str(path.relative_to(project_dir)) for path in required if not path.is_file()]
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
        missing = [str(path.relative_to(project_dir)) for path in required if not path.is_file()]
        addon_missing = [str(path.relative_to(project_dir)) for path in addon_files if not path.is_file()]
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
        },
        "controller": controller,
        "recommendedExecution": recommended_execution,
        "parallelAgentSafety": parallel_agent_safety,
        "hosts": {
            "codex": codex_host,
        },
        "contextCapsule": build_context_capsule_state(project_dir),
        "providers": provider_items,
        "resolution": resolve_capabilities(registry, engine, provider_status),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="qq provider discovery and capability resolution doctor")
    parser.add_argument("--project", default=".", help="Project root to inspect")
    parser.add_argument("--engine", default=None, help="Engine adapter id to inspect")
    parser.add_argument("--registry", default=str(DEFAULT_REGISTRY_PATH), help="Path to qq capability registry JSON")
    parser.add_argument("--write-state", action="store_true", help="Write provider-resolution.json into .qq/state/")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    project_dir = Path(args.project).resolve()
    registry = load_json(Path(args.registry).resolve())
    config = resolve_project_config(project_dir)
    engine = args.engine or str(config.get("engine") or "") or resolve_project_engine(project_dir) or registry.get("defaultEngine") or "unity"

    payload = build_payload(project_dir, engine, registry)
    if args.write_state:
        payload["statePath"] = str(write_state(project_dir, payload))

    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=args.pretty)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

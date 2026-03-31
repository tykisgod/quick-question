#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import uuid
from pathlib import Path
from typing import Any

from qq_bridge_common import (
    BridgeError,
    build_tool_result,
    latest_stage_record,
    load_json_file,
    normalize_run_status,
    pretty_json,
    run_command,
)
from qq_engine import bridge_server_name, engine_metadata, resolve_project_engine


CAPABILITIES_PATH = Path(__file__).resolve().with_name("godot_capabilities.json")
PLUGIN_STATE_TTL_SEC = 5.0
REQUEST_POLL_INTERVAL_SEC = 0.1
DEFAULT_BRIDGE_TIMEOUT_SEC = 15


TOOL_DEFINITIONS: dict[str, dict[str, Any]] = {
    "godot_health": {
        "title": "Godot Health",
        "description": "Check Godot project discovery, qq script wiring, addon installation, and editor bridge reachability.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
            },
        },
    },
    "godot_doctor": {
        "title": "Godot Doctor",
        "description": "Diagnose qq direct-path readiness, built-in MCP configuration, addon installation, and Godot editor bridge reachability.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
            },
        },
    },
    "godot_compile": {
        "title": "Godot Compile",
        "description": "Run the project-local compile workflow for Godot.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "timeout_sec": {"type": "integer", "minimum": 1},
                "mode": {"type": "string", "enum": ["auto", "editor", "batch"]},
            },
        },
    },
    "godot_run_tests": {
        "title": "Godot Run Tests",
        "description": "Run the project-local Godot test workflow.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "mode": {"type": "string"},
                "filter": {"type": "string"},
                "assembly_names": {"type": "array", "items": {"type": "string"}},
                "timeout_sec": {"type": "integer", "minimum": 1},
            },
        },
    },
    "godot_console": {
        "title": "Godot Console",
        "description": "Read or clear the Godot editor bridge event log for this project.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {"type": "string", "enum": ["get", "clear"]},
                "count": {"type": "integer", "minimum": 1},
                "filter": {"type": "string"},
            },
            "required": ["action"],
        },
    },
    "godot_editor": {
        "title": "Godot Editor",
        "description": "Control editor state and scenes: play, stop, pause, save, open, create, or reload scenes.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": ["play", "stop", "pause", "save_scene", "open_scene", "new_scene", "reload_scene"],
                },
                "path": {"type": "string"},
                "node_type": {"type": "string"},
                "name": {"type": "string"},
            },
            "required": ["action"],
        },
    },
    "godot_query": {
        "title": "Godot Query",
        "description": "Read editor state, scene hierarchy, selection, nodes, scenes, and assets.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": ["status", "hierarchy", "find", "inspect", "get_selection", "list_scenes", "list_assets"],
                },
                "depth": {"type": "integer", "minimum": 1},
                "path": {"type": "string"},
                "name": {"type": "string"},
                "type": {"type": "string"},
                "group": {"type": "string"},
                "filter": {"type": "string"},
            },
            "required": ["action"],
        },
    },
    "godot_object": {
        "title": "Godot Objects",
        "description": "Create and mutate scene nodes, transforms, parenting, selection, and serialized properties.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {
                    "type": "string",
                    "enum": [
                        "create",
                        "instantiate",
                        "destroy",
                        "duplicate",
                        "set_transform",
                        "set_parent",
                        "set_active",
                        "set_property",
                        "add_script",
                        "select",
                    ],
                },
                "path": {"type": "string"},
                "parent": {"type": "string"},
                "name": {"type": "string"},
                "node_type": {"type": "string"},
                "scene": {"type": "string"},
                "position": {"type": "array", "items": {"type": "number"}},
                "rotation": {"type": "array", "items": {"type": "number"}},
                "scale": {"type": "array", "items": {"type": "number"}},
                "active": {"type": "boolean"},
                "property": {"type": "string"},
                "value": {},
                "script_path": {"type": "string"},
            },
            "required": ["action"],
        },
    },
    "godot_assets": {
        "title": "Godot Assets",
        "description": "Refresh the editor filesystem, list assets, and create basic scene or material assets.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "action": {"type": "string", "enum": ["refresh", "list_assets", "create_scene", "create_material"]},
                "path": {"type": "string"},
                "source": {"type": "string"},
                "filter": {"type": "string"},
                "node_type": {"type": "string"},
                "material_type": {"type": "string"},
                "shader": {"type": "string"},
            },
            "required": ["action"],
        },
    },
    "godot_batch": {
        "title": "Godot Batch",
        "description": "Execute multiple Godot bridge tool calls in one request.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "operations": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "tool": {"type": "string"},
                            "arguments": {"type": "object"},
                        },
                    },
                },
            },
            "required": ["operations"],
        },
    },
    "godot_raw_command": {
        "title": "Godot Raw Command",
        "description": "Send an arbitrary Godot editor bridge command directly.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {"type": "string"},
                "command": {"type": "string"},
                "args": {"type": "object"},
                "timeout_sec": {"type": "integer", "minimum": 1},
            },
            "required": ["command"],
        },
    },
}


EDITOR_ACTIONS = {
    "play": "play",
    "stop": "stop",
    "pause": "pause",
    "save_scene": "save-scene",
    "open_scene": "open-scene",
    "new_scene": "new-scene",
    "reload_scene": "reload-scene",
}

QUERY_ACTIONS = {
    "status": "status",
    "hierarchy": "hierarchy",
    "find": "find",
    "inspect": "inspect",
    "get_selection": "get-selection",
    "list_scenes": "list-scenes",
    "list_assets": "list-assets",
}

OBJECT_ACTIONS = {
    "create": "create-node",
    "instantiate": "instantiate-scene",
    "destroy": "destroy-node",
    "duplicate": "duplicate-node",
    "set_transform": "set-transform",
    "set_parent": "set-parent",
    "set_active": "set-active",
    "set_property": "set-property",
    "add_script": "add-script",
    "select": "select-node",
}

ASSET_ACTIONS = {
    "refresh": "refresh-filesystem",
    "list_assets": "list-assets",
    "create_scene": "create-scene-asset",
    "create_material": "create-material",
}


def load_config(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise BridgeError("INVALID_CONFIG", f"Expected JSON object in {path}")
    return payload


def unique_strings(items: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for item in items:
        token = str(item or "").strip()
        if token and token not in seen:
            seen.add(token)
            ordered.append(token)
    return ordered


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
        plugins.extend(re.findall(r'"([^"]+)"', stripped))
    return plugins


class GodotQueueClient:
    def __init__(self, project_dir: Path):
        self.project_dir = project_dir.resolve()
        self.metadata = engine_metadata("godot")

    @property
    def state_path(self) -> Path:
        return self.project_dir / str(self.metadata.get("editorBridgeStateFile") or ".qq/state/qq-godot-editor-bridge.json")

    @property
    def request_dir(self) -> Path:
        return self.project_dir / str(self.metadata.get("editorBridgeRequestDir") or ".qq/state/qq-godot-editor/requests")

    @property
    def response_dir(self) -> Path:
        return self.project_dir / str(self.metadata.get("editorBridgeResponseDir") or ".qq/state/qq-godot-editor/responses")

    @property
    def console_path(self) -> Path:
        return self.project_dir / str(self.metadata.get("editorBridgeConsoleFile") or ".qq/state/qq-godot-editor-console.jsonl")

    @property
    def plugin_config_path(self) -> str:
        return str(self.metadata.get("editorPluginConfigPath") or "res://addons/qq_editor_bridge/plugin.cfg")

    @property
    def addon_paths(self) -> list[Path]:
        return [
            self.project_dir / "addons" / "qq_editor_bridge" / "plugin.cfg",
            self.project_dir / "addons" / "qq_editor_bridge" / "plugin.gd",
        ]

    def addon_installed(self) -> bool:
        return all(path.is_file() for path in self.addon_paths)

    def plugin_configured(self) -> bool:
        return self.plugin_config_path in enabled_godot_plugins(self.project_dir)

    def ensure_runtime_dirs(self) -> None:
        self.request_dir.mkdir(parents=True, exist_ok=True)
        self.response_dir.mkdir(parents=True, exist_ok=True)
        self.console_path.parent.mkdir(parents=True, exist_ok=True)

    def load_state(self) -> dict[str, Any]:
        if not self.state_path.is_file():
            return {}
        try:
            return load_json_file(self.state_path)
        except Exception:
            return {}

    def bridge_health(self) -> dict[str, Any]:
        state = self.load_state()
        heartbeat = float(state.get("lastHeartbeatUnix") or 0.0)
        age_sec = (time.time() - heartbeat) if heartbeat > 0 else None
        running = bool(state.get("running")) and age_sec is not None and age_sec <= PLUGIN_STATE_TTL_SEC
        warnings: list[str] = []
        if not self.addon_installed():
            warnings.append("qq_editor_bridge addon files are not installed in addons/qq_editor_bridge")
        if not self.plugin_configured():
            warnings.append("project.godot does not enable res://addons/qq_editor_bridge/plugin.cfg")
        if not self.state_path.is_file():
            warnings.append("Godot editor bridge state file has not been written yet")
        elif not running:
            warnings.append("Godot editor bridge heartbeat is stale or the editor is not open")
        return {
            "addonInstalled": self.addon_installed(),
            "pluginConfigured": self.plugin_configured(),
            "stateFile": str(self.state_path),
            "requestDir": str(self.request_dir),
            "responseDir": str(self.response_dir),
            "consoleFile": str(self.console_path),
            "running": running,
            "lastHeartbeatUnix": heartbeat,
            "lastHeartbeatAgeSec": age_sec,
            "state": state,
            "warnings": warnings,
        }

    def send_command(self, command: str, args: dict[str, Any] | None = None, *, timeout_sec: int | None = None) -> dict[str, Any]:
        timeout = int(timeout_sec or DEFAULT_BRIDGE_TIMEOUT_SEC)
        self.ensure_runtime_dirs()
        request_id = uuid.uuid4().hex
        request_path = self.request_dir / f"{request_id}.json"
        response_path = self.response_dir / f"{request_id}.json"
        payload = {
            "requestId": request_id,
            "command": command,
            "args": args or {},
            "createdAtUnix": time.time(),
        }
        temp_path = request_path.with_suffix(".json.tmp")
        temp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temp_path.replace(request_path)

        deadline = time.time() + timeout
        while time.time() < deadline:
            if response_path.is_file():
                response = load_json_file(response_path)
                response_path.unlink(missing_ok=True)
                return response
            time.sleep(REQUEST_POLL_INTERVAL_SEC)

        health = self.bridge_health()
        raise BridgeError(
            "BRIDGE_TIMEOUT",
            f"Godot editor bridge timed out waiting for {command}",
            {
                "command": command,
                "requestId": request_id,
                "stateFile": str(self.state_path),
                "running": health.get("running"),
                "warnings": health.get("warnings"),
            },
        )

    def read_console_entries(self, count: int = 50, filter_text: str | None = None) -> list[dict[str, Any]]:
        if not self.console_path.is_file():
            return []
        entries: list[dict[str, Any]] = []
        for line in self.console_path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            try:
                payload = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if not isinstance(payload, dict):
                continue
            entries.append(payload)
        if filter_text:
            token = filter_text.lower()
            entries = [entry for entry in entries if token in json.dumps(entry, ensure_ascii=False).lower()]
        return entries[-max(int(count or 50), 1):]

    def clear_console(self) -> None:
        self.console_path.parent.mkdir(parents=True, exist_ok=True)
        self.console_path.write_text("", encoding="utf-8")


class GodotBridge:
    def __init__(self, default_project_dir: str | None = None, profile: str | None = None, capabilities_path: Path | None = None):
        self._config = load_config(capabilities_path or CAPABILITIES_PATH)
        self.supported_protocol_versions = list(self._config["protocolVersions"])
        self.profile = profile or self._config["defaultProfile"]
        if self.profile not in self._config["profiles"]:
            raise BridgeError(
                "INVALID_PROFILE",
                f"Unknown MCP profile: {self.profile}",
                {"supported": sorted(self._config["profiles"].keys())},
            )
        self.engine = "godot"
        self.default_project_dir = str(Path(default_project_dir).resolve()) if default_project_dir else None
        self.server_name = bridge_server_name("godot") or "qq-godot"
        self.instructions = (
            "This bridge exposes typed Godot editor tools backed by the built-in qq Godot editor addon. "
            "Use godot_compile and godot_run_tests for whole-workflow verification, then godot_query, "
            "godot_object, and godot_assets for editor-side inspection and mutation."
        )

    def list_tools(self) -> list[dict[str, Any]]:
        tool_names = self._config["profiles"][self.profile]
        tools: list[dict[str, Any]] = []
        for tool_name in tool_names:
            base = dict(TOOL_DEFINITIONS[tool_name])
            base["name"] = tool_name
            base["annotations"] = self._config["toolAnnotations"].get(tool_name, {})
            tools.append(base)
        return tools

    def tool_result(self, structured: dict[str, Any], is_error: bool | None = None) -> dict[str, Any]:
        return build_tool_result(structured, default_message="Godot bridge operation completed", is_error=is_error)

    def call_tool(self, tool_name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        args = arguments or {}
        if tool_name not in {tool["name"] for tool in self.list_tools()}:
            raise BridgeError("UNKNOWN_TOOL", f"Unknown tool: {tool_name}")
        if tool_name == "godot_health":
            return self.health(args.get("project_dir"))
        if tool_name == "godot_doctor":
            return self.doctor(args.get("project_dir"))
        if tool_name == "godot_compile":
            return self.compile(args)
        if tool_name == "godot_run_tests":
            return self.run_tests(args)
        if tool_name == "godot_console":
            return self.console(args)
        if tool_name == "godot_editor":
            return self.action_tool(args, EDITOR_ACTIONS, "godot_editor")
        if tool_name == "godot_query":
            return self.action_tool(args, QUERY_ACTIONS, "godot_query")
        if tool_name == "godot_object":
            return self.action_tool(args, OBJECT_ACTIONS, "godot_object")
        if tool_name == "godot_assets":
            return self.action_tool(args, ASSET_ACTIONS, "godot_assets")
        if tool_name == "godot_batch":
            return self.batch(args)
        if tool_name == "godot_raw_command":
            return self.raw_command(args)
        raise BridgeError("UNKNOWN_TOOL", f"Unsupported tool handler: {tool_name}")

    def resolve_project(self, project_dir: str | None = None) -> Path:
        candidate = None
        if project_dir:
            candidate = Path(project_dir).expanduser()
        elif self.default_project_dir:
            candidate = Path(self.default_project_dir).expanduser()
        elif os.environ.get("QQ_PROJECT_DIR"):
            candidate = Path(os.environ["QQ_PROJECT_DIR"]).expanduser()
        elif os.environ.get("GODOT_PROJECT_DIR"):
            candidate = Path(os.environ["GODOT_PROJECT_DIR"]).expanduser()
        else:
            candidate = Path.cwd()
        resolved = candidate.resolve()
        if resolve_project_engine(resolved) != "godot":
            raise BridgeError("PROJECT_NOT_FOUND", f"Not a Godot project: {resolved}", {"required": "project.godot"})
        return resolved

    def queue_client(self, project_dir: str | None = None) -> GodotQueueClient:
        return GodotQueueClient(self.resolve_project(project_dir))

    def has_project_fast_path(self, project_dir: Path) -> bool:
        required = [
            project_dir / "scripts" / "qq-compile.sh",
            project_dir / "scripts" / "qq-test.sh",
            project_dir / "scripts" / "qq-doctor.py",
            project_dir / "scripts" / "qq-project-state.py",
            project_dir / "scripts" / "qq-policy-check.sh",
            project_dir / "scripts" / "qq_mcp.py",
        ]
        return all(path.is_file() for path in required)

    def health(self, project_dir: str | None = None) -> dict[str, Any]:
        resolved = self.resolve_project(project_dir)
        client = GodotQueueClient(resolved)
        bridge_health = client.bridge_health()
        qq_scripts_available = self.has_project_fast_path(resolved)
        warnings = list(bridge_health["warnings"])
        if not qq_scripts_available:
            warnings.append("qq fast-path scripts are not installed in this project")
        payload = {
            "ok": qq_scripts_available and bool(bridge_health["addonInstalled"]) and bool(bridge_health["pluginConfigured"]) and bool(bridge_health["running"]),
            "category": "OK" if bridge_health["running"] else "GODOT_BRIDGE_UNAVAILABLE",
            "message": "Godot editor bridge reachable" if bridge_health["running"] else "Godot editor bridge not reachable",
            "project_dir": str(resolved),
            "backend": "qq-godot-editor" if bridge_health["running"] else "unavailable",
            "engine": "godot",
            "engineName": str(engine_metadata("godot").get("displayName") or "Godot"),
            "qq_scripts_available": qq_scripts_available,
            "addon_installed": bridge_health["addonInstalled"],
            "plugin_configured": bridge_health["pluginConfigured"],
            "editor_running": bridge_health["running"],
            "bridge_state_file": bridge_health["stateFile"],
            "request_dir": bridge_health["requestDir"],
            "response_dir": bridge_health["responseDir"],
            "console_file": bridge_health["consoleFile"],
            "last_heartbeat_unix": bridge_health["lastHeartbeatUnix"],
            "last_heartbeat_age_sec": bridge_health["lastHeartbeatAgeSec"],
            "command_count": len(EDITOR_ACTIONS) + len(QUERY_ACTIONS) + len(OBJECT_ACTIONS) + len(ASSET_ACTIONS),
            "warnings": unique_strings(warnings),
        }
        return payload

    def doctor(self, project_dir: str | None = None) -> dict[str, Any]:
        resolved = self.resolve_project(project_dir)
        health = self.health(str(resolved))
        command = ["python3", str(resolved / "scripts" / "qq-doctor.py"), "--project", str(resolved)]
        result = run_command(command, cwd=resolved)
        if result.returncode != 0:
            raise BridgeError("DOCTOR_FAILED", result.stderr.strip() or result.stdout.strip() or "qq-doctor failed")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise BridgeError("DOCTOR_FAILED", "qq-doctor returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise BridgeError("DOCTOR_FAILED", "qq-doctor returned a non-object payload")
        warnings = unique_strings(list(payload.get("warnings") or []) + list(health.get("warnings") or []))
        payload["health"] = health
        payload["warnings"] = warnings
        payload["ok"] = bool(payload.get("ok")) and bool(health.get("ok"))
        if health.get("ok"):
            payload["message"] = "qq direct path and Godot editor bridge are ready"
        else:
            payload["message"] = "qq routing is installed, but the Godot editor bridge is not fully ready"
        return payload

    def compile(self, args: dict[str, Any]) -> dict[str, Any]:
        project_dir = self.resolve_project(args.get("project_dir"))
        timeout_sec = int(args.get("timeout_sec") or 0) or None
        mode = str(args.get("mode") or "").strip().lower()
        command = ["bash", str(project_dir / "scripts" / "qq-compile.sh"), "--project", str(project_dir)]
        if timeout_sec:
            command.extend(["--timeout", str(timeout_sec)])
        if mode == "editor":
            command.append("--editor")
        elif mode == "batch":
            command.append("--batch")
        result = run_command(command, cwd=project_dir, timeout_sec=timeout_sec)
        record = latest_stage_record(project_dir, "compile")
        status = normalize_run_status(record.get("status"), result.returncode)
        summary = str(record.get("summary") or result.stderr.strip() or result.stdout.strip() or "Compile finished")
        return {
            "ok": status in {"passed", "warning"},
            "state": status,
            "message": summary,
            "engine": "godot",
            "project_dir": str(project_dir),
            "backend": str(record.get("backend") or ""),
            "transport": str(record.get("transport") or ""),
            "failureCategory": str(record.get("failure_category") or ""),
            "recordPath": str(record.get("record_path") or ""),
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exitCode": result.returncode,
        }

    def run_tests(self, args: dict[str, Any]) -> dict[str, Any]:
        project_dir = self.resolve_project(args.get("project_dir"))
        timeout_sec = int(args.get("timeout_sec") or 0) or None
        mode = str(args.get("mode") or "").strip()
        filter_value = str(args.get("filter") or "").strip()
        assembly_names = args.get("assembly_names") or []
        command = ["bash", str(project_dir / "scripts" / "qq-test.sh")]
        if mode:
            command.append(mode)
        command.extend(["--project", str(project_dir)])
        if filter_value:
            command.extend(["--filter", filter_value])
        if isinstance(assembly_names, list) and assembly_names:
            command.extend(["--assembly", ";".join(str(item) for item in assembly_names if str(item))])
        if timeout_sec:
            command.extend(["--timeout", str(timeout_sec)])
        result = run_command(command, cwd=project_dir, timeout_sec=timeout_sec)
        record = latest_stage_record(project_dir, "test")
        status = normalize_run_status(record.get("status"), result.returncode)
        summary = str(record.get("summary") or result.stderr.strip() or result.stdout.strip() or "Test run finished")
        return {
            "ok": status in {"passed", "warning"},
            "state": status,
            "message": summary,
            "engine": "godot",
            "project_dir": str(project_dir),
            "backend": str(record.get("backend") or ""),
            "transport": str(record.get("transport") or ""),
            "failureCategory": str(record.get("failure_category") or ""),
            "recordPath": str(record.get("record_path") or ""),
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exitCode": result.returncode,
        }

    def console(self, args: dict[str, Any]) -> dict[str, Any]:
        action = str(args.get("action") or "").strip()
        if action not in {"get", "clear"}:
            raise BridgeError("INVALID_ARGUMENT", "godot_console.action must be 'get' or 'clear'")
        client = self.queue_client(args.get("project_dir"))
        if action == "get":
            entries = client.read_console_entries(int(args.get("count") or 50), str(args.get("filter") or "").strip() or None)
            return {
                "ok": True,
                "action": action,
                "message": f"Retrieved {len(entries)} bridge console entries",
                "entries": entries,
            }
        client.clear_console()
        return {
            "ok": True,
            "action": action,
            "message": "Cleared Godot bridge console entries",
            "entries": [],
        }

    def action_tool(self, args: dict[str, Any], mapping: dict[str, str], tool_name: str) -> dict[str, Any]:
        action = str(args.get("action") or "").strip()
        if action not in mapping:
            raise BridgeError("INVALID_ARGUMENT", f"{tool_name}.action is invalid", {"supported": sorted(mapping)})
        timeout_sec = int(args.get("timeout_sec") or 0) or None
        client = self.queue_client(args.get("project_dir"))
        command_args = {
            key: value
            for key, value in args.items()
            if key not in {"project_dir", "action", "timeout_sec"} and value is not None
        }
        response = client.send_command(mapping[action], command_args, timeout_sec=timeout_sec)
        return {
            "ok": bool(response.get("ok")),
            "action": action,
            "message": str(response.get("message") or f"{tool_name} action completed"),
            "response": response.get("data"),
            "category": str(response.get("category") or ""),
        }

    def batch(self, args: dict[str, Any]) -> dict[str, Any]:
        operations = args.get("operations")
        if not isinstance(operations, list) or not operations:
            raise BridgeError("INVALID_ARGUMENT", "godot_batch.operations must be a non-empty array")

        results: list[dict[str, Any]] = []
        any_errors = False
        available_tools = {tool["name"] for tool in self.list_tools()}
        for index, operation in enumerate(operations):
            if not isinstance(operation, dict):
                results.append({"ok": False, "index": index, "message": "Operation must be an object"})
                any_errors = True
                continue
            tool_name = operation.get("tool")
            if tool_name == "godot_batch":
                results.append({"ok": False, "index": index, "message": "godot_batch cannot recursively call itself"})
                any_errors = True
                continue
            if tool_name not in available_tools:
                results.append({"ok": False, "index": index, "message": f"Tool not exposed in current profile: {tool_name}"})
                any_errors = True
                continue
            try:
                result = self.call_tool(str(tool_name), operation.get("arguments") or {})
                results.append({"index": index, "tool": tool_name, "result": result})
                any_errors = any_errors or not bool(result.get("ok", False))
            except BridgeError as exc:
                any_errors = True
                results.append({"index": index, "tool": tool_name, "result": exc.to_result()})

        return {
            "ok": not any_errors,
            "message": f"Executed {len(results)} batch operation(s)",
            "results": results,
        }

    def raw_command(self, args: dict[str, Any]) -> dict[str, Any]:
        command = str(args.get("command") or "").strip()
        if not command:
            raise BridgeError("INVALID_ARGUMENT", "godot_raw_command.command is required")
        timeout_sec = int(args.get("timeout_sec") or 0) or None
        raw_args = args.get("args") or {}
        if not isinstance(raw_args, dict):
            raise BridgeError("INVALID_ARGUMENT", "godot_raw_command.args must be an object")
        client = self.queue_client(args.get("project_dir"))
        response = client.send_command(command, raw_args, timeout_sec=timeout_sec)
        return {
            "ok": bool(response.get("ok")),
            "command": command,
            "message": str(response.get("message") or f"Executed raw command: {command}"),
            "response": response.get("data"),
            "category": str(response.get("category") or ""),
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="Godot bridge helper")
    parser.add_argument("--project", help="Godot project root")
    parser.add_argument("--profile", choices=["standard", "full"], help="Tool profile to expose")
    parser.add_argument("--doctor", action="store_true", help="Print doctor diagnostics for the target project")
    parser.add_argument("--health", action="store_true", help="Print health diagnostics for the target project")
    parser.add_argument("--tool", choices=sorted(TOOL_DEFINITIONS), help="Call one bridge tool directly")
    parser.add_argument("--arguments", help="JSON object passed to --tool")
    args = parser.parse_args()

    try:
        bridge = GodotBridge(
            default_project_dir=args.project or os.environ.get("QQ_PROJECT_DIR") or os.environ.get("GODOT_PROJECT_DIR"),
            profile=args.profile,
        )
        if args.doctor:
            print(pretty_json(bridge.doctor(args.project)))
            return 0
        if args.health:
            print(pretty_json(bridge.health(args.project)))
            return 0
        if args.tool:
            payload = {}
            if args.arguments:
                try:
                    payload = json.loads(args.arguments)
                except json.JSONDecodeError as exc:
                    raise BridgeError("INVALID_ARGUMENT", "--arguments must be valid JSON") from exc
                if not isinstance(payload, dict):
                    raise BridgeError("INVALID_ARGUMENT", "--arguments must decode to an object")
            print(pretty_json(bridge.call_tool(args.tool, payload)))
            return 0
        parser.print_help()
        return 0
    except BridgeError as exc:
        sys.stderr.write(f"{exc.category}: {exc.message}\n")
        if exc.details:
            sys.stderr.write(pretty_json(exc.details) + "\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
